# Schedule + Session Sync — implementation plan

**Date:** 2026-04-26
**Author:** Pivot suite agent (overnight session)
**Status:** Spec ready for review. NOT implemented.
**Companion docs:**
- [`cross-repo-puck-pivot-2026-04-26.md`](../../cross-repo-puck-pivot-2026-04-26.md) — overnight SSoT
- [`cross-repo-partner-sync-investigation-2026-04-26.md`](../../cross-repo-partner-sync-investigation-2026-04-26.md) — the architectural pattern this spec builds on

---

## Goals

Two paired features that share infrastructure, hence one spec:

1. **iOS Schedule view** — replace the "Schedule — coming soon" placeholder (commit `28a9f87` on `feat/home-restructure`) with a real schedule view that mirrors the macOS schedule. Same blocks, same titles, same intent text, same colors. Initially read-only on iOS; later, edit-on-iOS that writes back.

2. **Cross-device active session indicator** — a single source of truth for "is a focus session currently running on any device on this account?" so the iOS Home shows "▶ Deep Work · 23 min remaining" when the user is in a session on Mac (or vice-versa). The other agent shipped a local-only indicator on `feat/active-session-indicator` (commit `8325ba1`). This phase makes it cross-device.

Both ride the **same account-scoped sync infrastructure** the partner-sync fix establishes (commit `7491228` on backend, commit `90f3100` on `feat/partner-link-account` on iOS). Once iOS devices link their legacy device row to an account, every account-scoped backend endpoint becomes addressable from iOS.

## Non-goals

- **iOS as the editor of record for the schedule.** Mac stays authoritative this phase. iOS reads, displays, and (later phase) edits with optimistic-local + last-write-wins. Drag-to-edit in the iOS UI is a follow-up, not in this spec.
- **Real-time push.** Session sync uses the existing `/focus/*` WebSocket relay, which is ~1s latency. Schedule sync uses HTTP poll on tab-open + on app-foreground. No push for schedule blocks in this phase.
- **Historical schedule replay.** Today + tomorrow only. Past blocks live as `FocusSession` records (already synced). Future weeks are not in scope.
- **Conflict resolution UI.** Server is authoritative. If iOS and Mac edit the same block at the same time, last-write-wins, no merge UI. Both clients re-fetch on reconnect.

---

## Data model

### Macros recap (existing, no change)

`ScheduleManager.FocusBlock` on macOS (`Intentional/ScheduleManager.swift:18`):

| Field | Type | Notes |
|---|---|---|
| `id` | String (UUID) | Stable across devices |
| `title` | String | |
| `description` | String | Used by AI relevance scorer |
| `startHour` / `startMinute` | Int | 0-23, 0-59. Local clock. |
| `endHour` / `endMinute` | Int | 0-23, 0-59. Local clock. |
| `blockType` | enum: `deepWork`, `focusHours`, `freeTime` | |
| `ignoreProfile` | Bool | Scorer hint |

This model is *per-day* and stored locally on Mac as a JSON file per date (per `ScheduleManager` persistence). The schedule for "today" is one array of these.

### New backend table: `schedule_blocks`

| Column | Type | Notes |
|---|---|---|
| `id` | UUID PK | |
| `account_id` | UUID FK → `accounts.id` | Account-scoped, NOT device-scoped |
| `block_id` | String | Mirrors the client-side UUID; used for upsert across devices |
| `block_date` | Date | The calendar date this block applies to. Drives queries like "today's blocks" |
| `title` | String | |
| `description` | String | nullable |
| `start_hour` / `start_minute` | int2 | |
| `end_hour` / `end_minute` | int2 | |
| `block_type` | enum or text-with-check | `deepWork` / `focusHours` / `freeTime` |
| `ignore_profile` | bool | default false |
| `client_updated_at` | timestamptz | The originating device's clock when the block was last edited. Used for last-write-wins. |
| `created_at` | timestamptz | server clock |
| `updated_at` | timestamptz | server clock |

**Unique constraint**: `(account_id, block_id)` — same block_id across devices means it's the same block (last-write-wins).

**Index**: `(account_id, block_date)` for the today/tomorrow read query.

### Migration

`migrations/006_add_schedule_blocks.sql`:

```sql
CREATE TABLE schedule_blocks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  block_id TEXT NOT NULL,
  block_date DATE NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  description TEXT NOT NULL DEFAULT '',
  start_hour SMALLINT NOT NULL CHECK (start_hour BETWEEN 0 AND 23),
  start_minute SMALLINT NOT NULL CHECK (start_minute BETWEEN 0 AND 59),
  end_hour SMALLINT NOT NULL CHECK (end_hour BETWEEN 0 AND 23),
  end_minute SMALLINT NOT NULL CHECK (end_minute BETWEEN 0 AND 59),
  block_type TEXT NOT NULL CHECK (block_type IN ('deepWork', 'focusHours', 'freeTime')),
  ignore_profile BOOLEAN NOT NULL DEFAULT false,
  client_updated_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, block_id)
);

CREATE INDEX idx_schedule_blocks_account_date
  ON schedule_blocks(account_id, block_date);
```

### Existing tables we lean on (no schema change)

- **`focus_sessions`** — already exists with `account_id`, `started_at`, `ended_at`, `status`, `triggered_by`. The Mac writes here on block start/end. Already broadcast over the `/focus/*` WebSocket relay.
- **`registered_devices`** — already maps account_id ↔ device_type (mac/ios) ↔ device_name. Used for "which devices are running this session." May want to add `current_block_id` so a Mac in deep work can advertise *which* block (not just "active"), but defer until we see the iOS UI design.

---

## Backend endpoints

### Schedule sync (NEW)

| Method | Path | Auth | Purpose |
|---|---|---|---|
| `GET` | `/schedule?date=YYYY-MM-DD` | Bearer | Get all blocks for a date for the account. Date defaults to today (UTC) if omitted. |
| `PUT` | `/schedule` | Bearer | Upsert one or more blocks. Body: `{ blocks: [<FullBlock>...] }`. Server takes per-block last-write-wins via `client_updated_at`. |
| `DELETE` | `/schedule/{block_id}` | Bearer | Delete a block. Idempotent. |

Pydantic models follow the existing `models.py` pattern:

```python
class ScheduleBlock(BaseModel):
    block_id: str
    block_date: str  # ISO date YYYY-MM-DD
    title: str = ""
    description: str = ""
    start_hour: int = Field(..., ge=0, le=23)
    start_minute: int = Field(..., ge=0, le=59)
    end_hour: int = Field(..., ge=0, le=23)
    end_minute: int = Field(..., ge=0, le=59)
    block_type: str = Field(..., pattern="^(deepWork|focusHours|freeTime)$")
    ignore_profile: bool = False
    client_updated_at: datetime  # ISO 8601 from the originating client

class ScheduleSyncRequest(BaseModel):
    blocks: list[ScheduleBlock]

class ScheduleListResponse(BaseModel):
    success: bool
    date: str
    blocks: list[ScheduleBlock]
```

**Last-write-wins logic**: on `PUT`, for each block, compare `incoming.client_updated_at` vs the row's stored `client_updated_at`. Skip writes where incoming is older. This handles the case where iOS edits an old version of a block while offline and Mac has since edited it — Mac wins.

### Active session broadcast (extend existing)

The existing `broadcast_focus_signal()` (`main.py:2834`) sends JSON to all `/focus/*` WebSocket clients on an account. Today it's just `{type: "focus_started" | "focus_stopped"}`. Extend the payload with the block context so the iOS active-session card can render rich info:

```json
{
  "type": "session_state",
  "is_active": true,
  "session_id": "uuid",
  "started_at": "2026-04-26T10:00:00Z",
  "scheduled_seconds": 5400,
  "block": {
    "id": "block-uuid",
    "title": "Deep Work — finalize Q2 roadmap",
    "description": "",
    "block_type": "deepWork",
    "start_hour": 10,
    "start_minute": 0,
    "end_hour": 11,
    "end_minute": 30
  },
  "device": {
    "device_type": "mac",
    "device_name": "Ameer's MacBook Pro"
  }
}
```

When idle: `{type: "session_state", "is_active": false}`.

The Mac's call to `IntentionalFocusSignalClient.shared.toggleFocus(action: .start)` (already exists, see `Intentional/FocusWebSocketClient.swift`) is enriched with the block context. Same for `.stop`.

### New: pull current state on connect

For iOS to render the right state on first WebSocket connect (vs waiting for the next event), add `GET /focus/state` (Bearer):

```python
@app.get("/focus/state", response_model=SessionStateResponse)
async def get_focus_state(authorization: str = Header(...)):
    """Return the current session_state payload — same shape as the WebSocket event."""
    account_id = await _resolve_account_from_token(authorization)
    # Look up active focus_sessions row for this account
    # Join with most recent schedule_blocks row matching the session start time
    # Return the same payload structure as broadcast_focus_signal sends
```

iOS calls this immediately on app foreground + on WebSocket reconnect, so the active-session card hydrates before the next websocket event.

---

## iOS implementation

### Phase B.1: Schedule API client

`Puck/Core/Network/IntentionalAPIClient.swift` — add `// MARK: - Schedule API` extension:

```swift
extension IntentionalAPIClient {
    struct ScheduleBlock: Codable, Identifiable {
        let blockId: String
        let blockDate: String  // YYYY-MM-DD
        let title: String
        let description: String
        let startHour: Int
        let startMinute: Int
        let endHour: Int
        let endMinute: Int
        let blockType: String
        let ignoreProfile: Bool
        let clientUpdatedAt: Date

        var id: String { blockId }

        enum CodingKeys: String, CodingKey {
            case blockId = "block_id"
            case blockDate = "block_date"
            case title, description
            case startHour = "start_hour"
            case startMinute = "start_minute"
            case endHour = "end_hour"
            case endMinute = "end_minute"
            case blockType = "block_type"
            case ignoreProfile = "ignore_profile"
            case clientUpdatedAt = "client_updated_at"
        }
    }

    struct ScheduleListResponseBody: Codable {
        let success: Bool
        let date: String
        let blocks: [ScheduleBlock]
    }

    func getSchedule(date: Date = Date()) async throws -> [ScheduleBlock] {
        let dateString = ISO8601DateFormatter.dayOnly.string(from: date)
        let resp: ScheduleListResponseBody = try await get(
            path: "schedule?date=\(dateString)",
            auth: .bearer
        )
        return resp.blocks
    }

    // PUT and DELETE wrappers — symmetric. Defer until edit-from-iOS phase.
}
```

### Phase B.2: ScheduleStore (iOS)

`Puck/Core/Schedule/ScheduleStore.swift` (new):

```swift
@MainActor
final class ScheduleStore: ObservableObject {
    static let shared = ScheduleStore()
    @Published private(set) var todayBlocks: [IntentionalAPIClient.ScheduleBlock] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: Error?

    func refresh() async {
        guard AuthService.shared.accessToken != nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            todayBlocks = try await IntentionalAPIClient.shared.getSchedule()
            lastError = nil
        } catch {
            lastError = error
            AppLogger.coordinatorError("ScheduleStore.refresh failed", errorObj: error)
        }
    }
}
```

Trigger refresh from:
- App foreground (`scenePhase == .active`)
- Schedule tab `.task { await ScheduleStore.shared.refresh() }`
- After Supabase login (`AuthService.triggerPostAuthBackendCalls`)

### Phase B.3: ScheduleView (iOS)

Replace `Puck/Views/Routine/RoutineView.swift` body. Tab is currently `case routine` in `PuckTab`; consider renaming to `case schedule` in a separate small commit to make naming consistent.

Layout:
```
┌────────────────────────────────────────┐
│ Schedule                          [⟳]  │   ← page title + refresh button
│ Today, Apr 26                          │
├────────────────────────────────────────┤
│  Now bar (current time line)           │
│                                        │
│  10:00–11:30  ▌ Deep Work              │
│               ▌ Finalize Q2 roadmap    │
│               ▌                        │
│  11:30–12:00  ▌ Break                  │
│  12:00–13:30  ▌ Focus Hours            │
│               ▌ Slack catch-up         │
│  ...                                   │
│                                        │
│  [+ Add a block]   ← future phase      │
└────────────────────────────────────────┘
```

Block colors: map `block_type` → `DesignTokens.Mode.deep / focus / freeTime` colors. Each block is a `Button` that shows a detail sheet (read-only this phase: title, description, start, end, type).

Empty state: "No blocks scheduled yet. Open Intentional on your Mac to plan your day." (single-source-of-truth language until iOS gets edit support.)

### Phase C.1: Cross-device active session card

The other agent's `feat/active-session-indicator` (`8325ba1`) added a local "No active session" / "▶ <mode> · X min remaining" card on the iOS home, fed by `BlockingService.blockingState`. To extend it cross-device:

1. New `Puck/Core/Focus/FocusStateService.swift`:

```swift
@MainActor
final class FocusStateService: ObservableObject {
    static let shared = FocusStateService()

    @Published private(set) var remoteSessionState: RemoteSessionState?

    struct RemoteSessionState: Codable, Equatable {
        let isActive: Bool
        let sessionId: String?
        let startedAt: Date?
        let scheduledSeconds: Int?
        let block: BlockSummary?
        let device: DeviceSummary?
    }

    /// Hydrate from /focus/state on app foreground + on websocket reconnect.
    func refresh() async { /* GET /focus/state */ }

    /// Subscribe to /focus/* websocket events. Reuses existing
    /// IntentionalFocusSignalClient socket if connected, else opens one.
    func startListening() { /* websocket consumer */ }
}
```

2. `HomeView` (other agent owns; coordinate) — feed the existing session card from `FocusStateService.remoteSessionState` whenever it's set, falling back to local `blockingService.blockingState` when no remote signal. Show "On your Mac · Deep Work · 23 min" when the active session is on a different device.

3. `IntentionalFocusSignalClient` (existing) — extend the websocket message parser to recognize the new `session_state` payload shape and forward to `FocusStateService`. The existing `toggleFocus` writer becomes the writer side for the iOS half (already wired in `PuckCoordinator.activateMode` → `IntentionalFocusSignalClient.shared.toggleFocus(action: .start)`).

---

## macOS implementation

Mac is the authoritative editor for the schedule this phase, so the only new work is "push to backend."

### Phase B.M.1: Push schedule on every change

`ScheduleManager` already has the schedule in memory and persists to disk on edit. Add a backend write right after the disk write:

```swift
// After existing self.persist() in ScheduleManager.updateBlock / addBlock / removeBlock:
Task { await BackendClient.shared.pushSchedule(blocks: blocks, date: today) }
```

`BackendClient.pushSchedule` calls `PUT /schedule`. Use existing Bearer-auth path.

On macOS app launch, also call `GET /schedule` to pull latest from backend if it's newer than the local disk version (so a Mac that was offline picks up edits made on iOS — once iOS edit support lands).

### Phase C.M.1: Enrich session broadcast with block context

`FocusWebSocketClient.swift` already sends focus signals. Currently the payload is bare. Add the active block info:

```swift
// In ScheduleManager.onBlockChanged callback wiring (AppDelegate.swift around line 16):
focusWebSocketClient.broadcast(.sessionState(
    isActive: block != nil,
    block: block,
    startedAt: state == .active ? Date() : nil,
    scheduledSeconds: block?.durationSeconds
))
```

Backend's `broadcast_focus_signal` already exists; just feed it richer payloads.

---

## Phasing — what ships first

**Phase B (Schedule sync)** — can ship without C.

1. Backend migration + endpoints (small, ~150 LOC).
2. Mac push (smallest macOS change — one new BackendClient method + 3-line wire-up).
3. iOS pull + ScheduleView (largest single piece, ~300 LOC).

Schedule view goes live: iOS reads from backend, shows today's blocks, no editing.

**Phase C (Cross-device session sync)** — depends on B's account-scoping but not its endpoints.

1. Backend extension to `broadcast_focus_signal` + new `GET /focus/state` (~50 LOC).
2. Mac enriches signal payload (~20 LOC).
3. iOS `FocusStateService` + Home card wiring (coordinate with the other agent on `feat/active-session-indicator`) (~150 LOC).

Active session card goes live cross-device.

**Phase D (iOS editing of schedule)** — explicitly out of scope for this spec. Sequence:

1. Add edit/create/delete UI to iOS ScheduleView.
2. Wire to `PUT /schedule` and `DELETE /schedule/{block_id}`.
3. Mac picks up changes via existing pull-on-launch + a new pull-on-foreground.
4. Conflict UX: simple "schedule changed on another device — refreshed" toast on local stale-read.

Defer until B and C are stable.

---

## Testing strategy

**Backend:**
- Unit-test `ScheduleSyncRequest` with mixed last-write-wins scenarios. New file: `tests/test_schedule.py`.
- Existing 34-test suite stays green (additive endpoints only).

**iOS:**
- No unit tests in puck-ios for HTTP layer; smoke test only:
  1. Set up a schedule on Mac with three blocks.
  2. Sign in on iOS, open Schedule tab. Three blocks should appear.
  3. Edit one block on Mac, return to iOS Schedule tab. Pulled refresh should show the new state.
  4. Start a Deep Work block on Mac. iOS Home shows "▶ On your Mac · Deep Work · 25 min remaining" within 2s.
  5. Stop the session on Mac. iOS Home shows "No active session" within 2s.

**macOS:**
- Existing schedule tests stay green.
- Manual smoke: edit block, observe `PUT /schedule` in network log.

---

## Risks & open questions

1. **Block UUIDs need to be the same string across devices.** Mac generates UUIDs as `String(format: ...)` UUIDs; iOS-side new blocks (when iOS edit support lands) must use the same format. Document and enforce in `ScheduleBlock.id` factory.

2. **Time zones.** Block times are local-clock (startHour/Minute). If the user moves time zones, blocks "shift." Mac currently treats blocks as local-clock-anchored — keep that behavior for now and document. iOS displays in device-local time same way. Out-of-scope: per-block time zone storage.

3. **WebSocket reliability on iOS.** iOS suspends sockets aggressively when backgrounded. Plan: on `scenePhase == .active`, always call `GET /focus/state` AND reconnect the websocket. Don't rely on the socket to stay alive across backgrounding.

4. **What about extension's lock state?** Mac extension can also start enforcement-related state changes. Out of scope for this phase — extension state stays per-device, only Mac app sessions broadcast.

5. **ScheduleManager on Mac uses local JSON-per-day persistence**, which is the source of truth currently. After this phase, backend becomes the source of truth — local JSON becomes a read-through cache. Plan migration: on first run with this code, push existing local schedules to backend (idempotent via block_id), then trust backend on subsequent reads.

6. **Account-not-linked devices** can't sync. The partner-sync work added `/devices/link-legacy` which iOS calls after Supabase login (commit `90f3100`). Schedule sync also requires this link. If iOS legacy device row hasn't been linked, `GET /schedule` will 401 (no Bearer-resolvable account → wait, Bearer auth doesn't need the legacy link, it's the X-Device-ID endpoints that do). Actually schedule sync uses Bearer, so it'll work as soon as Supabase auth succeeds. Good — schedule sync has fewer prerequisites than partner sync.

7. **Push notifications for "your accountability partner just stopped a session"?** Out of scope. Logging activity for partner is already covered by the existing partner email infrastructure; live push is a separate piece.

---

## Estimated effort (rough)

- Phase B backend: 2-3 hours
- Phase B Mac push: 30 min
- Phase B iOS read + UI: 3-4 hours (ScheduleView is the largest piece)
- Phase C backend extension: 1 hour
- Phase C Mac signal enrich: 30 min
- Phase C iOS FocusStateService + Home wire: 2-3 hours

**Total: ~10-12 focused hours of implementation.** Well within a day for a single agent.

---

## What this enables

After Phases B and C ship:

- A user signs in on iPhone, opens the Schedule tab, and sees the same week they planned on their Mac.
- They start a Deep Work session on Mac, glance at their phone, and see "▶ On your Mac · Deep Work · 38 min" without having to do anything.
- They tap a synced-from-Mac mode on their iPhone NFC puck (after the partner-sync + distractions-guard work on `feat/distractions-guard` is also merged), and either it activates or shows the "no apps configured — start anyway?" prompt — never silently no-ops.

The combined experience after these phases land + the partner-sync fix + the distractions guard is: **iOS becomes a real second device for Intentional, not a parallel app that happens to share branding.**

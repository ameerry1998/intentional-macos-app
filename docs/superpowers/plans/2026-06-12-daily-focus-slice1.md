# Daily Focus Slice 1 — Session Model Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sessions become floor-not-box objects with clean end semantics; typed coach-card text creates a today-only Daily Focus, never a Weekly Goal; the pill counts a real floor then counts up; restart-safe; killable. (Spec: `docs/superpowers/specs/2026-06-12-daily-focus-and-coach-powers-design.md` §CONVERGED BEHAVIOR C1–C4, C7.)

**Architecture:** Mac is source of truth for the live session (`FocusModeController.Period` gains floor/label/dailyFocusId, persisted v3). The synthetic 23:59 block stays ONLY as an enforcement shim — the pill stops reading block end entirely and renders the Period. Backend gains a `daily_focus` table + columns on `focus_sessions`; Mac syncs best-effort (everything works offline). Coach card v2 routes: tap-goal → linked DailyFocus; typed → unlinked DailyFocus; 🤷 → 10-min sort-it-out session. NOTHING creates an Intention.

**Tech Stack:** Swift/AppKit (Mac), FastAPI + Supabase (backend), XCTest files per repo convention (no wired test target — build must compile them; behavior verified live per verifier-intentional-gui), pytest with mocked Supabase for backend.

**Blocking dependency:** migration 032 must be applied by Ameer in the Supabase SQL editor (same as 029–031). All Mac behavior degrades gracefully until then (daily-focus sync is fire-and-forget).

---

## Task 1: Backend migration 032 (daily_focus + focus_sessions columns)

**Files:**
- Create: `/Users/arayan/Documents/GitHub/intentional-backend/migrations/032_daily_focus.sql`

- [ ] **Step 1: Write the migration**

```sql
-- 032_daily_focus.sql — APPLY MANUALLY IN SUPABASE (SQL editor)
-- Daily Focus: today-scoped commitment, NOT an Intention/Weekly Goal.
-- Spec: intentional-macos-app/docs/superpowers/specs/2026-06-12-daily-focus-and-coach-powers-design.md §1, §CONVERGED C1/C2

CREATE TABLE IF NOT EXISTS daily_focus (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    local_date DATE NOT NULL,
    title TEXT NOT NULL CHECK (char_length(title) <= 60),
    intent_text TEXT CHECK (char_length(intent_text) <= 140),
    linked_intention_id UUID REFERENCES focus_modes(id) ON DELETE SET NULL,
    created_via TEXT NOT NULL DEFAULT 'coach_card'
        CHECK (created_via IN ('coach_card','today_tab','promoted_from_chat')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','done','expired')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS daily_focus_account_date
    ON daily_focus(account_id, local_date);

ALTER TABLE focus_sessions ADD COLUMN IF NOT EXISTS daily_focus_id UUID
    REFERENCES daily_focus(id) ON DELETE SET NULL;
ALTER TABLE focus_sessions ADD COLUMN IF NOT EXISTS floor_minutes INTEGER;
ALTER TABLE focus_sessions ADD COLUMN IF NOT EXISTS label TEXT;
CREATE INDEX IF NOT EXISTS focus_sessions_daily_focus_idx
    ON focus_sessions(daily_focus_id) WHERE daily_focus_id IS NOT NULL;

ALTER TABLE daily_focus ENABLE ROW LEVEL SECURITY;
-- Service role bypasses RLS; no policies = default-deny direct user access (same as coach tables, 029).
```

Note: `linked_intention_id` references `focus_modes` (the base table — `intentions` is a view post-022; FK must target the table).

- [ ] **Step 2: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
git add migrations/032_daily_focus.sql
git commit -m "feat(db): daily_focus table + focus_sessions floor/label/daily_focus_id (migration 032)"
```

---

## Task 2: Backend models + /daily_focus endpoints + toggle passthrough

**Files:**
- Modify: `/Users/arayan/Documents/GitHub/intentional-backend/models.py` (after CoachOutcomeIn, ~line 996)
- Modify: `/Users/arayan/Documents/GitHub/intentional-backend/main.py` (new endpoints near /intentions ~3584; toggle ~3323; `_create_focus_session` ~3192)
- Test: `/Users/arayan/Documents/GitHub/intentional-backend/tests/test_daily_focus.py`

- [ ] **Step 1: Write failing tests** (pattern: mock Supabase like `tests/test_focus_intention_id.py`; device auth via patched `get_user_by_device_id`)

```python
# tests/test_daily_focus.py
import pytest
from unittest.mock import patch, MagicMock
from fastapi.testclient import TestClient
import main

client = TestClient(main.app)
DEV = {"X-Device-ID": "mac-test-device-0001"}

def _auth(monkeypatch):
    async def fake_user(_): return {"account_id": "acc-1"}
    monkeypatch.setattr(main, "get_user_by_device_id", fake_user)
    monkeypatch.setattr(main, "validate_device_id", lambda _: True)

def test_create_daily_focus(monkeypatch):
    _auth(monkeypatch)
    db = MagicMock()
    db.table.return_value.insert.return_value.execute.return_value.data = [{
        "id": "df-1", "account_id": "acc-1", "local_date": "2026-06-12",
        "title": "Job apps", "intent_text": "Job apps", "linked_intention_id": None,
        "created_via": "coach_card", "status": "active",
        "created_at": "2026-06-12T13:00:00Z", "updated_at": "2026-06-12T13:00:00Z"}]
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = client.post("/daily_focus", headers=DEV, json={
        "local_date": "2026-06-12", "title": "Job apps"})
    assert r.status_code == 200
    assert r.json()["title"] == "Job apps"
    assert r.json()["status"] == "active"

def test_toggle_start_carries_daily_focus(monkeypatch):
    _auth(monkeypatch)
    captured = {}
    async def fake_create(db, account_id, intention_id=None, triggered_by="puck",
                          time_block_id=None, daily_focus_id=None,
                          floor_minutes=None, label=None):
        captured.update(daily_focus_id=daily_focus_id,
                        floor_minutes=floor_minutes, label=label)
        return "sess-1"
    monkeypatch.setattr(main, "_create_focus_session", fake_create)
    monkeypatch.setattr(main, "get_db", lambda: MagicMock())
    r = client.post("/focus/toggle", headers=DEV, json={
        "action": "start", "triggered_by": "mac_manual",
        "daily_focus_id": "df-1", "floor_minutes": 25, "label": "Job apps"})
    assert r.status_code == 200
    assert captured == {"daily_focus_id": "df-1", "floor_minutes": 25, "label": "Job apps"}
```

- [ ] **Step 2: Run, verify both FAIL** — `cd /Users/arayan/Documents/GitHub/intentional-backend && python3 -m pytest tests/test_daily_focus.py -v` → 404 / TypeError.

- [ ] **Step 3: Implement.** models.py:

```python
class DailyFocusCreate(BaseModel):
    local_date: str                      # YYYY-MM-DD (user-local)
    title: str = Field(..., min_length=1, max_length=60)
    intent_text: Optional[str] = Field(None, max_length=140)
    linked_intention_id: Optional[str] = None
    created_via: str = "coach_card"

class DailyFocusOut(BaseModel):
    id: str
    local_date: str
    title: str
    intent_text: Optional[str] = None
    linked_intention_id: Optional[str] = None
    created_via: str
    status: str
```

main.py — add `daily_focus_id/floor_minutes/label: Optional` to `FocusToggleRequest` (models.py:444), thread all three through `_create_focus_session` (line 3192: add kwargs, include in `payload` when not None) and the `/focus/toggle` start branch (line 3338). New endpoints (copy `_resolve_account_dual_auth` auth pattern):

```python
@app.post("/daily_focus", response_model=DailyFocusOut)
async def create_daily_focus(request: DailyFocusCreate,
        authorization: Optional[str] = Header(None),
        x_device_id: Optional[str] = Header(None, alias="X-Device-ID")):
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    db = get_db()
    row = db.table("daily_focus").insert({
        "account_id": account_id, "local_date": request.local_date,
        "title": request.title,
        "intent_text": request.intent_text or request.title,
        "linked_intention_id": request.linked_intention_id,
        "created_via": request.created_via}).execute()
    if not row.data:
        raise HTTPException(status_code=500, detail="daily_focus insert failed")
    r = row.data[0]
    return DailyFocusOut(id=str(r["id"]), local_date=str(r["local_date"]),
        title=r["title"], intent_text=r.get("intent_text"),
        linked_intention_id=str(r["linked_intention_id"]) if r.get("linked_intention_id") else None,
        created_via=r["created_via"], status=r["status"])

@app.get("/daily_focus/today")
async def get_daily_focus_today(local_date: str,
        authorization: Optional[str] = Header(None),
        x_device_id: Optional[str] = Header(None, alias="X-Device-ID")):
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    rows = get_db().table("daily_focus").select("*") \
        .eq("account_id", account_id).eq("local_date", local_date) \
        .eq("status", "active").order("created_at", desc=True).limit(1).execute().data or []
    return {"daily_focus": rows[0] if rows else None}

@app.post("/daily_focus/{df_id}/status")
async def set_daily_focus_status(df_id: str, payload: dict,
        authorization: Optional[str] = Header(None),
        x_device_id: Optional[str] = Header(None, alias="X-Device-ID")):
    account_id = await _resolve_account_dual_auth(authorization, x_device_id)
    status = payload.get("status")
    if status not in ("active", "done", "expired"):
        raise HTTPException(status_code=400, detail="bad status")
    get_db().table("daily_focus").update({"status": status}) \
        .eq("id", df_id).eq("account_id", account_id).execute()
    return {"id": df_id, "status": status}
```

- [ ] **Step 4: Run tests, verify PASS** (same command). Also run the full suite: `python3 -m pytest tests/ -q` — no regressions.

- [ ] **Step 5: Commit** — `git add models.py main.py tests/test_daily_focus.py && git commit -m "feat(api): /daily_focus CRUD + focus toggle carries daily_focus_id/floor/label"`

---

## Task 3: Coach context — dead session ≠ plan set; today's focus in context

**Files:**
- Modify: `/Users/arayan/Documents/GitHub/intentional-backend/main.py` — `_plan_prompt_available` (~5566)
- Test: `/Users/arayan/Documents/GitHub/intentional-backend/tests/test_daily_focus.py` (append)

- [ ] **Step 1: Failing test** — a session that started AND ended >30 min ago must NOT gate plan_prompt:

```python
def test_plan_prompt_reopens_after_dead_session():
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    local_now = now  # function only checks .hour ∈ [5,21); pick 15:00 explicitly
    local_now = local_now.replace(hour=15)
    ev = lambda kind, mins_ago: {"kind": kind,
        "ts": (now - timedelta(minutes=mins_ago)).isoformat()}
    events = [ev("session_start", 180), ev("session_end", 171)]  # 9-min dead session, 3h ago
    caps = {"plan_prompt_left": 2}
    assert main._plan_prompt_available(local_now, now, events, [], caps) is True
```

- [ ] **Step 2: Run, verify FAIL** (current code returns False on any `session_start` today).

- [ ] **Step 3: Implement** in `_plan_prompt_available` (~5582): replace the two blanket gates with stretch-aware logic:

```python
    # A session only "covers" the day while it is alive or freshly ended.
    # A dead session (ended >30 min ago, none active since) re-opens the
    # planless stretch — spec §CONVERGED C4 ("plan set is not a pass").
    starts = [e for e in todays_events if e.get("kind") == "session_start"]
    ends = [e for e in todays_events if e.get("kind") == "session_end"]
    if starts:
        if len(ends) < len(starts):
            return False                      # a session is live right now
        last_end = max(_parse_ts(e["ts"]) for e in ends)
        if (now - last_end) < timedelta(minutes=30):
            return False                      # just ended — settle grace
    recent_tap = any(d.get("outcome") == "tapped_start"
                     and (now - _parse_ts(d.get("outcome_ts") or d.get("ts", now.isoformat()))) < timedelta(hours=3)
                     for d in todays_decisions)
    if recent_tap:
        return False
```

(Add tiny helper `_parse_ts(s)` next to the function if one doesn't exist; reuse the module's existing ISO parsing if present.)

- [ ] **Step 4: Run tests → PASS; full suite green.** Re-run the coach bench (`set -a && source .env && set +a && python3 coach_bench/run_bench.py`) — wrong-speak must stay 0/72 (charter unchanged; this is caps code, but verify).

- [ ] **Step 5: Commit** — `git commit -am "fix(coach): dead session no longer silences the day — stretch-aware plan_prompt gate"`

---

## Task 4: Mac — Period v3 (floor, label, dailyFocusId) + persistence

**Files:**
- Modify: `Intentional/FocusModeController.swift` (Period struct lines 31–45; persistence payload lines 77–161; activate() lines 169–203)
- Test: `IntentionalTests/FocusModePersistenceTests.swift` (create; repo convention: XCTest files compile in target but are manual smoke specs — they MUST compile)

- [ ] **Step 1: Extend Period** (keep memberwise defaults so all existing call sites compile):

```swift
struct Period {
    let id: UUID
    let startedAt: Date
    let intention: String?
    let intentionId: UUID?
    let source: ActivationSource
    // Slice 1 (spec §CONVERGED C1): sessions are floor-not-box.
    let floorMinutes: Int?          // nil = legacy/scheduled block session
    let dailyFocusId: UUID?         // backend daily_focus row, when synced
    let label: String?              // pill display label (Daily Focus title)

    var floorEndsAt: Date? {
        floorMinutes.map { startedAt.addingTimeInterval(TimeInterval($0 * 60)) }
    }

    init(id: UUID, startedAt: Date, intention: String?, intentionId: UUID? = nil,
         source: ActivationSource, floorMinutes: Int? = nil,
         dailyFocusId: UUID? = nil, label: String? = nil) { ... assign all ... }
}
```

- [ ] **Step 2: Persistence v3** — bump schemaVersion to 3; add `periodFloorMinutes`, `periodDailyFocusId`, `periodLabel` to the disk payload (lines 80–88); decode tolerantly (v2 files load with nils). Extend `activate(intention:intentionId:source:)` to `activate(intention:intentionId:source:floorMinutes:dailyFocusId:label:)` with defaulted nils so every existing caller compiles unchanged.

- [ ] **Step 3: Write the round-trip test** (IntentionStoreTests pattern — temp dir, encode v2-style JSON, assert nils; encode v3, assert fields):

```swift
func test_period_v3_round_trip_and_v2_tolerance() throws {
    // v3 round-trip: activate with floor 25 + label, saveToDisk, new controller, assert restored
    // v2 tolerance: write a schemaVersion=2 payload by hand, load, assert floorMinutes == nil
}
```
(Write the real bodies — construct the controller with its settingsDir injection the same way FocusModeController is constructed in tests/AppDelegate; if it hardcodes the path, add an `init(stateDirectory:)` test seam.)

- [ ] **Step 4: Build** — `xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5` → BUILD SUCCEEDED.

- [ ] **Step 5: Commit** — `git commit -am "feat(session): Period v3 — floorMinutes/dailyFocusId/label, persisted, restart-safe"`

---

## Task 5: Mac — DailyFocusClient (fire-and-forget backend sync)

**Files:**
- Create: `Intentional/DailyFocusClient.swift`
- Modify: `Intentional/BackendClient.swift` (add three calls, copy the postFocusToggle request pattern + X-Device-ID auth)

- [ ] **Step 1: BackendClient methods** (signatures; bodies follow existing postFocusToggle/fetchPendingCoachDecision JSON patterns):

```swift
func createDailyFocus(localDate: String, title: String, intentText: String?,
                      linkedIntentionId: UUID?, createdVia: String) async -> UUID?   // POST /daily_focus → id, nil on any failure
func setDailyFocusStatus(id: UUID, status: String) async                              // POST /daily_focus/{id}/status
func postFocusToggle(action:intentionId:triggeredBy:) — EXTEND with dailyFocusId: UUID?, floorMinutes: Int?, label: String? (defaulted nil; include in JSON body when present)
```

- [ ] **Step 2: DailyFocusClient.swift** — a tiny stateless helper (no store/cache in slice 1 — YAGNI; the Period carries what the pill needs):

```swift
/// Creates the backend daily_focus row best-effort. Returns nil offline —
/// the session works identically without it (spec: graceful degradation).
enum DailyFocusClient {
    static func create(title: String, linkedIntentionId: UUID?, via: String,
                       backend: BackendClient?) async -> UUID? {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        return await backend?.createDailyFocus(
            localDate: fmt.string(from: Date()),
            title: String(title.prefix(60)),
            intentText: String(title.prefix(140)),
            linkedIntentionId: linkedIntentionId, createdVia: via)
    }
}
```

- [ ] **Step 3: Build → SUCCEEDED. Commit** — `git commit -am "feat(session): DailyFocus backend sync (best-effort) + toggle carries floor/label"`

---

## Task 6: Mac — kill the midnight pill: Period-driven timer with floor → count-up

**Files:**
- Modify: `Intentional/DeepWorkTimerController.swift` (timer loop 238–260; add `show(session:)`)
- Modify: `Intentional/FocusMonitor.swift` (`showTimerForCurrentBlock` 954–966)
- Modify: `Intentional/AppDelegate.swift` (synthetic injection 823–838 — KEEP for enforcement, but the pill no longer reads it)

- [ ] **Step 1: New pill entry point** in DeepWorkTimerController:

```swift
struct SessionTimerData {
    let label: String
    let startedAt: Date
    let floorEndsAt: Date?    // nil → legacy countdown behavior unchanged
}
func show(session: SessionTimerData) {
    // reuse show(intention:endsAt:) plumbing; store sessionData on the VM
}
```

- [ ] **Step 2: Rework the timer tick** (the ONLY behavioral change to lines 238–260): when the VM has sessionData, the tick becomes:

```swift
if let floorEnd = vm.sessionFloorEndsAt {
    let remaining = floorEnd.timeIntervalSinceNow
    if remaining > 0 {
        vm.timeDisplay = mmss(remaining)               // floor countdown, as today
        vm.isApproachingEnd = remaining <= 60
    } else {
        // §CONVERGED C1 flow protection: NEVER flip to .blockComplete here.
        let elapsed = Date().timeIntervalSince(vm.sessionStartedAt)
        vm.timeDisplay = hmmss(elapsed) + " ↑"          // count-up, silent
        vm.isApproachingEnd = false
    }
} else { /* existing block-countdown branch, untouched (scheduled blocks) */ }
```
`.blockComplete` is now reachable ONLY from `handlePillEndBlock` (FocusMonitor 1298) and the new clean-end card (Task 7). Delete nothing else in the loop.

- [ ] **Step 3: FocusMonitor.showTimerForCurrentBlock** — branch on the live Period FIRST:

```swift
private func showTimerForCurrentBlock() {
    if let period = appDelegate?.focusModeController?.currentPeriod,
       period.floorMinutes != nil {
        deepWorkTimerController?.show(session: .init(
            label: period.label ?? period.intention ?? "Focus",
            startedAt: period.startedAt, floorEndsAt: period.floorEndsAt))
        deepWorkTimerController?.update(isDistracted: false)
        pushFocusStatsToTimer()
        return
    }
    /* existing block branch unchanged */
}
```
The synthetic 23:59 block injection in AppDelegate stays byte-identical (enforcement `guard let block` paths still need it) — it is now invisible to the user.

- [ ] **Step 4: Boot reconcile** (AppDelegate 960–976): inside the `state == .focus` restore branch, if `currentPeriod?.floorMinutes != nil` ALSO re-inject the synthetic block (currently only `.off→.focus` injects — restart loses it; this is the restart-survival fix) and call `focusMonitor?.onBlockChanged()` (already there). Reuse the exact injection code as a private `injectSyntheticBlockForCurrentPeriod()` called from both sites.

- [ ] **Step 5: Build → SUCCEEDED. Manual check** (dev build, scripts/dev-launch.sh): start a session from the dashboard Goals page → pill shows `25:00` counting DOWN, then ` ↑` count-up at zero, NO "Block complete". Restart the app mid-session → pill returns. Screenshot both.

- [ ] **Step 6: Commit** — `git commit -am "feat(pill): Period-driven floor→count-up timer; midnight countdown + wedge dead; restart survival"`

---

## Task 7: Mac — clean end semantics (the C1 contract)

**Files:**
- Modify: `Intentional/FocusMonitor.swift` (drift handling in `evaluateApp`/relevance path; `handlePillEndBlock` 1298–1321)
- Modify: `Intentional/DeepWorkTimerController.swift` (clean-end card = a small variant of the existing coach card UI)
- Modify: `Intentional/AppDelegate.swift` (endSession plumbing)

- [ ] **Step 1: One end path.** Add to AppDelegate:

```swift
/// THE single way any session ends. Sends backend stop (with focus score),
/// deactivates, marks daily focus done, cleans the pill. C1: full credit, no moralizing.
func endCurrentSession(reason: String) {
    guard let period = focusModeController?.currentPeriod else { return }
    let score = SessionFocusScore.current()   // existing machinery from e449783
    Task { _ = await backendClient?.postFocusToggle(action: .stop, intentionId: period.intentionId,
            triggeredBy: "mac", focusScore: score) }
    if let dfId = period.dailyFocusId {
        Task { await backendClient?.setDailyFocusStatus(id: dfId, status: "done") }
    }
    focusModeController?.deactivate(source: .manual)
    postLog("🛑 Session ended (\(reason)) — \(Int(Date().timeIntervalSince(period.startedAt)/60))m counted")
}
```
(Wire `handlePillEndBlock` for floor-sessions to call this instead of mutating block end hours; keep the strict-mode guard. Verify the exact name/shape of the focus-score helper from `SessionFocusScore.swift` and `postFocusToggle`'s focusScore parameter before coding — adjust to what exists.)

- [ ] **Step 2: Post-floor drift → clean-end card.** In FocusMonitor where hedonic off-task content is confirmed during a session (the same code path that fires level-1 nudges): if `period.floorEndsAt != nil && Date() > floorEndsAt && offTaskContinuousSeconds >= 300` show the clean-end card ONCE (reuse CoachCardData):

```swift
let mins = Int(Date().timeIntervalSince(period.startedAt) / 60)
pill.showCoachCard(data: CoachCardData(
    message: "Calling it here? \(mins) min counted.",
    onStart: { _ in self.appDelegate?.endCurrentSession(reason: "post-floor drift accepted") },
    onLater: { /* dismiss; do not re-show for 10 min */ }))
```
Pre-floor drift behavior is UNCHANGED in slice 1 (existing tint + nudge ladder already does pull-back; the Standard soft-close ladder is Slice 2).

- [ ] **Step 3: Build, manual check:** start session, hit floor, open YouTube 5+ min → card appears, "Calling it here?" → tap → session ends everywhere (pill gone, sidebar "Start session", backend row ended). Screenshot.

- [ ] **Step 4: Commit** — `git commit -am "feat(session): single endCurrentSession path + post-floor clean-end card"`

---

## Task 8: Mac — idle/away ends the session at last activity

**Files:**
- Modify: `Intentional/FocusMonitor.swift` (it already runs a periodic evaluate loop — add idle check)
- Modify: `Intentional/AppDelegate.swift` (SleepWakeMonitor wiring — `onWake` exists at SleepWakeMonitor.swift:15)

- [ ] **Step 1: Idle detection.** In FocusMonitor's existing periodic tick add:

```swift
private var lastIdleCheck = Date()
private func checkIdleEnd() {
    guard let period = appDelegate?.focusModeController?.currentPeriod,
          period.floorMinutes != nil else { return }
    let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                       eventType: .null)
    if idle >= 300 {  // 5 min — C1
        let lastActivity = Date().addingTimeInterval(-idle)
        appDelegate?.pendingWarmReentry = (period.label ?? "Focus",
            Int(lastActivity.timeIntervalSince(period.startedAt) / 60))
        appDelegate?.endCurrentSession(reason: "idle 5m — ended at last activity")
    }
}
```
Sleep: wire `sleepWakeMonitor.onWake` → if a floor-session is live and sleep gap >5 min, same end + warm re-entry stash.

- [ ] **Step 2: Warm re-entry.** On next user activity (first FocusMonitor tick with idle < 10s) when `pendingWarmReentry != nil`, show coach card: `"You left — \(mins) min counted. Back for more?"` `[▶ 25 min]` (onStart → restart session, same daily focus) / `[Done]`. Clear the stash either way.

- [ ] **Step 3: Build, manual check:** start session, lock screen 6 min, return → pill gone during idle; warm card on return; tap ▶ → fresh 25:00 against the same focus. Commit — `git commit -am "feat(session): idle/away clean end + warm re-entry"`

---

## Task 9: Mac — coach card v2 (goals chips + 🤷 + typed → DailyFocus, NEVER an Intention)

**Files:**
- Modify: `Intentional/DeepWorkTimerController.swift` (CoachCardData lines 112–116 + the card SwiftUI body)
- Modify: `Intentional/AppDelegate.swift` (`handleCoachCardStart` 1846–1897, `presentCoachDecision` 1804–1838)

- [ ] **Step 1: Extend CoachCardData:**

```swift
struct CoachCardChip { let title: String; let intentionId: UUID? }
struct CoachCardData {
    let message: String
    var chips: [CoachCardChip] = []            // weekly goals (in_progress), max 4
    var onStart: (String) -> Void              // typed text path
    var onChipTap: ((CoachCardChip) -> Void)? = nil
    var onNotSure: (() -> Void)? = nil         // 🤷 → sort-it-out
    var onLater: () -> Void
}
```
Card body: message → chip buttons (goal names) → `[🤷 I'm not sure]` → text field (existing) → Later. No pre-filled text ever (C2).

- [ ] **Step 2: Rewrite `handleCoachCardStart` routing** — DELETE the `IntentionStore.shared.create` call (lines 1859–1874). New flows, all converging on one helper:

```swift
private func startDailyFocusSession(title: String, linkedIntentionId: UUID?,
                                    via: String, floorMinutes: Int = 25) {
    Task { [weak self] in
        guard let self else { return }
        let dfId = await DailyFocusClient.create(title: title,
            linkedIntentionId: linkedIntentionId, via: via, backend: self.backendClient)
        await MainActor.run {
            self.focusModeController?.activate(
                intention: title, intentionId: linkedIntentionId, source: .manual,
                floorMinutes: floorMinutes, dailyFocusId: dfId, label: title)
        }
        _ = await self.backendClient?.postFocusToggle(action: .start,
            intentionId: linkedIntentionId, triggeredBy: "mac_manual",
            dailyFocusId: dfId, floorMinutes: floorMinutes, label: title)
    }
}
```
- typed text → `startDailyFocusSession(title: trimmed, linkedIntentionId: nil, via: "coach_card")`
- chip tap → `startDailyFocusSession(title: chip.title, linkedIntentionId: chip.intentionId, via: "coach_card")` (linked → relevance scoring uses the goal's intentText via existing refreshIntentionEnforcement; unlinked → intent = title)
- 🤷 → `startDailyFocusSession(title: "Sort out the day", linkedIntentionId: nil, via: "coach_card", floorMinutes: 10)` — notes/calendar/task apps count on-task because the intent text IS "sort out the day; planning"; ONE per planless stretch: guard with a `lastSortItOutAt` timestamp (≥90 min).
- Populate chips in `presentCoachDecision`: `await IntentionStore.shared.active().filter { $0.status == .inProgress }.prefix(4)`.
- Keep outcome posts (tapped_start once, busy gate) byte-identical.

- [ ] **Step 3: Same routing for the Goals-page start** — `startIntentionSession(id:)` (1767–1793) now ALSO passes `floorMinutes: 25, label: intention.name` into `activate` and the toggle, so dashboard-started sessions get the same pill. No DailyFocus row for direct goal-starts (it IS the goal).

- [ ] **Step 4: Build. THE REGRESSION TEST (the bug that started all this):** type literally `Idk what to do` into the card → session starts labeled "Idk what to do", pill 25:00, **zero new rows in Goals** (check dashboard Goals tab + `focus_modes` table), coach context shows plan set while live. Screenshot.

- [ ] **Step 5: Commit** — `git commit -am "feat(coach-card): v2 — goal chips, not-sure sort-it-out, typed→DailyFocus; Intentions never auto-created"`

---

## Task 10: Copy sweep on touched surfaces (states not math)

**Files:**
- Modify: `Intentional/DeepWorkTimerController.swift` (focusStatText ~1026; any "earn"-flavored strings on the pill/cards touched above)

- [ ] **Step 1:** Pill idle/unplanned strings → plain states (`Focusing`, `Break`, `Unplanned`); celebration "+Nm earned" line on the clean-end/warm cards → "break's covered". Tank/allowance numbers: only render when balance ≤ 10 min (existing allowanceBalance pill mode untouched otherwise). Grep the touched files for `earn` and adjust ONLY surfaces this slice touched (full sweep is Slice 2).
- [ ] **Step 2:** Build, commit — `git commit -am "copy: states not math on slice-1 surfaces; 'breaks are covered'"`

---

## Task 11: Live GUI verification (verifier-intentional-gui) + docs

**Files:**
- Modify: `docs/features/focus-sessions.md` (create from `docs/features/_TEMPLATE.md` if absent; `status: shipping`, `last_verified: 2026-06-13`, files list = every file touched above)
- Modify: `docs/PROJECT-STATE-2026-06-12.md` successor or append run log `docs/overnight-run-2026-06-12.md`

- [ ] **Step 1:** Full pass on the dev build (foreground bursts, focus restore, live coords): (1) Goals-page start → floor pill; (2) coach-card typed start → no goal created; (3) chip start → linked; (4) 🤷 → 10-min sort-it-out; (5) floor → count-up, no wedge at any point incl. leaving it 10+ min past floor; (6) End session from pill; (7) post-floor YouTube 5 min → clean-end card; (8) restart mid-session → pill restored; (9) idle 6 min → warm re-entry. Screenshot evidence per step; verify which binary is running first (`pgrep -lf "Intentional.app/Contents/MacOS"` — DerivedData = dev).
- [ ] **Step 2:** `./scripts/check-docs.sh` → 0 errors. Commit docs — `git commit -m "docs: focus-sessions feature doc + slice-1 verification log"`

---

## Self-review notes (done at write time)
- **Spec coverage:** C7.1→Tasks 1/2/5/9 · C7.2→4/6/7 · C7.3→9 (session-count question deliberately DEFERRED to the morning-ritual slice — the rolling "another round?" card covers the need; noted as deviation) · C7.4→8 · C7.5→10 · C7.6→11. C3 tone: all new user-facing strings in Tasks 7–9 are flat/factual per C3.
- **Break machinery ("another round?" at break end)** is Slice 2 (it needs the planless-stretch accumulator); slice 1 sessions end clean and the coach's existing plan_prompt (Task 3 stretch fix) re-engages.
- **Type consistency:** `floorMinutes` (Int?), `dailyFocusId` (UUID?), `label` (String?) used identically in Tasks 4/5/6/9; backend `floor_minutes/label/daily_focus_id` in 1/2/3.
- **Known seams to verify in code, not assume:** exact `SessionFocusScore` API name (Task 7), `postFocusToggle` current signature (Task 5), FocusMonitor's off-task-continuous-seconds source (Task 7 — reuse whatever the nudge ladder uses), FocusModeController test seam (Task 4).

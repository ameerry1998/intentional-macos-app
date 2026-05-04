# iPhone Schedule Tab — 2026-04-30 hand-off

**Goal:** Add a Schedule tab to the Puck iPhone app so users can define recurring Deep Work / Focus Hours blocks with per-block app blocklists. Blocks engage automatically at scheduled times via DeviceActivityMonitor — even with the app closed. Schedule timing syncs across devices via the backend; blocklists remain per-device.

**Status: shipped on feature branches, awaiting Xcode UI target verification + manual smoke test.**

---

## What shipped

### Backend — `intentional-backend` branch `feat/schedule-blocks`

Four commits on top of `main`:

| SHA | Subject |
|---|---|
| `540350f` | feat(schedule): migration for schedule_blocks table |
| `4048a03` | feat(schedule): pydantic models for /schedule/blocks endpoints |
| `5a07adc` | feat(schedule): GET /schedule/blocks endpoint |
| `5ebc9a9` | feat(schedule): PUT /schedule/blocks endpoint (atomic replace) + Field caps |

**Data model.** `schedule_blocks` table is keyed on `(block_id, account_id)`. Per-block fields: `title` (text), `block_type` (`deep_work` | `focus_hours`), `start_hour` + `start_minute` + `end_hour` + `end_minute` (integers, constrained), `active_days` (integer array, ISO weekday encoding 1=Mon..7=Sun), `enabled` (bool), `created_at`, `updated_at`. RLS is enabled (service-role bypass for all server writes; no user-level policies = default-deny for direct access). No account_id → block_id uniqueness constraint beyond the PK — the PUT is atomic delete-then-insert for the entire account's set.

`GET /schedule/blocks` returns all rows for the authenticated account. `PUT /schedule/blocks` accepts a list; runs `DELETE FROM schedule_blocks WHERE account_id = $1` then `INSERT` for every row in the request, inside a single transaction. Caps enforced via Pydantic `Field`: `active_days` max 7 items, top-level list max 20 blocks.

### iOS — `puck-ios` branch `feat/iphone-schedule`

11 commits. Branch base: `feat/bedtime-device-activity` (the DeviceActivityMonitor extension wiring commit `50aac6e`).

| SHA | Subject |
|---|---|
| `32a8e29` | feat(schedule): IntentionalScheduleClient — HTTP wrapper for /schedule/blocks |
| `fc7a4aa` | feat(schedule): SwiftData ScheduleBlock model + lifecycle helper |
| `ae8fddc` | feat(schedule): ScheduleBlocksService — sync + DeviceActivity registration |
| `158aa9e` | feat(schedule): wire ScheduleBlocksService from PuckApp |
| `f7abe37` | feat(schedule): BedtimeSharedStorage — per-block blocklist + metadata |
| `1f72e11` | feat(schedule): extension dispatches bedtime + schedule_<id> activities |
| `c5989d8` | feat(schedule): CalendarTimelineView — vertical hour grid + block tiles |
| `1b70c69` | feat(schedule): ScheduleBlockEditSheet — full edit for future / new blocks |
| `1736ca3` | feat(schedule): ScheduleBlockDetailSheet — read-only past, limited active |
| `e340ada` | feat(schedule): QuickBlockButton — Deep Work / Focus now with 15-min snap |
| `6a2520d` | feat(schedule): ScheduleTabView root + tab bar wiring |

**Data layer (Phase 2):**

`IntentionalScheduleClient` (`32a8e29`) is a thin HTTP wrapper over `IntentionalAPIClient` — mirrors the `IntentionalBedtimeClient` shape. Two methods: `fetchBlocks() async throws -> [ScheduleBlockDTO]` and `updateBlocks(_ blocks: [ScheduleBlockDTO]) async throws`. Note: the SwiftData model class is `IntentionalBlock` (not `ScheduleBlock` as the spec originally named it) due to a legacy collision — `Puck/Models/PuckSchedule.swift` already contains a `@Model class ScheduleBlock` from the earlier local-only schedule work. Renaming would require a SwiftData migration schema version bump, so the new cloud-synced model ships as `IntentionalBlock`.

`IntentionalBlock` (`fc7a4aa`) is a SwiftData `@Model` with the same fields as the backend DTO plus `blocklist: Data?` for the encoded `FamilyActivitySelection`. A `lifecycle(now:)` helper returns `.past`, `.active`, or `.future` based on wall-clock time and `active_days`. The short DeviceActivity name (`schedule_<8 hex chars>`) is computed from the first 8 hex chars of `blockId.uuidString.replacingOccurrences(of: "-", with: "")` — stays under the ~36-char `DeviceActivityName` limit.

`ScheduleBlocksService` (`ae8fddc`) is a `@MainActor ObservableObject` singleton. Pull path: `pull()` calls `IntentionalScheduleClient.fetchBlocks()`, upserts into the local `ModelContext`, then calls `reregisterAllSchedules()`. Push path: `push()` collects all `IntentionalBlock` objects from the context and calls `IntentionalScheduleClient.updateBlocks(_:)`. Edit helpers (`createBlock`, `updateBlock`, `deleteBlock`) write to the context then call `push()` and `reregisterAllSchedules()`. `deleteBlock(_:)` explicitly calls `activityCenter.stopMonitoring([.scheduleBlock(id)])` and clears the `BedtimeSharedStorage` entry before deleting from the context (risk R6 from the plan). Pull is fired on init, on `willEnterForeground`, and every 60s via a `Timer`. The soft limit on DeviceActivity registrations (20 simultaneous) is enforced in `reregisterAllSchedules()` — if `enabledBlocks.count > 20` a warning is logged; only the first 20 are registered.

`PuckApp` wiring (`158aa9e`) injects `ScheduleBlocksService.shared` into the environment and adds `IntentionalBlock` to the SwiftData `Schema`.

**Extension layer (Phase 3):**

`BedtimeSharedStorage` extensions (`f7abe37`) add: `saveBlockBlocklist(blockId:tokens:)` + `loadBlockBlocklist(blockId:)` (encodes/decodes `FamilyActivitySelection` via `NSKeyedArchiver` into the App Group `UserDefaults` at key `puck_block_blocklist_<blockId>`), plus `saveBlockMetadata(blockId:title:type:)` + `loadBlockMetadata(blockId:)` for the title/type the shield extension displays.

`BedtimeMonitorExtension` dispatcher (`1f72e11`) extends the existing `intervalDidStart(for:)` with prefix-match routing: if `activity.rawValue == "bedtime"` → existing bedtime path unchanged; if `activity.rawValue.hasPrefix("schedule_")` → new path reads the per-block blocklist from `BedtimeSharedStorage.loadBlockBlocklist(blockId:)` and applies it via a `ManagedSettingsStore(named: activity.rawValue)`. `intervalDidEnd(for:)` mirrors this — calls `store.clearAllSettings()` for the matching named store. The named `ManagedSettingsStore` is keyed on the same `DeviceActivityName` string so activation and deactivation always hit the same store.

**UI layer (Phase 4):**

`CalendarTimelineView` (`c5989d8`) renders a vertical 24-hour grid inspired by Apple Calendar's Day view. Each hour slot is a labeled row. Block tiles are overlaid as `ZStack` rectangles with indigo (Deep Work) or amber (Focus Hours) fill, rounded corners, and a block-title label. Empty slots render as faint horizontal dividers with the hour label. Tapping a tile dispatches to the correct sheet based on `block.lifecycle(now:)`.

`ScheduleBlockEditSheet` (`1b70c69`) handles "+" (new block) and tapping a future block. Fields: title (text), type picker (Deep Work / Focus Hours), start time + end time (wheel pickers), active days (multi-select day chips), and a "Choose apps to block" button that presents `FamilyActivityPicker`. On save: calls `ScheduleBlocksService.shared.createBlock(_:)` or `updateBlock(_:)`.

`ScheduleBlockDetailSheet` (`1736ca3`) handles past blocks (read-only) and the active block (limited edit: "Extend +15 min" and "End now" CTAs). Past sheet shows title, type badge, time range, active days, and blocked app count. Active sheet adds the two action buttons which call `ScheduleBlocksService.shared.extendActiveBlock(minutes:)` and `endActiveBlock()`.

`QuickBlockButton` (`e340ada`) renders two pill buttons above the timeline: "Deep Work" and "Focus Hours". Tap snaps the end time to the next 15-minute boundary from now, creates a block with a default 60-minute duration, calls `createBlock(_:)`, and opens `ScheduleBlockEditSheet` in edit mode so the user can adjust before committing.

`ScheduleTabView` (`6a2520d`) is the tab root. Contains a `CalendarTimelineView` for today, two `QuickBlockButton`s in a header, a "+" toolbar button to create a new block, and an empty-state card ("Build your week, brick by brick") when no blocks exist. Tab bar wiring adds a "Blocks" tab (calendar grid SF Symbol) to `ContentView`'s `TabView`. The tab is labeled **"Blocks"** (not "Schedule") because `RoutineView` is already using the "Schedule" tab label — either rename the existing tab or keep this naming in v2.

---

## How it works end-to-end

1. User opens the "Blocks" tab → sees an empty 24-hour calendar grid.
2. Taps "+" or a Quick Block button → fills in title, pick type, start/end time, active days, and optionally an app blocklist via `FamilyActivityPicker`. Taps Save.
3. `ScheduleBlocksService.createBlock(_:)` writes to SwiftData, calls `push()` which PUTs the full list to `/schedule/blocks` on the backend, and calls `reregisterAllSchedules()`.
4. `reregisterAllSchedules()` calls `DeviceActivityCenter.startMonitoring(activity:using:)` once per enabled block. The `DeviceActivityName` is `schedule_<8 hex chars>` (e.g. `schedule_a1b2c3d4`). The `DeviceActivitySchedule` uses `intervalStart` / `intervalEnd` `DateComponents` (hour + minute) and `repeats: true`.
5. At the scheduled time, the OS fires `intervalDidStart(for:)` in `BedtimeMonitorExtension` (same extension target as bedtime, dispatched by prefix). Extension reads the per-block blocklist from App Group `UserDefaults` and applies it via `ManagedSettingsStore(named: activity.rawValue).shield.applications = tokens`.
6. At the end time, `intervalDidEnd(for:)` fires → `store.clearAllSettings()`.
7. On launch or foreground, `ScheduleBlocksService.pull()` reads from the backend and upserts local SwiftData — Mac changes (once Mac gets schedule editing) appear on iPhone within 60s.

---

## What the user must do next

1. **Apply migration 017** in Supabase. Run manually via the Supabase SQL editor or migrations CLI:
   ```sql
   -- paste contents of intentional-backend/migrations/017_schedule_blocks.sql
   ```
2. **Verify `PuckBedtimeMonitor` extension target** is in Xcode — the schedule feature reuses the same extension target created for bedtime. If the bedtime extension was already added via Xcode UI (`50aac6e`), no new target is needed. Confirm `PuckBedtimeMonitor/BedtimeMonitorExtension.swift` is in the build sources for that target.
3. **Build + install on physical iPhone** (simulator won't work for FamilyControls).
4. **Smoke test** — see section below.

---

## Manual smoke test

1. Open the "Blocks" tab → empty calendar grid visible (24-hour rows, no blocks).
2. Tap "+" → fill in title "Test Block", pick Deep Work, start in 3 min, end in 8 min, pick 1-2 apps as blocklist. Save.
3. Block appears on timeline as an indigo tile.
4. Force-quit Puck.
5. At start time, open one of the chosen blocked apps — shielded.
6. Open a non-blocked app — works fine.
7. At end time, re-open the blocked app — works.
8. Foreground Puck. Console.app (filter "Puck" or "BedtimeMonitor") should show:
   - `[ext] intervalDidStart[schedule_<short>]: shield ON (N apps)`
   - `[ext] intervalDidEnd[schedule_<short>]: shield OFF`
9. Tap the past block tile → read-only detail sheet opens (title, time, active days, blocked-app count).
10. Create a future block → tap it → full edit sheet opens.
11. Edit the future block title → Save → backend is pushed, DeviceActivity re-registered.
12. Delete a future block → DeviceActivityName unregistered, tile disappears from grid.
13. Active block tile → limited sheet with "Extend +15 min" and "End now" buttons.
14. Tap "End now" → shield drops, tile disappears.

---

## Risks not covered (deferred)

- **20-schedule limit not surfaced in UI.** `ScheduleBlocksService` logs a warning and silently registers only the first 20. A user who creates 21+ enabled blocks sees no error.
- **Free Time / Bedtime block types deferred.** v1 has Deep Work + Focus Hours only. Bedtime remains its own subsystem.
- **No ritual / celebration / Live Activity for focus blocks.** The Mac's block-start ritual and end-of-block celebration are iOS v2 features.
- **Mac does NOT read `/schedule/blocks`.** The Mac already has its own ScheduleManager with a local-file schedule format. Cross-device schedule sync to Mac is a future task once a migration plan for the Mac's schedule format is agreed on.
- **Tab naming collision.** The new tab is "Blocks" because "Schedule" is taken by `RoutineView`. Decide in a follow-up whether to rename `RoutineView`'s tab or rebrand the new one.
- **`ScheduleBlock` model naming legacy.** `Puck/Models/PuckSchedule.swift` has an existing `@Model class ScheduleBlock`. The new cloud-synced model ships as `IntentionalBlock` to avoid a schema version bump. Clean this up in a v2 migration.

---

## Branches to merge

```
intentional-backend:   feat/schedule-blocks  (4 commits) → main
puck-ios:              feat/iphone-schedule  (11 commits) → feat/bedtime-device-activity or main
```

Both branches must build clean before merging. The iOS branch depends on `feat/bedtime-device-activity` (`50aac6e`) being present — merge or rebase onto that branch first if it isn't already on main.

---

## Companion docs

- `docs/superpowers/plans/2026-04-30-iphone-schedule-tab.md` — full implementation plan with schema, phase breakdown, risk catalog.
- `docs/overnight-run-2026-04-30.md` — same overnight session's earlier work (bedtime lock-loop fix + partner sync).
- `docs/cross-repo-partner-sync-2026-04-30.md` — sibling cross-repo log from the same session (partner cross-device sync).
- `puck-ios/docs/bedtime-device-activity-extension-setup.md` — one-time Xcode target setup for `PuckBedtimeMonitor` (the extension this feature reuses).

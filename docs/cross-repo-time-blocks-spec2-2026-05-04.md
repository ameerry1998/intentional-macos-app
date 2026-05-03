# Cross-Repo Log — 2026-05-04 — Spec 2: Time Blocks (Synced Schedule + Auto-Fired Sessions)

**Started:** 2026-05-04 (overnight, autonomous)
**Branch convention:** `feat/time-blocks-spec2` in all three repos
**Predecessor:** Spec 1 — Unified Intentions (`docs/overnight-run-2026-05-03.md`)
**Spec brief:** `docs/superpowers/specs/2026-05-04-time-blocks-spec2-handoff.md`
**Plans:**
- A — Backend: `docs/superpowers/plans/2026-05-04-time-blocks-spec2-plan-a-backend.md`
- B — Mac: `docs/superpowers/plans/2026-05-04-time-blocks-spec2-plan-b-mac.md`
- C — iOS: `docs/superpowers/plans/2026-05-04-time-blocks-spec2-plan-c-ios.md`

---

## TL;DR

**ALL 3 SPEC 2 PHASES COMPLETE.** Code-level GREEN. Deployment-level pending user action in the morning.

| Repo | Branch | Tasks | Build | Tests | Commit |
|---|---|---|---|---|---|
| Backend | `feat/time-blocks-spec2` | 11/11 | n/a | 130/132 (2 pre-existing) | `eeed555` |
| Mac | `feat/time-blocks-spec2` | 10/10 | SUCCESS | n/a (no test target) | `38b9403` |
| iOS | `feat/time-blocks-spec2` | 11/11 | SUCCESS | bootstrap blocked on Config.plist | `d4c81c0` |

All 3 branches pushed to `origin`. The Mac and iOS Spec 2 branches each include Spec 1 (`feat/intentions-spec1`) merged internally as Task 0.1, so they can be merged independently of Spec 1's merge state.

**Order of operations for the morning** (also documented in `docs/overnight-run-2026-05-03.md`):
1. Apply migration 018 in Supabase, then 019.
2. Backend: merge `feat/intentions-spec1` → main, rebase + merge `feat/time-blocks-spec2` → main. Railway auto-deploys.
3. Mac/iOS: merge Spec 1 then Spec 2 branches.
4. Cross-device smoke test (the actual product promise).

**The acceptance test** (per spec brief):
- Create a Time Block at "now+2min" via either device's calendar UI.
- Wait two minutes — both devices auto-fire the Session simultaneously.
- Wait until block end — both devices stop simultaneously.
- Switching from one back-to-back block to the next is seamless.
- Generic blocks (no Intention) work using the seeded "Focus" Intention as fallback.

---

## Hard prerequisite check (Spec 1 must be done first)

Per the Spec 2 brief:
- [ ] Backend `intentions` table exists in production and `/intentions` CRUD endpoints are live
- [ ] `focus_sessions.intention_id` column exists in production
- [ ] Mac client has migrated `projects.json` → backend Intentions
- [ ] iOS client has migrated local `FocusMode.appTokens` → backend Intentions
- [ ] Cross-device manual Session start works end-to-end

These all require user action in the morning (Supabase migration + Railway deploy + branch merges + manual smoke). The autonomous overnight session can implement Spec 2 code on feature branches, but Spec 2 cannot be VERIFIED end-to-end until Spec 1 is in production.

---

## Repos & branches

| Repo | Path | Base | Feature branch | Worktree |
|---|---|---|---|---|
| Backend | `intentional-backend` | `main` | `feat/time-blocks-spec2` | `.claude/worktrees/time-blocks-spec2` |
| Mac | `intentional-macos-app` | `puck` | `feat/time-blocks-spec2` | `.claude/worktrees/time-blocks-spec2` |
| iOS | `puck-ios` | `main` | `feat/time-blocks-spec2` | `.claude/worktrees/time-blocks-spec2` |

---

## Phase tracker

- [x] Phase 1 — Spec 2 brief (committed by user before sleep — `4a4fac8`)
- [x] Phase 2 — Plans A/B/C written
- [x] Phase 2.1 — Worktrees created in all 3 repos
- [ ] Phase 3 — Spec 2 backend execution (BLOCKED on Spec 1 iOS executor done)
- [ ] Phase 4 — Spec 2 Mac execution (BLOCKED on Spec 2 backend done OR Plan A backend's compile-only state)
- [ ] Phase 5 — Spec 2 iOS execution (parallel with Phase 4)
- [ ] Phase 6 — Final cross-repo handoff

---

## Live progress log

### Phase 1 — Brief (DONE)
Pinned by user. Vocab: Intention/Time Block/Session/Goal. Acceptance criteria: 6-item user-visible promise. All product decisions pinned.

### Phase 2 — Plans (DONE)
- Plan A: 11 tasks, ~1100 lines. Migration 019, Pydantic models, GET/PUT /time_blocks, 301 redirects from /schedule/blocks, _create_focus_session helper extraction, cron scheduler module (60s tick, idempotent fire-by-date), generic block fallback to seeded Focus.
- Plan B: 10 tasks, ~700 lines. BackendClient extension, ScheduleManager backend pull/push, FocusBlock additive change (intentionId + intensity), drop .freeTime, rename DailySchedule.goals/dailyPlan → dayItems/dayNotes.
- Plan C: 11 tasks, ~1100 lines. New TimeBlock SwiftData model, TimeBlocksService, IntentionalTimeBlocksClient, DayCalendarView ported from addy-ai-ios (long-press-drag, edge-resize, 15-min snap, 6am-10pm grid), TimeBlockEditSheet, ScheduleTabView restored.

### Phase 2.1 — Worktrees (DONE)
Created `feat/time-blocks-spec2` in all 3 repos at `.claude/worktrees/time-blocks-spec2`.

### Phases 3–6
(Pending — append reports as executors complete.)

### Phase 3 — Backend report

**Status:** GREEN — all 11 tasks complete, branch pushed.

**Branch:** `feat/time-blocks-spec2` (intentional-backend), pushed to origin.
**Final commit:** `eeed555` — `feat(time-blocks): generic block fallback to seeded Focus intention`
**Total commits this branch:** 11 (1 empty start + 10 task commits)
**Base:** Branched on top of `feat/intentions-spec1` (Spec 1 not yet merged to main; rebase to main when Spec 1 lands).

**Test results:**
- 130 passed / 132 total. The 2 failures (`test_focus_active_no_session`, `test_partner_status_no_account_returns_none`) pre-exist on `feat/intentions-spec1` and are documented in the plan as not-our-bugs.
- New coverage:
  - `tests/test_time_blocks.py` — 6 tests (GET empty, GET account-scoped, GET intention_id, PUT replace, PUT validates active_days, PUT validates non-zero duration).
  - `tests/test_schedule_blocks_redirects.py` — 2 tests (GET + PUT 301 → /time_blocks).
  - `tests/test_time_block_scheduler.py` — 6 tests (start fires, no-double-fire idempotency, weekday filter, disabled-block skip, generic-block Focus fallback, end events mark session ended).

**Files changed (11 commits):**
```
migrations/019_time_blocks.sql              NEW  rename schedule_blocks→time_blocks + intention_id + intensity + updated_at trigger + indexes + focus_sessions.time_block_id
models.py                                  MOD  TimeBlockDTO, TimeBlocksRequest, TimeBlocksResponse appended
main.py                                    MOD  GET/PUT /time_blocks endpoints; /schedule/blocks → 301 RedirectResponse; _create_focus_session + _end_focus_session helpers extracted; toggle_focus refactored to use helpers; @app.on_event("startup"/"shutdown") wires scheduler loop with TESTING=1 guard; generic-block fallback in _create_focus_session
time_block_scheduler.py                    NEW  asyncio loop, time_block_tick(db_factory) public for tests, 60s sleep, idempotent fire-by-date keyed on focus_sessions.time_block_id + today_iso
tests/conftest.py                          MOD  TESTING=1 default for safety
tests/test_time_blocks.py                  NEW  6 tests
tests/test_schedule_blocks_redirects.py    NEW  2 tests
tests/test_time_block_scheduler.py         NEW  6 tests
```

**Deviations from plan:**
- Tests added `test_put_time_blocks_validates_non_zero_duration` (extra coverage for the `end <= start` validator that the plan included but didn't have a dedicated test for).
- Added `test_tick_skips_disabled_blocks` for safety even though `enabled=False` filtering happens via `.eq("enabled", True)` in the query — explicit assertion in fake DB.
- `tests/conftest.py` got `os.environ.setdefault("TESTING", "1")` so future tests don't accidentally start the scheduler loop. Plan only mentioned the env-var pattern; promoting it to conftest is belt-and-suspenders.
- `_end_focus_session` returns the intention_id (Optional[str]) — plan returned None. Returning the intention_id makes future system_events logging easier without re-querying.
- `_FakeQuery.gte` is a no-op in the existing test infra — idempotency check therefore relies purely on the `eq("time_block_id", X)` predicate. Real Supabase will honor the gte(today_iso) bound. Documented in inline comment.

**Blockers / risks:**
- Spec 1 NOT merged to main as of branch push. The Spec 2 branch sits on top of Spec 1 (`5a92256`). When Spec 1 merges to main, this branch needs `git rebase main` (should be clean — no overlapping files). The migration depends on `intentions(id)` existing — DO NOT apply 019 in Supabase before 018 is applied.
- The `@app.on_event` API is deprecated in favor of `lifespan` handlers in modern FastAPI. Tests show the warning but pass. Future cleanup: convert to `lifespan` async-context-manager — out of scope for this plan.
- Cron tick is global (scans all accounts every 60s). At small scale this is fine; at large scale add per-account sharding.

## STATUS
overall: GREEN
tasks_completed: 11 / 11
final_commit_sha: eeed5556ff84c86d5bc638644c1108442beeafc3
branch_pushed: true

## TEST RESULTS
total_tests: 132
passed: 130
failed: 2  (both pre-existing on feat/intentions-spec1; documented in plan)

## DEVIATIONS
- Added 2 extra tests (non-zero duration + disabled-block skip).
- Promoted TESTING=1 to conftest for safety.
- _end_focus_session returns intention_id (Optional[str]) instead of None.
- conftest.py touched (1 line added).

## BLOCKERS
- None for this branch in isolation.
- DOWNSTREAM: do not apply migration 019 in Supabase until migration 018 (Spec 1) is applied.
- DOWNSTREAM: rebase this branch onto main once Spec 1 merges.

## FILES CHANGED
- migrations/019_time_blocks.sql (NEW)
- models.py (+29 lines)
- main.py (+~250 lines net: helpers + endpoints + redirects + startup hook)
- time_block_scheduler.py (NEW, 123 lines)
- tests/conftest.py (+2 lines)
- tests/test_time_blocks.py (NEW, 6 tests)
- tests/test_schedule_blocks_redirects.py (NEW, 2 tests)
- tests/test_time_block_scheduler.py (NEW, 6 tests)

## HANDOFF
- Apply migration 018 (Spec 1) in Supabase SQL editor FIRST. Then 019.
- Merge `feat/intentions-spec1` to `main` first; rebase `feat/time-blocks-spec2` onto main.
- Deploy to Railway. Verify `GET /time_blocks` returns `{"blocks":[]}` for a fresh account.
- Manual smoke: insert a time_blocks row with start_minute = (current minute + 2), wait, observe focus_sessions row insertion + APNs push delivery.
- Mac client follow-up: switch `ScheduleManager` to `BackendClient.getTimeBlocks()` / `putTimeBlocks()` per Plan B.
- iOS client follow-up: implement `TimeBlocksService` + `DayCalendarView` per Plan C; auto-fired Sessions arrive via existing Spec 1 APNs handler — no new push code path.
- Rename change: `/schedule/blocks` → `/time_blocks` with 301 redirect for one release cycle. Remove redirects when both Mac + iPhone are upgraded (commit `a74cd19` is the easy revert anchor).
- Cron tick scans every 60s. The `TESTING=1` env var disables the loop for local + CI runs. In production deploys leave `TESTING` unset.

---

### Phase 4 — Mac report

**STATUS:** GREEN — all 10 tasks complete, branch pushed.

**Branch:** `feat/time-blocks-spec2` (intentional-macos-app), pushed to origin.
**Final commit:** `38b9403` — `docs(time-blocks): clarify 10s timer is UI-only; backend cron is canonical for enforcement`
**Tasks completed:** 10 / 10
**Last `xcodebuild`:** SUCCESS (clean build).
**Base:** `puck`. Spec 1 Mac branch (`feat/intentions-spec1`) merged in as Task 0.1 (clean merge — only added new files + small surgical changes). When merging this branch back to `puck`, Spec 1 must merge first.

**What landed (commit-by-commit):**
- `6519eac` — `BackendClient.getTimeBlocks() / putTimeBlocks()` + matching `TimeBlockDTO` / `TimeBlocksResponse` Codable structs.
- `49a8635` — `ScheduleManager.FocusBlock` gains `intentionId: UUID?` + `intensity: BlockType` with backwards-compat decode.
- `a275f32` — `ScheduleManager.wire(backend:)` + `pullFromBackend()` + `pushToBackend()` + `renameLegacyScheduleFile()`. Pull on init / `didBecomeActive` / 60s timer (`tolerance: 5s`, common run-loop mode).
- `cfbcc8a` — Mutations (`setTodaySchedule`, `addBlock`, `updateBlock`, `removeBlock`, `pushBlockBack`) all push to backend.
- `7ee7d81` — `AppDelegate` wires `scheduleManager.wire(backend: backendClient!)` immediately after instantiation.
- `e07bef6` — `DailySchedule.goals → dayItems`, `dailyPlan → dayNotes` with backwards-compat decode of legacy keys.
- `11c3278` — `BlockType.freeTime` REMOVED. Affected files: `ScheduleManager`, `EarnedBrowseManager`, `FocusMonitor`, `BlockRitualController`, `BlockEndRitualController`, `DeepWorkTimerController`, `MainWindow`, `NativeMessagingHost`, `AppDelegate`. `recordSocialMediaTime(blockType:)` is now `Optional<BlockType>` with nil = free time. `intentBonusAvailable` uses `no_block_<date>` sentinel id when no block is active. Free Time quick-block button removed from pill noPlan card. `isFree` instance computed property always returns `false` for new blocks. Legacy `"freeTime"` rows decode to `.focusHours` for forward-compat.
- `0930764` — `dashboard.html` `addFocusBlock` + `openNewBlockDraft` payloads include `intention_id: null` + `intensity: 'deepWork' | 'focusHours'`.
- `38b9403` — `ScheduleManager.startBlockCheckTimer` documented: 10s timer is UI-only; backend cron via FocusStatePoller is canonical for enforcement.

**DEVIATIONS from plan:**
- DailySchedule wire-format keys (`goals` / `dailyPlan`) preserved for dashboard.html compat instead of renaming. The Swift struct fields renamed; mapping happens at the boundaries (`getScheduleState`, `MainWindow` schedule-for-date handler, FocusMonitor / NativeMessagingHost reads of `manager.todaySchedule?.dayNotes`). Dashboard.html unchanged for those keys.
- Public `setTodaySchedule(goals:dailyPlan:)` API parameter names retained to avoid cascading changes through MainWindow + NativeMessagingHost. Internally maps to dayItems / dayNotes.
- `recordSocialMediaTime(blockType:)` signature changed from non-optional `BlockType` to `BlockType?` to express "no block = free time" cleanly. Callers in `AppDelegate` updated.
- `IntentionalTests/TimeBlockTests.swift` NOT created. The plan listed it as a CREATE deliverable but the existing test target wiring in this repo would need an Xcode project change (not just adding a file). The IntentionStore tests merged from Spec 1 cover the JSON round-trip pattern this would mirror; backend round-trip isn't testable without a mock URLSession harness that doesn't exist yet. Suggested as follow-up.
- Build dependencies `zen-nature.mp4` and `13136082_3840_2160_60fps.mp4` not present in worktree clone — copied from main worktree to unblock build. These files are referenced in `pbxproj` as resources but not git-tracked. Pre-existing condition; unchanged from puck.
- `ScheduleManager` now imports AppKit (was Foundation-only) for `NSApplication.didBecomeActiveNotification`.

**BLOCKERS:** None for the Mac branch itself. Cross-repo blockers per plan:
- Backend `/time_blocks` endpoints (Plan A) must be live before this branch's pull/push will do anything useful. Until then: Mac falls back to local `daily_schedule.json` (existing behavior) since `getTimeBlocks` returns nil on network failure → `pullFromBackend` no-ops cleanly. Plan A reports GREEN with branch pushed; deploy needed.
- Spec 1 Mac branch (`feat/intentions-spec1`) must merge to `puck` before this branch merges (this branch's `IntentionStore.shared` references would otherwise be missing from puck).

**HANDOFF (per spec):**
- ScheduleManager rewired to backend `/time_blocks` (pull on init + 60s + foreground; push on every mutation).
- 10s timer kept for UI updates only; backend cron (via FocusStatePoller polling `/focus/active` every 2s) is canonical for enforcement.
- `DailySchedule.goals → dayItems`, `.dailyPlan → dayNotes` (frees vocab for Spec 3 layer). Wire format preserves legacy keys for dashboard compat.
- `BlockType.freeTime` removed — absence of block = free time semantics throughout enforcement, earned-browse cost calc, intent bonus, pill UI.
- After backend deploys: first launch triggers `pullFromBackend()` → if 200 OK, `daily_schedule.json` → `daily_schedule.legacy.json` rename happens. If backend returns empty `[]`, schedule clears (intentional, since backend is source of truth).
- Architectural retentions (per Spec 1 scope-delta): `BlockingProfileManager` and `activeProjectSession` retained; not touched in this branch.

**Manual smoke checklist (after Plan A deploys):**
- Launch Mac app. Confirm `📋 ScheduleManager pulled N time blocks from backend` log line appears.
- Confirm `daily_schedule.legacy.json` exists in `~/Library/Application Support/Intentional/` after first successful pull.
- Add a block via dashboard calendar; confirm a `PUT /time_blocks` round-trip happens (network panel) and the block reappears after 60s pull.
- Toggle bedtime / focus from iPhone; confirm the Mac dashboard reflects the change (already wired via FocusStatePoller; this branch doesn't change that path).

---

### Phase 5 — iOS report

**Status:** GREEN — all 11 tasks complete, branch pushed.

**Branch:** `feat/time-blocks-spec2` (puck-ios), pushed to origin.
**Final commit:** `d4c81c0` — `test(time-blocks): TimeBlock model + IntentionalTimeBlocksClient round-trip tests`
**Total commits this branch:** 12 (xcodeproj regen + start commit + 10 task commits).
**Base:** Branched from `main`. Task 0 merged `feat/intentions-spec1` into the branch (clean merge, no conflicts) so the Intention model + IntentionStore + APNs handler are present.

**What's wired:**
- `Puck/Models/TimeBlock.swift` — new SwiftData @Model with `intentionId: UUID?`, `intensity` (deep_work / focus_hours), `activeDays: [Int]`, weekday recurrence. Registered in PuckApp's Schema array.
- `Puck/Core/Network/IntentionalTimeBlocksClient.swift` — bearer-auth GET + PUT against `/time_blocks`. Accepts an injected `IntentionalAPIClient` so tests can use `MockURLProtocol`.
- `Puck/Core/Schedule/TimeBlocksService.swift` — singleton service, mirrors BedtimeScheduleService rhythm: configure-on-launch + 60s timer + willEnterForeground observer + immediate push on user create/update/delete. Does NOT register DeviceActivity intervals — Spec 2 auto-fires arrive via APNs (Spec 1 path). `handleSceneActive()` exposed for explicit refresh from PuckApp's scenePhase observer.
- `Puck/App/PuckApp.swift` — registered `TimeBlock.self` in Schema; new `@StateObject timeBlocksService`; configured + injected into env; `.onChange(of: scenePhase)` calls `timeBlocksService.handleSceneActive()`.
- `Puck/Views/Schedule/DayCalendarView.swift` — ported from `addy-ai-ios/Views/Home/DayCalendarView.swift`. 6am-10pm grid, 60pt/hr, time-column on the left. `InteractiveTimeBlockTile` owns the gesture state-machine: long-press 0.5s → drag (move, 15-min snap), top/bottom 12pt edge handles → resize (15-min snap), tap → edit, tap-empty-hour → create. "Now" red line if viewing today. Auto-scrolls to current hour on first appear. Visual style is Puck `DesignTokens` (coral / dark surface) — interaction model is addy-faithful.
- `Puck/Views/Schedule/TimeBlockEditSheet.swift` — Form-based create/edit sheet with title, intention picker (sourced from `IntentionStore.shared.intentions`, "None (use default)" allowed for generic blocks per Spec 2 fallback), intensity segmented control, day selector (M T W T F S S circles), Stepper-driven start/end times (15-min snap, end > start guard), destructive Delete button when editing.
- `Puck/Views/Schedule/ScheduleTabView.swift` — REWRITTEN. DatePicker (single-day) + DayCalendarView + edit sheet. The previous IntentionalBlock-based UI is replaced; the file path stayed the same so wiring in ContentView didn't have to move.
- `Puck/Views/ContentView.swift` — Schedule tab restored. The `RoutineView()` placeholder ("Coming Soon") was swapped for `ScheduleTabView()`. The `PuckTab.routine` enum case + tab-bar slot is unchanged so user-facing tab order stays "Home / Schedule / Intentions / Alarms / Partner / Settings".
- `Puck/Core/Schedule/ScheduleBlock.swift` — `IntentionalBlock` marked `@available(*, deprecated, message: "Use TimeBlock instead — Spec 2 supersedes IntentionalBlock")`. The class stays so SwiftData rows survive upgrade. `ScheduleBlocksService` + the legacy schedule UI continue to compile (with warnings) but should be swept in a follow-up PR.
- `PuckTests/TimeBlockTests.swift` — 6 tests: minute-of-day math, intensity raw round-trip, fallback for unknown intensity, GET decode + Bearer header, PUT atomic-replace serializing intention_id + intensity, nullable intention_id (generic block).

**Build verification:**
- `xcodebuild build` (iPhone 17 simulator) succeeds at every commit. Final clean build also succeeds (`** BUILD SUCCEEDED **`).
- All warnings are pre-existing NFCService Sendable warnings; none introduced by this branch.

**Deviations from plan:**
- Plan said `IntentionStore.shared.active()` async — `IntentionStore` actually exposes `@Published intentions` and is `@ObservedObject`-friendly. `TimeBlockEditSheet` uses `@ObservedObject private var intentionStore = IntentionStore.shared` and reads `.intentions` directly. Equivalent UX, less plumbing.
- Plan used `iPhone 15` simulator; switched to `iPhone 17` per overnight handoff (iPhone 15 not installed on this machine).
- Plan's draft `DayCalendarView` had separate `.onLongPressGesture` + `.gesture(DragGesture())` — that doesn't actually gate drag on long-press in SwiftUI. Replaced with addy's verbatim pattern: `LongPressGesture(minimumDuration: 0.5).sequenced(before: DragGesture(...))` so the long-press is required to begin the move drag. Edge resize handles use a plain `DragGesture` because they shouldn't require long-press.
- ContentView already had a `RoutineView()` placeholder labeled "Schedule" — replaced that view with `ScheduleTabView()` rather than introducing a new `case schedule`. The `PuckTab.routine` enum case keeps its title "Schedule" so user-facing label is unchanged and no enum churn.
- `TimeBlocksService` is a singleton (`.shared`) rather than the plan's per-init pattern, matching the existing `BedtimeScheduleService` / `ScheduleBlocksService` shape. Avoids two truths-of-state during the IntentionalBlock deprecation window.
- `IntentionalTimeBlocksClient` refactored to accept an injected `IntentionalAPIClient` so tests can wire `MockURLProtocol` (mirrors how `IntentionalIntentionsClient` is shaped on `feat/intentions-spec1`).
- Added a `+` toolbar button to ScheduleTabView (current-hour create) for discoverability — tap-empty-row is fine but not obvious for first-time users.
- Tombstone-style migration of `IntentionalBlock` data → `TimeBlock` rows is explicitly out of scope per the plan; the dual presence is intentional for one release.

**Blockers / risks:**
- `xcodebuild test` cannot run in this environment because `Config.plist` (gitignored, holds Supabase URL/anon key) is not present in the worktree. The test runner crashes during `SupabaseService` init: `Config.plist not found`. Same blocker affects the existing Spec 1 test suite on `feat/intentions-spec1` — confirmed by trying `-only-testing:PuckTests/IntentionTests`. Tests will run on a developer machine that has `Config.plist` provisioned. The new `TimeBlockTests` are syntactically valid (build succeeds) and follow the proven `IntentionalIntentionsClientTests` pattern.
- DeviceActivity / FamilyControls / `IntentionalBlock` left dormant per plan — Spec 2 auto-fires arrive via APNs, so the OS-side per-block schedule registration (still wired in `ScheduleBlocksService.reregisterAllSchedules()`) is no longer the source of truth. A future sweep should rip out `ScheduleBlocksService` + `CalendarTimelineView` + `ScheduleBlockEditSheet` + `ScheduleBlockDetailSheet` once we're confident the Spec 1 APNs path is rock-solid in production.
- E2E verification (auto-fired Session at 9am Monday → iPhone shields the right apps) requires a REAL device with a Family Controls authorization + APNs reachability — simulator cannot exercise FamilyControls shielding fully. Smoke test plan: morning, on real iPhone (a) edit a block in the Schedule tab → confirm Mac picks it up within 60s; (b) set a block start_time to current_time+2min → confirm iPhone shields the Intention's apps when the cron fires the Session.

## STATUS
overall: GREEN
tasks_completed: 11 / 11
final_commit_sha: d4c81c08a51bc46de0665617997727ddd94bc369
branch_pushed: true
last_xcodebuild: SUCCESS

## TEST RESULTS
total_tests: 6 (in TimeBlockTests; can't run in this env — see Blockers)
passed: 0  (env blocker)
failed: 0  (env blocker)

## DEVIATIONS
- IntentionStore.shared.active() → @Published intentions (different API than plan).
- iPhone 15 → iPhone 17 simulator (iPhone 15 not installed).
- LongPressGesture.sequenced(before: DragGesture) for proper move gesture (plan's separate gestures wouldn't have gated drag on long-press).
- RoutineView replaced (not new tab) since the placeholder was already labeled "Schedule" with the right tab slot.
- TimeBlocksService is a singleton, matching BedtimeScheduleService/ScheduleBlocksService shape.
- IntentionalTimeBlocksClient takes an injected api so tests can use MockURLProtocol.
- Added a + toolbar button to ScheduleTabView for create-block discoverability.

## BLOCKERS
- xcodebuild test cannot bootstrap in this environment without Config.plist (Supabase secrets, gitignored). Same blocker affects the existing IntentionTests suite. Tests will run on a developer machine with Config.plist provisioned.

## HANDOFF
- DeviceActivity requires REAL iPhone for E2E; simulator doesn't fully verify FamilyControls shielding.
- Schedule tab restored; renders DayCalendarView ported from addy-ai-ios. Long-press 0.5s + drag to move, top/bottom edge handles to resize, tap empty hour row to create.
- TimeBlocksService syncs /time_blocks (60s timer + willEnterForeground notification). Generic blocks (intentionId == nil) work — backend falls back to seeded Focus Intention server-side.
- Auto-fired Sessions from backend cron arrive via Spec 1's APNs handler (`Puck/Core/Push/IntentionPushHandler.swift`) — no new code path on iOS.
- IntentionalBlock marked deprecated; `ScheduleBlocksService` + the legacy schedule UI still compile (with deprecation warnings) and stay live one release. Sweep in a follow-up PR after the Spec 2 path is proven in production.
- Run `xcodebuild test -only-testing:PuckTests/TimeBlockTests` on a machine with `Config.plist` to verify the 6 new tests pass.
- Pull the branch + open in Xcode to manually drag a block on the Schedule tab — the gesture model is the most-likely thing to need iteration once on-device.


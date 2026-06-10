# Plan: Goal-link fix (Step A) + Projects kill (Step B)

Spec: `docs/superpowers/specs/2026-06-10-projects-kill-and-intentionid-fix-design.md`

## Step A — Mac only (this session)

Findings that shaped the plan (verified in code, 2026-06-10):
- `AppDelegate` schedule transition (~line 1045) drops `block?.intentionId`. AI scoring is NOT affected (FocusMonitor reads `currentBlock.intentionId` directly). Broken: (1) sweep intent scope (`period?.intentionId` nil), (2) per-goal block/allow enforcement, (3) backend attribution — `postFocusToggleToBackend` sends `{"action"}` with no `intention_id`, so the server's fallback binds scheduled sessions to the earliest goal → hours_done credits the wrong goal.
- Per-goal enforcement is ALSO broken for manual starts of post-migration goals: `setActiveProjectSession(projectId: intentionId)` → `refreshProjectEnforcement` → ProjectStore lookup misses → enforcement cleared.

### A1. Pass the id at the schedule transition
`activate(intention: block?.title, intentionId: block?.intentionId, source: .schedule)`

### A2. Backend attribution
`postFocusToggleToBackend(action:intentionId:)` — include `intention_id` in body when present; fanout passes `period?.intentionId` on start.

### A3. Goal enforcement
New `refreshIntentionEnforcement(for: UUID)`: IntentionStore lookup → build `FocusMonitor.ProjectEnforcement` from `macWebsites`/`macBundleIds` (block) + `allowWebsites`/`allowBundleIds` (allow). Wire: (a) fanout `.focus` branch calls it when `period?.intentionId` set; (b) `refreshProjectEnforcement` falls through to it when ProjectStore has no match (fixes manual path) instead of clearing; (c) `.off` clears `projectEnforcement`. Guard against stale async application.

### A4. Verify (verifier-intentional-gui)
Dev build replaces production (same user now — takeover works). BEFORE run on unfixed main: stage goal-linked block in `daily_schedule.json`, observe: sweep log without goal intentText, goal-blocked domain not enforced, `/focus/toggle` body without intention_id. AFTER run on fixed build: all three flip. Screenshots + `/tmp/intentional-fresh.log` excerpts. Quit dev → watchdog respawns production.

## Step B — Mac + backend (after A verified)

- B1 backend (intentional-backend): migration 027 `focus_sessions.focus_score numeric NULL`; `/focus/toggle` stop accepts `focus_score`; `GET /intentions/{id}/sessions?limit=N`; pytest.
- B2 Mac: send focus % on stop (from `earnedBrowseManager.blockFocusStats`); fetch+cache recent sessions (`session_history.json`).
- B3 Mac kill: ProjectStore, IntentionMigration, activeProjectSession plumbing (goal enforcement from A3 replaces it), 8 `*_PROJECT_*` handlers; dashboard senders → INTENTION messages; goal panel reads new cache; `LearnedSitesStore` keyed by intentionId with one-shot migrate from projects.legacy.json.
- B4 Light naming: delete `FocusModeStore` typealias.
- B5 Docs: PROJECTS.md → archive; feature docs; CLAUDE.md; cross-repo log `docs/cross-repo-projects-kill-2026-06-10.md`.
- B6 Verify: GUI run-through of goal panel (sessions+focus %), create/edit/delete goal, start/stop session; backend pytest; build.

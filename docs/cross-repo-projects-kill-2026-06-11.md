# Cross-repo log — Projects kill (Step B) + session focus_score

**Date:** 2026-06-11 · **Repos:** intentional-macos-app (this log), intentional-backend (B1, deployed)
**Spec:** `docs/superpowers/specs/2026-06-10-projects-kill-and-intentionid-fix-design.md`
**Plan:** `docs/superpowers/plans/2026-06-10-projects-kill-plan.md` (Step A shipped + verified earlier; this log covers B2–B6)

## What shipped

### Backend (B1 — already deployed before this session, verified live)

- Migration 027: `focus_sessions.focus_score numeric NULL`.
- `POST /focus/toggle` stop accepts optional `focus_score` (0.0–1.0).
- `GET /intentions/{id}/sessions?limit=N` → `{sessions: [{id, started_at, ended_at, duration_seconds, focus_score, triggered_by}]}` (verified live against goal `712c83c5` "Intentional" — real rows returned).

### Mac B2 — focus_score on stop + session history panel

- **`SessionFocusScore.swift` (new):** derives the score from `relevance_log.jsonl` — fraction of relevance assessments inside the session window with `relevant == true`. Excludes `isEvent` (red-shift/intervention events) and `neutral` (neutral-app entries are logged `relevant:true, confidence:0` and would inflate the score). Keeps `userOverride` lines. Requires ≥3 qualifying samples, else returns nil (send nothing, never fabricate). Reads a bounded 8 MB tail of the log off the main thread.
  - Why not `BlockFocusStats`: nothing feeds it post-R6 (EarnedBrowseManager deleted; its tick counts had been all-zeros behind the feature flag long before).
- **`AppDelegate`:** the centralized stop POST (`focusModeController.onStateChanged`, `.focus → .off`, locally-originated) now computes the score from the ended period's window and sends `focus_score` in `postFocusToggleToBackend(action:"stop", focusScore:)`. Derived score and POST result are logged.
- **`BackendClient.getIntentionSessions(id:limit:)` (new)** + **`GoalSessionHistory.swift` (new):** `GoalSession` wire model + `GoalSessionHistoryCache` (`session_history.json`, keyed by intention id, fractional-ISO dates matching the backend).
- **Bridge:** `GET_GOAL_SESSIONS {id}` → `window._goalSessions({id, source: cache|live, sessions})` — replies instantly from cache when present, then refreshes from the live endpoint.
- **Dashboard:** Weekly Goal editor (`renderGoalEdit`) gains a "Recent sessions" section (date · duration · focus % when present; up to 10 rows). Stale-reply guard via `_editingGoalId`.

### Mac B3 — Projects deleted

- **Deleted files:** `ProjectStore.swift` (462 lines: Project/HostItem/SessionEntry/LearnedSite/ProjectSummary/ProjectPatch + actor), `IntentionMigration.swift` (receipt-complete since 2026-05-04), `IntentionalTests/ProjectStoreTests.swift`.
- **`AppDelegate`:** `activeProjectSession` + `setActiveProjectSession` / `clearActiveProjectSession` / `refreshActiveProjectEnforcement` / `ensureProjectSessionMatchesCurrentBlock` / `refreshProjectEnforcement` / `activeProjectId` all deleted. `refreshIntentionEnforcement` is the ONLY per-goal enforcement path (behavior unchanged; stale-guard now reads `currentPeriod.intentionId` only). The `onStateChanged` fanout clears the per-goal overlay when a goal-less session starts (preserves the old clear-on-block-change semantics). Local `SessionEntry` bookkeeping in `onBlockChanged` removed — backend `focus_sessions` is the record.
- **`FocusStatePoller`:** no longer mirrors into `activeProjectSession`; `activate(intentionId:)` + fanout covers enforcement.
- **`MainWindow`:** `START_PROJECT_SESSION`, `GET_PROJECTS`, `GET_PROJECT_DETAIL`, `CREATE_PROJECT`, `UPDATE_PROJECT`, `DELETE_PROJECT` are one-cycle no-op aliases (remove after 2026-07); their handler bodies deleted. `active_intention_id` pushed to the dashboard now reads `focusModeController.currentPeriod.intentionId` (falls back to current block's intentionId). `UPDATE_INTENTION` re-applies enforcement when the edited goal's session is live (replaces the old `refreshActiveProjectEnforcement` guarantee). Blocking-profile delete guard (projects referencing a blocklist) removed with the model.
- **`LearnedSitesStore.swift` (new):** local actor, `learned_sites.json` keyed by intentionId; LRU eviction (cap 200, promoted kept) ported from ProjectStore. One-shot migration from `projects.legacy.json` mapped by project NAME → active Intention (the May 2026 migration's receipt carries no id map); receipt `migration_learned_sites_v1.json`. `PROMOTE_LEARNED_SITE {id, host}` stays live: marks promoted + appends host to the goal's `allow_websites` (+ immediate enforcement re-apply when that goal's session is running); replies `window._learnedSitePromoted`.
- **Dashboard senders switched:** `GET_PROJECTS` dropped (intentionsCache is the index source); detail opens route to the Intent setup form; save → `CREATE_INTENTION` / `UPDATE_INTENTION` (HostItems map: blocked→mac_*, allowed→allow_*); delete → `DELETE_INTENTION`; start → `START_INTENTION_SESSION`.
- `projects.json` / `projects.legacy.json` left on disk untouched.

### Mac B4 — naming

- `typealias FocusModeStore = IntentionStore` deleted (zero code references; comments updated).

## Verification (B6)

See the Step B section of the verification evidence in the PR/commit message: build green per slice; live GUI run on the dev build — goal editor rendered the REAL backend session history for goal "Intentional"; one short manual session's stop POST carried the derived focus_score (log line + new row with score in the panel); PROMOTE_LEARNED_SITE round-trip (store file + allow_websites + receiver).

## Deferred / follow-ups

1. **No live feeder for learned-site hits:** `LearnedSitesStore.recordHit` has no callers (true since the legacy Projects dashboard died; pre-dates this slice). A future slice can feed it from FocusMonitor's relevant-host assessments during goal sessions.
2. **Legacy `*_PROJECT_*` no-op aliases + dashboard ProjectsController dead branches** (`onProjectsList`/`onProjectDetail` receivers, savePending plumbing): remove after 2026-07 with the other one-cycle aliases.
3. **`_handleDelete` in the legacy setup form uses `confirm()`** which WKWebView drops (pre-existing) — the delete button in THAT form is inert; the Weekly Goal editor's delete path is the live one.
4. **iPhone:** sends no focus_score on its stops yet (sessions ended from iPhone will have `focus_score: null`).

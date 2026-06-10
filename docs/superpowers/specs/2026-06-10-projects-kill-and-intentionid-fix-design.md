# Projects Kill + Scheduled-Session Goal-Link Fix — Design

**Date:** 2026-06-10 · **Status:** approved (user, in-session) · **Scope:** intentional-macos-app + intentional-backend. puck-ios untouched (verified zero coupling).

## Problem

1. **Bug:** When a scheduled Time Block starts, `AppDelegate` passes only `block?.title` into `FocusModeController.activate(...)` — `block?.intentionId` is dropped. Result: schedule-started sessions never enforce the Weekly Goal's own block/allow lists and never feed `intentText` to the AI scorer or sweep. Manual starts keep the link. (Backend handles `intention_id` correctly end-to-end; its fallback-binding has been masking this.)
2. **Zombie:** `Project`/`ProjectStore` is the pre-May goal model, superseded by Intentions ("Weekly Goals") but still live on the session-start path; the dashboard still sends legacy `*_PROJECT_*` bridge messages. Backend and iOS have zero project concepts — this is Mac-only surgery.

## Decisions (made with user)

- **Sequencing:** two steps — Step A (bug fix + enforcement reroute) ships and is verified live before Step B (Projects kill).
- **Session history:** backend is the permanent record **including focus %** (new column); Mac caches locally for instant/offline display. Goal detail page keeps looking the same.
- **Learned sites:** stays local; ported to a small store keyed by `intentionId`; data migrated from `projects.legacy.json`.
- **Naming:** light touch — kill `FocusModeStore` typealias and dead aliases; NO Intention→WeeklyGoal sweep, NO backend table rename this slice.
- **Verification:** per `verifier-intentional-gui` skill — before/after live GUI evidence with screenshots; backend pytest.

## Step A — goal-link fix (Mac)

- Pass `block?.intentionId` through `activate(intention:intentionId:source:)` at the schedule transition.
- At `.focus` activation with a resolvable `intentionId`: fetch Intention from `IntentionStore`, apply `macWebsites`/`macBundleIds` (block) + `allowWebsites`/`allowBundleIds` (allow) into FocusMonitor/WebsiteBlocker session enforcement, and surface `intentText`/`outcome` to RelevanceScorer + sweep.
- **Parity rule:** scheduled start of goal X behaves identically to manual start of goal X. Goal lists stack on top of default profile blocking. Globally-active Time Block rules still override per-goal allows (§17b.7).
- **Fail-safe:** lookup failure → today's behavior (default profile only) + log line. Never less enforcement than today.

## Step B — Projects kill (Mac) + focus-% (backend)

Mac deletes: `ProjectStore.swift`, `IntentionMigration.swift` (receipt-complete one-shot), `activeProjectSession`/`setActiveProjectSession`, `projectEnforcement` (replaced by Step A's goal enforcement), 8 `*_PROJECT_*` MainWindow handlers; dashboard senders switch to `*_INTENTION_*`/`START_GOAL_SESSION`; goal detail panel reads recent sessions from backend with local cache (`session_history.json`); new `LearnedSitesStore` (local, keyed by intentionId, one-shot migrate from projects.legacy.json). `projects.json`/`projects.legacy.json` left on disk untouched.

Backend adds: migration 027 `ALTER TABLE focus_sessions ADD COLUMN focus_score numeric NULL`; stop-action on `POST /focus/toggle` accepts optional `focus_score`; `GET /intentions/{id}/sessions?limit=N` returns recent sessions (started_at, ended_at, duration, focus_score). Mac sends focus % on session end.

## Out of scope

Five-list consolidation; `focus_modes` table rename; Tasks layer; Intention→WeeklyGoal rename. Each gets its own spec.

## Risks

- Step A touches the enforcement hot path → smallest possible diff + live before/after verification.
- Dashboard sender switch (PROJECT→INTENTION messages) must be 1:1 verified — every send has a handler (GUI-verified per page).
- relevance_log `grayscale_on/off` precedent: do NOT rename any persisted action strings or message names consumed elsewhere without a receiver-side check.

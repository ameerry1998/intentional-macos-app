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

## TL;DR (continuously updated; final summary at bottom)

(Pending — executors not yet dispatched. Spec 1 verification gate still in progress.)

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

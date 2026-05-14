# Cross-Repo Run — Prototype → Production Port (2026-05-14)

> Authoritative hand-off for the multi-repo prototype-to-production port.
> Per `CLAUDE.md` cross-repo / overnight-work convention.

**Status:** Phase 1 (planning) in progress
**Owner:** Claude (Opus 4.7) → human (Ameer) for Phase 1 sign-off
**Brief:** `docs/prototype-to-production-2026-05-14.md`
**Prototype source of truth:** `docs/unified-design-2026-05-13/app.html`
**Cloud Design source:** `docs/planning-system-design-2026-05-13/Planning Page.html`

---

## Repos touched

| Repo | Branch | Status |
|---|---|---|
| `intentional-macos-app` (this repo) | `slice-13-cleanup` (pushed) → will branch `feat/prototype-to-prod-mac` | Mac + dashboard work |
| `intentional-backend` | will branch `feat/prototype-to-prod-backend` | monthly_goals + extended fields |
| `puck-ios` | `slice-12-puck-alarm-only` | **read-only for this scope** |

---

## Phase 1 — Planning (in progress)

**Deliverables:**
- [x] Read brief, screenshots, Cloud Design React app, existing Spec 1 plan, existing redesign plan
- [x] Inspect backend (`/intentions` route, migrations 018/020/022, Pydantic models)
- [x] Inspect prototype app.html structure (sidebar, view containers, Plan embed pattern, Weekly Goal editor)
- [ ] Write `docs/superpowers/plans/2026-05-14-prototype-to-production-plan-a-backend.md`
- [ ] Write `docs/superpowers/plans/2026-05-14-prototype-to-production-plan-b-mac.md`
- [ ] Write `docs/superpowers/plans/2026-05-14-prototype-to-production-plan-c-dashboard.md`
- [ ] Surface open questions to human for sign-off

**Blockers:** None.

---

## Phase 2 — Implementation (queued, awaits sign-off)

Per `superpowers:subagent-driven-development`. Order:

1. **Plan A (backend)** ships first — Mac + dashboard need the endpoints + new fields live.
2. **Plan B (Mac)** + **Plan C (dashboard)** can run in parallel after A merges. Mac needs the new bridge messages before dashboard JS calls them; dashboard work can land first if bridge messages are added as no-op shims in Mac side first.

Verification gate per slice (per `superpowers:verification-before-completion`):
- Backend: pytest suite green + curl smoke against deployed Railway
- Mac: `xcodebuild` BUILD SUCCEEDED + PKG build clean
- Dashboard: Playwright tests pass + visual inspection of `/tmp/intentional-pw/*.png`

---

## Phase 3 — PRs (queued)

- 1 PR per repo, descriptions referencing brief + plan
- Mac PR includes both Plan B (Swift) + Plan C (dashboard) changes since they live in the same repo
- No auto-merge; leave for human review

---

## Live progress log

### 2026-05-14 — Phase 1 start
- 13:30 — Picked up handoff. Reading brief + linked files.

### 2026-05-14 — Phase 2 start (execution)
- User issued /goal command for autonomous run. Subagent-driven-development engaged.
- Backend worktree created: `intentional-backend/.claude/worktrees/prototype-to-production` on `feat/prototype-to-production` (cut from main @ 460055e). Initial empty commit @ daae2a0.
- Plan A (backend) executing first — Mac + dashboard depend on the new endpoints.
- Dispatching subagent for A2 (migration 026) + A3 (Intention extensions) + A4 (MonthlyGoal Pydantic models).

### 2026-05-14 — Phase 2A (backend) DONE
- **Backend PR opened:** https://github.com/ameerry1998/intentional-backend/pull/5 (branch `feat/prototype-to-production`, 12 commits ahead of main)
- Migration 026 ships against `focus_modes` (the underlying table) and refreshes the `intentions` VIEW so legacy queries surface the new columns transparently. Adaptation flagged in PR description.
- MonthlyGoal CRUD endpoints + extended `/intentions` round-trip + `?week` filter all wired.
- Tests: 19 new tests pass + 17 pre-existing intentions tests still pass; 2 unrelated pre-existing failures untouched.
- **Live deploy DEFERRED** per goal command (DNS still stale; live-smoke skipped). Migration apply + Railway deploy is a human step before Mac PR merge.

### 2026-05-14 — Phase 2B (Mac) start
- Setting up Mac worktree at `intentional-macos-app/.claude/worktrees/prototype-to-production` on branch `feat/prototype-to-production`.
- Backend inspection: migration 018 created `intentions` table; 020 added `strictness_preset`, `weekly_budget_hours`, `budget_enforcement` columns + `intention_strictness_changes` tracking table; 022 renamed `intentions` → `focus_modes` and created `intentions` SQL view alias. Endpoints `/intentions` + `/focus_modes` both live. Pydantic models: `Intention`, `IntentionCreate`, `IntentionUpdate`, `IntentionListResponse` in `models.py:623+`.
- Prototype inspection: sidebar at app.html:659-673 (5 items + bottom blocking pill + theme toggle). view-plan mounts React app via `<div id="plan-react-root"></div>` inside `<div class="cd-plan" data-theme="dark">`. PlanApp React component embedded inline at app.html:2295-2724 (~430 lines). Weekly Goal editor at app.html:895-924 (view) + 1172-1290 (`openWeeklyGoalEdit` JS). Custom Rules sub-page at 1293-1340.
- Backend ENDPOINT TLS issue (the user's iPhone-login blocker) **separate workstream**: I deleted+recreated the Railway custom domain (old ID `23b4cc0d-...` → new `66bdab15-...` on edge `b7qg65hf`). User needs to update Cloudflare CNAME `api` to `b7qg65hf.up.railway.app` (currently still `m5n78aku`) with grey-cloud proxy off. Once DNS updates, I'll verify cert. **This is independent of the prototype-port work and does not block Phase 1.**

---

## Open questions to surface at end of Phase 1

(Final list lands in the user-facing sign-off message; pre-draft here so it's already captured.)

1. Migration semantics for existing intentions data — default values for new fields?
2. "Monthly Goal" lifecycle — calendar month, rolling 30 days, or user-defined date range?
3. Drag-to-schedule semantics — does dropping a weekly card on the timeline always create a session for *today*, or does it ask which day?
4. Goal → session binding strictness — does running a session outside its parent goal's strictness still respect that strictness, or fall back to global?
5. Cross-device sync for monthly goals — silent APNs like intention sessions, or 60s pull only?
6. Theme persistence scope — per-device (UserDefaults only) or per-account (backend-synced)?
7. Schema rollout — feature-flag monthly_goals behind an env var, or unconditional?
8. "Help me plan" button — placeholder for v1, or wire to a real LLM endpoint?

---

## Files created by this run

- `docs/overnight-run-2026-05-14.md` (this file)
- `docs/superpowers/plans/2026-05-14-prototype-to-production-plan-a-backend.md` (pending)
- `docs/superpowers/plans/2026-05-14-prototype-to-production-plan-b-mac.md` (pending)
- `docs/superpowers/plans/2026-05-14-prototype-to-production-plan-c-dashboard.md` (pending)

---

**TL;DR:** Cross-repo log started. Phase 1 planning underway; three plans to write before the user signs off and Phase 2 implementation begins.

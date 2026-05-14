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
- Worktree cut from `slice-13-cleanup` (not `main`) because slice-13-cleanup contains the unified-design prototype + planning docs that the implementation depends on.
- Build verification confirmed: `xcodebuild build CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO` → BUILD SUCCEEDED. The signed-build path fails on provisioning profiles (Apple Developer agreement renewal pending — separate blocker called out in goal command). All Mac slices use this no-signing build flag for verification.
- Two large mp4 resources (`zen-nature.mp4`, `13136082_3840_2160_60fps.mp4`, ~270 MB total) live outside git (gitignored); symlinked from parent checkout into worktree so xcodebuild finds them.

### 2026-05-14 — Phase 2B (Mac Swift) DONE
- **B1-B2:** `Intention.swift` extended with 9 new fields + tolerant decoder + `GoalStatus` enum. New `MonthlyGoal.swift` model + payloads.
- **B3-B4:** 5 new `BackendClient` methods + `?week=` filter on `getIntentions`. New `MonthlyGoalStore.swift` actor (disk cache + 60s sync + 409 handling).
- **B5:** `AppDelegate.swift` wires `MonthlyGoalStore`. New `IntentTextMigration.swift` (one-shot, idempotent via receipt).
- **B6:** `MainWindow.swift` — 7 new bridge cases + 6 handlers + `monthlyGoalToDict` + extended `intentionToDict` with 9 fields. Observer for `.monthlyGoalsDidChange`.
- **B7:** `CLAUDE.md` updated with new architecture section.
- 9 commits on `feat/prototype-to-production` for Plan B.

### 2026-05-14 — Phase 2C (Dashboard) DONE
- **C1:** Sidebar restructure (5 items, Focus Modes nav removed). Bottom-left blocking pill. `#page-plan` stub container. **Theme toggle SKIPPED** per goal command + §17b.12.
- **C2:** Today header weekly-goal cards strip (`#now-card-mount`) + drag-to-schedule wiring. Cards click → editor; grip drag → `START_GOAL_SESSION`.
- **C3:** Plan tab — Cloud Design React app embedded verbatim (React 18 + Babel CDN). Lazy-mount on `navigateTo('plan')`. Bridge-fed MONTHLY + WEEKLY state with hardcoded fallback.
- **C4:** Full-page Weekly Goal editor (`#page-goal-edit`) + Custom Rules sub-page (`.cr-page`). Wired to `UPDATE_INTENTION`, `DELETE_INTENTION`, `LINK_WEEKLY_TO_MONTHLY`, `CREATE_MONTHLY_GOAL`, `UPDATE_INTENTION_STRICTNESS` bridge messages.
- **Playwright tests for dashboard.html SKIPPED** (per user direction mid-run): file:// runs in Chromium, not WKWebView, so it's a smoke check at best — not a real verification. Memory saved: `feedback_meaningful_tests.md`. The existing `weekly-goal-click.mjs` already exercises the prototype's Today + Plan + editor flows and remains the canonical Playwright reference. Real verification of `dashboard.html` is launching the Mac app — deferred to after Apple Dev agreement renewal.
- 6 commits on `feat/prototype-to-production` for Plan C (4 production + 2 leftover bridge-test-mode commits that survived from an earlier dispatch — harmless).

### 2026-05-14 — Phase 3 (PRs) DONE
- **Backend PR #5:** https://github.com/ameerry1998/intentional-backend/pull/5 (base: `main`, 12 commits). Migration 026 + MonthlyGoal CRUD + extended intentions endpoints.
- **Mac PR #3:** https://github.com/ameerry1998/intentional-macos-app/pull/3 (base: `slice-13-cleanup`, 15 commits). Plan B Swift + Plan C dashboard.
- Both PRs reference the brief + requirements + plan files in their descriptions.
- **Neither merged** per goal command — leave for human review.

### 2026-05-14 — Fix wave (17 issues from post-install audit) DONE
After installing the first PKG and clicking through, the user surfaced gaps the original plans didn't cover. Audited against `docs/requirements-2026-05-14.md` and shipped 17 fixes across 5 subagent waves:

- **Wave 1 (6 small fixes):** FIX-3 (+ New weekly/monthly goal flow), FIX-4 (intention→weekly-goal copy sweep), FIX-5 (empty-state replaces hardcoded fallback), FIX-8 (originating sidebar tab stays highlighted), FIX-14 (strict week_of filter on Today), FIX-16 (calendar drop-target narrowed to .calendar-hour-track[data-hour]).
- **Wave 2 (drag wire):** FIX-2 (drag-to-schedule creates real TimeBlock via new CREATE_SCHEDULED_SESSION bridge → ScheduleManager.addBlock → backend pushToBackend; legacy START_GOAL_SESSION kept as alias).
- **Wave 3 (Opal Blocks + dependent fixes):** FIX-1 (Today→Schedule/Blocks toggle + block list + create/edit + BlockingProfile model extended with schedule fields), FIX-6 (sidebar pill wired to real active-rule count), FIX-9 (block-conflict warning when adding to goal's Allow list).
- **Wave 4 (data-flow):** FIX-7 (Plan history derived from live cache + GET_INTENTIONS_FOR_WEEK on-demand fetch), FIX-10 (strictness pills greyed during active session — pushScheduleUpdate now stamps active_intention_id), FIX-11 (RelevanceScorer respects per-goal aiScoringEnabled + intentText — 4 callers updated in FocusMonitor + NativeMessagingHost).
- **Wave 5 (UI surfaces):** FIX-12 (Settings 11-subpage drilldown with aliases for spec-compliant IDs), FIX-13 (new session overlay on empty calendar hour click), FIX-15 (status footer wired — partner/content-safety/puck pulls on launch).
- **FIX-17:** Backend POST /time_blocks — verified `PUT /time_blocks` exists (atomic replace, accepts intention_id). Mac uses ScheduleManager.pushToBackend which already calls it. No backend changes needed.

All 17 fixes are committed to `feat/prototype-to-production`. Build verified clean with `CODE_SIGNING_ALLOWED=NO` after each wave. Total: 20+ commits added on top of the original prototype port work.

### FOLLOW-UP CALLED OUT: FIX-18 — Block rule enforcement (Opal-parity gap)
After Wave 3 the user inspected the new Blocks page and surfaced a fundamental gap: **the schedule fields on a BlockingProfile are stored but not enforced.** The Mac has `WebsiteBlocker`, `FocusMonitor`, `FocusModeController`, etc. but those only engage during an active focus *session* (via FocusModeController.activate). Standalone time-windowed block rules are inert — a rule set to "Weekdays 9–5" doesn't trigger anything at 9am.

To get Opal-parity for actual blocking, the gap is:
- New `RuleEnforcer` that ticks every 30–60s, checks each BlockingProfile.isCurrentlyActive, applies the union of blocklists via WebsiteBlocker + app process monitor
- Replace the JS prompt()-based block create/edit modal with a proper native-style modal
- Add countdown timer + progress bar on the active block card
- Add app categories (Social/Games/News/etc) so user doesn't type each site
- Cancel button on active block card
- Difficulty / bypass-mode per block (separate from per-goal strictness)
- "Set Time Limit" + "Set Open Limit" quick actions (currently stubs)

This is net-new scope beyond the original 17 — call it FIX-18, est. ~3–4 hours. Not included in this PR.
- `api.intentional.social` Cloudflare DNS still points at stale Railway edge `m5n78aku`; needs updating to `b7qg65hf.up.railway.app` (grey-cloud off). Until then, iOS login + Mac live-backend smoke fail with TLS -9802. Backend deploy of migration 026 can still happen via Railway dashboard / direct Supabase SQL editor — doesn't require DNS.
- Apple Developer agreement renewal pending — signed/notarized PKG build doesn't run locally. All Mac verification was done with `CODE_SIGNING_ALLOWED=NO` flag. Once renewed: `./scripts/build-pkg.sh` should produce a working notarizable PKG, then manual smoke per the Mac PR test plan.

### Action required from human (in priority order)
1. **Deploy backend first:** merge PR #5 → Railway auto-deploys → run `migrations/026_weekly_monthly_goals.sql` against production Supabase (via Railway dashboard or `psql`). Migration is additive — safe during business hours.
2. **Fix Cloudflare DNS:** update `api` CNAME to `b7qg65hf.up.railway.app`, grey-cloud (proxy off). Once propagated, iOS unblocks.
3. **Renew Apple Dev agreement,** then build + install the Mac PKG to verify the dashboard flow end-to-end.
4. **Manual smoke pass:** launch app → click Plan → click weekly card → edit → Done → confirm `UPDATE_INTENTION` round-trips. If green, merge PR #3.
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

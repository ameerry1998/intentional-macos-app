---
feature: Rules
status: shipping
owner: Intentional Mac
last_verified: 2026-06-11
files:
  - Intentional/Rule.swift
  - Intentional/RuleStore.swift
  - Intentional/RulesMigration.swift
  - Intentional/RulesMigrationPlan.swift
  - Intentional/BackendClient.swift
  - Intentional/MainWindow.swift
  - Intentional/AppDelegate.swift
  - Intentional/dashboard.html
  - Intentional/EnforcementResolver.swift
  - Intentional/FocusMonitor.swift
  - Intentional/WebsiteBlocker.swift
  - Intentional/focus-blocked.html
  - scripts/rules-migration-dryrun/main.swift
related:
  - focus-sessions
---

## TL;DR

One sidebar tab for everything block/limit/allow. A **rule** = target (site or app) + treatment (🚫 blocked / ⏳ limited / ✅ allowed) + optional schedule window. Limited targets spend a single shared daily **leisure pool** (renamed: **allowance**, 2026-06-11) (base minutes + minutes earned by focusing, 5:1 default, 60-min rollover cap); at zero they hard-block with an earn-path prompt. Rules are account-scoped on the backend (`rules` table, migration 028) and sync Mac ↔ iPhone.

Spec: `docs/superpowers/specs/2026-06-10-rules-consolidation-design.md` · Plan: `docs/superpowers/plans/2026-06-10-rules-consolidation-plan.md` · Research: `docs/blocks-consolidation-research-2026-06-10.md`

## Status (R-slices)

- R1 backend (rules + leisure_pool tables (renamed: allowance, 2026-06-11), endpoints, 34 tests): done on `intentional-backend:feat/rules-table` — **NOT deployed; migration 028 pending in Supabase**
- R2 Mac data layer (RuleStore actor, cache, bridge): done, committed
- R3 Rules page UI (5-tab sidebar, pool card, sections, add-rule modal, asymmetric partner-gating): done — server round-trips verified graceful-fail until deploy
- R4 enforcement unification: done — EnforcementResolver (one precedence: per-goal allow > ✅ > 🚫/⏳gate > goal blocklist > default) feeds both FocusMonitor and WebsiteBlocker; allow-lists now protect SITES (verified live before/after); session-start + sweep honor rule enabled/snoozes; Strict Mode lock gates real-store mutations server-side-of-bridge (verified refusal with live lock). ⏳ outside sessions = TODO(R5). Follow-up holes filed: SAVE_STRICT_MODE_LOCKS itself ungated; legacy UPDATE_BLOCK_RULE ungated.
- R5 earn engine: done, partially live-verified 2026-06-11 (backend deployed + live; allowance card/pill/zero-state verified on-machine; the two checks needing a free foreground — ⏳ active-tab spend accrual and a real session-end earn post — still pending a user-idle window, see slice report) — earn on session end (.focus→.off in AppDelegate posts wall-clock session minutes to /allowance/earn with period-id dedupe; EarnedBrowseManager.blockFocusStats was investigated and is dead behind featureEnabled=false, TimeTracker only meters social platforms, so wall clock is the live signal); out-of-session ⏳ spend metering via FocusMonitor's 5s allowance meter (whole-minute POSTs, ≥30s throttle, local pending between posts); `AllowanceBalance` mirrors server truth + pending spend for the sync enforcement paths; at zero the resolver gates ⏳ as blocked out-of-session too — WebsiteBlocker walls ⏳ sites with focus-blocked.html?mode=allowance ("Focus 30 min to earn N more" + intentional://start-focus deep link), FocusMonitor walls ⏳ apps with the blocking overlay; pill gains `.allowanceBalance` ("⏳ N min") shown out-of-session when ⏳ was used in the last 15 min or balance < base. EarnedBrowseManager NOT deleted (R6) — featureEnabled stays false so no double-metering.
- R6 migration + Settings cleanup: done + live-verified 2026-06-11 — one-shot `RulesMigration` (receipt `migration_rules_v1.json`, idempotent + resumable, backs originals up to a timestamped dir BEFORE any mutation, renames them to `*.legacy.json` only after every create lands) moved the user's real data: BlockingProfile block rules → 🚫 (schedule blob = the R3 editor shape `{start,end,days}`; enabled state preserved — the user's 2 disabled profiles became 10 disabled 🚫 site rules), AlwaysAllowedStore → ✅ (12 rules), backend always_blocked + distractions rows → 🚫 (0 rows for this account; tables NOT deleted — retire with their endpoints later). Collisions: 🚫 beats ✅; duplicate 🚫 targets keep the stricter copy; 409 = logged skip. Pure planner (`RulesMigrationPlan`) is rehearsable standalone via `scripts/rules-migration-dryrun/` and in-app via env `INTENTIONAL_RULES_MIGRATION_DRY_RUN=1`. Settings rows + detail pages Distractions / Always Blocked / Always Allowed (and the orphaned Distraction Budget page) deleted; Today "Blocks" sub-tab + moved-banner + Block Now/Pomodoro quick actions deleted (Schedule sub-tab is the only Today view); sidebar pill now counts schedule-active 🚫/⏳ rules and opens Rules. Removed bridge messages are one-cycle no-op aliases (GET/SAVE_ALWAYS_ALLOWED, GET/ADD/REMOVE_DISTRACTIONS + ALWAYS_BLOCKED, GET/SET_BUDGET_*, GET_EARNED_STATUS, REQUEST/VERIFY_EXTRA_TIME*). EarnedBrowseManager DELETED (BlockFocusStats extracted as the celebration data carrier; TimeTracker.onSocialMediaTimeRecorded removed — EarnedBrowse was its only consumer). Two enforcement-parity fixes shipped with the migration: the close-the-noise sweep unions ✅ rules into its never-touch list + 🚫/⏳ rules into its auto-stash inputs (the emptied legacy stores would otherwise have dropped those signals), and FocusMonitor gained an out-of-session 🚫 app-rule pre-gate (pre-R6 that signal only flowed from profiles via BlockRuleEnforcer). BlockingProfileManager + BlockRuleEnforcer code KEPT (resolver still reads their layers) but their stores are now empty — removal is a later slice.

## Key invariants

- Asymmetric locking: tightening always free; loosening (delete/disable 🚫, demote, raise base/cap, lower rate) partner-gated when Strict Mode on — `isLooseningAction` in dashboard.html.
- Site targets normalized server-side (lowercase, scheme/www/path stripped); duplicates rejected 409 → inline UI error.
- Pool day-boundary is server-local (UTC) — flagged for R5 tz handling.

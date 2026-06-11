---
feature: Rules
status: wip
owner: Intentional Mac
last_verified: 2026-06-11
files:
  - Intentional/Rule.swift
  - Intentional/RuleStore.swift
  - Intentional/BackendClient.swift
  - Intentional/MainWindow.swift
  - Intentional/dashboard.html
  - Intentional/EnforcementResolver.swift
  - Intentional/FocusMonitor.swift
  - Intentional/WebsiteBlocker.swift
  - Intentional/focus-blocked.html
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
- R6 migration + Settings cleanup: NOT STARTED — legacy Settings pages (Always Blocked/Allowed/Distractions) and Today Blocks sub-tab intentionally still live

## Key invariants

- Asymmetric locking: tightening always free; loosening (delete/disable 🚫, demote, raise base/cap, lower rate) partner-gated when Strict Mode on — `isLooseningAction` in dashboard.html.
- Site targets normalized server-side (lowercase, scheme/www/path stripped); duplicates rejected 409 → inline UI error.
- Pool day-boundary is server-local (UTC) — flagged for R5 tz handling.

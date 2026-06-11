---
feature: Rules
status: wip
owner: Intentional Mac
last_verified: 2026-06-10
files:
  - Intentional/Rule.swift
  - Intentional/RuleStore.swift
  - Intentional/BackendClient.swift
  - Intentional/MainWindow.swift
  - Intentional/dashboard.html
related:
  - focus-sessions
---

## TL;DR

One sidebar tab for everything block/limit/allow. A **rule** = target (site or app) + treatment (🚫 blocked / ⏳ limited / ✅ allowed) + optional schedule window. Limited targets spend a single shared daily **leisure pool** (base minutes + minutes earned by focusing, 5:1 default, 60-min rollover cap); at zero they hard-block with an earn-path prompt. Rules are account-scoped on the backend (`rules` table, migration 028) and sync Mac ↔ iPhone.

Spec: `docs/superpowers/specs/2026-06-10-rules-consolidation-design.md` · Plan: `docs/superpowers/plans/2026-06-10-rules-consolidation-plan.md` · Research: `docs/blocks-consolidation-research-2026-06-10.md`

## Status (R-slices)

- R1 backend (rules + leisure_pool tables, endpoints, 34 tests): done on `intentional-backend:feat/rules-table` — **NOT deployed; migration 028 pending in Supabase**
- R2 Mac data layer (RuleStore actor, cache, bridge): done, committed
- R3 Rules page UI (5-tab sidebar, pool card, sections, add-rule modal, asymmetric partner-gating): done — server round-trips verified graceful-fail until deploy
- R4 enforcement unification: done — EnforcementResolver (one precedence: per-goal allow > ✅ > 🚫/⏳gate > goal blocklist > default) feeds both FocusMonitor and WebsiteBlocker; allow-lists now protect SITES (verified live before/after); session-start + sweep honor rule enabled/snoozes; Strict Mode lock gates real-store mutations server-side-of-bridge (verified refusal with live lock). ⏳ outside sessions = TODO(R5). Follow-up holes filed: SAVE_STRICT_MODE_LOCKS itself ungated; legacy UPDATE_BLOCK_RULE ungated.
- R5 earn engine: NOT STARTED (old EarnedBrowseManager remains feature-flagged off)
- R6 migration + Settings cleanup: NOT STARTED — legacy Settings pages (Always Blocked/Allowed/Distractions) and Today Blocks sub-tab intentionally still live

## Key invariants

- Asymmetric locking: tightening always free; loosening (delete/disable 🚫, demote, raise base/cap, lower rate) partner-gated when Strict Mode on — `isLooseningAction` in dashboard.html.
- Site targets normalized server-side (lowercase, scheme/www/path stripped); duplicates rejected 409 → inline UI error.
- Pool day-boundary is server-local (UTC) — flagged for R5 tz handling.

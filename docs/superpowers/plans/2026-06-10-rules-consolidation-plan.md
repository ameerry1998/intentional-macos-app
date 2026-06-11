# Plan: Rules Consolidation

Spec: `docs/superpowers/specs/2026-06-10-rules-consolidation-design.md` (user-approved).
Research: `docs/blocks-consolidation-research-2026-06-10.md` — implementers MUST read both.
Mandate: no half-working controls; every slice verified before the next starts.

## Slices (strict order — each gates the next)

**R1. Backend: rules table + pool (intentional-backend, branch `feat/rules-table` off main)**
Migration 028: `rules` (id, account_id, target_kind site|app, target, treatment blocked|limited|allowed, schedule jsonb nullable, enabled bool, created/updated) + `leisure_pool` (account_id, date, base_minutes default 15, earned_minutes, spent_minutes, bank_minutes, earn_rate default 5, bank_cap default 60). CRUD `/rules` (dual auth like /intentions), `GET/PUT /leisure_pool/today`, `POST /leisure_pool/earn|spend` (idempotent increments). Pytest per repo patterns. NOT pushed/deployed — wire format documented in commit for R2.

**R2. Mac data layer: RuleStore**
Actor mirroring IntentionStore (pull launch+foreground+60s, cache `rules.json`), Codable Rule struct matching R1 wire format, bridge messages GET/CREATE/UPDATE/DELETE_RULE + GET_LEISURE_POOL. No UI. Unit-testable decode/merge.

**R3. Rules page UI + sidebar tab**
Sidebar: Today / Goals / Rules / Accountability / Settings. Page = one list grouped by treatment, add-rule modal (target + treatment + optional schedule), toggle/snooze/edit/delete per row, pool card (base/earned/spent/left + rate/base/cap editors). Partner-gate loosening actions (asymmetric, per spec #5) via existing unlock sheet. Old Today "Blocks" sub-tab content replaced by a link to Rules (kill in R6). Verify: every control via ui-test hook + screenshots.

**R4. Enforcement unification (the dangerous one — smallest possible diffs, before/after evidence per fix)**
(a) WebsiteBlocker consults ✅ allow rules (closes the site allow-list gap); (b) session-start + sweep honor rule enabled/snooze (kills the default-profile trap); (c) one precedence: per-goal allow > ✅ > 🚫/⏳gate > goal blocklist > default — same code path for sites and apps; (d) Strict-Mode lock checks move to the real rule store. Enforcement reads RuleStore; BlockingProfileManager becomes read-only legacy behind it.

**R5. Earn engine rebuild**
Pool source of truth = backend (R1), local cache for offline. Earn: on session end, focusedMinutes/earn_rate credited (server-side from focus_sessions where possible). Spend: TimeTracker AppleScript path meters foreground/active-tab time on ⏳ targets during free time only (sessions treat ⏳ as 🚫). Zero → blocked page variant with "Focus N min to earn M more" + Start button. Pill shows "⏳ N min". Old EarnedBrowseManager deleted (flag + dead feed per research).

**R6. Migration + Settings cleanup + docs**
One-shot receipt-stamped migration: block rules→🚫 (schedules kept), AlwaysAllowedStore→✅, backend always_blocked/distractions rows→🚫/✅; nothing auto-⏳; legacy files renamed .legacy. Settings rows Always Blocked/Always Allowed/Distractions removed; Today Blocks sub-tab removed; feature doc + CLAUDE.md + cross-repo log `docs/cross-repo-rules-2026-06-XX.md`.

## Deploy gate (explicit)
R1 (and the parked feat/session-history) live on local backend branches. Mac slices R2/R5 verify fully end-to-end ONLY after the user pushes + deploys + runs migrations in Supabase. Until then: backend = pytest; Mac = build + UI + cache-path verification, deploy-dependent checks listed per slice and re-run post-deploy.

## Verification bar (every slice)
Build green; ui-test hook + verifier-intentional-gui pass on touched surfaces; R4 fixes each carry before/after live evidence; R6 migration rehearsed on a copy of the user's real data before running for real (backup first).

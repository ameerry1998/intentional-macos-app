# Cross-Repo Log — Rules Consolidation (R1–R6), 2026-06-11

Authoritative hand-off for the Rules Consolidation feature across
`intentional-macos-app` + `intentional-backend`. Per-slice detail lives in
`docs/features/rules.md`; spec at
`docs/superpowers/specs/2026-06-10-rules-consolidation-design.md`; plan at
`docs/superpowers/plans/2026-06-10-rules-consolidation-plan.md`.

## What shipped (both repos)

### intentional-backend (branch `feat/rules-table` → DEPLOYED + live)
- Migration 028: `rules` table (account-scoped; `target_kind site|app`,
  `treatment blocked|limited|allowed`, opaque `schedule` jsonb, `enabled`)
  + `allowance` table (née `leisure_pool`; base 15 / earn-rate 5:1 / bank cap 60).
- Endpoints: `/rules` CRUD (dual auth — JWT or X-Device-ID; site targets
  normalized server-side; 409 on duplicate target), `GET /allowance/today`,
  `POST /allowance/earn` (session-id dedupe) / `POST /allowance/spend`
  (clamped), `PUT /allowance/config` (range-validated). 34 pytest tests.
- **NOT changed:** `always_blocked` + `distractions` tables and their
  endpoints still exist (now unread by any UI — see "Deferred").

### intentional-macos-app (R2–R6, all on main, NOT committed by R6 yet)
- R2: `Rule.swift` + `RuleStore.swift` (actor, cache `rules.json` /
  `allowance.json`, pull launch+foreground+60s) + bridge messages.
- R3: Rules page (5-tab sidebar), grouped 🚫/⏳/✅ list, add-rule modal with
  the schedule blob `{start,end,days}`, allowance card + editors, asymmetric
  Strict-Mode gating in JS (`isLooseningAction`).
- R4: `EnforcementResolver` — ONE precedence (per-goal allow > ✅ >
  🚫/⏳gate > goal blocklist > default) feeding WebsiteBlocker + FocusMonitor
  via `RuleEnforcementMirror`; real-store strict-mode gates in MainWindow.
- R5: allowance earn on session end (wall-clock, deduped), ⏳ spend metering
  (FocusMonitor 5s meter), zero-balance wall (`focus-blocked.html?mode=allowance`),
  pill `⏳ N min`.
- **R6 (this slice, 2026-06-11):**
  - `RulesMigration` + `RulesMigrationPlan` (+ standalone rehearsal driver
    `scripts/rules-migration-dryrun/`) — one-shot, receipt
    `migration_rules_v1.json`, resumable, backup-first. **Ran live on the
    user's real account:** 22 rules created (10 🚫 site rules from 2 disabled
    BlockingProfiles — enabled=false preserved; 12 ✅ rules from
    AlwaysAllowedStore), 1 duplicate skip (youtube.com in both profiles),
    0 backend taxonomy rows existed. Originals backed up to
    `migration_backup_rules_v1_20260611-143433/` and renamed
    `blocking_profiles.legacy.json` / `always_allowed.legacy.json`; live
    stores written empty (prevents default re-seed).
  - Settings cleanup: Distractions / Always Blocked / Always Allowed rows +
    detail pages deleted (plus the orphaned Distraction Budget page); Today
    "Blocks" sub-tab + moved-banner + Block Now/Pomodoro quick actions
    deleted; sidebar pill rewired to count schedule-active 🚫/⏳ rules and
    open the Rules page. Removed bridge messages → one-cycle no-op aliases
    (remove after 2026-07): `GET/SAVE_ALWAYS_ALLOWED`,
    `GET/ADD/REMOVE_DISTRACTION(S)`, `GET/ADD/REMOVE_ALWAYS_BLOCKED`,
    `GET_BUDGET_STATE`, `SET_BUDGET_CONFIG`, `GET_EARNED_STATUS`,
    `REQUEST_EXTRA_TIME`, `VERIFY_EXTRA_TIME_CODE`.
  - Legacy engine retirement: `EarnedBrowseManager.swift` DELETED (~560
    lines; was feature-flagged off with a dead feeder). `BlockFocusStats`
    extracted to its own file as the celebration data carrier.
    `TimeTracker.onSocialMediaTimeRecorded` removed (EarnedBrowse was its
    only consumer). Earned Browse hidden widget + Extra Time flow + their
    JS/CSS deleted from dashboard.html.
  - Enforcement-parity fixes shipped with the migration (the emptied legacy
    stores would otherwise have dropped these signals): the close-the-noise
    sweep unions ✅ rules into its never-touch list and 🚫/⏳ rules into its
    auto-stash inputs; FocusMonitor gained an out-of-session 🚫 app-rule
    pre-gate (pre-R6, out-of-session app blocking flowed only from profiles
    via BlockRuleEnforcer).

## Live verification evidence (R6, 2026-06-11)

- Dry-run rehearsal (standalone driver on COPIES of real data) printed the
  exact 22-rule plan before the live run; a synthetic rehearsal exercised
  collisions (🚫 beats ✅), duplicate-strictness merge, URL normalization,
  schedule conversion, backend-row classification, and existing-rule skip.
- Live run at dev-launch: 22/22 creates succeeded, receipt stamped,
  `curl /rules` shows exactly the 22 expected rows.
- Rules page renders all 22 (ui-test hook: 10 blocked + 12 allowed rows) —
  screenshot taken with real data.
- Settings menu = Strict Mode / Account / Strictness / Sensitive Content /
  Bedtime / Reset & Delete only; no ghost detail pages, no Blocks tab, no
  earned widget (DOM-verified).
- Enforcement spot-checks: temp 🚫 rule on example.com closed my own test
  tab out-of-session (redirected to blocked.html) within ~5s; ✅
  music.apple.com tab survived a ~2.5-min session (sweep counted the 12
  rule-fed always-allowed entries: "Always-allowed: 8 apps, 4 domains" with
  an EMPTY legacy store). Incidental: DELETE_RULE on the temp 🚫 rule was
  refused by the live daemon-level Strict-Mode lock ("Strict Mode locks Site
  & app blocks") — the R4 real-store gate works; cleanup went via backend
  DELETE (restoring pre-test state).

## Deferred / still pending

1. **Backend taxonomy retirement:** `always_blocked` + `distractions` tables
   and `/distractions` + `/always_blocked` + `/focus_modes/{id}/app_rules`
   endpoints are now read by NOTHING except `RulesMigration` (which keeps
   them as a migration source for other devices/accounts). Drop after the
   migration has run everywhere.
2. **023-tables drop still pending:** `distraction_budget_config` +
   `distraction_budget_state` (migration 023) and the `/budget_state` +
   `/budget_config` endpoints lost their last UI client in R6 (the orphaned
   Budget page + dual-write hooks are gone). `BackendClient`'s budget methods
   remain but have no callers. Drop tables + endpoints + client methods in a
   backend cleanup slice.
3. **BlockingProfileManager + BlockRuleEnforcer removal:** code kept (the
   resolver still reads their — now empty — layers, and legacy bridge
   handlers reference them). Remove in a later slice along with the legacy
   profiles JS (`onBlockingProfiles`, `loadBlockingProfiles`) and the
   one-cycle no-op aliases (after 2026-07).
4. **Production (caity) instance:** still runs the pre-R6 build with its own
   copies of the legacy local files. When the new build reaches
   `/Applications`, its migration will run for that user; duplicate creates
   409 → logged skips (idempotent). Until then production enforces from its
   own legacy profiles — both users' profiles were disabled, so no behavior
   divergence.
5. **iOS:** consumes synced site rules in a separate slice (per spec §7) —
   nothing iOS-side shipped in R1–R6.
6. `earned_browse.json` left orphaned on disk (not a migration source; the
   allowance starts fresh server-side). Harmless; delete whenever.

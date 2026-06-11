# Block / Allow / Distraction List Systems — Ground-Truth Research

**Date:** 2026-06-10
**Status:** Research artifact — facts only, no design proposals. Input for the consolidation design.
**Repos covered:** `intentional-macos-app` (primary), `intentional-backend`, `puck-ios`.
**Method:** every claim below was traced to a file:line in current `main` (mac app HEAD `b14d88e`, includes today's `ddfe652` goal-link fix and `c979d27`/`a7d6109` calm-down commits).

---

## 0. Census — how many list systems exist

Distinct user-or-system-maintained block/allow/distraction lists found:

| # | System | Storage | Enforced? |
|---|---|---|---|
| A | BlockingProfile / "Block Rules" | `blocking_profiles.json` (local) + `block_rule_snoozes.json` | ✅ yes (2 layers) |
| B | Backend app taxonomy: `distractions` + `always_blocked` tables | Postgres (account-scoped) | ❌ **never enforced on Mac** (UI-only) |
| B2 | Backend `focus_mode_app_rules` table | Postgres | ❌ **zero clients anywhere** |
| C | AlwaysAllowedStore | `always_allowed.json` (local) | ✅ sweep-only |
| D | Per-goal lists on Intention (`mac_websites`/`mac_bundle_ids`/`allow_websites`/`allow_bundle_ids`) | backend `focus_modes` table + local `intentions.json` cache | ✅ yes (since today's ddfe652 fix) |
| E | Earned Browse pool + Distraction Budget | `earned_browse.json` (local) + backend `distraction_budget_*` tables | ❌ feature-flagged OFF + feeder dead |
| F | iOS per-block blocklists (`ApplicationToken` sets) | App Group UserDefaults (`schedule_block_tokens_<id>`) | ✅ yes (iOS shield) |
| G1 | `alwaysRelevantSites` (settings JSON) | `onboarding_settings.json` | ✅ yes (skips AI, marks relevant) |
| G2 | Legacy `distractingSites`/`distractingApps` (settings JSON) | `onboarding_settings.json` + backend settings sync | ⚠️ not read by enforcement; **is** the strict-mode constraint source |
| G3 | Hardcoded `alwaysAllowedBundleIds` (~100 dev tools) + `com.apple.*` rule | compiled into FocusMonitor | ✅ yes |
| G4 | Hardcoded `socialMediaHostnames` (YT/IG/FB) | compiled into FocusMonitor | ✅ yes (always-irrelevant during session) |
| G5 | LearnedOverrideStore (promoted hosts) | UserDefaults + relevance JSONL | ✅ yes (forces OCR pass) |
| G6 | Legacy Project `allowed`/`blocked`/`learned`/`blocklistIds` | `projects.json` | ⚠️ only via legacy session path |
| G7 | JS category presets (Social/Games/News/Streaming/Shopping) | hardcoded in dashboard.html | n/a (input helper for A) |
| G8 | NE FilterExtension `blocklist.json` (App Group) | App Group container | ❌ `FilterManager.updateBlocklist` has **zero callers** |

That is **8 enforced-or-partially-enforced list systems plus 5+ dead/orphaned ones**.

---

## 1. System A — BlockingProfile / Block Rules

### 1.1 Storage + schema

- Model: `BlockingProfile` — `Intentional/BlockingProfileManager.swift:5–97`. Fields: `id, name, blockedDomains[], blockedAppBundleIds[], isDefault, alwaysActive, enabled, startHour/startMinute/endHour/endMinute (optional schedule), activeDays[ISO 1–7]`. Tolerant decoding (`:52–66`).
- `isCurrentlyActive` computed: enabled AND (no schedule OR now inside window+day) — `BlockingProfileManager.swift:71–91`.
- File: `~/Library/Application Support/Intentional/blocking_profiles.json` (`:148`). Save pretty-printed/sorted (`:307–316`).
- Seeded default on first run: profile named **"Distracting Apps & Sites"**, `isDefault: true`, `alwaysActive: false`, 10 domains (reddit/twitter/x/youtube/instagram/facebook/tiktok/twitch/discord/snapchat) + 4 app bundle ids (Spotify, Twitch, Discord, Steam) — `:120–165`.
- Snoozes: `~/Library/Application Support/Intentional/block_rule_snoozes.json`, dict `{profileUUID: releaseDate}` — `BlockRuleEnforcer.swift:47–52, 167–181`.
- The whole class carries `@available(*, deprecated, message: "Profile concept folded into Focus Mode app rules. Use FocusModeStore. Will be removed in slice 13.")` — `BlockingProfileManager.swift:106` — **but it is the live, primary block-rules engine today**. (`FocusModeStore` does not exist; the annotation points at a never-built thing.)
- **Local-only. Zero backend sync.** A second Mac gets none of these rules.

### 1.2 Write paths (UI control → bridge → handler)

All in `Intentional/dashboard.html` (Today → Blocks sub-tab) → `Intentional/MainWindow.swift`:

| Control | JS fn (dashboard.html) | Bridge msg | Handler (MainWindow.swift) |
|---|---|---|---|
| "+ New Block" / "Set Limits" / empty-state link | `openBlockRuleCreate()` :9576 → modal → `_saveBlockRuleFromModal()` :9772 | `CREATE_BLOCK_RULE` (alias `CREATE_BLOCKING_PROFILE`) | `handleCreateBlockingProfile` :2441–2471 |
| Block card click → edit modal Save | `openBlockRuleEdit()` :9592 → `_saveBlockRuleFromModal()` | `UPDATE_BLOCK_RULE` (alias `UPDATE_BLOCKING_PROFILE`) | `handleUpdateBlockingProfile` :2473–2503 |
| Card on/off toggle | `toggleBlockRule()` :9546 (optimistic) | `TOGGLE_BLOCK_RULE` | `handleToggleBlockRule` :2505–2512 |
| Modal "Delete" (confirm() — works; MainWindow implements `runJavaScriptConfirmPanel` :362) | `_deleteBlockRuleFromModal()` :9813 | `DELETE_BLOCK_RULE` | `handleDeleteBlockingProfile` :2514–2536 (refuses if a legacy Project references the profile) |
| "Snooze for today" (on ACTIVE card) | `snoozeBlockRule()` :9520 | `SNOOZE_BLOCK_RULE` | MainWindow :634–640 → `BlockRuleEnforcer.snoozeForRemainderOfWindow` (BlockRuleEnforcer.swift:88–116) |
| "Resume now" (on SNOOZED card) | `unsnoozeBlockRule()` :9527 | `UNSNOOZE_BLOCK_RULE` | MainWindow :642–648 → `clearSnooze` |
| Category chips Social/Games/News/**Streaming**/Shopping | `_addBlockCategory()` :9831–9852, presets :9820–9827 | (none — mutates modal draft) | n/a |
| "+ Add app" picker | `_openBlockRuleAppPicker()` :9722 (reuses installed-apps picker) | `GET_INSTALLED_APPS` for names | n/a |

Every create/update/toggle/delete handler calls `appDelegate.applyAlwaysActiveProfiles()` + `BlockRuleEnforcer.shared.reevaluateNow()` so changes engage instantly (MainWindow :2466–2470, 2499–2502, 2507–2511, 2530–2533).

Read path for UI: `GET_BLOCKING_PROFILES`/`GET_BLOCK_RULES` → `handleGetBlockingProfiles` :2424–2437, emits BOTH the legacy `onBlockingProfiles` (struct JSON) and the new snake_case `_blockingProfilesList` (via `blockingProfileToDict` :2394–2422 which adds `is_currently_active`, `is_in_window`, `is_snoozed`, `snoozed_until`). JS receiver :9410; renders cards :9443–9518; sidebar "N blocking" pill :9390–9407.

### 1.3 Read / enforcement paths — TWO separate layers

**Layer 1 — standalone (BlockRuleEnforcer), works WITHOUT a focus session:**
- `BlockRuleEnforcer` (`Intentional/BlockRuleEnforcer.swift`), wired+started at `AppDelegate.swift:969–977`. 30s ticker (`:63–72`) + `reevaluateNow()` on every mutation.
- Each tick (`:144–163`): filters profiles via `isEffectivelyActive` (enabled + in-window + **not snoozed**, `:137–140`), unions domains+bundleIds, pushes:
  - domains → `WebsiteBlocker.setStandaloneBlocklist` (`WebsiteBlocker.swift:129–143`; stored in `standaloneDomains` :32; auto-starts the 0.5s tab sweep if not running)
  - apps → `FocusMonitor.setStandaloneBlockedBundleIds` (`FocusMonitor.swift:97–105`; immediately re-evaluates frontmost app)
- App-side, out-of-session: `evaluateApp` checks `standaloneBlockedBundleIds` BEFORE the focus-mode gate (`FocusMonitor.swift:1645–1650`) → `handleStandaloneBlockedApp` (`:3171–3203`) shows the full blocking overlay regardless of enforcement settings.
- Tab-side: `WebsiteBlocker.effectiveBlockedDomains` = session `blockedDomains` ∪ `standaloneDomains` (`WebsiteBlocker.swift:37–44`); `shouldBlock` does host == or `.suffix` match (`:1044–1079`); matching tabs are redirected to `blocked.html` on a 0.5s AppleScript sweep across all browsers.

**Layer 2 — session-fed (legacy "profiles" pathway), only during a focus session:**
- On `.focus` entry, `FocusModeController.onStateChanged` calls `applyDefaultBlockingProfile()` (`AppDelegate.swift:828–836` → `:1837–1848`): merges **the `isDefault` profile only** and feeds `WebsiteBlocker.updateDistractingSites` + `FocusMonitor.distractingAppBundleIds`.
  - ⚠️ `applyDefaultBlockingProfile` checks ONLY `isDefault` — **NOT `enabled`, NOT snooze**. Toggling the default rule OFF in the Blocks tab does not stop it from being applied as the session blocklist (see §8 precedence traps).
- Manual legacy path `applyFocusSession(profileIds:)` merges explicit profile ids (`AppDelegate.swift:1744–1776`).
- On `.off`, `applyAlwaysActiveProfiles()` (`AppDelegate.swift:865–867, 1791–1798`) feeds the union of profiles with the **legacy `alwaysActive` flag** — which the new Blocks modal never sets (modal "Always active" = null schedule, a different concept). So for rules created via the current UI this layer is empty and Layer 1 carries all out-of-session enforcement.
- `FocusMonitor.evaluateApp` during a session blocks `distractingAppBundleIds ∪ standaloneBlockedBundleIds` (`FocusMonitor.swift:1785–1822`) — no grace period, deep-work → overlay, focus-hours → nudge.
- Sweep integration: `BlockingProfileManager.activeBlockedDomains()/activeBlockedBundleIds()` (`:291–303`) feed `Sweeper.decideTab/decideApp` as auto-stash/auto-hide inputs (`AppDelegate.swift:1916–1917`, `Sweeper.swift:150–153, 167`). ⚠️ These helpers use `isCurrentlyActive` directly — they do **NOT** consult snoozes (`BlockRuleEnforcer.currentlySnoozedIds` is not checked), so a snoozed rule still stashes tabs at session start.

### 1.4 Sync behavior

None. Local JSON only. Snoozes survive restart via receipt file. The iPhone never sees Block Rules; the backend never sees them.

### 1.5 What breaks if it moves

- `BlockRuleEnforcer` tick + `StandaloneBlockEvaluator` consumers.
- `applyDefaultBlockingProfile` / `applyAlwaysActiveProfiles` / `applyFocusSession` (AppDelegate session feed).
- Sweep `activeBlockedDomains/BundleIds`.
- Legacy Project `blocklistIds` resolution (`AppDelegate.refreshProjectEnforcement:178, 195–198`) and the delete-guard (`MainWindow:2514–2527`).
- Dashboard legacy `syncLegacyVars()` (dashboard.html:7439–7449) which mirrors the default profile into settings-JSON `distractingSites`/`distractingApps` — which in turn is the source for the backend strict-mode constraint blob (§7.2).
- Strict Mode UI promises "Can't delete or disable a block (snooze for today still works)" (dashboard.html:6352–6358) — note: **no Swift code enforces this lock today** (the `block_rules` key of `strictModeLocks` is stored at MainWindow:546–555 but never consulted by `handleDeleteBlockingProfile`/`handleToggleBlockRule`).

---

## 2. System B — Backend app taxonomy (`distractions`, `always_blocked`, `focus_mode_app_rules`)

### 2.1 Storage + schema

Migration `intentional-backend/migrations/024_app_taxonomy.sql`:
- `distractions(account_id, app_identifier, added_at)` PK (account_id, app_identifier) — "apps here drain the cohesive distraction budget".
- `always_blocked(account_id, app_identifier, added_at)` — "never usable".
- `focus_mode_app_rules(focus_mode_id, app_identifier, rule_type ∈ {block, allow}, added_at)` — per-Focus-Mode overrides.
- `app_identifier` is free-text: bundle id, domain, or iOS token marker — no kind discrimination.

### 2.2 Endpoints (intentional-backend/main.py)

| Endpoint | Lines |
|---|---|
| `GET /distractions` | 4232–4244 |
| `POST /distractions` | 4247–4260 (upsert) |
| `DELETE /distractions/{app_identifier}` | 4263–4272 |
| `GET /always_blocked` | 4276–4288 |
| `POST /always_blocked` | 4291–4304 |
| `DELETE /always_blocked/{app_identifier}` | 4307–4315 |
| `GET/POST/DELETE /focus_modes/{id}/app_rules` | 4319–4366 |

Auth: `_resolve_account_dual_auth` (JWT or X-Device-ID).

### 2.3 Mac write paths

- `BackendClient.getDistractions/getAlwaysBlocked/addDistraction/addAlwaysBlocked/removeDistraction/removeAlwaysBlocked` — `BackendClient.swift:2172–2258`.
- Bridge: `GET_DISTRACTIONS`, `ADD_DISTRACTION`, `REMOVE_DISTRACTION`, `GET_ALWAYS_BLOCKED`, `ADD_ALWAYS_BLOCKED`, `REMOVE_ALWAYS_BLOCKED` — `MainWindow.swift:687–707` → `handleGetAppList/handleAddAppList/handleRemoveAppList` :3358–3396 → JS receiver `window._appListResult` (dashboard.html:6611).
- UI: Settings → **Distractions** detail page (dashboard.html:5869–5883; menu row :5469; fetch on open :6313–6314) and Settings → **Always Blocked** detail page (:5947–5965; menu row :5474; fetch :6315–6316). Single text input each ("youtube.com or com.tiktok.app") + × remove per row (`addDistractionEntry` :6642, `addAlwaysBlockedEntry` :6649).
- The distractions list count is also surfaced on Focus Mode cards: `distractionsCache` (dashboard.html:9335, populated by `_appListResult`; `GET_DISTRACTIONS` fired on load at :13342; rendered as "N distractions + M mode-specific" at :13594–13604).

### 2.4 Read / enforcement paths

- **Mac: NONE.** The only Swift callers of `getDistractions`/`getAlwaysBlocked` are `MainWindow.handleGetAppList` (UI round-trip). `WebsiteBlocker`, `FocusMonitor`, `BlockRuleEnforcer`, the sweep — none read these tables. Adding `youtube.com` to "Always Blocked" does nothing.
- **iOS: NONE.** No `puck-ios` source references `/distractions` or `/always_blocked`.
- **`focus_mode_app_rules`: zero clients in any repo** (grep across both apps). Pure dead schema+endpoints.
- **Backend-side `enforcement.py` does NOT read these tables either.** `derive_enforcement_blob` reads the *settings JSON blob* keys `distractingSites` (lines 54–60 → constraint `distracting_sites: must_include_all`) and `alwaysBlockedApps` (lines 72–80 → `always_blocked_apps: must_include_all`). The settings key `alwaysBlockedApps` is **never written by any client** (not in `MainWindow.saveSettingsToFile` params nor `syncSettings` payload :1388–1401), so the `always_blocked_apps` constraint never materializes. The Mac's `EnforcementReconciler` has key mappings ready for both (`EnforcementReconciler.swift:180, 184`).

### 2.5 What breaks if it moves

Only the two Settings detail pages and the "N distractions" hint on Focus Mode cards. No enforcement regression possible — there is none.

---

## 3. System C — AlwaysAllowedStore (global allow list, sweep-scoped)

### 3.1 Storage + schema

- `AlwaysAllowedList { bundleIds: Set<String>, domains: Set<String> }` + `AlwaysAllowedStore` — `Intentional/AlwaysAllowedList.swift:5–78`. File: `~/Library/Application Support/Intentional/always_allowed.json` (`:38`).
- Ships defaults: System Settings, Calendar, Messages, Music, Spotify, 1Password×2, Finder; domains music.apple.com, 1password.com, calendar.google.com, icloud.com (`:9–26`).
- Domain matching: suffix (`isDomainAllowed` :57–63).
- One-shot migration `MigrationAlwaysAllowed.runIfNeeded` (`Intentional/MigrationAlwaysAllowed.swift:11–44`, run at `AppDelegate.swift:453–457`): unions every Intention's old per-goal `allowWebsites`/`allowBundleIds` from `intentions.json` into the global store; receipt `migration_always_allowed_v1.json`. (Note: per-goal allow lists were later resurrected as live fields — see §4 — so the same data now exists in two semantics.)

### 3.2 Write paths

- Settings → **Always Allowed** detail page (dashboard.html:5918–5944; menu row :5479). Apps + domains inputs; add/remove → `persistAlwaysAllowed()` :6727 → bridge `SAVE_ALWAYS_ALLOWED` → MainWindow :582–588 → `store.replace(...)`.
- Read bridge: `GET_ALWAYS_ALLOWED` → MainWindow :570–580 → JS `_alwaysAllowedResult` :6661.
- 🐛 **The page never sends `GET_ALWAYS_ALLOWED`**: `showSettingsDetail` (dashboard.html:6307–6329) wires fetch-on-open for `distractions`, `always-blocked`, `budget`, `enforcement` — but **not** `always-allowed`. Zero other senders in dashboard.html. The lists render "Loading…" forever; saving from that state would replace the store with empty arrays if the user adds one entry (state starts `{bundleIds:[], domains:[]}` :6657).

### 3.3 Read / enforcement paths

- **Sweep only.** `AppDelegate.runCloseTheNoiseSweep` guards on the store (`AppDelegate.swift:1864`), logs counts (`:1945`), passes the list into `Sweeper.decideTab` (keep precedence #2 after pinned — `Sweeper.swift:147–149`) and `Sweeper.decideApp` (keep precedence #1 — `:166`).
- **NOT consulted by FocusMonitor or WebsiteBlocker.** In-session enforcement uses the entirely separate hardcoded `FocusMonitor.alwaysAllowedBundleIds` (~100 dev/system apps, `FocusMonitor.swift:208+`) and `alwaysRelevantHostnames` from settings JSON (§7.1). Three different "always allowed" concepts coexist.

### 3.4 What breaks if it moves

Sweep `decideTab/decideApp` signatures; `MigrationAlwaysAllowed`; the Settings page; `SweepBenchmark` test cases that take an `AlwaysAllowedList`.

---

## 4. System D — Per-goal lists on Intention (Weekly Goal / Focus Mode)

### 4.1 Storage + schema

- Swift: `Intention.macWebsites/macBundleIds` (block) + `allowWebsites/allowBundleIds` (allow) — `Intentional/Intention.swift:51–52, 87–89`; tolerant decode :182–202; round-tripped in `IntentionCreatePayload`/`IntentionUpdatePayload` :213–287.
- Backend: `focus_modes` table (renamed from `intentions` in migration 022 with a compat VIEW). `mac_websites`/`mac_bundle_ids` from migration 018; `allow_websites`/`allow_bundle_ids` (+ `intent_text`, `ai_scoring_enabled`, `week_of`, …) from migration 026. CRUD round-trip at `main.py:3599–3666`; row mapping :3477–3495.
- Day-1 seed: fresh accounts get a "Focus" intention with 8 blocked domains (twitter/x/reddit/HN/youtube/instagram/tiktok/facebook), no apps — `main.py:3501–3530`.
- Local cache: `~/Library/Application Support/Intentional/intentions.json` via `IntentionStore` (pull on launch/foreground/60s).

### 4.2 Write paths

- Goal editor → "Custom rules" page (`openGoalCustomRules`, dashboard.html:10569–10643): Block section (+ Site / + App) and Allow section (+ Site / + App); `addRule`/`removeRule` :10661–10712 mutate the cached goal then `_sendIntentionUpdate` :10637 → bridge `UPDATE_INTENTION` → `MainWindow.handleUpdateIntention` → `IntentionStore` → `PUT /intentions/{id}`.
  - `addRule` shows a confirm() heads-up when an Allow entry collides with an enabled Block Rule ("won't override that during the blocked window") — :10666–10681. (confirm() works; WKUIDelegate panel at MainWindow:362.)
- iOS: `IntentionEditView` writes `ios_app_tokens_b64`/`ios_category_tokens_b64` (FamilyActivitySelection) on the same record; Mac stores+forwards, never decodes.
- Legacy ProjectsController "Focus Modes" page maps `mac_websites`/`mac_bundle_ids` into its Setup form (dashboard.html:13520–13528).

### 4.3 Read / enforcement paths (the 2026-06-10 fix)

- `AppDelegate.refreshIntentionEnforcement(for:)` (`AppDelegate.swift:146–166`, added in `ddfe652` today): builds `FocusMonitor.ProjectEnforcement` with `allowedBundleIds=allowBundleIds, allowedDomains=allowWebsites, blockedBundleIds=macBundleIds, blockedDomains=macWebsites`; stale-guards against the currently-active goal; sets `focusMonitor.projectEnforcement`.
- Call sites: `.focus` entry with `period.intentionId` (`AppDelegate.swift:838–843`); boot-reconcile after mid-session restart (`:943–945`); fallback from `refreshProjectEnforcement` when no legacy Project matches (`:168–177`); manual session start via `setActiveProjectSession` (`:104–106`).
- Cleared on `.off` (`AppDelegate.swift:870`).
- Enforcement semantics (`FocusMonitor.ProjectEnforcement.verdict`, `FocusMonitor.swift:109–131`): **allow checked before block**; domain matching exact-or-suffix. Apps evaluated at `evaluateApp:1729–1778` (allow → relevant + work ticks; block → forced overlay, ignores block-type softness). Browser tabs at `processActiveTabInfo:2141–2185` (allow → skip AI; block → hard redirect to focus-blocked page).
- ⚠️ **`allowWebsites` does NOT reach WebsiteBlocker.** The 0.5s tab-redirector has no allow-list concept (`WebsiteBlocker.swift` contains zero references to allow lists or the Intention). A domain in both the default profile and a goal's Allow list still gets its tab closed (§8).
- ⚠️ **`macWebsites` per-goal blocks are enforced only via FocusMonitor's frontmost-tab scoring path**, not via the WebsiteBlocker background sweep — a goal-blocked site in a background tab isn't auto-closed; only when focused.

### 4.4 Sync

Full cross-device sync via backend, optimistic versioning, APNs push to iOS on session start. This is the ONLY block/allow system that syncs.

### 4.5 What breaks if it moves

`refreshIntentionEnforcement` + `ProjectEnforcement`; Custom-rules editor; iOS `BlockingService`/`IntentionPushHandler` (consume `ios_app_tokens` from the same record — `puck-ios/Puck/Core/Blocking/BlockingService.swift:165`, `Core/Push/IntentionPushHandler.swift:85`); `MigrationAlwaysAllowed` (reads old allow fields from cache); migration 026 columns.

---

## 5. System E — Earned Browse engine + Distraction Budget

### 5.1 Current truth: the engine is feature-flagged OFF

`EarnedBrowseManager.featureEnabled = false` — `Intentional/EarnedBrowseManager.swift:17` (`static let`, commit `50025c6` "feat(earned): gate behind featureEnabled flag (default off)"). Every public method early-returns; `availableMinutes` returns 0. **The claim "fully alive" is true of the call-site plumbing, not the engine: FocusMonitor still calls into it on every tick, but every call no-ops.**

Additionally the *consume* feeder is dead independent of the flag: `TimeTracker.recordUsageHeartbeat` / `recordTime` (`TimeTracker.swift:126, 170`) have **zero callers** since the Chrome-extension removal (2026-05-21). `onSocialMediaTimeRecorded` (wired at `AppDelegate.swift:673–682`) can never fire.

### 5.2 The mechanism (preserved code — the concept the user wants to KEEP)

- Earning: `recordWorkTick(seconds:)` on each relevant ~10s tick (`EarnedBrowseManager.swift:137–163`). Rates: standard 0.2 (5 min work → 1 min browse), deep-work 0.3 (`:41–43`). Deep-work auto-detect: 25-min all-relevant rolling window (`:244–272`).
- Spending: `recordSocialMediaTime(minutes:blockType:isFreeBrowse:)` (`:172–197`). Cost multipliers: deepWork 0× (blocked outright), focusHours 2×, free time 1×, free-browse 2× (`:48–52, 175–185`).
- Extras: welcome credit 5 min/day (`:71, 310`), intent bonus +10 min once/block (`:76, 340–362`), partner extra time +30 default (`:66, 327–333`), AI-override budget 2/block (`:223–238`), per-block focus stats + focusScore (`:88–104`).
- Persistence: `~/Library/Application Support/Intentional/earned_browse.json` (`:130`), daily reset (`:294–322`).
- FocusMonitor call sites that survive: `recordWorkTick` (e.g. `FocusMonitor.swift:2097, 2118, 2154, 2218, 2292, 2571, 3377`), `recordAssessment` (≈12 sites), `overridesRemaining`/`useOverride` (`:1311–1341`), `recordNudge` (`:3269, 3508`), `incrementRecoveryCount` (`:2782`), `availableMinutes` reads for the pill (`:822, 1034, 1089`).

### 5.3 Cross-device Distraction Budget (Slice 3/8 of 2026-05-05 redesign)

- Backend: migration 023 — `distraction_budget_config(account_id, baseline_minutes default 60, is_locked)` + `distraction_budget_state(account_id, day, earned_minutes, consumed_minutes)`.
- Endpoints (`main.py`): `GET /budget_state` :4415–4436 (available = baseline + earned − consumed), `POST /budget_state/consume` :4439–4455, `POST /budget_state/earn` :4458–4474, `PUT /budget_config` :4477–4508 (423 when locked without `partner_code`; **partner-code verification is a TODO — any non-empty string passes**, :4495–4498).
- Mac client: `BackendClient.swift:2074–2166` (`getBudgetState/postBudgetConsume/postBudgetEarn/putBudgetConfig`). Dual-write hooks inside `recordWorkTick`/`recordSocialMediaTime` (`EarnedBrowseManager.swift:158–162, 191–194`) — **dead because of the feature flag**.
- Mac bridge: `GET_BUDGET_STATE` / `SET_BUDGET_CONFIG` (`MainWindow.swift:708–713` → `handleGetBudgetState`/`handleSetBudgetConfig` :3398–3430 → JS `_budgetState` dashboard.html:6788).
- iOS client: `getBudgetState` + consume in `puck-ios/Puck/Core/Network/IntentionalAPIClient.swift:378–394`; **no iOS UI/logic calls them** (D9 placeholder; `ScheduleTabView.swift:12–13, 48, 84–86` reserves a 0-height budget header).

### 5.4 UI surfaces

- **Hidden dashboard widget**: "Earned Browse" card with avail/used bars, platform usage, cost indicator, deep-work flag, full partner Extra Time flow (15/30/60 pills → 6-digit code grid → verify) — `dashboard.html:5182–5244`, wrapper `style="…display:none;"` :5182, comment "hidden — stripped for Puck model". JS still calls `GET_EARNED_STATUS` on load (:12943); Swift still pushes `pushEarnedUpdate` (`MainWindow.swift:3236`).
- **Orphaned Budget settings page**: `settings-detail-budget` (baseline input, partner-lock toggle, live readout, Save → `SET_BUDGET_CONFIG`) — dashboard.html:5886–5916, JS :6786–6824. **No settings-menu row navigates to it** (menu rows :5445–5499 — no `showSettingsDetail('budget')` anywhere). Reachable only from console.
- Distractions settings page copy *promises* budget semantics: "Apps and sites that drain your daily Distraction Budget… At zero budget remaining, all of these are locked for the rest of the day" (:5872) — **nothing implements that lock**.
- Docs: `docs/EARNED_BROWSE_SYSTEM.md`, `docs/EARN_YOUR_BROWSE_IMPLEMENTATION.md`, `docs/UNIFIED_BUDGET_DESIGN.md` (the "one daily pool" unified design).

### 5.5 What breaks if it moves

Pill stats (focusScore/overrides read through EarnedBrowseManager), celebration cards, `GET_EARNED_STATUS` payload shape, `REQUEST_EXTRA_TIME`/`VERIFY_EXTRA_TIME_CODE` flow, backend budget tables/endpoints (shared with future iOS).

---

## 6. System F — iOS coupling (puck-ios)

- **Per-block blocklists are local-only `ApplicationToken` sets** in App Group UserDefaults: `BedtimeSharedStorage.saveBlockBlocklist/loadBlockBlocklist` keyed `schedule_block_tokens_<blockId>` — `puck-ios/Puck/Core/Bedtime/BedtimeSharedStorage.swift:163–180`; per-block metadata (shortName `schedule_<8hex>`, activeDays) :147–192.
- **DeviceActivity extension** dispatches on activity-name prefix: `bedtime` vs `schedule_` — `puck-ios/PuckBedtimeMonitor/DeviceActivityMonitorExtension.swift:29–50`; applies a per-block `ManagedSettingsStore` shield from `loadBlockBlocklist` at `:94`.
- **Block timing source of truth**: `GET/PUT /schedule/blocks` (`puck-ios/Puck/Core/Network/IntentionalScheduleClient.swift:29–47`; backend migration `017_schedule_blocks.sql`, table `schedule_blocks`). ⚠️ The Mac does **not** read `/schedule_blocks`; the Mac schedule syncs through the separate `/time_blocks` endpoint (migration 019; `ScheduleManager.swift:550, 587`; `BackendClient.swift:1974–1996`). **Two parallel schedule tables exist on the backend.**
- **Intention blocklists on iOS**: `Intention.iosAppTokens/iosCategoryTokens` (opaque, set by `IntentionEditView`, migrated by `IntentionMigrationRunner.swift:125–156`); applied by `BlockingService` (`Core/Blocking/BlockingService.swift:165`) and by `IntentionPushHandler` on silent APNs when a Mac session starts (`Core/Push/IntentionPushHandler.swift:32, 85`). iOS never reads `mac_websites`/`mac_bundle_ids`; Mac never reads the iOS tokens. Clean split on the same row.
- **No iOS usage** of `/distractions`, `/always_blocked`, block rules, or budget UI.

What breaks if lists move: nothing iOS-side as long as the `focus_modes` row keeps `ios_app_tokens`/`ios_category_tokens` and the silent-push flow; `schedule_blocks` and App Group token sets are fully decoupled from all Mac lists.

---

## 7. System G — the other list systems (discovered during trace)

### 7.1 `alwaysRelevantSites` (settings JSON → AI bypass)

- Stored in `onboarding_settings.json` key `alwaysRelevantSites`; loaded at launch (`AppDelegate.swift:711–714`) and on backend-settings sync (`:1536–1537`); updated on `SAVE_SETTINGS` (`MainWindow.swift:1378–1382`); synced to backend in settings payload (`:1394`).
- Enforcement: `FocusMonitor.alwaysRelevantHostnames` (`FocusMonitor.swift:87, 158–166`) — during a session a matching tab skips AI and is treated relevant + earns ticks (`:2205–2222`).
- UI today: populated only through the **legacy profiles JS** (`getAlwaysRelevant` per-profile map `profileAlwaysRelevant`, dashboard.html:7049, 7159–7164; mirrored to the flat settings key by `syncLegacyVars` :7439–7449). The profiles UI markup is gone — `document.getElementById('profile-list-rows')` has **no corresponding element** — so `renderProfileList` no-ops and there is **no live UI to edit always-relevant sites**.

### 7.2 Legacy `distractingSites` / `distractingApps` (settings JSON) + strict-mode constraints

- Saved by `SAVE_SETTINGS` (`MainWindow.swift:1319–1344`); explicitly **no longer feed enforcement** (comment :1365–1368: "Blocking is now profile-driven… WebsiteBlocker is fed by applyAlwaysActiveProfiles() and applyFocusSession() only").
- JS keeps them mirrored from the default BlockingProfile (`syncLegacyVars`, dashboard.html:7439–7449; also :7093–7097), then syncs to backend (`MainWindow.swift:1391–1393`).
- Backend `derive_enforcement_blob` turns `distractingSites` into the `distracting_sites: must_include_all` strict-mode constraint (`enforcement.py:54–60`); Mac reconciler auto-corrects the settings file if sites are removed while locked (`EnforcementReconciler.swift:180, 191–230`). Lock-mode save-guards also live in `MainWindow.swift:1290–1311` (can't remove distracting apps/platform sites while locked).
- Net effect: **the strict-mode tamper-protection for blocklists protects a mirror file that enforcement doesn't read.** Editing `blocking_profiles.json` directly is not covered by any constraint.

### 7.3 Hardcoded allowlists/denylists in FocusMonitor

- `alwaysAllowedBundleIds` — ~100 terminals/IDEs/utilities, compiled in (`FocusMonitor.swift:208+`), checked at `:1843–1862`.
- `com.apple.*` auto-allow except `appleEntertainmentBundleIds` (`:1825–1840`).
- `socialMediaHostnames` = youtube/instagram/facebook (+www/m) hard-coded always-irrelevant during sessions, skipping AI (`:145–149, 2187–2203`).
- Neutral-app list (`isNeutralApp`, gate at `:1678–1689`).

### 7.4 LearnedOverrideStore (per-host user corrections)

- `Intentional/LearnedOverrideStore.swift` — 3 corrections within 30 days promotes a host so OCR verification always runs (`:19, 33–37`). Persisted in UserDefaults `learnedOverrideSummary`, rebuilt from the relevance JSONL. Used by `RelevanceScorer` (`RelevanceScorer.swift:402, 414`); written via `recordUserOverride` (`FocusMonitor.swift:3644`).
- Distinct from legacy Project `learned: [LearnedSite]` + `PROMOTE_LEARNED_SITE` bridge (`MainWindow.swift:682–685, 2648–2661` → `ProjectStore.promoteLearnedSite` :366) which promotes a learned host into the *Project's* allowed list — legacy-Projects-only.

### 7.5 Legacy Project lists (`projects.json`)

- `Project.allowed/blocked: [HostItem]`, `blocklistIds: [UUID]` (refs into BlockingProfiles), `learned: [LearnedSite]` — `ProjectStore.swift:31–39`.
- Enforced only via `refreshProjectEnforcement` when a *legacy* Project row matches the session id (`AppDelegate.swift:168–210`); post-migration goals fall through to System D. A projects-kill spec exists (`dfacd87`, plan `ee6f1e4`) — Step A landed today (`ddfe652`).

### 7.6 NE FilterExtension blocklist

- `FilterManager.updateBlocklist(_ domains:)` writes `blocklist.json` to the App Group for the network-extension content filter (`FilterManager.swift:120–140`). **No callers anywhere in the app target** — the network-level blocking layer is unwired.

### 7.7 Misc

- New Session modal sends `auto_activate_block_rules: [ruleId]` — accepted and **dropped** (`MainWindow.swift:3839–3844`: "accepted but not yet wired").
- Bedtime allowlist (iOS App Group + Mac bedtime settings) is a separate per-feature allow concept, out of scope here but exists.
- WebsiteBlocker auto-expands every blocked domain to `domain`, `www.domain`, `m.domain` (`WebsiteBlocker.swift:107–115`) while standalone domains rely on suffix matching only — minor semantic divergence.

---

## 8. Precedence analysis — what wins today

### 8.1 Browser tabs (domains) — two engines run in parallel

**Engine 1 — WebsiteBlocker (0.5s AppleScript sweep, redirects to blocked.html):**
matches `effectiveBlockedDomains` = session-fed `blockedDomains` ∪ BlockRuleEnforcer `standaloneDomains` (`WebsiteBlocker.swift:37–44, 1044–1079`). Session-fed content depends on state:
- `.focus`: the **default** profile's domains (`applyDefaultBlockingProfile`, AppDelegate:1837 — ignores `enabled` + snooze) (+ explicit profiles via legacy `applyFocusSession`).
- `.off`: legacy `alwaysActive`-flagged profiles (none, for rules made in current UI).
**No allow list of any kind is consulted.** First match → tab closed/redirected.

**Engine 2 — FocusMonitor frontmost-tab scoring (only when Focus Mode is ON):** order inside `processActiveTabInfo` (`FocusMonitor.swift:1993–2311`):
1. blocking-page transition bookkeeping (:2061)
2. unchanged-tab skip (:2092)
3. **Per-goal `ProjectEnforcement`** — allow → relevant (skip AI), block → hard redirect (:2141–2185); allow checked before block (:118–124)
4. hardcoded social media → irrelevant, skip AI (:2190–2203)
5. `alwaysRelevantSites` whitelist → relevant, skip AI (:2205–2222)
6. AI relevance scoring (:2227–2311), with `ConfidenceGate` low-confidence passthrough

### 8.2 Native apps — single engine (FocusMonitor.evaluateApp, `FocusMonitor.swift:1591–1968`)

| Order | Check | Lines | Result |
|---|---|---|---|
| 0 | break / ritual / justification in progress | 1593–1608 | skip everything |
| 1 | **standalone Block-Rule bundleId, Focus Mode OFF** | 1645–1650 | hard overlay (`handleStandaloneBlockedApp` :3171) |
| 2 | Focus Mode OFF | 1657–1667 | allow everything |
| 3 | neutral app | 1678–1689 | neutral (no earn/penalty, state frozen) |
| 4 | own app | 1696–1709 | allow |
| 5 | **per-goal allow** (ProjectEnforcement) | 1729–1743 | allow, skip AI, earn |
| 6 | **per-goal block** | 1744–1774 | forced overlay (ignores block-type softness) |
| 7 | `distractingAppBundleIds` ∪ standalone rule bundleIds | 1785–1822 | overlay (deep work) / nudge (focus hours), no grace |
| 8 | `com.apple.*` non-entertainment | 1825–1840 | allow |
| 9 | hardcoded `alwaysAllowedBundleIds` | 1843–1862 | allow |
| 10 | browser → tab path (§8.1 engine 2) | 1865–1888 | — |
| 11 | AI scoring of app name | 1901–1968 | allow / overlay-nudge |

### 8.3 Sweep at session start (`Sweeper.decideTab` :139–157, `decideApp` :162–170)

Tabs: **pinned > AlwaysAllowedStore (global) > active Block-Rule host (stash) > per-goal/voice scope (keep) > intent keywords (keep) > AI batch → review modal (user confirms before anything closes)**.
Apps: **AlwaysAllowedStore > active Block-Rule bundleId (hide) > scope (keep) > hide by default**.
Block-Rule inputs come from `activeBlockedDomains()/activeBlockedBundleIds()` which **ignore snoozes** (`BlockingProfileManager.swift:291–303`).

### 8.4 Same-domain conflict matrix (during an active focus session)

| Domain appears in… | …and in… | Who wins | Why |
|---|---|---|---|
| Goal `allow_websites` | Default profile `blockedDomains` | **Block** (tab closed) | WebsiteBlocker consults no allow lists; default profile fed at `.focus` (AppDelegate:835, 1845) |
| Goal `allow_websites` | Active Block Rule (standalone) | **Block** (tab closed) | same — standalone domains union (WebsiteBlocker:37–44). Matches requirements §17b.7, and the UI warns (dashboard:10666–10681) |
| Goal `allow_bundle_ids` (app) | Global distracting list / active Block Rule (app) | **Allow** ✳ | ProjectEnforcement checked at :1729 BEFORE the union at :1785 — **apps and domains have opposite precedence** |
| Goal `mac_websites` (block) | `alwaysRelevantSites` | **Block** | ProjectEnforcement (:2141) runs before whitelist (:2207) |
| `alwaysRelevantSites` | Default profile blockedDomains | **Block** (tab closed by WebsiteBlocker before scoring matters) | engine 1 doesn't know about the whitelist |
| Hardcoded social media | Goal `allow_websites` | **Allow** | goal allow (:2141) runs before social-media check (:2190) — a goal can whitelist YouTube against the hardcode, but only until WebsiteBlocker closes it if it's also in the session blocklist |
| Snoozed Block Rule domain | (sweep) | **Stash** | sweep ignores snoozes (§8.3) |
| Snoozed Block Rule domain | (live enforcement) | **Allowed** | `isEffectivelyActive` excludes snoozed (BlockRuleEnforcer:137–140) — but the default profile copy still applies during a session regardless of snooze (:1837) |
| Backend `always_blocked` entry | anything | **Loses to everything** | never enforced |

### 8.5 Precedence traps worth naming

1. **Disabling/snoozing the default "Distracting Apps & Sites" rule does not stop session blocking** — `applyDefaultBlockingProfile` filters only on `isDefault` (AppDelegate:1838–1839). The Blocks-tab toggle controls only the standalone layer.
2. **Per-goal Allow saves apps but not sites** (8.4 rows 1–3 vs row "Allow ✳").
3. Three unrelated "always allowed" lists (sweep store, hardcoded bundleIds, alwaysRelevantSites) with three different match semantics and two of them user-invisible.
4. The legacy `alwaysActive` profile flag vs the modal's "Always active" checkbox are different fields; only the legacy flag feeds `applyAlwaysActiveProfiles`.
5. Strict-mode locks protect the settings-JSON mirror (`distractingSites`), not the actual enforcement store (`blocking_profiles.json`), and the advertised `block_rules` lock has no Swift enforcement.

---

## 9. Complete user-visible control inventory

Legend: ✅ wired end-to-end · ⚠️ wired but with a caveat · ❌ broken/orphaned/no-op.

### Today → Blocks sub-tab (dashboard.html:5107–5131, JS :9320–9935)

| Control | Wiring | Status |
|---|---|---|
| Schedule / Blocks segmented toggle | `setTodayMode()` :9920 (+ refresh `GET_BLOCKING_PROFILES`) | ✅ |
| **Block Now** | `openBlockNowModal()` :9856 → duration chips → `FOCUS_MODE_TOGGLE on:true` + JS `setTimeout` auto-stop :9897–9907 | ⚠️ session starts for real; the auto-stop timer lives in the webview and dies on page reload (12h backend TTL is the only backstop) |
| **Pomodoro 25** | `startPomodoro()` :9913 → `_startBlockNow(25)` | ⚠️ same caveat; no break loop |
| **Plan Day** | `navigateTo('plan')` :5121 | ✅ |
| **Set Limits** | `openBlockRuleCreate()` :5123 | ⚠️ misleading — opens the New-Block modal; no time/open-limit feature exists |
| **+ New Block** / empty-state "+ Create your first block" | `openBlockRuleCreate()` → `CREATE_BLOCK_RULE` → MainWindow:2441 | ✅ |
| Block card enable toggle | `TOGGLE_BLOCK_RULE` → MainWindow:2505 | ✅ instant enforcement via `reevaluateNow` |
| Block card click → edit modal (name, sites textarea, apps picker, **category chips incl. "Block streaming"**, Always-active checkbox, time + day-chip schedule) | `UPDATE_BLOCK_RULE` → MainWindow:2473 | ✅ |
| Modal Delete | confirm() → `DELETE_BLOCK_RULE` → MainWindow:2514 | ✅ (refuses when a legacy Project references it) |
| "Snooze for today" / "Resume now" | `SNOOZE_BLOCK_RULE`/`UNSNOOZE_BLOCK_RULE` → BlockRuleEnforcer | ✅ live layer; ⚠️ sweep + default-profile session copy ignore snooze |
| "Ends in Xm" countdown | 30s text tick :9536 | ✅ |
| Sidebar "N blocking" pill | `refreshSidebarBlockingPill` :9390 | ✅ |

### Settings → list pages

| Control | Wiring | Status |
|---|---|---|
| Distractions add/remove | `ADD_DISTRACTION`/`REMOVE_DISTRACTION` → backend table | ⚠️ persists, surfaces a count on Focus-Mode cards, **enforces nothing**; page copy promises budget-lock behavior that doesn't exist |
| Always Blocked add/remove | `ADD_ALWAYS_BLOCKED`/`REMOVE_ALWAYS_BLOCKED` → backend table | ❌ persists but enforces nothing anywhere |
| Always Allowed apps/domains add/remove | `SAVE_ALWAYS_ALLOWED` → `always_allowed.json` (sweep) | ❌ page never fetches (`GET_ALWAYS_ALLOWED` has no sender) — stuck on "Loading…"; saving from a fresh page can wipe the list |
| Distraction Budget page (baseline, partner lock, readout, Save) | `GET_BUDGET_STATE`/`SET_BUDGET_CONFIG` → backend | ❌ orphaned — no menu row reaches it; backend partner-code check is a stub |
| Strict Mode checklist row "Site & app blocks" | `SAVE_STRICT_MODE_LOCKS` → settings JSON | ❌ stored but never consulted by delete/toggle handlers |

### Goal editor (Weekly Goal / Focus Mode)

| Control | Wiring | Status |
|---|---|---|
| Custom rules → Block "+ Site/+ App", Allow "+ Site/+ App", × remove | `UPDATE_INTENTION` round-trip | ✅ (since ddfe652 actually enforced in-session) |
| Allow-vs-block-rule conflict heads-up | confirm() :10666–10681 | ✅ |
| "N distractions + M mode-specific" meta line on cards | `distractionsCache` :13594–13604 | ✅ display-only |
| New Session modal `auto_activate_block_rules` | accepted, dropped (MainWindow:3839–3844) | ❌ dead parameter |

### Hidden / dead surfaces

| Surface | Status |
|---|---|
| Earned Browse widget + Extra-Time flow (dashboard:5182–5244) | ❌ `display:none` + engine flag off |
| Legacy Profiles editor JS (renderProfileList, per-profile always-relevant) | ❌ markup removed; functions no-op; **only writer of `alwaysRelevantSites` is now unreachable** |
| `focus_mode_app_rules` endpoints | ❌ zero clients |
| `FilterManager.updateBlocklist` (NE filter) | ❌ zero callers |

---

## 10. Unknowns / risks

1. **EarnedBrowse "fully alive" discrepancy.** The brief said the engine is fully alive per audit; ground truth is `featureEnabled = false` (`EarnedBrowseManager.swift:17`) plus a dead consume feeder (no `recordUsageHeartbeat` callers post-extension-removal). If a prior audit observed live focus scores, those come from `blockFocusStats` paths that are also gated — worth re-verifying on a live build; I could not find any code path that flips the flag at runtime.
2. **Whether anyone still has legacy `alwaysActive=true` profiles on disk.** If yes, removing `applyAlwaysActiveProfiles` changes their out-of-session blocking; if no, the function is effectively dead weight. Can't verify other users' disks.
3. **`distracting_sites` constraint blast radius.** Consolidating lists will change what's in settings-JSON `distractingSites`; the backend constraint is `must_include_all` over whatever was locked in. Migrating users with strict mode ON could trigger reconciler "corrections" that resurrect old domains. Needs a data-migration story per locked account.
4. **Mac vs iPhone schedule split** (`time_blocks` vs `schedule_blocks`) means "blocks" already denotes two different backend tables; any consolidated vocabulary must not collide further.
5. **WebsiteBlocker domain expansion vs suffix matching** (`www.`/`m.` expansion :107–115 vs suffix `shouldBlock` :1072) makes the expansion redundant but harmless; consolidation should pick one semantic.
6. **Snooze semantics are inconsistent by layer** (live enforcement honors it; sweep and default-profile session copy don't). Unclear which behavior is intended — no spec covers it.
7. **`blockingProfileToDict` is @MainActor and reads BlockRuleEnforcer state** — moving profiles off-main needs care.
8. **`SweepBenchmark` + `IntentionalTests/sweep-test-cases/*.json`** encode current `decideTab` precedence (always-allowed > block rule > scope); changing precedence breaks the benchmark's ground truth and CLAUDE.md's "benchmark before AI tuning" discipline applies.
9. **Backend `PUT /budget_config` partner-code stub** accepts any non-empty string — a security hole if budget lock is ever surfaced.
10. **Two-user split-brain on the dev Mac**: production (caity) and dev (arayan) instances each own a separate copy of every local JSON list — local-file consolidation/migration will run twice on this machine, and receipts are per-user. Plan for idempotency (existing receipts pattern covers this if kept).
11. I did not run the app; all "wired/broken" statuses are static-analysis conclusions (e.g. `GET_ALWAYS_ALLOWED` never sent, no `showSettingsDetail('budget')` caller). They are high-confidence greps but unverified at runtime.

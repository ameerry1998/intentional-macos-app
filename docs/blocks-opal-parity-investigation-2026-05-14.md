# Blocks Feature — Why It Doesn't Work Like Opal + Fix Plan

**Date:** 2026-05-14
**Author:** Claude
**Status:** Investigation + draft plan — awaiting user answers to the open questions at the bottom before writing code.

---

## What the user sees today (per screenshot at 17:36)

- Today → Blocks tab renders correctly
- Quick Actions row: Block Now / Plan Day / Pomodoro 25 / Set Limits ✅ visually present
- "Your blocks": 1 row — "Distracting Apps & Sites · Always active · Blocking: youtube.com, instagram.com" with toggle ON
- Sidebar pill: "1 blocking"
- "Coach Context" panel at bottom

The UI is rendering. The user's complaint: **none of it actually does anything.**

---

## Root cause — three layers stacked

### Layer 1: Quick Action buttons are no-ops or stubs

| Button | Current behavior | What Opal does |
|---|---|---|
| Block Now | Calls `TOGGLE_FOCUS_MODE` (toggles a Focus Mode session) | Opens modal to pick duration + apps → immediately starts enforced block |
| Plan Day | Navigates to Plan tab | (same — fine) |
| Pomodoro 25 | Shows a "Pomodoro 25 starting..." toast, then nothing | Starts a 25-min countdown that blocks distracting apps for the duration |
| Set Limits | Doesn't exist (button wired but no handler) | Opens UI to set per-app daily time limit / open count |

### Layer 2: Block CRUD uses `prompt()` which WKWebView silently drops

- `openBlockRuleCreate()` chains 4 `prompt()` calls — none surface in WKWebView (no `WKUIDelegate.runJavaScriptTextInputPanel`)
- `openBlockRuleEdit()` same problem
- User clicks → nothing visible happens → assumes broken
- We already hit this with the monthly-goal create (fixed in commit `f45d9c7`); same pattern needed here

### Layer 3: **The schedule isn't actually enforced** (the big one)

This is the show-stopper. The `BlockingProfile` model now has `enabled`, `startHour/endHour`, `activeDays` fields. There's an `isCurrentlyActive` computed property. **But nothing reads it.**

The existing enforcement chain:
- `WebsiteBlocker` (closes tabs matching blocklist) — works
- `FocusMonitor` (kills distracting apps) — works
- `FilterExtension` (network-level filter) — works

But they only engage when `FocusModeController.activate(...)` is called — meaning only **during a manually-started or schedule-triggered focus session**. Standalone block rules with `Always active` or time-windowed schedules don't trigger anything.

So in the screenshot, "Distracting Apps & Sites — Always active — youtube.com, instagram.com" with toggle ON does NOT block YouTube or Instagram. The data is stored, the UI says "ACTIVE", the OS doesn't enforce.

---

## Opal feature matrix vs us

| Opal feature | We have it? | Notes |
|---|---|---|
| Create blocks with schedule (time + days) | ✅ data model | UI broken (prompt() bug) |
| Toggle block on/off | ✅ data + UI | Toggle does nothing functionally |
| Active block list with status pills | ✅ rendered | "ACTIVE" pill is cosmetic — no enforcement |
| **Enforcement during scheduled window** | ❌ | The actual feature |
| Countdown timer + progress bar on active block | ❌ | Opal shows "Remaining 12:11:14" |
| Cancel active block (inline ⊗ button) | ❌ | |
| Block Now (instant) | ⚠️ stub | Wired to `TOGGLE_FOCUS_MODE`, no app picker |
| Pomodoro 25 | ⚠️ stub | Toast only |
| Set Time Limit (X min/day on app) | ❌ | Opal feature |
| Set Open Limit (X opens/day on app) | ❌ | Opal feature |
| Difficulty / bypass mode per block | ❌ | "make it easy / harder / impossible" |
| App categories (Social / Games / News) | ❌ | Predefined groups |
| Screen Time Today counter | ❌ | "5h 26m" at top of Opal sidebar |
| Block templates / suggested presets | ❌ | "Work Time" 9–5 etc |
| Native modal create/edit | ❌ | We use prompt() chain |

---

## Fix plan — four phases, ordered by what unlocks the rest

### Phase 1 — Make rules actually enforce (the show-stopper)

Build a `BlockRuleEnforcer` Mac component that:

1. Runs a 30–60s ticker via `Timer.scheduledTimer`
2. Each tick: query `BlockingProfileManager` for all profiles where `isCurrentlyActive == true`
3. Compute the union of `blockedDomains` + `blockedAppBundleIds` across active profiles
4. Apply via existing chains:
   - **Domains** → `WebsiteBlocker.enforceBlocklist(domains)` (closes matching tabs in all browsers)
   - **Apps** → `FocusMonitor.setStandaloneBlockedBundleIds(bundles)` (kills/overlay on launch)
5. When NO rules are active, clear the standalone enforcement set
6. Compose with focus-session enforcement: when a focus session is also active, UNION its blocklists with the rules' set (so both apply)

This is the difference between "stores config" and "actually blocks." Estimated 2–3 hours.

**Critical detail:** the enforcer must NOT fight focus sessions. Currently `FocusModeController.activate` engages `WebsiteBlocker`. We need a layered model:
- Base layer: rule-enforcer's union of currently-active rules
- Session layer: when a focus session is active, that session's blocklist ALSO applies
- The two unions

### Phase 2 — Replace the `prompt()` UI with real modals

Three modals in HTML (same `.ns-modal-*` pattern we built for monthly create + new session):

1. **Block Rule Create/Edit modal**
   - Title input
   - Sites textarea (one per line)
   - Apps picker (we could ship as bundle-id text input for v1; native app picker is v2)
   - Schedule: "Always active" toggle, OR time pickers + days-of-week chips
   - Difficulty pills (v2 — punt for now)
   - Save / Cancel

2. **Block Now modal**
   - Duration picker (15 / 30 / 60 / 90 / custom min)
   - App / site picker — preselect from existing rules or pick a profile
   - Start button → fires `TOGGLE_FOCUS_MODE` with the picked rule applied
   - Or simpler: just lists existing rules with a "Block now for X min" option per rule

3. **Pomodoro 25 modal** (optional — or just start immediately)
   - 25 min focus + 5 min break loop
   - Uses the same focus-session machinery

### Phase 3 — Active block UI (countdown + cancel)

When a block rule is currently active (in its scheduled window):
- Render at top of "Your blocks": "Now" section with the rule name, the time remaining, progress bar
- Cancel button (⊗) → adds a temporary `disabledUntil` timestamp on the rule that overrides `isCurrentlyActive` for the rest of the current window (so user can disable it for the day without permanently disabling it)

This requires:
- A `temporarilyDisabledUntil: Date?` field on BlockingProfile
- The `isCurrentlyActive` check considers this field
- UI ticks every 1s to update the countdown

### Phase 4 — Opal-extra features (defer to a separate plan?)

These are nice-to-haves and not core to "actually blocks":
- App categories (Social / Games / News presets)
- Set Time Limit (daily minutes per app)
- Set Open Limit (daily opens per app)
- Difficulty / bypass mode
- Screen Time Today counter
- Block templates ("Work Time" preset)

Recommend punting these to a v2 spec.

---

## Open questions (please answer before I start writing code)

1. **Scope:** For "works like Opal," do you mean:
   - (a) Core: rules actually enforce + real modal CRUD + countdown UI (Phases 1–3 above), OR
   - (b) Full Opal feature surface including app categories, time/open limits, difficulty modes (Phases 1–4)?
   
   My recommendation: (a) first, then a separate spec for (b). (b) is a multi-day build.

2. **Block-rule + Focus-session conflict semantics:**
   - Layered union (both apply when overlapping) → most permissive: a site appearing in EITHER blocks it, OR
   - Session overrides rules during sessions, OR
   - Rules override sessions (sessions can't unblock what a rule blocks)?
   
   My recommendation: layered union. A user setting "Block social 9–5" probably wants social blocked DURING a focus session too.

3. **Cancel-active-block behavior:** When user hits ⊗ on an active block:
   - Disable the rule entirely (toggle off — affects future days), OR
   - Disable only for the rest of today's window (re-enables tomorrow), OR
   - Disable for a custom duration ("Snooze 30 min")?
   
   My recommendation: middle option (rest of today's window) — matches Opal.

4. **Pomodoro 25 behavior:** Should it:
   - Just start a 25-min focus session with the user's current default blocklist, OR
   - Open a picker to select which rules/blocks apply, OR
   - Both — quick start + customize?
   
   My recommendation: option 1 (quick start, no picker). Power users can edit settings.

5. **Block Now behavior:** Same question — instant or picker?

   My recommendation: short modal — pick duration (15/30/60/custom) + which existing rule to enforce (or "everything"). 5 seconds of interaction max.

6. **Set Limits button:** 
   - Punt entirely (greyed out / coming soon), OR
   - Implement minimal version (text input "X minutes/day for Y app"), OR
   - Full Opal parity?
   
   My recommendation: punt for this round. Add a "Coming soon" tooltip.

7. **App picker — site list is text input. Apps?**
   - Bundle ID text input ("com.apple.Safari" — power-user only), OR
   - Picker UI with installed apps grid (Opal's approach), OR
   - Predefined categories (Social / Games / News)?
   
   My recommendation: bundle ID text input for v1. Picker UI is a v2 feature.

8. **Existing "Distracting Apps & Sites" rule in your screenshot — preserved or wiped?** It looks like a seeded default. Once enforcement turns on, that rule will actually block YouTube + Instagram. Confirm that's the intent.

9. **Domain matching strictness for WebsiteBlocker:**
   - Exact: `youtube.com` matches only `youtube.com` (NOT `www.youtube.com` or `m.youtube.com`), OR
   - Subdomain: `youtube.com` matches `*.youtube.com` AND `youtube.com`?
   
   My recommendation: subdomain (the saner default). Existing WebsiteBlocker may already do this — I'll verify when I code.

10. **Coach Context panel at the bottom of the screenshot — is that load-bearing for this fix, or scope-creep?** I'd punt unless you tell me it's part of the Blocks feature.

---

## Suggested execution order (once you answer the Qs)

1. **Wire `BlockRuleEnforcer`** (Phase 1) → makes existing rules actually block
2. **Replace `prompt()` with real modal** for Block Rule create/edit (Phase 2.1) → fixes the UI bug
3. **Cancel button + countdown** on active block card (Phase 3) → completes Opal parity for the core flow
4. **Block Now modal + Pomodoro** (Phase 2.2 + 2.3) → real Quick Action behavior

Each phase produces a testable, install-able PKG. Estimated total: ~4–6 hours focused work.

---

## What I'm NOT doing without explicit confirmation

- Touching the FilterExtension entitlements
- Touching `WebsiteBlocker.appleScriptQueue` (known not-on-main-queue rule from CLAUDE.md)
- Building a native app picker / category system (large surface area, v2 spec)
- Building Set Time Limit / Set Open Limit features
- Building difficulty/bypass mode
- Rebuilding the Coach Context panel

These are gated on either your explicit yes or a separate spec.

# App Redesign — Master Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement each slice task-by-task. Each slice has its own detailed plan file with checkbox (`- [ ]`) tasks.

**Goal:** Implement the redesign spec (`docs/superpowers/specs/2026-05-05-app-redesign-design.md`) across 3 repos via 13 vertical slices over ~6 weeks. Each slice produces working, testable software on its own.

**Architecture:** Backend canonical → Mac thick client → iOS thin client. Subscription/entitlements is the foundation; everything else gates behind it. **Feature-branch-per-slice + hard-delete-on-merge:** old code stays untouched on `main` while we work in `slice-NN-<name>` branches. When a slice is verified, merge to main with old code deleted in that branch's diff. Rollback = git revert. No commented-out cruft on main.

> **Strategy update 2026-05-05:** Originally specced as "soft-deprecate" (comment out, leave alongside) per Q23 of brainstorm. Switched to feature-branches before slice 1 dispatch — dual code paths on main create harder bugs than git-based rollback solves. References to "soft-deprecation" elsewhere in this plan should be read as "hard-delete inside the slice's feature branch, with old code preserved on main until merge."

**Tech Stack:**
- Backend: FastAPI + Postgres (Supabase) on Railway, Stripe, APNs
- Mac: SwiftUI/AppKit, WKWebView dashboard, Qwen3-4B local AI scorer
- iOS: SwiftUI, SwiftData, DeviceActivityMonitor + ManagedSettings
- Site: Next.js (already done; pricing model finalized in `docs/pricing-strategy-2026-05-05.md`)

---

## How to read this plan

This is a **coordination master**, not a task-level breakdown:

1. **Master plan (this file)** = sequencing, scope per slice, dependencies, acceptance criteria, risks. Use to understand the whole project at a glance.
2. **Slice plans** (`slice-NN-<name>-plan.md`) = TDD task-level detail. Write the next slice's plan **just before starting that slice**, not all at once. Reasons: (a) we'll learn from earlier slices that change later ones, (b) writing 13 detailed plans up front is wasteful, (c) the spec is the contract — slice plans are scaffolding.
3. **Slice 1 plan exists alongside this master** (`slice-01-entitlements-plan.md`). Slices 2–13 get their detailed plans written when their turn comes.

---

## Repository map

### `intentional-backend/` (Railway/Supabase, FastAPI, Postgres)

Files added/modified by this redesign:

| File | Purpose | Slices that touch it |
|---|---|---|
| `migrations/021_subscription_tier.sql` | Add subscription state to users | 1 |
| `migrations/022_focus_modes_rename.sql` | Rename `intentions` → `focus_modes` | 2 |
| `migrations/023_focus_mode_app_rules.sql` | Replace `mac_websites`/`mac_bundle_ids` | 5 |
| `migrations/024_distraction_budget.sql` | New tables for budget state + config | 3 |
| `migrations/025_distractions_lists.sql` | `distractions` + `always_blocked` tables | 5 |
| `migrations/026_focus_lock_state.sql` | Persist Focus Lock per user | 6 |
| `main.py` (extended) | New routes for entitlements, budget, lists, focus_lock, etc. | 1, 3, 5, 6, 7 |
| `models.py` (extended) | Pydantic models for new endpoints | All |
| `enforcement.py` (extended) | Strict Mode constraint emission | 7 |
| `stripe_webhooks.py` (new) | Stripe webhook handlers | 1 |
| `auth.py` (extended) | Magic-link verification (existing pattern, possibly already there) | 1 |

### `intentional-macos-app/` (Mac app)

Files added/modified:

| File | Purpose | Slices |
|---|---|---|
| `Intentional/EntitlementClient.swift` | Calls `/me/entitlements`, caches tier locally | 1 |
| `Intentional/FocusModeStore.swift` (rename of `IntentionStore.swift`) | Renamed, expanded properties | 2 |
| `Intentional/DistractionBudgetClient.swift` | Backend-resident budget state | 3 |
| `Intentional/AppRulesStore.swift` | Manages distractions/always-blocked lists | 5 |
| `Intentional/FocusLockController.swift` | Master "I'm serious" wrapper | 6 |
| `Intentional/StrictModeController.swift` | Master "lock everything sensitive" toggle | 7 |
| `Intentional/SignInWindowController.swift` | New sign-in window for unauthenticated users | 1 |
| `Intentional/EarnedBrowseManager.swift` (refactored, kept name) | Now drives BackendClient calls instead of local file | 3, 8 |
| `Intentional/BlockingProfileManager.swift` (soft-deprecated) | Marked deprecated, removed in slice 13 | 2, 13 |
| `Intentional/ProjectStore.swift` (soft-deprecated) | Marked deprecated, removed in slice 13 | 2, 13 |
| `Intentional/dashboard.html` (significant rewrite) | New sidebar (4 tabs), new Today page, new Settings sub-pages | 5, 6, 7, 9, 10 |
| `Intentional/AppDelegate.swift` (init order updated) | Wires new components, retains old as deprecated | All |

### `puck-ios/` (iOS Puck companion)

Files added/modified:

| File | Purpose | Slices |
|---|---|---|
| `Puck/Models/FocusMode.swift` (extended) | Add weekly_target_hours, strictness_preset, app_rules | 2 |
| `Puck/Models/Intention.swift` (deleted, merged into FocusMode) | Removed | 2 |
| `Puck/Auth/SignInView.swift` (new or existing) | Magic-link sign-in screen | 1 |
| `Puck/Auth/EntitlementGate.swift` (new) | Reads `/me/entitlements`, gates UI | 1 |
| `Puck/Core/Network/IntentionalAPIClient.swift` (extended) | New endpoints | 1, 3, 5, 6 |
| `Puck/Views/ContentView.swift` (rewritten) | 6 tabs → 3 tabs (Today / Week / Settings) | 11 |
| `Puck/Views/Home/HomeView.swift` (renamed/refactored to TodayView) | Today view | 11 |
| `Puck/Views/Schedule/ScheduleTabView.swift` (folded into Week) | Folded | 11 |
| `Puck/Views/Intentions/IntentionsTabView.swift` (deleted) | Folded into Settings + Today | 11 |
| `Puck/Alarm/PuckAlarmService.swift` (new) | Alarm-locked-screen flow | 12 |
| `Puck/NFC/PuckNFCReader.swift` (refactored) | Strip daytime use, alarm-dismiss only | 12 |

---

## Slice dependency graph

```
                     ┌────────────────────┐
                     │ Slice 1            │
                     │ Subscription /     │  ← FOUNDATION (must be first)
                     │ Entitlements       │
                     └─────────┬──────────┘
                               │
              ┌────────────────┼────────────────┬────────────┐
              ▼                ▼                ▼            ▼
       ┌───────────┐    ┌───────────┐    ┌───────────┐   ┌─────────┐
       │ Slice 2   │    │ Slice 3   │    │ Slice 7   │   │ Slice 12│
       │ Focus     │    │ Distract. │    │ Strict    │   │ Puck    │
       │ Mode      │    │ Budget    │    │ Mode      │   │ alarm   │
       │ rename    │    │ x-device  │    │ master    │   │ only    │
       └─────┬─────┘    └─────┬─────┘    └───────────┘   └─────────┘
             │                │
       ┌─────┴─────┐    ┌─────┴─────┐
       ▼           ▼    ▼           ▼
  ┌─────────┐  ┌─────────┐    ┌─────────┐
  │ Slice 4 │  │ Slice 5 │    │ Slice 8 │
  │Schedule │  │ App     │    │AI score │
  │ unify   │  │taxonomy │    │  rewire │
  └────┬────┘  └────┬────┘    └────┬────┘
       │            │              │
       └─────┬──────┴──────────────┘
             ▼
       ┌──────────┐
       │ Slice 6  │
       │ Focus    │
       │ Lock     │
       └────┬─────┘
            │
       ┌────┴─────┐
       ▼          ▼
  ┌─────────┐  ┌─────────┐
  │ Slice 9 │  │ Slice 10│
  │ Block   │  │ Mac     │
  │ life-   │  │ sidebar │
  │ cycle   │  │ rebuild │
  └────┬────┘  └────┬────┘
       │            │
       └─────┬──────┘
             ▼
       ┌──────────┐
       │ Slice 11 │
       │ iOS tabs │
       │ rebuild  │
       └────┬─────┘
            ▼
       ┌──────────┐
       │ Slice 13 │  ← STABILIZATION
       │ Cleanup  │  (≥2 weeks after slice 12 ships)
       │ deletion │
       └──────────┘
```

---

## The 13 slices

### Slice 1: Subscription / Entitlements infrastructure

**Goal:** Backend knows who's a subscriber, Mac and iOS verify on launch + foreground, app gracefully handles trial / active / lapsed states.

**In scope:**
- Backend: `users.subscription_tier` (`none`/`trialing`/`active`/`past_due`/`canceled`), `trial_ends_at`, `current_period_ends_at`. `GET /me/entitlements` endpoint. Stripe webhook handlers. Magic-link auth verification.
- Mac: `EntitlementClient` polls on launch + foreground + every 60s. Sign-in window if no token. 24h grace period after lapse, then planner-only mode (no AI / blocking / budget). Lapsed banner UI.
- iOS: Magic-link sign-in (audit existing flow, likely already works). `EntitlementGate` checks tier on launch + foreground. "Subscribe at intentional.app →" link on sign-in screen for non-subscribers.

**Out of scope (for later slices):**
- Removing existing app features for non-subscribers (slice 13 adds the actual feature gating; slice 1 just gets the data flowing)
- Stripe price IDs configuration (already done in pricing-strategy work)
- Klaviyo email flows

**Files to create:** `migrations/021_subscription_tier.sql`, `stripe_webhooks.py`, Mac `EntitlementClient.swift`, Mac `SignInWindowController.swift`, iOS `EntitlementGate.swift`.

**Files to modify:** Backend `main.py` (add `/me/entitlements`), Mac `AppDelegate.swift` (call entitlement check on launch), iOS `ContentView.swift` (gate behind entitlement).

**Acceptance criteria:**
1. `curl https://api.intentional.social/me/entitlements -H "Authorization: Bearer <token>"` returns `{tier, plan, trial_ends_at, current_period_ends_at, ship_puck}`
2. Webhook from Stripe `customer.subscription.created` updates `users.subscription_tier = 'trialing'` and `trial_ends_at` correctly
3. Mac launches: shows sign-in window if no token; otherwise calls `/me/entitlements` and proceeds
4. Mac with `tier=active`: full app works
5. Mac with `tier=canceled` and `current_period_ends_at` >24h ago: planner-only banner, no enforcement
6. iOS launches: magic-link sign-in works; non-subscribed users see "Subscribe at intentional.app" link

**Risks:**
- Stripe webhook signing/verification has historically had bugs. Test locally with `stripe listen` before deploying.
- Magic-link auth flow on iOS may already exist in some form — audit before reimplementing.
- Lapsed-state UX is easy to get wrong. Test the 24h transition carefully.

**Estimated duration:** 4–6 days. Backend ~2 days, Mac ~2 days, iOS ~1 day, integration testing ~1 day.

**Detailed plan:** `docs/superpowers/plans/2026-05-05-slice-01-entitlements-plan.md` (created alongside this master).

---

### Slice 2: Focus Mode rename + merge from Intentions/Profiles

**Goal:** All references to "Intention" become "Focus Mode". Profile concept folded in (each Profile becomes a property of the Focus Mode that uses it). Backwards-compat aliases retained.

**In scope:**
- Backend: migration renames `intentions` table → `focus_modes`. Pydantic models `Intention` → `FocusMode`. Routes `/intentions/*` → `/focus_modes/*`. Legacy `/intentions/*` aliases retained for one release cycle.
- Mac: `IntentionStore.swift` → `FocusModeStore.swift`. `Intention` struct → `FocusMode` struct. Bridge messages `*_INTENTION_*` → `*_FOCUS_MODE_*` with legacy aliases. Dashboard sidebar text + Block editor copy.
- iOS: `Intention.swift` deleted (already had a `FocusMode.swift` that becomes canonical). `IntentionStore` → `FocusModeStore`. `IntentionsTabView` → `FocusModesTabView` (still its own tab in this slice; tabs restructure happens in slice 11).
- Profiles: `BlockingProfileManager` marked `@available(*, deprecated)`. Profile UI hidden from dashboard. Existing profile→intention bindings auto-resolved into focus_mode.app_rules during migration.

**Out of scope:**
- Per-Focus-Mode app_rules table (slice 5 does that — slice 2 keeps existing `mac_websites`/`mac_bundle_ids` columns under the renamed table)
- Strictness preset logic changes (slice 9)
- Sidebar restructure (slice 10)

**Acceptance criteria:**
1. Migration runs cleanly on a copy of production data
2. `GET /focus_modes` returns the same data `GET /intentions` did (both routes work)
3. Mac dashboard sidebar item now says "Focus Modes"
4. Existing intention IDs preserved across rename (no data loss)
5. iOS `IntentionStore` references all updated; no compile errors
6. `BlockingProfileManager` wrapper still functions for legacy code paths

**Risks:**
- Rename touches dozens of files. High mechanical-error rate. Use IDE rename refactor + grep verification.
- Swift type renames may cascade into Codable keys, breaking persisted JSON. Test app-launch with old `intentions.json` cache.

**Estimated duration:** 3–4 days.

---

### Slice 3: Distraction Budget — cross-device backend-resident

**Goal:** Replace local-only `EarnedBrowseManager` pool with backend tables. Both Mac and iOS read/write the same budget state.

**In scope:**
- Backend: `migrations/024_distraction_budget.sql` — `distraction_budget_state` (per-user, per-day) + `distraction_budget_config` (per-user). Endpoints: `GET /budget_state` (today's state), `POST /budget_state/consume` (decrement available), `POST /budget_state/earn` (increment earned), `PUT /budget_config` (set baseline + lock).
- Mac: `DistractionBudgetClient.swift` wraps the endpoints. `EarnedBrowseManager` refactored to call backend instead of local file (file becomes a fallback cache). Local persistence still exists for offline support.
- iOS: `DistractionBudgetClient` (separate Swift implementation, same endpoints). Pulls budget state on foreground + 60s timer. iOS reports consumption when DeviceActivity flags a Distraction-list app open.

**Out of scope:**
- The Distractions list itself (slice 5 creates that)
- AI scoring → earning wire-up (slice 8)
- UI changes for budget meter visibility (slice 10)

**Acceptance criteria:**
1. Budget state visible identically on Mac and iOS within 5s of change
2. Closing TikTok on iPhone decrements budget on Mac's pill within 5s
3. Mac AI-judged focus minute increments backend earned_minutes
4. Setting `baseline_minutes = 60, is_locked = true` rejects subsequent updates without partner code
5. Daily reset at midnight (local time) zeros out consumed/earned

**Risks:**
- Cross-device race conditions on consume. Use Postgres-level atomic increment.
- The existing EarnedBrowseManager has subtle invariants (per CLAUDE.md item 2: order matters). Don't break the activeBlockId-before-recordWorkTick rule.
- Local-fallback cache vs backend-canonical state: define source-of-truth resolution (backend wins on conflict).

**Estimated duration:** 4 days.

---

### Slice 4: Schedule unification

**Goal:** One `time_blocks` table on backend. Both Mac and iOS read/write same schedule. Mac stops using local file as canonical.

**In scope:**
- Backend: extend existing `time_blocks` table (slice 2 from prior work). Endpoints already exist (`GET/POST/PUT/DELETE /time_blocks`). Add `POST /time_blocks/auto_fill` (returns suggested layout).
- Mac: existing `ScheduleManager` refactored to read/write backend instead of local file. Migration: on first launch with backend support, push existing local schedule to backend.
- iOS: existing `/schedule/blocks` consumer code unchanged. Maybe extend to read/write through new endpoints.
- Auto-fill: backend logic that allocates today's time given weekly Focus Mode hour targets + days remaining in week + reasonable defaults (8am-10pm waking hours).

**Out of scope:**
- Calendar drag-to-create UX (deferred to future)
- Conflict resolution UI (last-write-wins is fine in v1)

**Acceptance criteria:**
1. Schedule edited on iPhone visible on Mac within 5s
2. Auto-fill button on Mac dashboard generates a sensible day given weekly targets
3. Existing local schedule on Mac migrated to backend on first launch with new build
4. No double-writes (local file + backend) — backend is canonical

**Risks:**
- Mac schedule has months of accumulated local state (per CLAUDE.md the user's testing data lives there). Migration must be idempotent and never overwrite backend with stale local data.
- Auto-fill output quality matters — bad allocations make Focus Lock feel broken.

**Estimated duration:** 4 days.

---

### Slice 5: App taxonomy — Allowed / Distraction / Always-Blocked + Focus Mode overrides

**Goal:** Three distinct app lists at user level + per-Focus-Mode override rules. Replaces the current ad-hoc `mac_websites`/`mac_bundle_ids` pattern.

**In scope:**
- Backend: `migrations/023_focus_mode_app_rules.sql` (per-Focus-Mode rules, type='block' or 'allow') + `migrations/025_distractions_lists.sql` (`distractions` + `always_blocked` user-level tables). Endpoints for both lists.
- Mac: `AppRulesStore.swift` manages all three. New Settings sub-pages: "Distractions" and "Always-Blocked". Block editor in Focus Modes page now shows additional-block + explicit-allow lists for the active Focus Mode.
- iOS: same `AppRulesStore` pattern. Settings shows the lists (read-only or light-editing in v1).
- DeviceActivity rules updated to reflect new model.

**Out of scope:**
- Distraction Budget interaction (slice 3 already there, this just defines what's a "distraction")
- The blocking primitive itself (existing `WebsiteBlocker` + `FilterManager` still do the work)

**Acceptance criteria:**
1. Settings → Distractions: add/remove apps, both Mac and iOS see the change
2. Settings → Always-Blocked: same
3. Focus Mode editor: per-Focus-Mode "additionally block" and "explicitly allow" lists work
4. Resolution priority correct: Always-Blocked wins, Focus Mode rules next, Distraction below, Allowed default
5. iOS DeviceActivity shielding respects the resolved rules per active Focus Mode

**Risks:**
- The data model is more complex than current state. Migration of existing per-Intention `mac_websites`/`mac_bundle_ids` into the new model needs to be careful.
- Resolution priority bugs are subtle and hard to test exhaustively.

**Estimated duration:** 4 days.

---

### Slice 6: Focus Lock master toggle

**Goal:** New `FocusLockController` on Mac. Wraps "force a plan + context-switching limiter + partner-gate to turn off." Today page has the visible toggle.

**In scope:**
- Backend: `migrations/026_focus_lock_state.sql` for persistence. Endpoint `POST /focus_lock/toggle` accepts `{is_on, partner_code?}`.
- Mac: `FocusLockController.swift` is the new wrapper. When `is_on = true`: requires today's calendar to be auto-filled (uses slice 4 endpoint). Activates `SwitchInterventionCoordinator` (existing). When user tries to turn off: requires partner code via `BedtimeUnlockRequestView` (extended for new lock kind).
- Today page: Focus Lock toggle, status indicator, plan-required prompt with one-tap auto-fill.

**Out of scope:**
- Strict Mode (separate, slice 7)
- AI scoring changes (slice 8)
- Block lifecycle UI (slice 9)

**Acceptance criteria:**
1. Focus Lock OFF → Distraction Budget runs as defined in slice 3
2. Focus Lock ON with no plan → modal "Auto-fill today from your weekly targets?"
3. Focus Lock ON with plan → context-switching limiter active
4. Attempt to turn Focus Lock OFF while ON → BedtimeUnlockRequestView modal asks for partner code
5. Cross-device: Focus Lock state visible on iOS within 5s of Mac toggle

**Risks:**
- Force-a-plan was deleted in TimeState consolidation. Resurrecting requires care to not re-introduce previously fixed bugs.
- BedtimeUnlockRequestView extension for new lock kind may interact with iOS strictness-unlock partner flow.

**Estimated duration:** 5 days.

---

### Slice 7: Strict Mode master toggle

**Goal:** New `StrictModeController` on Mac. Settings → Strict Mode flips `users.lock_mode` and the backend emits constraints for all sensitive things.

**In scope:**
- Backend: `enforcement.py` extended. When `lock_mode = 'partner'`, enforced_settings constraints emitted for: `bedtime.enabled`, `content_safety.enabled`, distractions list (read-only), always-blocked list (read-only), AI scorer enabled, daily reset (deferred), partner removal (deferred — separate lock).
- Mac: `StrictModeController.swift`. Settings → Strict Mode toggle. EnforcementReconciler (existing) handles the constraint set; new constraint keys map to the right onboarding_settings.json paths. UI marks all locked toggles as gray-disabled with "Get partner code to unlock" link.
- iOS: matches Mac behavior. Strict Mode toggle in iOS Settings shows current state; cannot be toggled from iOS (Mac is canonical for now).

**Out of scope:**
- Per-toggle granular locks (B-option from Q14, deferred)
- Partner-unlock flow improvements (existing flow used)

**Acceptance criteria:**
1. Strict Mode toggle ON → all 5 sensitive toggles gray-disabled in dashboard
2. Strict Mode constraint enforced via existing EnforcementReconciler — onboarding_settings.json corrected if user manually edits
3. Strict Mode toggle OFF requires partner code (lock_mode = partner makes it self-locking)
4. Backend emits constraints for content_safety, bedtime, AI scoring; cross-device

**Risks:**
- Self-lock paradox: Strict Mode itself becomes partner-locked once on. Make sure first-time-on flow is correct.
- Existing EnforcementReconciler has known constraint mapping (per CLAUDE.md item 6). Reuse the mapping pattern.

**Estimated duration:** 4 days.

---

### Slice 8: AI scoring → Distraction Budget rewire

**Goal:** Existing AI scoring pipeline (Qwen3-4B + RelevanceScorer) feeds the new backend-resident Distraction Budget instead of the local `EarnedBrowseManager` file.

**In scope:**
- Mac: `RelevanceScorer` keeps its scoring logic. `EarnedBrowseManager.recordWorkTick` now calls `DistractionBudgetClient.earn(minutes: 1)` (backend) instead of writing local file.
- Tap-once override: existing `LearnedOverrideStore` (already present) used. Override increments earned regardless of AI judgment. AI override count tracked in PostHog.
- AI scoring uses Focus Mode's `description` field as scoring context (instead of Intention name).

**Out of scope:**
- Improving AI accuracy (deferred — see spec §17)
- Override logging visible to partner (option D from Q12, deferred)
- Deterministic earning (alternative considered in brainstorm Q12, deferred)

**Acceptance criteria:**
1. Mac AI judges minute focused → `POST /budget_state/earn` increments earned_minutes
2. AI judges not-focused → no increment
3. Tap-once override → increment regardless of AI
4. Override events fire PostHog event `override_tapped`

**Risks:**
- The scoring loop is in a real-time critical path. Don't introduce backend latency that delays minute-counting.
- Use a queue + retry on backend errors so transient network issues don't lose minutes.

**Estimated duration:** 3 days.

---

### Slice 9: Block lifecycle UI changes

**Goal:** Per-Focus-Mode strictness preset affects override and end-early behavior. Extend prompt at 5 min before block end.

**In scope:**
- Mac: `DeepWorkTimerController` (existing) updated. End-block button:
  - Strict: hidden / disabled with tooltip
  - Standard: 10s confirmation modal
  - Soft: ends instantly
- 5-min-before-end pill prompt: "Extend? (15 / 30 / 60)" buttons. Tap shifts schedule via `POST /time_blocks/:id` with new `end_at`, then auto-shift downstream blocks.
- 60s grace period at block start (existing pattern, just verify behavior with new strictness model).

**Out of scope:**
- Celebration card content changes (existing card good as-is)
- Block start ritual changes (existing good)

**Acceptance criteria:**
1. Strict block: cannot end early
2. Standard block: end early prompts 10s confirmation
3. Soft block: ends instantly on tap
4. Block at 9:55 with end at 10:00: pill shows extend prompt with 3 options
5. Tapping "extend 30" shifts current end to 10:30 and pushes Reading 10:00–11:00 to 10:30–11:30

**Risks:**
- Extending mid-block triggers complex schedule recalculation. Edge cases: extension pushes past midnight, multiple blocks back-to-back, gap-creating extensions.
- Strictness is a new property; verify migration default sensibly to "Standard" if not set.

**Estimated duration:** 4 days.

---

### Slice 10: Mac sidebar restructure

**Goal:** 8 sidebar items → 4 (Today / Week / Focus Modes / Settings). Distractions, Sensitive Content, Weekly Planning, Accountability folded into Settings sub-sections. Profiles tab removed.

**In scope:**
- `dashboard.html`: replace sidebar HTML, remove Profiles section, fold Distractions + Sensitive Content + Accountability into Settings drill-down. Today page includes Focus Lock toggle, current Focus Mode + countdown, distraction budget meter, today's blocks timeline. Week page renders calendar + Focus Mode hour bars.
- Bridge messages: any sidebar-tab-specific JS handlers update to new structure.
- Cleanup: 14 still-active legacy branches in dashboard.html Intentions tab (per Mac inventory §9) deleted under feature flag for slice 10's release.

**Out of scope:**
- Today page polish (basic functional version in this slice; design polish later)
- Week page interactions (tap-to-edit deferred — read mostly)

**Acceptance criteria:**
1. Sidebar shows 4 items: Today, Week, Focus Modes, Settings
2. Settings has 5+ sub-sections: Account, Partner, Distractions, Always-Blocked, Sensitive Content, Strict Mode, Bedtime
3. Today page shows Focus Lock toggle, current state, today's plan
4. No regressions to existing functionality (everything that worked still works in new location)

**Risks:**
- Dashboard HTML is large and has many bridge handlers. Test every interaction.
- Existing users (you) need a way to find old features in new locations. Add subtle copy ("now in Settings → Distractions") on first launch.

**Estimated duration:** 5 days.

---

### Slice 11: iOS tabs restructure

**Goal:** 6 tabs → 3 (Today / Week / Settings). Schedule + Intentions + Alarms + Partner folded in.

**In scope:**
- `ContentView.swift` rewritten with 3 tabs.
- HomeView (Focus Modes grid) becomes part of Today.
- ScheduleTabView merged into Today (current block) + Week (calendar).
- IntentionsTabView (now FocusModesTabView per slice 2) folded into Settings → Focus Modes.
- AlarmsTabView (PuckAlarm management) folded into Settings → Alarm.
- PartnerTabView folded into Settings → Partner.
- Sign-out, account info in Settings.
- Subscribe link on sign-in (already done in slice 1; verify present).

**Out of scope:**
- Calendar editing on iPhone (read-only-ish in v1)
- Push notifications config (deferred)

**Acceptance criteria:**
1. App opens to 3 tabs
2. Today shows: current Focus Mode, distraction budget meter, today's blocks read-only
3. Week shows: 7-day calendar view, weekly Focus Mode hour bars
4. Settings has: Account, Sign out, Partner, Alarms, Bedtime, Focus Modes
5. No dead navigation — everything reachable

**Risks:**
- iOS has many dead views per inventory (RoutineView, HabitGoalCreationView, WeeklyReportSheet, CalendarTimelineView, ScheduleBlockEditSheet, etc.). Some may be referenced by removed tabs and quietly break. Audit imports.

**Estimated duration:** 4 days.

---

### Slice 12: Puck → alarm-only

**Goal:** Strip daytime NFC tap-to-toggle. Build alarm-locked-screen flow where Puck tap is the only dismiss.

**In scope:**
- iOS: `PuckAlarmService.swift` — alarm-time UIWindow that locks the screen, requires NFC tap to dismiss. Distractions stay shielded by DeviceActivity post-dismiss until first scheduled Focus Mode.
- iOS: `PuckNFCReader` refactored — only handles alarm-dismiss. Daytime NFC tap code removed.
- Marketing: pricing-strategy doc updated (alarm-only is the unique value prop).

**Out of scope:**
- Without-Puck alarm experience (deferred — Puck holders only get the magic; non-Puck users get a normal phone alarm in v1)
- Wake-up routine choreography (gradual unlock, etc.) — v1 is binary lock-until-tap

**Acceptance criteria:**
1. Alarm rings at scheduled time
2. Phone screen shows custom alarm UI, swipe/buttons inert
3. NFC Puck tap dismisses alarm
4. After dismiss, Distractions list apps remain shielded until first scheduled Focus Mode block start
5. No daytime NFC code paths active

**Risks:**
- iOS lock-screen UI is constrained by Apple. Use `UIApplication.shared.isProtectedDataAvailable` and DeviceActivity to enforce, not custom lock UI (Apple won't allow custom lock).
- Alarm reliability: app must wake up reliably from background. Use Local Notifications + `notificationCenter(_:willPresent:withCompletionHandler:)` pattern.

**Estimated duration:** 5 days.

---

### Slice 13: Soft-deprecation cleanup

**Goal:** Delete all the code marked deprecated by slices 1–12. Run after ≥2 weeks of stability with the new system.

**In scope:**
- Mac: delete `BlockingProfileManager`, `ProjectStore`, dead Settings → Focus Mode JS, dead force-a-plan code (resurrected by slice 6, ensure cleanup), dead `IntentionalModeController` references, `*_PROJECT_*` legacy bridge handlers, 14 legacy dashboard.html branches in Intentions tab.
- iOS: delete `Intention.swift` (merged into FocusMode), `RoutineView`, `HabitGoalCreationView`, `WeeklyReportSheet`, `CalendarTimelineView`, `QuickBlockButton`, `ScheduleBlockEditSheet/DetailSheet`, `NetworkClient` (superseded), `ModePickerSheet`, legacy SwiftData models (`PuckSchedule`, `ScheduleBlock`, `IntentionalBlock`).
- Backend: drop `/partner/dashboard/*` (zero callers), `/ws/focus` (Mac uses polling), legacy `/schedule/blocks` redirects, mig 020 columns if no longer needed.
- All repos: remove legacy bridge-message aliases, deprecation warnings, etc.

**Out of scope:**
- Adding new features
- Refactoring beyond removal

**Acceptance criteria:**
1. All previously deprecated code is removed
2. Compile/run clean across all 3 repos
3. No references to deleted symbols remain
4. PR diff is "lots removed, nothing added"

**Risks:**
- Forgotten consumers — search exhaustively before deleting public API
- Test suite may reference deprecated code

**Estimated duration:** 3 days.

---

## Cross-cutting concerns

### Testing strategy

Each slice's detailed plan includes:
- Backend: pytest for new endpoints + webhook handlers + migration up/down
- Mac: XCTest for new Swift classes; manual test plan for UI-heavy slices (10, 11)
- iOS: XCTest where possible; manual on TestFlight for DeviceActivity-dependent slices (5, 12)
- Cross-device sync: 2-device manual test plan per slice

### Rollback plan

Each slice ships behind a backend-side feature flag (`features.NEW_REDESIGN_ENABLED` per user) and a Mac-side `UserDefaults` flag. If a slice breaks:
1. Toggle the feature flag off via SQL update
2. Mac respawns reads new flag, reverts to legacy code path
3. Investigate, fix, re-enable for the user
4. After ≥48 hours of green, deploy fix to anyone else affected

The soft-deprecation pattern means legacy code is still there to fall back to — until slice 13 deletes it.

### Data migration safety

Slices that touch data (1, 2, 3, 4, 5):
- Run migration on a Postgres dump locally first
- Backend writes new schema in addition to old for one release (dual-write during transition)
- Verify old reads still work after migration
- Backfill scripts must be idempotent

### Telemetry / measurement

PostHog events to add per slice:
- Slice 1: `entitlement_check_succeeded`, `entitlement_check_failed`, `subscription_state_observed`
- Slice 3: `budget_consume`, `budget_earn`, `budget_locked`
- Slice 6: `focus_lock_toggle_on`, `focus_lock_toggle_off`, `focus_lock_partner_unlock_request`
- Slice 8: `override_tapped`, `ai_score_judgment`
- Slice 12: `alarm_fired`, `alarm_dismissed_by_puck`

Goal: detect regressions in real-time once you (the only user) start using each slice.

### Slice ordering rationale

- **Slice 1 first** because: nothing else makes sense without entitlements gating. Without subscription, any work below either has no users or has every user.
- **Slice 2 next** because: rename is mechanical and unblocks renames in everything below.
- **Slices 3, 4 in parallel** if you have bandwidth: budget cross-device + schedule cross-device. Both extend backend, no UI overlap.
- **Slice 5 after 2** because: app rules need Focus Mode renames first.
- **Slice 6 after 4** because: Focus Lock requires plan = today's schedule = backend-resident schedule.
- **Slice 7 in parallel with 6** if bandwidth: Strict Mode is independent of Focus Lock.
- **Slice 8 after 3** because: AI scoring rewire calls budget endpoints.
- **Slice 9 after 6** because: block lifecycle uses Focus Lock state.
- **Slice 10 after 6, 9** because: sidebar restructure includes Today page that uses Focus Lock + new lifecycle.
- **Slice 11 after 1, 4** because: iOS tabs need entitlements gate + schedule sync.
- **Slice 12 anytime after 1**: Puck redesign is independent.
- **Slice 13 last**: cleanup happens after everything is stable.

### Estimated total duration

13 slices × 3–5 days each = **6–9 weeks of focused work** for a solo developer. Some slices can be parallelized (3+4, 6+7); realistic estimate: **6 weeks**.

---

## What this plan does NOT cover

- **AI accuracy improvements.** Spec §17 calls these out as deferred. Today's ~80% AI accuracy is accepted; tap-once override is the safety net. Future "deterministic earning + AI for nudges" work is its own spec.
- **Without-Puck alarm experience.** Non-Puck users get a normal phone alarm. Anti-doomscroll is the unique-to-Puck story.
- **Override logging + partner-visible counts (option D from brainstorm Q12).** Wait until AI hits 95%.
- **Per-app individual budgets.** Cohesive only.
- **Calendar gesture editing.** Tap-and-modal in v1.
- **Multi-language, Android.** Not in v1.

---

## Self-review summary

Spec coverage check:
- §1 (3 user-facing concepts): Slices 2, 3, 6 implement. ✓
- §2 (Focus Mode properties incl. strictness): Slices 2, 9. ✓
- §3 (Strict Mode): Slice 7. ✓
- §4 (App taxonomy): Slice 5. ✓
- §5 (Block lifecycle, Puck alarm): Slices 9, 12. ✓
- §6 (AI scoring): Slice 8. ✓
- §7 (Architecture): foundational across all slices. ✓
- §8, §9 (UI structure Mac/iOS): Slices 10, 11. ✓
- §10 (Onboarding defaults): Slices 1, 2 (default seed Focus Modes are part of slice 2). ✓
- §11 (Notifications): added to slice 6 (Focus Lock notifications) + slice 9 (5-min warning). Daily summary deferred to follow-up.
- §12 (Subscription): Slice 1. ✓
- §13 (Cross-device data flow): Slices 3, 4. ✓
- §14 (Migration plan): Slice 13 (deletion); other slices have their own dual-write transitions. ✓
- §15–17 (non-goals, risks, open questions): captured in this master and passed to slice plans. ✓
- §18 (Vocabulary): enforced through naming in every slice. ✓
- §19 (Decisions log): linkable from slice plans. ✓

Gaps / additions needed: **Daily summary notification** (spec §11) is not covered by any slice. **Add as a small task in slice 9** (block lifecycle slice already touches notifications).

Placeholder scan: clean.

Type consistency: `FocusMode` used consistently. `DistractionBudgetClient` used in slices 3 and 8. `EntitlementClient` in slice 1. `FocusLockController` in slice 6. `StrictModeController` in slice 7. ✓

---

**Next step:** Slice 1 detailed plan is written alongside this master at `docs/superpowers/plans/2026-05-05-slice-01-entitlements-plan.md`. Read it, approve or redline, then we begin execution via `superpowers:subagent-driven-development`.

# Intentional App Redesign — Design Spec

**Date:** 2026-05-05
**Status:** Draft. Direction approved via 28-decision brainstorm 2026-05-05.
**Affects:** intentional-backend, intentional-macos-app, puck-ios. (puck-site separately settled — see `docs/pricing-strategy-2026-05-05.md`.)
**Supersedes:** Spec 1 (Intentions), Spec 2 (Time Blocks), Profile system, current Focus Mode controller terminology.

---

## 1. Why this redesign

Today's app has accumulated 8+ overlapping concepts (Intentions, Focus Modes, Profiles, Time Blocks, Schedule Blocks, Earned Browse, Intentional Mode, Focus Sessions, etc.) that fragment the user's mental model and triple the surface area of code. The cross-repo inventory (`docs/inventory-{mac,ios,backend}-2026-05-04.md`) found 4 different things called "Focus Mode" alone, plus dead code paths, broken end-to-end features (strict-unlock partner flow), and a Mac/iOS asymmetry that makes the iPhone feel like a remote control rather than a real product.

The redesign collapses the user-facing surface to **3 concepts** while keeping (and tightening) the existing infrastructure. The goal: a single coherent product that an ADHD impulse-scroller can use without configuration overload, that earns trust via consistent behavior, and that has clean enough internals to ship features instead of fight regressions.

---

## 2. The product, in 3 user-facing concepts

### 2.1 Focus Mode

A named time category with rules. Replaces Intentions, Profiles, and the old "Focus Mode" controller terminology.

Each Focus Mode has:
- **Name** (e.g., "Coding", "Gym", "Reading", "Free Time") + emoji
- **Description** (1-2 sentences) — used as context for the AI scorer ("am I actually doing this?")
- **Apps additionally blocked when active** (e.g., Coding additionally blocks Slack even though Slack is "Allowed" globally)
- **Apps explicitly allowed when active** (e.g., Coding allows YouTube even though YouTube is on the global Distractions list — for tutorial videos)
- **Weekly hour target** (e.g., "20h coding/week")
- **Strictness preset**: Strict / Standard / Soft. Affects override behavior (see §6.4).
- **Default duration** when started ad-hoc (e.g., 60 min)

Free Time is just a Focus Mode with no blocking rules and no AI scoring. Distractions are usable during Free Time, drawing from the budget normally.

### 2.2 Distraction Budget

A single number representing how much distraction time the user has today. One pool, shared across all "Distraction" apps (see §5).

- **Baseline** — user-set daily allowance (default 60 min). Locked behind partner approval if user chooses.
- **Earned** — added on top of baseline via AI-judged focus minutes during Focus Mode blocks (see §6.2). No cap on earned amount.
- **Drains** when user opens any app on the Distractions list.
- At 0 (baseline + earned both consumed) → all Distractions list apps lock for the rest of the day.
- **Resets at midnight** (user's local time, calendar-aligned).

### 2.3 Focus Lock

The "I'm serious today" master toggle. Lives on the Today page.

- **OFF (default)** — Distraction Budget runs normally (baseline + earning + lock at zero). No plan required. No context-switching limiter. User can flip Focus Lock on/off freely.
- **ON** — All of the above PLUS:
  - **Today's calendar must be scheduled** (every chunk of time labeled with a Focus Mode, Free Time included). App refuses to enter Focus Lock until the day is filled. Auto-fill from weekly targets is one tap (see §10.2).
  - **Context-switching limiter** active (cooldown between switching Focus Modes; existing `SwitchInterventionCoordinator`).
  - **Partner code required to turn Focus Lock OFF** during the day (cannot casually disable).

This is the "external executive function he can't override" mechanic.

---

## 3. Strict Mode (a separate, master lock — distinct from per-Focus-Mode strictness)

Separate switch in Settings. When ON, **everything sensitive locks behind partner approval**:
- Bedtime config
- Content Safety toggle
- Distractions list (add/remove apps)
- Always-Blocked list
- AI scorer enabled/disabled
- Daily reset time (if ever made user-configurable — see §17)
- Removing the accountability partner

When OFF, only the two locks already settled (baseline budget + Focus Lock OFF) are partner-gated.

Strict Mode is the "harden everything in one switch" toggle. Reuses the existing `lock_mode` mechanism on the user record.

---

## 4. App-level taxonomy (not the same as Focus-Mode-level)

Every app/website on the user's devices is in **one of three states** (user-configured in Settings):

1. **Allowed** — no restriction. Default state for most apps.
2. **Distraction** — drains the cohesive Distraction Budget when used. Locked when budget hits 0.
3. **Always-Blocked** — never usable. Hard block. (e.g., porn, gambling.)

These lists are user-level and synced across devices.

**On top of that**, a Focus Mode block can override apps:
- Add app to "additionally blocked while active" — even Allowed apps get blocked during this Focus Mode (e.g., Slack during Coding).
- Add app to "explicitly allowed while active" — even Distraction apps become free during this Focus Mode (e.g., YouTube during Reading, for an audio book).

Resolution priority (highest to lowest):
1. Always-Blocked list — never overridable, period.
2. Focus Mode "additionally blocked" — blocks during the active block.
3. Focus Mode "explicitly allowed" — allows during the active block (overrides Distraction status).
4. Distraction list — drains budget when used.
5. Allowed (default).

---

## 5. Block lifecycle and day rhythm

### 5.1 Wake-up alarm (Puck holders only)

- User sets alarm in iOS app for, e.g., 7am.
- At 7am, alarm rings. Phone screen is **locked** (custom UI, not iOS lock screen). Only way to dismiss: walk to Puck and tap it.
- After Puck tap: phone unlocks. **Distractions remain blocked until the user's first scheduled Focus Mode block starts.** (No doomscroll between waking and starting work.)
- Without Puck: alarm is a normal phone alarm. No anti-doomscroll lock. (This is the unique-to-Puck value prop.)

### 5.2 Scheduled block start

- 60-second grace period. At 8:55 (block scheduled 9:00), pill widget shows "Coding starts in 60s — tap to delay 5 min."
- If user does nothing → block auto-starts at 9:00. Focus Mode rules engage. AI scoring begins (if Focus Mode has scoring enabled).
- If user taps "delay 5 min" → block starts at 9:05. Schedule does not shift.

### 5.3 Mid-block: ending early

- Tap "End block now" in the pill (if allowed by strictness):
  - **Strict** Focus Mode: button does nothing. Block runs to scheduled end.
  - **Standard** Focus Mode: 10-second confirmation dialog before ending.
  - **Soft** Focus Mode: ends instantly.
- Ending early triggers the celebration card (see §5.5), then transitions immediately to next scheduled block (or Free Time if gap).

### 5.4 Mid-block: extending

- 5 minutes before scheduled end, pill shows "Extend? (15 / 30 / 60 min)" buttons.
- User taps a duration → schedule auto-shifts: next block + everything after it pushed back by the chosen duration.
- If extending pushes the end of day past midnight, schedule wraps to "rest of plan canceled" (rare edge case; warn user).

### 5.5 Block end

- Celebration card appears: focus score, app breakdown, budget earned in this block.
- User taps "Continue" to start next block (which then runs its own grace period). Pause-and-acknowledge model.
- If user is mid-something, celebration card minimizes to pill after 30 seconds; can be re-opened.

### 5.6 Free Time blocks

- Just a Focus Mode block with no blocking rules and no AI scoring.
- Distraction Budget drains as user opens Distractions list apps.
- No earning during Free Time (AI isn't watching).
- Same start/end rituals as any other block.

### 5.7 Day end

- Daily summary notification at end of day (see §11): focus minutes, blocks completed, weekly target progress, budget used.
- Distraction budget resets at midnight local time.

---

## 6. AI scoring (the engine that gates earning)

### 6.1 What it sees

During a Focus Mode block (one with AI scoring enabled), Mac captures screen + active app + recent activity, sends to Qwen3-4B local model with the Focus Mode's description as context.

### 6.2 What it decides

Per-minute binary judgment: **focused** (yes/no) relative to the Focus Mode description. Yes → that minute is credited to the Distraction Budget at the configured earning rate (existing rate, simplified — see §17 for follow-up).

### 6.3 Override mechanic

If the AI says "not focused" but the user disagrees: **tap once to override**. The minute counts as focused. AI accumulates correction signal for future tuning.

No logging or partner-visibility on overrides in v1 (option A from brainstorm Q12). At ~80% AI accuracy, override count would be dominated by AI errors, not user dishonesty — D becomes viable later when accuracy is verified at 95%+.

### 6.4 Strictness affects override

Per Focus Mode strictness preset (§2.1):
- **Strict**: tap-to-override does nothing. AI judgment is final.
- **Standard**: override works after a 10-second confirmation dialog.
- **Soft**: override works instantly (the default A behavior).

### 6.5 AI failure modes

- Local model crashes → block continues, earning is paused but not penalized. Notification: "AI scoring paused, focus is being tracked by activity only."
- Local model returns invalid response → fail-closed (no credit) for that minute. Existing pattern from CLAUDE.md item 3.

---

## 7. Architecture

### 7.1 Backend = canonical source of truth

All cross-device state lives on the backend.

**New / renamed tables**:

- `focus_modes` (renames `intentions`) — fields: id, user_id (account_id), name, emoji, description, strictness_preset, weekly_target_hours, default_duration_minutes
- `focus_mode_app_rules` (replaces `mac_websites` + `mac_bundle_ids`) — fields: focus_mode_id, app_identifier, rule_type ('block' | 'allow')
- `time_blocks` (already exists from Spec 2) — fields: id, user_id, focus_mode_id, start_at, end_at, day, status
- `distractions` — user-level list. Fields: user_id, app_identifier, added_at
- `always_blocked` — user-level list. Fields: user_id, app_identifier, added_at
- `distraction_budget_state` — fields: user_id, day (local date), baseline_minutes, earned_minutes, consumed_minutes
- `distraction_budget_config` — fields: user_id, baseline_minutes (default 60), is_locked
- `focus_lock_state` — fields: user_id, is_on, turned_on_at
- `users.subscription_tier` (`none` | `trialing` | `active` | `past_due` | `canceled`), `users.trial_ends_at`, `users.current_period_ends_at`

**Endpoints (new or modified)**:

- `GET /me/entitlements` — returns `{tier, plan, trial_ends_at, current_period_ends_at, ship_puck}`
- `GET /focus_modes`, `POST /focus_modes`, `PUT /focus_modes/:id`, `DELETE /focus_modes/:id`
- `GET /time_blocks?day=YYYY-MM-DD`, `POST /time_blocks`, `PUT /time_blocks/:id`, `DELETE /time_blocks/:id`
- `POST /time_blocks/auto_fill` — body: `{day, weekly_targets}` → returns suggested block layout
- `GET /distractions`, `POST /distractions`, `DELETE /distractions/:id`
- `GET /always_blocked`, `POST /always_blocked`, `DELETE /always_blocked/:id`
- `GET /budget_state` — returns today's budget state for the calling user
- `POST /budget_state/consume` — increments consumed_minutes
- `POST /budget_state/earn` — increments earned_minutes (AI-gated, called from Mac)
- `PUT /budget_config` — sets baseline_minutes, is_locked
- `POST /focus_lock/toggle` — body: `{is_on, partner_code?}` (code required to turn off if was on)
- Stripe webhooks (covered in pricing-strategy doc)

### 7.2 Mac = thick client (the brain)

Runs the AI scorer (Qwen3-4B local). Does the actual app blocking via existing `WebsiteBlocker` (browser tabs) + new Network Extension or process-monitoring for non-browser apps (existing or to-be-built). Hosts the pill widget. Hosts the schedule editor.

Mac calls backend on:
- Launch + foreground + 60s timer: pull all state
- Every state change: push to backend
- 2s `/focus/active` poll for cross-device focus sync (existing pattern)

Mac is responsible for:
- AI scoring → calling `POST /budget_state/earn`
- Distraction app open detection → calling `POST /budget_state/consume`
- Block start/end transitions
- Pill widget rendering
- Schedule editor UI
- Settings UI
- Strict Mode partner-unlock UI

### 7.3 iOS = thin client

Sign-in screen (magic link). Backend `GET /me/entitlements` checks subscription on every launch + foreground. If `tier == 'none'`, app shows a "Subscribe at intentional.app" link and locks features.

**iOS does NOT run AI scoring.** Battery impact + model size make this impractical.

iOS is responsible for:
- Sign-in flow
- Today + Week views (mirror Mac, read-only-ish in v1)
- Settings (account, sign out, partner status)
- DeviceActivity-based shielding per active Focus Mode (existing — `PuckBedtimeMonitor` pattern)
- Wake-up alarm (NFC Puck dismiss)
- Background fetch on APNs silent push for cross-device focus state changes

iOS shares the budget number with Mac via backend. If iOS user opens TikTok for 5 min, Mac sees `/budget_state/consume` increment and updates the pill.

### 7.4 Puck = wake-up alarm only

Single use case: tap to dismiss the morning alarm. NFC.

Removed from this redesign: tap-to-toggle Focus Mode (was redundant with software toggles), daytime button on Mac.

### 7.5 puck-site

Already redesigned (`docs/pricing-strategy-2026-05-05.md`). Subscription model, two SKUs, sign-in-only iOS pattern.

---

## 8. Mac UI structure

### 8.1 Pill widget (always-visible floating UI)

**v1**: keep current behavior — current Focus Mode title + countdown timer + small stats row. Same as today's `timer` mode.

**Future direction (post-v1)**: minimize to a small dot/icon. Click to expand for details. Reduces visual footprint.

Modes (post-redesign): timer (in-block), startRitual (60s grace pre-block), celebration (block-end card), noPlan (Focus Lock OFF + no scheduled block + Free Time gap).

### 8.2 Sidebar (5 tabs, down from 8)

> **Updated 2026-05-06 during slice 10 implementation:** earlier draft folded Sensitive Content + Accountability into Settings. User feedback: those are *features* not configuration; burying them makes them hard to find. Restored as top-level items. Today/Week became a view-toggle on the Today page rather than two sidebar items.

1. **Today** — current Focus Mode + countdown, distraction budget meter, today's blocks (timeline), Focus Lock toggle. Top-of-page **Today / Week** toggle switches the visible content (Today = current state; Week = calendar + weekly Focus Mode hour bars).
2. **Focus Modes** — list of Focus Modes with their rules. Add/edit/delete here.
3. **Sensitive Content** — NSFW monitor: real-time activity, history of detections, partner-notification state. Top-level because it's an active feature, not a setting.
4. **Accountability** — partner pairing, breach log, unlock requests, override history. Top-level for the same reason.
5. **Settings** — account, distractions list management, always-blocked list management, strict mode, bedtime config, accessibility/permissions, app preferences.

**Removed sidebar items**: Intentions / Profiles (folded into Focus Modes). Distractions list-management folded into Settings (the budget meter for active distraction state lives on Today). Weekly Planning killed (placeholder, no real UI; future budgets work folds into Today's Week toggle when it ships).

**Distinction:** "Settings" is configuration only. Anything the user actively *uses* during the day (modes, sensitive content monitor, partner system) is a top-level sidebar item.

### 8.3 Overlays (kept, unchanged structure)

- Block start ritual (full-screen pre-block confirmation, existing `BlockRitualController`)
- Block end ritual (celebration card, existing `BlockEndRitualController`)
- Focus enforcement overlay (red screen on Distraction violation during a block)
- Switch limiter overlay (cooldown between Focus Modes when Focus Lock ON)
- Bedtime lock loop (existing — orthogonal to redesign)
- Tamper overlay (existing — orthogonal)

---

## 9. iOS UI structure

### 9.1 Sign-in screen

- Email field + "Send magic link" button
- "No account? Subscribe at intentional.app →" — direct link, legal in US per `docs/app-store-strategy-2026-05-05.md`
- That's it. No pricing in-app.

### 9.2 Tabs (3 tabs, down from 6)

1. **Today** — current Focus Mode + countdown, distraction budget meter, today's blocks, alarm setup
2. **Week** — calendar view + weekly Focus Mode hour bars (read-only or light editing in v1)
3. **Settings** — account, sign out, partner, alarm config, Puck pairing

**Removed tabs from current state**: Schedule (folded into Today + Week), Focus Modes/Intentions tab, Alarms tab (folded into Settings + Today), Partner tab (folded into Settings).

### 9.3 Lapsed-subscriber state

- 24-hour grace period after subscription lapses (covers Stripe card-retry edge cases).
- After 24h: enforcement features disabled. App stays usable as a planner: schedule and Focus Modes editable, but no blocking, no AI, no budget.
- Banner: "Your subscription has lapsed. Renew to re-enable focus features →" (link to web account management).

---

## 10. Onboarding

### 10.1 First-launch flow

Sane defaults, no forced setup. After sign-in:

- 4 pre-built Focus Modes seeded for new users:
  - **Deep Work** — Standard strictness, 20h/week target, blocks the default Distractions list
  - **Free Time** — Soft, no weekly target, no extra blocking, no AI scoring
  - **Gym/Health** — Standard, 5h/week target, blocks everything except Spotify and Health apps
  - **Reading** — Standard, 5h/week target, blocks everything except books/articles apps
- Default Distractions list pre-populated: Instagram, TikTok, YouTube, Twitter/X, Reddit, Snapchat, Facebook
- Default Always-Blocked list: empty (user adds if they want)
- Default Distraction Budget baseline: 60 minutes/day, not locked
- Default Focus Lock: **OFF** (user has no plan yet — turning it on would just block them)
- Default Strict Mode: OFF
- Partner setup: optional, prompted as a single banner card on Today page that user can dismiss

### 10.2 Auto-fill from weekly targets

When user enables Focus Lock with no plan, app shows: **"Auto-fill today from your weekly targets?"** One tap → app generates a daily schedule using:
- Each Focus Mode's weekly hours target
- Days remaining in the week
- Reasonable spread across waking hours (e.g., 8am-10pm by default)
- Free Time fills any remaining gaps

User then drags/edits the generated schedule before confirming.

---

## 11. Notifications

External notifications (vs in-pill UI) for:
- "5 minutes left in current block"
- Daily summary at end of day (focus minutes, weekly target progress, budget used)
- Distraction Budget exhausted (locked)
- Partner: unlock request received, granted, denied
- Subscription: trial ending in 24h, payment failed, payment succeeded
- Strict Mode: partner unlock approved

Quiet hours: bedtime mode silences all non-critical notifications.

---

## 12. Subscription / entitlements

Settled in `docs/pricing-strategy-2026-05-05.md`. Brief recap:
- 7-day free trial, card required up front (Stripe Checkout)
- Plans: Monthly $12.99/mo OR Annual $79/yr (annual ships free Puck after day 14)
- Lapsed = 24h grace, then app becomes a free read-only-ish planner until renewal
- iOS: sign-in-only, no IAP, link to website for subscribe (legal in US per `docs/app-store-strategy-2026-05-05.md`)

---

## 13. Cross-device data flow

- Schedule (`time_blocks`) — backend canonical, both clients sync.
- Focus modes — backend canonical, both clients sync.
- Distractions list, Always-Blocked list — backend, both clients.
- Distraction Budget state — backend, both clients. Mac increments earned (AI-gated). Both clients increment consumed (when their device opens a Distraction app).
- Focus Lock state — backend.
- Active focus session — backend (existing `focus_sessions` from earlier consolidation).

Mac polls `/focus/active` every 2s for cross-device transitions (existing). iOS uses APNs silent push on state changes (existing).

Conflict resolution: last-write-wins for most fields, with `updated_at` timestamps. For schedule edits, server-side conflict detection on `start_at` overlap (rare, only matters if user edits same block on both devices in <10s).

---

## 14. Migration plan (high level — full plan in writing-plans phase)

Per Q23: **soft-deprecate**. Old code stays for one release cycle. New code lives alongside. Old code deleted only after new code is verified working.

### 14.1 What gets renamed

| Today | New |
|---|---|
| `intentions` (table, code) | `focus_modes` |
| Intention struct | FocusMode struct |
| IntentionStore | FocusModeStore |
| `mac_websites`, `mac_bundle_ids` | `focus_mode_app_rules` |
| Bridge messages: `*_INTENTION_*` | `*_FOCUS_MODE_*` (legacy aliases retained) |
| Sidebar "Intentions"/"Focus Modes" | "Focus Modes" |
| Project / Profile concepts | Folded into Focus Mode |

### 14.2 What gets created (new)

- Backend: `distractions`, `always_blocked`, `distraction_budget_state`, `distraction_budget_config`, `focus_lock_state` tables + endpoints
- Mac: `DistractionListManager`, `BudgetSync`, `FocusLockController`, sign-in flow, entitlements check on launch
- iOS: sign-in flow, entitlements check, Today/Week/Settings tab restructure, Puck-pairing migration to alarm-only
- Backend: Stripe webhooks, `/me/entitlements`, magic-link auth (if not already present)

### 14.3 What gets deleted (after one release cycle of stability)

- `IntentionalModeController` references (already deleted, cruft remains)
- `Settings → Focus Mode` toggle (dead code)
- `BlockingProfileManager` + Profiles tab in dashboard
- 14 legacy branches in `dashboard.html` Intentions tab (per Mac inventory §9)
- Legacy `*_PROJECT_*` bridge handlers
- Per-platform earning rates / cost multipliers / intent bonus / delay escalation (simplified to one rate)
- Daytime Puck NFC toggle code (Puck → alarm-only)
- iOS Schedule tab (folded into Today + Week)
- iOS dead views: RoutineView, HabitGoalCreationView, WeeklyReportSheet, CalendarTimelineView, QuickBlockButton, ScheduleBlockEditSheet/DetailSheet, NetworkClient, ModePickerSheet, legacy SwiftData PuckSchedule + ScheduleBlock + IntentionalBlock
- Backend: `/partner/dashboard/*` (zero callers), `/ws/focus` (Mac uses polling), legacy `/schedule/blocks` redirects, mig 020 unused weekly_budget columns (actually USED now per this redesign — re-evaluate)

### 14.4 What stays unchanged

- Bedtime lock loop (orthogonal, working)
- Content Safety (orthogonal, working)
- Strict mode lock_mode mechanism (just expanded scope)
- Existing AI scoring pipeline (Qwen3-4B + RelevanceScorer + cache + fail-closed)
- EarnedBrowseManager pipeline (renamed/refactored to back the Distraction Budget concept)
- Partner-unlock infrastructure (extended to handle more lock types)
- Pill widget rendering layer (just new content)

---

## 15. Out of scope for v1 (deferred)

- AI accuracy improvements (deterministic earning + AI-as-nudge-only). Ship at current ~80%, track override counts, plan v2 once accuracy is measurable in production.
- Override logging + partner-visibility (option D from Q12). Comes when AI is at 95%+.
- Per-app individual time budgets. Cohesive only in v1.
- Custom daily reset time. Hardcoded midnight in v1.
- iOS as full enforcer (running its own AI). Light client only.
- iOS schedule editing on iPhone (read-only-ish in v1).
- Calendar drag-to-create / drag-to-resize (gesture editor). Tap-and-modal in v1.
- Multi-language. English only in v1.
- Android. Not in v1.
- Focus Mode color customization (just emoji in v1).

---

## 16. Risks and what we're betting on

- **AI accuracy at 80%**. Tap-once override is the safety net. If real-world override count is much higher than 1/5 minutes, AI accuracy is worse than expected and v1 might feel broken. Mitigation: instrument override counts in PostHog, dashboard the data, react.
- **Migration breakage**. Soft-deprecation reduces risk but doesn't eliminate. Test heavily on a clean account + an existing account before each release.
- **iOS sign-in conversion**. Going from "you bought hardware" to "you signed up for sub" is a different funnel. Track conversion at every step.
- **Cross-device state divergence**. Backend-canonical reduces this but doesn't eliminate (clients might have stale cache). Mitigation: aggressive 2s polling on Mac, APNs push to iOS, optimistic UI with backend confirmation.
- **Backend deploy cadence**. Adding ~15 new endpoints + 5+ new tables is not a small backend change. Stage carefully.

---

## 17. Open implementation questions (for writing-plans)

1. **Do we ship in vertical slices or horizontal layers?** (Recommend vertical: subscription/entitlements first, then Focus Mode rename, then budget cross-device, then UI restructure, then Puck-narrowing.)
2. **What's the first user-visible deliverable?** (Probably: subscription+entitlements + Mac sign-in check; you become your own "subscribed user" before anything else changes.)
3. **What's behind a feature flag during development?** (The new sidebar layout, the new Today page UI, Distraction Budget cross-device.)
4. **Testing strategy for the AI scoring pipeline?** (Unit tests for the scorer wrapper, integration test against sample Focus Mode descriptions, manual test plan for accuracy.)
5. **How do we test cross-device sync?** (Existing pattern from focus state polling; extend for new tables.)
6. **What's the rollback plan if a release breaks for you (the only user)?** (Soft-deprecation gives us this for free — flip a feature flag back to old code path.)
7. **How long does each vertical slice take?** (Target: ship one slice every 3-5 days, not weeks.)

These get answered in writing-plans, not here.

---

## 18. Vocabulary lock

These names are now canonical. Use everywhere — code, UI, marketing, docs.

| Concept | Name |
|---|---|
| The named time-category | **Focus Mode** |
| The cohesive distraction time pool | **Distraction Budget** |
| User-set baseline portion of the budget | **Baseline budget** |
| AI-earned portion of the budget | **Earned budget** |
| The "I'm serious today" master toggle | **Focus Lock** |
| Sensitive-things-master-lock toggle | **Strict Mode** |
| An instance of a Focus Mode on a calendar | **Block** |
| The Focus Mode for unstructured time | **Free Time** |
| App that drains the budget | **Distraction** |
| App that's never usable | **Always-Blocked** |
| App with no restrictions | **Allowed** |
| Per-Focus-Mode override of an app's status | **Allow exception** / **Block exception** |
| Override the AI's "not focused" judgment | **Tap-to-override** |
| The 60s pre-block UI | **Grace period** |
| The end-of-block UI | **Celebration card** |
| The 5-min-before-end extension UI | **Extend prompt** |

---

## 19. Decisions log (for traceability)

This spec is the result of 28 brainstorm decisions on 2026-05-05. Key calls:

| # | Question | Decision |
|---|---|---|
| 1 | Scope | Big redesign |
| 2 | Unified concept name | "Focus Mode" |
| 3 | Budget under Focus Lock OFF | Budget always runs; Focus Lock layers plan/limiter/partner on top |
| 4 | Earning gate | AI-gated only |
| 5 | Budget structure | Baseline (user-set, lockable) + earned ON TOP |
| 6 | Cap on earned | None |
| 7 | "A plan" definition | Whole day scheduled, with auto-fill from weekly targets |
| 8 | iOS scope | Light client (no AI) |
| 9 | App categories | Allowed / Distraction / Always-Blocked + Focus Mode overrides |
| 10 | Free Time | A Focus Mode |
| 11 | Schedule storage | Backend canonical, cross-device |
| 12 | AI override | Tap once (no logging in v1) |
| 13 | Puck role | Wake-up alarm only |
| 14 | Daily reset | Midnight |
| 15 | Strict Mode scope | Master toggle locks everything sensitive |
| 16 | Per-Focus-Mode strictness | Yes, three levels |
| 17 | Strictness behavior | Affects override behavior only |
| 18 | Onboarding | Sane defaults, sign-in-and-go |
| 19 | Block end | Celebration card pause-and-acknowledge |
| 20 | Lapsed sub | 24h grace, then planner-only |
| 21 | iOS sign-in | Magic link |
| 22 | Default Focus Modes | 4 (Deep Work, Free Time, Gym, Reading) |
| 23 | Cleanup strategy | **Updated 2026-05-05:** feature-branch + hard-delete-on-merge (was: soft-deprecate). Old code stays on main until slice's branch merges; rollback via git revert. Replaces commented-out-cruft pattern. |
| 24 | Pill widget | Keep current; future direction = minimal dot |
| 25 | Notifications | Critical + 5-min warning + daily summary |
| 26 | End-block early | Strictness-dependent |
| 27 | Extending block | Prompt with 15/30/60 options |
| 28 | Wake alarm | Hard-locked phone, only Puck dismisses |

---

## 20. Next step

Once you've reviewed and approved this doc:

1. I commit it to git.
2. I invoke `superpowers:writing-plans` to break implementation into vertical-slice tasks under `docs/superpowers/plans/2026-05-05-app-redesign-plan.md`.
3. You review the plan.
4. I invoke `superpowers:subagent-driven-development` to start executing tasks one slice at a time.

---

**TL;DR:** Three user-facing concepts (Focus Mode, Distraction Budget, Focus Lock), one Strict Mode master lock, three app states, sane defaults, magic-link iOS sign-in, soft-deprecation for migration. Old code dies after new code proves itself. AI ships at 80% accuracy with tap-once override. Puck is alarm-only. Spec captures all 28 brainstorm decisions plus architecture, migration, and what gets deleted/added/renamed.

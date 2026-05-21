# Feature Inventory — Verified (2026-05-13)

> **Phase 1 deliverable.** Built from CLAUDE.md, BRAINSTORMING_CONTEXT.md, inventory-mac-2026-05-04.md, inventory-synthesis-2026-05-04.md, dashboard.html (slice 10 redesign), AppDelegate.swift init order, and MainWindow.swift bridge messages.
>
> Every row in this table will be placed in exactly one surface in `architecture.md`. No row left orphaned.

---

## A. Focus enforcement (Category 1 — the "blocker" job)

| # | Feature | Status | Current home (today's app) | Source-of-truth file |
|---|---|---|---|---|
| A1 | Focus Modes / Intentions (named intents with strictness preset Standard/Strict; Soft dropped) | working | Sidebar → Focus Modes (cards grid) + per-block Intention picker | `IntentionStore.swift`, `intentions.json` |
| A2 | Global Distractions list (3-tier: Allowed / Distraction / Always-Blocked) | working | Folded into Settings per slice-10 redesign | `onboarding_settings.json` (legacy keys retained) |
| A3 | Schedule of focus blocks (calendar of recurring time-blocked windows) | working | Today page → Schedule section (calendar) | `daily_schedule.json` + `/time_blocks` (Spec 2) |
| A4 | Today/Week segmented toggle on schedule | working | Top of Today page | dashboard.html line 4700 |
| A5 | +Focus button (insert draft Focus Hours block) | working | Top of schedule on Today | `SET_SCHEDULE` |
| A6 | +Free Time button (insert "Break" block) | working | Top of schedule on Today | `SET_SCHEDULE` |
| A7 | Calendar block → editor modal | working | Today page calendar | `SET_SCHEDULE` |
| A8 | Calendar block → assessments inline panel | working | Today page calendar | `GET_BLOCK_ASSESSMENTS` |
| A9 | Calendar zoom level | working | Top of schedule | `SET_CALENDAR_ZOOM` |
| A10 | Calendar day navigation (←/→ + "Today" label) | working | Top of schedule | `GET_SCHEDULE_FOR_DATE` |
| A11 | Focus Mode (Focus Lock) toggle — manual on/off enforcement | working | Today page → toggle | `FOCUS_MODE_TOGGLE` → `/focus/toggle` |
| A12 | Context-switching overlay (non-skippable countdown on cross-app switches in session) | working | Full-screen overlay (SwitchOverlayController) | `SwitchInterventionCoordinator.swift` |
| A13 | Drift / nudge — Level 1 (in-pill distraction card with "Back to Task") | working | Pill widget | `DeepWorkTimerController.swift` |
| A14 | Drift / nudge — Level 2+ (external toast — "Got It" / "This Is Relevant") | working | NudgeWindowController | `NudgeWindowController.swift` |
| A15 | Block-start ritual (pill `.startRitual` mode — "Up next" + Start/Edit) | working | Floating pill | `DeepWorkTimerController.swift` |
| A16 | Block-start edit (pill `.startRitualEdit` — title/desc/type, rejects empty for work) | working | Floating pill | same |
| A17 | Auto-start (3 min for work blocks, 30s for free blocks) | working | Pill behavior | same |
| A18 | Block-end ritual / celebration (3–4 card carousel: Session Complete, Focus Score, App Breakdown, Up Next) | working | Pill `.celebration` mode (also BlockEndRitualController full-screen variant for some cases) | `DeepWorkTimerController.swift` + `BlockEndRitualController.swift` |
| A19 | Skip celebration link | working | Pill | same |
| A20 | Pill `.timer` mode (300×70 — dot + intention + MM:SS + stats + recovery message + distraction card) | working | Pill | same |
| A21 | Pill `.blockComplete` mode (amber border, "Block complete · 0:00") | working | Pill | same |
| A22 | Pill `.noPlan` mode (4 substates: noPlan / gap / allCaughtUp / doneForDay) | working | Pill | same |
| A23 | Pill minimize-to-dock (dismiss button → `minimize()`) | working | Pill | same |
| A24 | Pill drag-to-move + position persistence | working | Pill | UserDefault `pillWindowTopRight` |
| A25 | Quick-block buttons from noPlan card (15/30/60 min) | working | Pill noPlan | same |
| A26 | "Plan Day" / "Schedule Now" links from noPlan card | working | Pill noPlan | same |
| A27 | Snooze on noPlan card | working | Pill noPlan | same |
| A28 | Atmospheric vignette / grayscale overlay during deep-work | working | Full-screen (click-through) | `GrayscaleOverlayController.swift` |
| A29 | Focus Start overlay (Cmd+Shift+P / menu / Puck / WS signal) — profile chips + intention text + AI scoring toggle + Start | working | Full-screen overlay | `FocusStartOverlay.swift` |
| A30 | AI relevance scoring (Qwen3-4B local model) | working | Background, surfaces in pill + AI Assessments | `RelevanceScorer.swift` + `relevance_log.jsonl` |
| A31 | AI Assessments card (scrollable last-N coach verdicts) | working | Today page — bottom card | `GET_RELEVANCE_LOG` |
| A32 | Export Relevance Log button | working | AI Assessments card | `EXPORT_RELEVANCE_LOG` |
| A33 | AI Model selector (Apple FM / Qwen) | working | Settings → AI Scoring | `SET_AI_MODEL` |
| A34 | "Enable Daily Focus Plan" toggle (schedule engine on/off) | working | Settings → AI Scoring | `SET_FOCUS_ENABLED` |
| A35 | Focus Enforcement mode (nudge vs block) | working | Settings → AI Scoring | `SET_FOCUS_ENFORCEMENT` |
| A36 | Per-block enforcement toggles (6 mechanisms × 2 block types = 12 toggles) | working | Settings → Enforcement | `SET_ENFORCEMENT_SETTINGS` |
| A37 | Intervention exercise overlay (5-min cumulative distraction → Scrambled Words / Reflect & Commit, mandatory 60/90/120s wait) | working | Full-screen overlay | `InterventionOverlayController.swift` |
| A38 | Intervention toggles (per-intervention enable) | working | Settings → Focus Mode → Interventions | `INTERVENTION_TOGGLE_SET` |
| A39 | Tamper overlay (settings changed outside dashboard) | working | Full-screen | `TamperOverlayController.swift` + `EnforcementReconciler.swift` |
| A40 | Earned Browse pool tracking (focus minutes × multiplier × intent bonus) | working (UI hidden) | Pipeline alive, widget `display:none` | `EarnedBrowseManager.swift` + `earned_browse.json` |
| A41 | Earned Browse widget on Today | hidden (CLAUDE.md "stripped for Puck model") | Today page (display:none) | dashboard.html line 4479 |
| A42 | Extra Time request flow (partner email code) | working (hidden UI) | Code-grid + verify | `REQUEST_EXTRA_TIME`, `VERIFY_EXTRA_TIME_CODE` |
| A43 | Promote learned site (banner: add learned-override host to always-relevant) | working | Intentions detail | `PROMOTE_LEARNED_SITE` |
| A44 | If-then plan (default plan index) | working | Block-start ritual | `SAVE_IF_THEN_PLAN` |
| A45 | Block ritual variant (8 design variants) | working | UserDefault | `blockRitualDesign` |
| A46 | Coach Context card (profile + daily plan) | working | Top of Today | dashboard.html line 4682 |
| A47 | Focus profile inline editor (work profile textarea) | working | Today page (rendered conditionally) | `SET_PROFILE` |
| A48 | Save daily plan ("Today: No plan yet — add one") | working | Coach context row | (writes to focus_profile.json / daily plan) |
| A49 | Website blocker (AppleScript tab blocking) | working | Background | `WebsiteBlocker.swift` |
| A50 | Browser monitor (extension connection cross-check) | working | Background + status indicator | `BrowserMonitor.swift` |
| A51 | Filter Manager (System Extension content filter) | working | Background (System Settings → Network surfaces it) | `FilterManager.swift` |
| A52 | Always-allowed apps list | working | Implicit in distracting-apps logic | `onboarding_settings.json` |
| A53 | Always-blocked apps list | working | Implicit | `onboarding_settings.json` |
| A54 | Distracting apps list (separate from websites) | working | (Legacy — now driven by BlockingProfileManager) | `onboarding_settings.json` |
| A55 | Block focused-blocked.html / blocked.html (in-browser block page) | working | Browser-side | `focus-blocked.html`, `blocked.html` |
| A56 | In-dashboard toast (save/error indicators inside WKWebView) | working | All pages | `MainWindow.swift` |
| A57 | "Force-a-plan" / no-plan overlay (in FocusMonitor) | **DEAD** — deleted in TimeState consolidation; TODO to restore | n/a | `FocusMonitor.swift:1634` |

---

## B. Intentions / Missions / Goals (Category 2 — the "planner" job)

| # | Feature | Status | Current home | Source-of-truth file |
|---|---|---|---|---|
| B1 | Intentions list (cards grid) | working | Sidebar → Focus Modes | `IntentionStore.swift` |
| B2 | Intention detail dashboard | working | Click an intention card | `GET_INTENTION` |
| B3 | + New Intention setup form (name / blocklist sites / blocklist apps / strictness) | working | Click "+ New" card | `CREATE_INTENTION` |
| B4 | Edit intention (UPDATE) | working | Detail dashboard | `UPDATE_INTENTION` |
| B5 | Delete intention | working | Detail dashboard | `DELETE_INTENTION` |
| B6 | Start session from intention (manual) | working | "Start" on detail | `START_INTENTION_SESSION` |
| B7 | Strictness preset (Standard / Strict; Soft dropped) | working | Inline on card + edit form | `UPDATE_INTENTION_STRICTNESS` |
| B8 | Strictness — instant tightening | working | Strictness picker | (no delay) |
| B9 | Strictness — 24h cool-down softening (Standard → Soft) | partially live | (Soft removed per CLAUDE.md so this path may be dormant) | backend cron |
| B10 | Strictness — Strict → softer requires partner unlock | DEFERRED (backend endpoints not deployed) | UI exists, always fails at runtime | `requestIntentionStrictnessUnlock` (404) |
| B11 | Cancel pending strictness change | working | Detail dashboard | `CANCEL_PENDING_STRICTNESS_CHANGE` |
| B12 | Intention strictness unlock sheet (reuses BedtimeUnlockRequestView) | working UI / broken backend | Floating window | `BedtimeUnlockRequestView` kind=intentionStrictness |
| B13 | Weekly Planning placeholder page (`page-weekly`) | DEPRECATED — removed from sidebar slice 10 | DOM retained, no UI | dashboard.html `page-weekly` |
| B14 | Spec 1 schema fields: `weeklyBudgetHours`, `budgetEnforcement` | DEFERRED — no UI yet | Schema only | `Intention.swift` |
| B15 | **NEW** — Monthly goals (cap 3, identity color) | DESIGNED (planning spec) | n/a yet | planning spec |
| B16 | **NEW** — Weekly missions (cap 3, color-linked to monthly) | DESIGNED | n/a yet | planning spec |
| B17 | **NEW** — Daily sessions (drag missions to today's timeline, 15-min snap, NOW indicator) | DESIGNED | n/a yet | planning spec |
| B18 | **NEW** — Edit modal (Title / Done looks like / For monthly goal / Hours target) | DESIGNED | n/a yet | planning spec |
| B19 | **NEW** — "Help me plan" guided ritual (3–4 steps, voice-friendly, generates draft cards) | DESIGNED | n/a yet | planning spec |
| B20 | **NEW** — Weekly review (Done / Slipped / Dropped, planned-vs-actual hours, pattern insight) | DESIGNED | n/a yet | planning spec |
| B21 | **NEW** — Monthly review (Complete / Continue / Drop / Replace + combined with weekly review last week of month) | DESIGNED | n/a yet | planning spec |
| B22 | **NEW** — Empty states (new month / new week / all caught up / day complete) | DESIGNED | partial via pill noPlan | planning spec |
| B23 | **NEW** — Pattern insight card ("Planned 9h 30m, did 7h 45m. IG goals have come up short 4 weeks running.") | DESIGNED | n/a yet | planning spec |
| B24 | **NEW** — Today timeline strip (drag-and-drop, 8am-8pm) | DESIGNED | (today calendar exists but no drag-from-missions) | planning spec |

---

## C. Sensitive content / porn blocker (Category 3)

| # | Feature | Status | Current home | Source-of-truth file |
|---|---|---|---|---|
| C1 | NSFW detection (on-device OpenNSFW model) | working | Background | `ContentSafetyMonitor.swift` |
| C2 | Apple SensitiveContentAnalysis fallback | partial (entitlement stripped from PKG; OpenNSFW is production) | Background | same |
| C3 | System Extension content filter | working | Background (System Settings surfaces) | `FilterManager.swift` |
| C4 | AppleScript blocking | working | Background | `WebsiteBlocker.swift` |
| C5 | DNS-level blocking (System Extension) | working | Background | same |
| C6 | Per-window screen capture (every 2s) | working | Background | `ContentSafetyMonitor.swift` |
| C7 | Content Safety toggle (Screen monitoring) | working | Sidebar → Sensitive Content + Settings → Content Safety | `SAVE_SETTINGS` |
| C8 | Content Safety detection overlay (per-screen blur) | working | Full-screen overlay | `ContentSafetyMonitor.overlayWindows` |
| C9 | Content Safety permission overlay (when ScreenCapture revoked) | working | Full-screen overlay | same |
| C10 | Partner notification on detection (every detection uploads; email after 3rd in 1hr) | working | Backend | `reportContentSafety` → `/content-safety/report` |
| C11 | Content Safety tamper reporting | working | Backend | `reportContentSafetyTamper` |
| C12 | Test detection button (triggers fake detection through pipeline) | working | Settings → Content Safety | `TEST_CONTENT_SAFETY` |
| C13 | Open System Settings (when permission missing) | working | Banner action | `OPEN_CONTENT_SAFETY_SETTINGS` |
| C14 | Content Safety log (append-only event log) | working | Local file | `content_safety_log.jsonl` |
| C15 | Sensitive Content sidebar page (`page-sensitive`) | working | Sidebar | dashboard.html |
| C16 | Settings → Content Safety detail | working | Settings | mirrors sidebar page |

---

## D. Accountability + Strict (Category 1 + 3 cross-cutting)

| # | Feature | Status | Current home | Source-of-truth file |
|---|---|---|---|---|
| D1 | Set partner email + name | working | Sidebar → Accountability | `SAVE_LOCK_SETTINGS` → `setPartner` |
| D2 | Resend partner invite | working | Accountability page | `RESEND_PARTNER_INVITE` |
| D3 | Remove partner | working | Accountability page | `REMOVE_PARTNER` |
| D4 | Lock-Mode picker (None / Partner) | working | Accountability page | `SAVE_LOCK_SETTINGS` |
| D5 | Enable Partner Lock button (gradient hero) | working | Accountability page | same |
| D6 | Partner status indicator (Active · ready to lock) | working | Accountability page | `_partnerStatusResult` |
| D7 | Partner sibling-sync (account-scoped, all devices share partner) | working | Backend | `PartnerSyncService.shared` |
| D8 | Strict Mode toggle (anti-tamper) | working | Accountability page | `SAVE_STRICT_MODE` |
| D9 | Strict Mode flag file | working | local file | `~/Library/Application Support/Intentional/strict-mode` |
| D10 | Watchdog daemon (LaunchAgent re-opens app if flag present) | working | Background | `com.intentional.watchdog.plist` |
| D11 | Watchdog respawn after SIGKILL | working | Background | watchdog |
| D12 | Login-item persistence | working | Background | LSSharedFileList |
| D13 | Cmd+Q strict behavior (partner-gated quit) | working | App-level | AppDelegate |
| D14 | Request Unlock (partner-gated unlock) | working | Accountability page | `REQUEST_UNLOCK` → `/unlock/request` |
| D15 | Verify Unlock code (6-digit code from partner) | working | Accountability page | `VERIFY_UNLOCK` → `/unlock/verify` |
| D16 | Re-lock after temporary unlock | working | Accountability page | `RELOCK_SETTINGS` |
| D17 | Get Unlock Status (launch sync, post-foreground) | working | Background | `getUnlockStatus` |
| D18 | Bedtime unlock-request sheet (partner-gated bedtime release, duration slider 15/30/60/120/until-wake) | working | Floating window | `BedtimeUnlockRequestView` |
| D19 | Intention strictness unlock sheet (Strict → softer) | UI works, backend deferred | Floating window | same view, `kind: .intentionStrictness` |
| D20 | Tamper detection + auto-correction | working | Background | `EnforcementReconciler.swift` |
| D21 | Tamper overlay (settings changed outside dashboard) | working | Full-screen | `TamperOverlayController.swift` |
| D22 | "Self" lock mode (deprecated, defensive translation in 4 places) | DEPRECATED | n/a | dead code |
| D23 | Uninstall flow (partner-gated full uninstall) | working | Settings → Reset & Delete | `UNINSTALL_APP`, `VERIFY_UNINSTALL` |

---

## E. Bedtime (Cat 4 partial — bedtime side; wake side missing)

| # | Feature | Status | Current home | Source-of-truth file |
|---|---|---|---|---|
| E1 | Bedtime enforcer toggle | working | Settings → Bedtime | `SAVE_BEDTIME_SETTINGS` |
| E2 | Bedtime / Wake times (currently hard-coded display "11:00 PM" / "7:00 AM" — actual edit lives elsewhere) | partial | Settings → Bedtime | dashboard.html line 5069 |
| E3 | Bedtime config cross-device sync | working | `/bedtime/config` GET on launch + foreground + 60s | `BedtimeConfigSync.swift` |
| E4 | Wind-down notifications T-30 / T-15 / T-10 / T-5 / T-1 | working | macOS `.timeSensitive` notifications | `BedtimeWindDownController.swift` |
| E5 | Bedtime pill `.bedtimeWindDown` mode (moon glyph + countdown, minimize allowed at T-30) | working | Pill | `DeepWorkTimerController.swift` |
| E6 | Bedtime pill `.bedtimeLocked` mode (lock glyph + "Bedtime active" + Ask Partner button) | working | Pill | same |
| E7 | Bedtime lock-loop (`SACLockScreenImmediate` every 10s) | working | Background, drives OS lock screen | `BedtimeLockLoop.swift` |
| E8 | Partner unlock for bedtime (duration-limited: 15/30/60/120/until-wake) | working | `BedtimeUnlockRequestView` floating window | same as D18 |
| E9 | Once-per-night unlock cap | working | enforcer state | `BedtimeEnforcer.swift` |
| E10 | Wake side / morning alarm | **NOT BUILT** — entirely missing | n/a | n/a |
| E11 | Synchronized wake (cross-device) | **NOT BUILT** | n/a | n/a |
| E12 | Migration of legacy local bedtime config → backend | working (one-time) | Background | `BedtimeConfigSync` migration path |

---

## F. Puck device (current state: minimal)

| # | Feature | Status | Current home | Source-of-truth file |
|---|---|---|---|---|
| F1 | Puck pairing (iPhone-side) | working | iOS app | iOS code |
| F2 | Puck start/stop focus signal (via WS to Mac) | working | Background | `FocusWebSocketClient.swift` |
| F3 | Puck press → triggers FocusStartOverlay on Mac | working | Full-screen overlay | `FocusStartOverlay.swift` |
| F4 | **NEW** — Puck as NFC wake-alarm tap target (Unbed pattern) | PLANNED | n/a | (Cat 4 Perplexity research pending) |
| F5 | **NEW** — Puck tap → route into morning planning ritual | PLANNED | n/a | concept |
| F6 | **NEW** — Puck as session-end dismiss | PLANNED | n/a | concept |

---

## G. Cross-device sync

| # | Feature | Status | Current home | Source-of-truth file |
|---|---|---|---|---|
| G1 | Focus state sync (Mac polls `/focus/active` every 2s + WS push) | working | Background | `FocusStatePoller.swift` + `FocusWebSocketClient.swift` |
| G2 | Bedtime config sync (see E3) | working | Background | `BedtimeConfigSync.swift` |
| G3 | Partner sibling-sync (see D7) | working | Background | `PartnerSyncService.shared` |
| G4 | Intentions sync (GET on launch + foreground + 60s, push on CRUD) | working | Background | `IntentionStore.swift` |
| G5 | Time blocks sync (Spec 2 — Mac local + `/time_blocks`) | working | Background | `ScheduleManager.swift` |
| G6 | iPhone scheduled blocks via DeviceActivityMonitor | working (iOS-only) | iOS extension | `PuckBedtimeMonitor` |
| G7 | Cross-device socket relay (Chrome extension ↔ Mac) | working | Background | `SocketRelayServer.swift` |
| G8 | WebSocket relay server | working | Background | same |
| G9 | Backend as source of truth for focus_sessions | architectural rule | Backend | `focus_sessions` table |
| G10 | Device registration | working | Launch | `BackendClient.registerDevice` |
| G11 | Heartbeat (2 min interval) | working | Background | `BackendClient.sendEvent` |
| G12 | `BlockingProfileManager` profiles (local-only, never syncs) | KNOWN GAP | Local file | `blocking_profiles.json` |
| G13 | Earned Browse pool (Mac local only — double-earn risk on 2 Macs) | KNOWN GAP | Local file | `earned_browse.json` |
| G14 | iOS Alarms (`PuckAlarm` SwiftData) — local to iPhone | KNOWN GAP | iOS local | iOS SwiftData |
| G15 | Mac schedule format ≠ iOS `/schedule/blocks` format | KNOWN GAP — schedules don't unify | both local + backend | `/time_blocks` + `/schedule/blocks` |
| G16 | Strict mode state (Mac local + partial backend; iOS no view) | partial | Mac flag file | partial backend |

---

## H. Account / app / system

| # | Feature | Status | Current home | Source-of-truth file |
|---|---|---|---|---|
| H1 | Onboarding wizard (lock mode, partner email, theme) | working | onboarding.html | first launch |
| H2 | Magic-link login (email + 6-digit code) | working | login.html | `AUTH_LOGIN` / `AUTH_VERIFY` |
| H3 | Sign out | working | Settings → Account | `AUTH_LOGOUT` |
| H4 | Delete account | working | Settings → Reset & Delete | `AUTH_DELETE` |
| H5 | Account info (email / member since / devices) | working | Settings → Account | `GET_AUTH_STATE` |
| H6 | Stripe subscription status | partial (trial not dogfooded) | (mentioned in inventory) | backend |
| H7 | Theme picker (Deep Lush / Iridescent / Warm / etc.) | working | Settings → Theme | `SAVE_SETTINGS` (`theme`) |
| H8 | Open on login | working | Settings | login-item |
| H9 | Notifications toggle | working | Settings | `SAVE_SETTINGS` |
| H10 | Sound effects (NSSound Pop/Glass/Tink) | working | Pill behavior + Preview Sound button | `PREVIEW_SOUND` |
| H11 | Menu bar icon (eye.circle.fill) + right-click menu | working | Always present | `AppDelegate.setupMenuBar` |
| H12 | Menu bar items: Status / Show Window / Debug Monitor / Open Dashboard / Toggle Focus (⌘⇧P) / Quit | working | Menu bar | same |
| H13 | Show Window | working | Menu bar | AppDelegate |
| H14 | Debug Monitor window (⌘M) | LEGACY | Floating SwiftUI | `LegacyMonitorView.swift` |
| H15 | Reset all settings | working | Settings → Reset & Delete | `RESET_SETTINGS` |
| H16 | Open System Settings (TCC pane for Screen Recording) | working | from CS banner | `OPEN_CONTENT_SAFETY_SETTINGS` |
| H17 | Open Extensions Page (per-browser, opens Web Store URL) | working | Settings → Browsers | `OPEN_EXTENSIONS_PAGE` |
| H18 | Per-browser status row (extension installed/active) | working | Settings → Browsers | `GET_EXTENSION_STATUS` |
| H19 | Permission monitoring (Accessibility, Screen Recording, Notifications) | working | Background + onboarding | `PermissionManager.swift` |
| H20 | Sleep/wake monitor | working | Background | `SleepWakeMonitor.swift` |
| H21 | Daemon availability banner (degraded mode if Phase A fails) | working | Banner | `_daemonAvailable` |
| H22 | Native messaging setup (auto-discover extensions, install manifests) | working | Background | `NativeMessagingSetup.swift` |
| H23 | Usage history view | working | (dashboard bridge) | `GET_USAGE_HISTORY` |
| H24 | Sessions journal | working | (dashboard bridge) | `GET_JOURNAL` |
| H25 | App "Save indicator" / in-WKWebView toast | working | All pages | dashboard.html |

---

## I. Planned / envisioned (not yet built or designed)

| # | Feature | Status | Source |
|---|---|---|---|
| I1 | Cross-device shared time budgets ("30 min YouTube total across iPhone + Mac") | PLANNED | BRAINSTORMING_CONTEXT.md + screenshot analysis |
| I2 | Active planning intelligence (AI proposes the day, learns over time) | PLANNED | BRAINSTORMING_CONTEXT.md |
| I3 | Drift redirect = active coach (vs. passive nudge) | PLANNED | BRAINSTORMING_CONTEXT.md missions reframe |
| I4 | Status footer on Today (always-on differentiator visibility) | DESIGNED v0 | unified-design-sketch v0 |
| I5 | Status pill expanded popover (defenses detail) | NEW (proposed) | this doc |
| I6 | End-of-day reflection (2-line shape: "you worked 4h 12m. Linear got 2h. Tomorrow's plan ready.") | PLANNED | memory file project_intentional_icp |
| I7 | Adaptive re-plan when day breaks (skipped/overrun → regenerate the rest) | PLANNED | memory file |
| I8 | Day-1 defaults work without setup | PRINCIPLE | memory file |

---

## J. Surfaces (not features — but every feature lands on one)

This list helps us cross-check Phase 2.

**Sidebar tabs (current, slice-10):** Today / Focus Modes / Sensitive Content / Accountability / Settings
**Sidebar tabs (proposed, this design):** Today / Plan / Settings
**Persistent overlay:** Floating pill (8 modes)
**Persistent menu:** Menu bar icon (6 items)
**Status indicator:** Sidebar bottom "Session" footer (current) / new "Status footer" on Today (proposed)
**Banner:** Daemon availability degraded-mode banner

**Modal / popover surfaces (current):**
- Calendar block editor (modal)
- Per-block AI assessments panel (inline)
- Intention setup form (modal-ish, page-internal)
- Intention strictness picker (popover)
- Cancel-pending-strictness confirmation
- Partner email/name editor (page-internal)
- Lock-mode picker
- Resend / Remove partner confirmations
- Strict Mode confirmation
- Request Unlock code entry
- Verify Unlock code entry
- Re-lock confirmation
- Bedtime unlock-request sheet (separate window)
- Intention strictness unlock sheet (separate window)
- Theme picker grid
- AI Model selector
- Enforcement toggle grid
- Intervention toggle list
- Browsers list
- Reset All confirmation
- Delete Account confirmation
- Uninstall request + verify
- Save-indicator toast
- Save-error toast

**Full-screen overlays (current):**
- Onboarding wizard (multi-step)
- Login screen
- Block start ritual (legacy, replaced by pill `.startRitual` — but BlockRitualController class still exists)
- Block end ritual / celebration (3-card carousel — also via BlockEndRitualController)
- Focus blocking overlay (FocusOverlayWindowController, per-screen)
- Intervention exercise overlay (InterventionOverlayController, per-screen)
- Switch intervention overlay (SwitchOverlayController, per-screen)
- Tamper overlay (TamperOverlayController, per-screen)
- Content Safety detection overlay (ContentSafetyMonitor, per-screen blur)
- Content Safety permission overlay (per-screen)
- Focus Start overlay (FocusStartOverlay — Cmd+Shift+P / Puck / WS)
- Grayscale / vignette overlay (click-through)
- Bedtime lock screen (OS native, every 10s)
- Debug Monitor window (legacy SwiftUI)

**Full-screen rituals (proposed new / unbuilt):**
- Wake-up: alarm fired → "tap Puck to wake"
- Wake-up: after tap → enter morning planning ritual (Help me plan)
- "Help me plan" guided ritual (3–4 steps; currently only conceptually)
- Bedtime planning (next day prep / carry-forward)

---

## K. Dead code / deprecation candidates (placement: deprecate)

| # | Item | Why | Action |
|---|---|---|---|
| K1 | Settings → Focus Mode → Screen Lock toggle + schedule selector + grace period | UserDefaults wiped on launch (`IntentionalModeController` deleted) | REMOVE in design — do not surface |
| K2 | `BlockRitualController` full-screen path | Replaced by pill `.startRitual` mode | KEEP for end-ritual; remove start-ritual call sites |
| K3 | Force-a-plan / no-plan overlay in FocusMonitor | Deleted in TimeState consolidation | Restore as part of unified design wake-up ritual |
| K4 | BlockingProfileManager UI in calendar block editor | Hidden per Spec 1 D14 | KEEP underlying data; Distractions page is its only UI |
| K5 | Legacy `*_PROJECT_*` bridge handlers | One-cycle aliasing period elapsed | REMOVE |
| K6 | `.allCaughtUp` NoPlanData state (referenced but enum doesn't have it) | Either stale memory or branch via flag | Verify in design; either add enum case or fix branching |
| K7 | Earned Browse widget on Today (`display:none`, "stripped for Puck model") | Pipeline alive, UI hidden | Decide in Phase 4: re-surface as Status pill / budget meter / Settings row |
| K8 | `page-schedule` orphan div | Sidebar item removed slice-10 | Remove DOM in slice-13 cleanup |
| K9 | `BlockingProfilesToIntentionsMigration` runner (after stability period) | One-time migration | Remove after ≥2 weeks of stability |
| K10 | `projects.json` + ProjectStore detail dashboard | Replaced by IntentionStore | Remove dashboard legacy branches |
| K11 | "Self" lock mode (defensive 4-place translation) | Removed | Remove translations |
| K12 | `focus_session.json` + `intentional_mode_state.json` cleanup | Defensive removal | Keep cleanup, remove SAVE_INTENTIONAL_MODE handler |
| K13 | `requestIntentionStrictnessUnlock` / verify (backend NOT deployed) | Always errors | Either deploy backend or hide UI |
| K14 | `AppDelegate.activeProjectSession` (in-RAM cache) | Redundant with FocusModeController | Remove |
| K15 | Bedtime time labels in Settings (hard-coded "11:00 PM" / "7:00 AM") | Display not bound to bedtime_settings.json | Fix binding in design |
| K16 | Debug Monitor window (LegacyMonitorView) | Legacy SwiftUI | Move to dev menu / remove |
| K17 | `main.swift.disabled` | Disabled file in tree | Remove |
| K18 | `ScheduleManager.BlockType.freeTime` `isFree` flag | Retained for legacy callers | Remove after audit |
| K19 | `distractingSites` / `distractingApps` legacy keys in onboarding_settings.json | No longer feed enforcement | Remove on next settings-schema break |

---

## Summary counts

- **Total features cataloged:** 200+ (A: 57, B: 24, C: 16, D: 23, E: 12, F: 6, G: 16, H: 25, I: 8, K: 19 deprecation candidates + J surface counts)
- **Working today:** ~145
- **Hidden but firing:** ~5 (Earned Browse pipeline, Extra Time flow, etc.)
- **Designed but not built:** ~17 (planning system)
- **Planned but not designed:** ~6 (wake alarm, shared budgets, etc.)
- **Dead code:** ~19

Every numbered row above will appear in `architecture.md` placed in exactly one surface, or in `K` (deprecation).

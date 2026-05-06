# Intentional macOS App — Product Inventory (2026-05-04)

Snapshot of every user-visible surface, control, bridge message, backend call, persisted file, and dead-code candidate in the Mac app. Source of truth for the upcoming product brainstorm. Read-only — no source modified.

Codebase root: `/Users/arayan/Documents/GitHub/intentional-macos-app`
Sibling repos referenced: `intentional-backend`, `puck-ios`, `intentional-extension`.

---

## 1. Top-level surfaces

| # | Surface | Trigger | Content (1-line) |
|---|---|---|---|
| 1 | **Menu bar icon** (eye.circle.fill) | Always present after launch | Right-click menu: Status, Show Window, Debug Monitor, Open Dashboard, Toggle Focus (⌘⇧P), Quit. (`AppDelegate.setupMenuBar` line 1179) |
| 2 | **Main window — onboarding.html** | First launch / `onboardingComplete` UserDefault false | First-run wizard (lock mode, partner email, theme). Single WKWebView. |
| 3 | **Main window — login.html** | Backend says `loggedIn=false` after onboarding | Email + magic-code sign-in. |
| 4 | **Main window — dashboard.html** | Default after login | The big WKWebView with the sidebar + 8 pages (see §2). |
| 5 | **Floating pill (top-right)** | Driven by `DeepWorkTimerController` from FocusMonitor; visible during work blocks, bedtime, gap states | 8 PillModes (see §3). Draggable, position persisted. |
| 6 | **External nudge toast** | `NudgeWindowController.showNudge` — escalated/warning nudges only (level 1 lives inside the pill now) | Translucent 300px panel below the pill — "off-task" message + Got It / This Is Relevant. |
| 7 | **Block start ritual overlay** | `BlockRitualController.show` when a work block becomes current and `awaitingRitual` set | Full-screen card (focus question + if-then plan dropdown + Start). 8 design variants persisted in UserDefaults. |
| 8 | **Block end ritual overlay** | `BlockEndRitualController.show` at block boundary | 3-card carousel: reflection + self-assessment + AI verdict log. |
| 9 | **Focus blocking overlay** | `FocusOverlayWindowController.showOverlay` from FocusMonitor on hard-block decisions | Full-screen card (one window per display): intention, reason, "Back to work", "Why?" disclosure. |
| 10 | **Intervention exercise overlay** | `InterventionOverlayController.showIntervention` after 5 min cumulative distraction in a Focus Hours block | Full-screen Scrambled Words OR Reflect & Commit, mandatory 60/90/120s wait. |
| 11 | **Switch intervention overlay** | `SwitchOverlayController.show` via `SwitchInterventionCoordinator` on cross-app switch during focus | Full-screen countdown (one window per display) with "Back to work" / "Continue anyway". |
| 12 | **Tamper overlay** | `TamperOverlayController.show` from `EnforcementReconciler` when partner-locked setting was changed outside the dashboard | Full-screen "settings were tampered with" card. |
| 13 | **Content Safety overlay** | `ContentSafetyMonitor` on NSFW detection (private `overlayWindows`) | Per-screen blur overlay; partner emailed on 3rd detection within 1hr. Dismiss returns user to clean state. |
| 14 | **Content Safety permission overlay** | When ScreenCapture permission revoked while CS enabled | Blocking per-screen "you must re-grant permission" overlay; auto-dismisses on grant. |
| 15 | **Focus Start overlay** | `AppDelegate.showFocusStartOverlay` — Cmd+Shift+P / menu / Puck press / cross-device WS signal | Full-screen panel: profile chips + intention text + AI scoring toggle + Start. |
| 16 | **Bedtime wind-down notifications** | `BedtimeWindDownController` at T-30/T-15/T-10/T-5/T-1 before bedtime | Native macOS `.timeSensitive` notifications (no full-screen panel). |
| 17 | **Bedtime lock loop** | `BedtimeLockLoop.start` once `BedtimeEnforcer.state == .locked` | Triggers `SACLockScreenImmediate` every 10s until enforcer state changes. No window — drives the OS lock screen. |
| 18 | **Bedtime unlock-request sheet** | `AppDelegate.openBedtimeUnlockRequestSheet` when user taps "Ask partner" on bedtime pill | Floating window, 460×520, hosting `BedtimeUnlockRequestView`. Duration slider (15/30/60/120/until-wake). |
| 19 | **Intention strictness unlock sheet** | `AppDelegate.openIntentionStrictnessUnlockSheet` from dashboard step-down softening (Strict→…) | Floating window using same `BedtimeUnlockRequestView` with `kind: .intentionStrictness`. |
| 20 | **Atmospheric vignette / grayscale overlay** | `GrayscaleOverlayController` — applied during deep-work focus on multi-display | Click-through full-screen radial vignette. No interactive controls. |
| 21 | **Debug Monitor window** | Menu bar → Debug Monitor (⌘M) | Legacy SwiftUI `LegacyMonitorView` (browser/protection diagnostics). |
| 22 | **System extension (FilterManager)** | Loaded on launch when entitlements allow | Network filter for blocking; UI exposed only via System Settings → Network. Managed by `FilterManager.swift`. |
| 23 | **focus-blocked.html / blocked.html** | Browser redirect target when WebsiteBlocker / extension blocks a tab | "Blocked by Intentional" page rendered inside the user's browser, not in the app. |
| 24 | **Toast (in-dashboard)** | `MainWindow` JS toast div | Save indicators / error toasts inside the WKWebView. |

---

## 2. Dashboard pages

Sidebar is rendered in `dashboard.html` line 4379. **Eight items shown**:
Today · Focus Modes · Distractions · Sensitive Content · Weekly Planning · Accountability · Settings.

(Note: sidebar label says **"Focus Modes"** but `data-page="intentions"` and CLAUDE.md uses **"Intentions"**. Schedule sidebar item was removed but `page-schedule` div remains as orphan deep-link target — see §9.)

### 2.1 Today (`page-today`, line 4428)

| Control | What it does | Bridge / Backend | Local persistence | Cross-device sync? |
|---|---|---|---|---|
| Coach context card (profile + plan rows) | Static display of focus profile + daily plan | (read-only render of GET_DASHBOARD_DATA + GET_SETTINGS) | `focus_profile.json`, `daily_schedule.json` | partial (focus_profile.json is local-only; daily_schedule via `/time_blocks` Spec 2 PUT) |
| Date arrows / "Today" label | Navigate calendar day | `GET_SCHEDULE_FOR_DATE` | `daily_schedule.json` | yes (Spec 2 backend) |
| `+ Focus` button | Insert draft Focus Hours block | `SET_SCHEDULE` (after edit) | `daily_schedule.json` | yes |
| `+ Free Time` button | Insert "Break" block | `SET_SCHEDULE` | `daily_schedule.json` | yes |
| `…` (schedule settings) | Navigates to Settings | none | — | n/a |
| Calendar (drag-create disabled) | Click block → editor; tap chip → assessments | `GET_BLOCK_ASSESSMENTS` (per block); editor save → `SET_SCHEDULE` | `daily_schedule.json` | yes |
| **Focus Mode toggle** (`#focus-mode-toggle`) | Manual on/off of focus enforcement | `FOCUS_MODE_TOGGLE` → `BackendClient.postFocusToggle` (`/focus/toggle`) | `focus_mode_state.json` | yes (server is source of truth) |
| AI Assessments card | Scrollable last-N coach verdicts | `GET_RELEVANCE_LOG`, `EXPORT_RELEVANCE_LOG` | `relevance_log.jsonl` | local-only |
| Focus profile inline (textarea) | Edit work profile | `SET_PROFILE` | `focus_profile.json` | local-only |
| Earned Browse widget | **Hidden** (`display:none`) | (Stripped for Puck model — code retained) | `earned_browse.json` | local-only |
| Extra Time pills + code grid | (hidden surface) | `REQUEST_EXTRA_TIME`, `VERIFY_EXTRA_TIME_CODE` | partner emails | yes (backend) |

### 2.2 Focus Modes / Intentions (`page-intentions`, line 4603)

Three sub-views: index (cards), dashboard (detail), setup (form).

| Control | What it does | Bridge / Backend | Local persistence | Cross-device |
|---|---|---|---|---|
| "+ New Intention" card | Open setup form | `CREATE_INTENTION` on save | `intentions.json` (cache) | yes (`POST /intentions`) |
| Intention card (click) | Open detail dashboard | `GET_PROJECT_DETAIL` (legacy) → falls back to `intentionsCache` | `projects.json` (legacy) / `intentions.json` | yes |
| Intention card → caption "Standard" / "Soft" / "Strict" | Inline strictness display + step-down dialog | `UPDATE_INTENTION_STRICTNESS` (instant tighten / 24h delayed soften / partner-unlock for Strict→…) | `intentions.json` | yes |
| Cancel pending strictness change | Cancel scheduled softening | `CANCEL_PENDING_STRICTNESS_CHANGE` | `intentions.json` | yes |
| Setup form: name / blocklist sites / blocklist apps / strictness | Save intention | `CREATE_INTENTION`, `UPDATE_INTENTION` | `intentions.json` | yes |
| Delete intention | (in detail view) | `DELETE_INTENTION` (with `DELETE_PROJECT` legacy alias) | `intentions.json` | yes |
| Promote learned site (banner) | Add to always-relevant from learned overrides | `PROMOTE_LEARNED_SITE` | UserDefaults `learnedOverrideSummary` + onboarding_settings.json | partial |

### 2.3 Schedule (`page-schedule`, line 4610)

**Orphan page** — sidebar item removed (commit eaeb80b notes); div retained per inline comment line 4390. Deep-link only.

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Day / Week segmented toggle | Switch view (week is "coming soon" placeholder) | none | UserDefaults `scheduleViewMode` | n/a |
| `schedule-day-host` | Calendar host (same component as Today) | inherits Today's wiring | `daily_schedule.json` | yes |

### 2.4 Sensitive Content (`page-sensitive`, line 4629)

Container `sensitive-content-host` is populated by JS that mirrors the Settings → Content Safety detail (toggle + permission banner + Test button).

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Screen monitoring toggle | On/off (saves immediately, not debounced) | `SAVE_SETTINGS` (`contentSafety.enabled`) → `BackendClient.syncSettings` | `onboarding_settings.json` | yes (settings-sync) |
| Open System Settings (when permission missing) | Opens TCC pane | `OPEN_CONTENT_SAFETY_SETTINGS` | — | n/a |
| Test detection (if shown) | Triggers fake detection through pipeline | `TEST_CONTENT_SAFETY` → `ContentSafetyMonitor.triggerTestDetection` | — | n/a |

### 2.5 Weekly Planning (`page-weekly`, line 4640)

**Placeholder.** No interactive controls yet. CTA "Go to Focus Modes →" navigates to intentions. Spec 1 D9 prep — schema fields exist on `Intention` (`weeklyBudgetHours`, `budgetEnforcement`) but no UI yet.

### 2.6 Distractions (`page-distractions`, line 4655)

Two sub-views: list, detail. Surfaces `BlockingProfileManager` profiles directly (Spec 1 D14 — UI hidden in calendar block editor but still owned by this page).

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| `+ Create New Profile` | Append profile | `CREATE_BLOCKING_PROFILE` | `blocking_profiles.json` | **no** (local-only) |
| Profile row click | Show detail | (no message — local view switch) | — | n/a |
| Detail: rename / domain chips / app chips / always-active toggle / default toggle | Edit profile | `UPDATE_BLOCKING_PROFILE` | `blocking_profiles.json` | no |
| Delete profile | Remove (with active-session guard) | `DELETE_BLOCKING_PROFILE` | `blocking_profiles.json` | no |
| Lock banner (if locked) | "Unlock to edit" | (`REQUEST_UNLOCK` flow) | — | yes (backend) |

### 2.7 Accountability / Partner (`page-lock`, line 4684)

Three states (paired / pending / empty) inside `lock-content`, populated by `_lockStateResult`.

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Set/edit partner email + name | Save partner | `SAVE_LOCK_SETTINGS` → `BackendClient.setLockMode`, `setPartner` | `onboarding_settings.json` | yes |
| Resend partner invite | Re-email partner | `RESEND_PARTNER_INVITE` | — | yes |
| Remove partner | Clear partner | `REMOVE_PARTNER` → `BackendClient.removePartner` | — | yes |
| Lock-Mode (None / Partner) | Set lock mode | `SAVE_LOCK_SETTINGS` | `onboarding_settings.json` | yes |
| Strict Mode toggle | Make app un-uninstallable / login-item / watchdog | `SAVE_STRICT_MODE` | UserDefaults `strictModeEnabled` + `~/Library/Application Support/Intentional/strict-mode` flag | partial |
| Request unlock / Verify unlock code | Partner-gated unlock | `REQUEST_UNLOCK`, `VERIFY_UNLOCK` | — | yes (`/unlock/request`, `/unlock/verify`) |
| Re-lock | Lock back after unlock | `RELOCK_SETTINGS` → `BackendClient.relockSettings` | — | yes |

### 2.8 Settings (`page-settings`, line 4694)

Drill-down list. 9 detail panels.

#### 2.8.1 Account (`#settings-detail-account`)

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Email / Member since / Devices | Read-only display | `GET_AUTH_STATE` → `BackendClient.authMe` | Keychain JWT | n/a |
| Sign out | Logout | `AUTH_LOGOUT` → `BackendClient.authLogout` | clears Keychain | yes (revokes token) |

#### 2.8.2 Theme (`#settings-detail-theme`)

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Theme picker grid (Deep Lush / Iridescent / Warm / etc.) | Switch theme | `SAVE_SETTINGS` (`theme`) | `onboarding_settings.json` | yes |

#### 2.8.3 AI Scoring (`#settings-detail-ai`)

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Enable Daily Focus Plan | Enable schedule engine | `SET_FOCUS_ENABLED` | `focus_settings.json` | local-only |
| Block irrelevant tabs | nudge vs block mode | `SET_FOCUS_ENFORCEMENT` | `focus_settings.json` | local-only |
| AI Model selector (Apple / Qwen) | Pick scoring model | `SET_AI_MODEL` | `focus_settings.json` | local-only |
| Edit profile button | Navigates to Today | none | — | n/a |

#### 2.8.4 Enforcement (`#settings-detail-enforcement`)

A 6×2 grid (per-mechanism × per-block-type). Toggles for: Nudge notifications · Screen red shift · Auto-redirect · Blocking overlay · Intervention exercises · Background audio block · Context-switch countdown. Two columns: Deep Work, Focus Hours.

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Each toggle (12 total) | Per-block-type, per-mechanism enable | `SET_ENFORCEMENT_SETTINGS` | `onboarding_settings.json` (`enforcement.{deepWork,focusHours}.{...}`) | yes |

#### 2.8.5 Content Safety (`#settings-detail-safety`)

Mirrors Sensitive Content sidebar page (kept for legacy nav). Same controls as §2.4.

#### 2.8.6 Bedtime (`#settings-detail-bedtime`)

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Bedtime Enforcer toggle | Enable wind-down + lock loop | `SAVE_BEDTIME_SETTINGS` → `BackendClient.putBedtimeConfig` | `bedtime_settings.json` | yes (`/bedtime/config`) |
| Bedtime / Wake displayed | (currently read-only "11:00 PM" / "7:00 AM" — actual edit happens via dashboard JS) | same as above | same | yes |

#### 2.8.7 Focus Mode (`#settings-detail-focusgate`)

This is the page where the **third meaning of "Focus Mode"** lives — see §10.

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Screen Lock toggle (`#intentional-mode-enabled`) | Was "Intentional Mode" — controller deleted, toggle still wired to UserDefaults | `SAVE_INTENTIONAL_MODE` | UserDefaults (`intentionalModeEnabled` etc) — wiped on launch by migration (see §9) | **no** |
| Schedule selector (Always / Custom / Puck Only) | Storage only — no behavior wired | `SAVE_INTENTIONAL_MODE` | UserDefaults | no |
| Custom hours start/end | Storage only | `SAVE_INTENTIONAL_MODE` | UserDefaults | no |
| Grace period select | Storage only | `SAVE_INTENTIONAL_MODE` | UserDefaults | no |
| **Interventions** sub-card (`#intervention-toggles`) | Per-intervention enable while Focus Mode is on | `INTERVENTION_TOGGLE_SET` | `onboarding_settings.json` | yes |

#### 2.8.8 Browsers (`#settings-detail-browsers`)

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Per-browser status row | Show extension installed/active | `GET_EXTENSION_STATUS` → `_extensionStatusResult` | — | n/a |
| Open Web Store link | Open in target browser | `OPEN_EXTENSIONS_PAGE` | — | n/a |

#### 2.8.9 Reset & Delete (`#settings-detail-reset`)

| Control | What it does | Bridge / Backend | Persistence | Cross-device |
|---|---|---|---|---|
| Reset all settings | Wipe local state, re-onboard | `RESET_SETTINGS` | wipes `onboarding_settings.json` | local |
| Delete account | Backend delete | `AUTH_DELETE` → `BackendClient.authDelete` | — | yes |
| Uninstall Intentional | Partner-gated full uninstall | `UNINSTALL_APP`, `VERIFY_UNINSTALL` | removes app, daemon, data | yes |

---

## 3. Pill modes

`PillMode` enum at `DeepWorkTimerController.swift:48`. State machine driven by `FocusMonitor`.

| Mode | Trigger | Content | Controls / Actions | Dismiss path |
|---|---|---|---|---|
| `.timer` | Work block active and ≥1s remaining | 300×70: dot (indigo focused / red distracted / green recovery) + intention + MM:SS countdown + focus%/earned stats. Recovery shows large motivational message for 3s. Distraction-card variant (level 1 nudge) shows "Not related" + Back to Task button for 8s. | Drag-to-move; click-through on stats area; Back to Task button (in-pill nudge) | Block ends → blockComplete; user clicks Back to Task → restores `.timer`; explicit `dismiss()` |
| `.blockComplete` | Countdown hits 0:00 before celebration begins | 300×70 amber border, "Block complete · 0:00" | none | `enterCelebration` (auto) or `resumeIfPendingBlockStart` |
| `.celebration` | Block ends and `prevStats.totalTicks > 0` | 460×~400 expanded card, 3-4 sub-cards auto-advance every 10s: Session Complete, Focus Score (confetti via Lottie ≥80%), App Breakdown, Up Next | Carousel dots + skip link; Start (on Up Next card if back-to-back) | Carousel completes → noPlan / next block ritual; user clicks skip; `onDone` |
| `.startRitual` | New block begins (work block) and `awaitingRitual` flag set | 460×160: green border, block type badge, "Up next: TITLE" + Start button + Edit button | Start → exits ritual + activates focus; Edit → `.startRitualEdit` | onStart fires; auto-start (3min for work, 30s for free) |
| `.startRitualEdit` | User clicks Edit on `.startRitual` | 460×~340: title field, description field, type segmented, Done button | Save (rejects empty title for work blocks); Cancel | Done → re-enters `.startRitual` then auto-starts; Cancel returns to ritual |
| `.noPlan` | No current block + dashboard schedule absent or finished | 310×(155-310). 4 internal substates: `noPlan` (quick blocks + Plan Day), `gap` (block list + Schedule Now), `allCaughtUp` (stats + Schedule More, before 9 PM), `doneForDay` (green DAY COMPLETE, 9 PM+) | Quick block buttons (15/30/60min); Plan Day; Schedule Now; Snooze; Dismiss (-) → `minimize()` (dock icon) | block becomes active; user dismisses to dock; explicit `dismiss()` |
| `.bedtimeWindDown` | `BedtimeEnforcer.state == .windDown(phase)` | 300×70 with moon glyph + "Bedtime in N min" + (T-30 only) minimize allowed | Pill drag; minimize (T-30 only) | enforcer transitions to `.locked` or `.released` |
| `.bedtimeLocked` | `BedtimeEnforcer.state == .locked` | 300×70 with lock glyph + "Bedtime active — locked until 6:30 AM" + "Ask Partner" button | Ask Partner → opens unlock-request sheet | enforcer transitions to `.released` (BedtimeLockLoop self-cancels) |

`NoPlanData.CardState` (line 86): `.noPlan`, `.gap`, `.doneForDay`. Note: `.allCaughtUp` is referenced in code but not in the enum — see §10 #4.

---

## 4. Fullscreen overlays

Each is its own NSWindow controller. Convention: 1 window per `NSScreen.screens`, `.screenSaver` level, `[.canJoinAllSpaces, .fullScreenAuxiliary]`.

| Controller | File | Trigger | Controls | Dismiss path |
|---|---|---|---|---|
| `FocusOverlayWindowController` | `FocusOverlayWindow.swift` | FocusMonitor hard-block decision (irrelevant content during work block, after nudge timeout) | "Back to work", "Why?" disclosure, "Approve for this block", "This was wrong" | `onBackToWork` callback (clicking app, switching to relevant content) |
| `InterventionOverlayController` | `InterventionOverlayController.swift` | After 5 min cumulative distraction in Focus Hours | Scrambled Words / Reflect & Commit puzzle + mandatory wait timer (60/90/120s) | `onComplete` after puzzle + timer |
| `SwitchOverlayController` | `SwitchOverlayController.swift` | `SwitchInterventionCoordinator` on cross-app switch from work-context to non-work | Countdown + "Continue anyway" + Esc/Back-to-work | `viewModel.onComplete`; Esc routes to back-to-work |
| `TamperOverlayController` | `TamperOverlayController.swift` | `EnforcementReconciler` force-corrected a partner-locked setting | Headline + bullet list + "OK" | manual dismiss only |
| `NudgeWindowController` | `NudgeWindowController.swift` | FocusMonitor escalated/warning nudge (level 1 in-pill) | "Got It", "This is relevant" with inline justification | 8s auto-dismiss (level 1) / persistent until interaction (level 2) |
| `BedtimeLockLoop` | `BedtimeLockLoop.swift` | `BedtimeEnforcer.state == .locked` | (none — drives OS lock screen via `SACLockScreenImmediate` every 10s) | Enforcer state changes (timer auto-cancels) |
| `BlockRitualController` | `BlockRitualController.swift` | New work block becomes current AND `awaitingRitual` flag set (see Note 1 below) | Focus question textarea, if-then plan dropdown, Focus Goal slider, Start, Edit, Push Back | Start → `onStart`; Edit → `onSaveEdit`; Push Back → `onPushBack` |
| `BlockEndRitualController` | `BlockEndRitualController.swift` | Work block ends and `prevStats.totalTicks > 0` | 3-card carousel: reflection, self-assessment, AI verdict log | carousel completes / Skip |
| `GrayscaleOverlayController` | `GrayscaleOverlayController.swift` | Deep Work block active (atmospheric vignette) | (click-through, no controls) | block ends |
| `FocusStartOverlayView` (managed by AppDelegate) | `FocusStartOverlay.swift` | Cmd+Shift+P / menu / Puck press / cross-device WS signal | Profile chips, intention text, AI scoring toggle, Start, Cancel | Start → activate FocusModeController; Cancel → dismiss |
| `ContentSafetyMonitor.overlayWindows` | `ContentSafetyMonitor.swift` (private) | NSFW detection passes threshold | "Take a breath" message + auto-dismiss after grace period | Grace period elapses |
| `ContentSafetyMonitor.permissionOverlayWindows` | `ContentSafetyMonitor.swift` (private) | ScreenCapture permission revoked while CS enabled | "Re-grant permission" + open System Settings | Permission re-granted (auto) |
| `bedtimeUnlockWindow` (singleton on AppDelegate) | `BedtimeUnlockRequestView.swift` | "Ask Partner" tapped on bedtime pill | Duration slider, request code, verify code | partner approves; user closes |
| `intentionStrictnessUnlockWindow` (singleton on AppDelegate) | reuses `BedtimeUnlockRequestView` (`kind: .intentionStrictness`) | Step-down softening from Strict in Intentions UI | Same view, no duration slider | partner approves; user closes |

> Note 1: `BlockRitualController` is *initialized* but its full-screen invocation has been *commented out* in AppDelegate (`// focusMonitor?.ritualController = BlockRitualController()  // Now pill-centric` line 591). The pill's `.startRitual` mode replaced it. The class is still alive — re-wired only via `endRitualController`. See §9.

---

## 5. Bridge messages (dashboard ↔ Swift)

Direction marked from JS perspective. JS→Swift = via `window.webkit.messageHandlers.intentional.postMessage`. Swift→JS = `webView.evaluateJavaScript("window._receiver(...)")`.

### 5.1 JS → Swift handlers (`MainWindow.userContentController switch`)

| Message | Direction | What it does |
|---|---|---|
| `DIAGNOSTIC_LOG` | JS→Swift | Pipe JS console message to native log + UIPERF tracker |
| `SAVE_ONBOARDING` | JS→Swift | Persist onboarding settings, set partner, set lock mode, broadcast SETTINGS_SYNC |
| `GET_EXTENSION_STATUS` | JS→Swift | Returns per-browser extension status (icon, install state) |
| `GET_DASHBOARD_DATA` | JS→Swift | Bundle of usage history, browser status, partner status, etc. |
| `GET_SETTINGS` | JS→Swift | Return `onboarding_settings.json` + UserDefault overrides + content safety state |
| `GET_FOCUS_MODE` | JS→Swift | Return current `FocusModeController.state` |
| `TEST_CONTENT_SAFETY` | JS→Swift | Trigger fake NSFW detection through pipeline |
| `OPEN_CONTENT_SAFETY_SETTINGS` | JS→Swift | Open `x-apple.systempreferences:` for ScreenRecording |
| `SAVE_LOCK_SETTINGS` | JS→Swift | Save partner email/name + lockMode → backend |
| `REQUEST_UNLOCK` | JS→Swift | Hit `/unlock/request`, persist request state |
| `VERIFY_UNLOCK` | JS→Swift | Hit `/unlock/verify` with 6-digit code |
| `GET_PARTNER_STATUS` | JS→Swift | Hit `/partner/status` |
| `RELOCK_SETTINGS` | JS→Swift | Re-lock after temporary unlock |
| `REMOVE_PARTNER` | JS→Swift | Clear partner |
| `RESEND_PARTNER_INVITE` | JS→Swift | Re-email invite |
| `SAVE_SETTINGS` | JS→Swift | Persist generic settings update + sync to backend |
| `END_SESSION` | JS→Swift | End current session row (TimeTracker) |
| `RESET_SETTINGS` | JS→Swift | Wipe local files + return to onboarding |
| `UNINSTALL_APP` | JS→Swift | Trigger partner-gated uninstall flow |
| `VERIFY_UNINSTALL` | JS→Swift | Verify code + execute uninstall |
| `OPEN_EXTENSIONS_PAGE` | JS→Swift | Open extensions Web Store URL in target browser |
| `NAVIGATE_TO_DASHBOARD` | JS→Swift | Reload dashboard.html (post-onboarding / post-login) |
| `GET_AUTH_STATE` | JS→Swift | Return loggedIn + email/account + device count |
| `AUTH_LOGIN` | JS→Swift | Magic-link request |
| `AUTH_VERIFY` | JS→Swift | Magic-link verify |
| `AUTH_LOGOUT` | JS→Swift | Clear tokens, revoke server-side |
| `AUTH_DELETE` | JS→Swift | Delete account |
| `AUTH_COMPLETE` | JS→Swift | Sign-in done — connect WS, refresh page |
| `GET_USAGE_HISTORY` | JS→Swift | Pull `/usage/history?days=7` |
| `GET_JOURNAL` | JS→Swift | Pull `/sessions/journal` |
| `GET_SCHEDULE_STATE` | JS→Swift | Return today's blocks + state |
| `SET_FOCUS_ENABLED` | JS→Swift | Enable/disable schedule engine |
| `SET_PROFILE` | JS→Swift | Save focus profile text |
| `SET_SCHEDULE` | JS→Swift | Persist edited block list (Spec 2: also pushes to backend `/time_blocks`) |
| `GET_FOCUS_SCORE` | JS→Swift | Per-block focus stats |
| `GET_RELEVANCE_LOG` | JS→Swift | Last N AI assessments |
| `EXPORT_RELEVANCE_LOG` | JS→Swift | Open `relevance_log.jsonl` in Finder |
| `SET_FOCUS_ENFORCEMENT` | JS→Swift | nudge / block mode |
| `SET_AI_MODEL` | JS→Swift | apple / qwen |
| `GET_EARNED_STATUS` | JS→Swift | Pool + per-platform usage (hidden in current UI) |
| `REQUEST_EXTRA_TIME` | JS→Swift | Extra-time request flow |
| `VERIFY_EXTRA_TIME_CODE` | JS→Swift | Verify partner code for extra time |
| `GET_BLOCK_ASSESSMENTS` | JS→Swift | Per-block AI verdict log |
| `SET_CALENDAR_ZOOM` | JS→Swift | Persist calendar zoom level |
| `SET_ENFORCEMENT_SETTINGS` | JS→Swift | Per-block-type × per-mechanism toggles |
| `GET_SCHEDULE_FOR_DATE` | JS→Swift | Calendar day navigation |
| `GET_INSTALLED_APPS` | JS→Swift | List of LSAppCheck-discovered apps for blocklist UI |
| `PREVIEW_SOUND` | JS→Swift | NSSound playback |
| `SAVE_STRICT_MODE` | JS→Swift | Toggle strict mode (login item / watchdog / flag file) |
| `SAVE_IF_THEN_PLAN` | JS→Swift | Persist default if-then plan index in UserDefaults |
| `SAVE_INTENTIONAL_MODE` | JS→Swift | **Dead** — see §9 — writes to UserDefaults that get wiped on next launch |
| `GET_BEDTIME_SETTINGS` | JS→Swift | Read `bedtime_settings.json` |
| `SAVE_BEDTIME_SETTINGS` | JS→Swift | Save bedtime + push to `/bedtime/config` |
| `GET_BLOCKING_PROFILES` | JS→Swift | List `BlockingProfile` rows |
| `CREATE_BLOCKING_PROFILE` | JS→Swift | Append profile (local) |
| `UPDATE_BLOCKING_PROFILE` | JS→Swift | Edit profile (local) |
| `DELETE_BLOCKING_PROFILE` | JS→Swift | Delete with active-session guard |
| `START_PROJECT_SESSION` | JS→Swift | **Deprecated alias** — projects → intentions Spec 1 |
| `GET_PROJECTS` | JS→Swift | **Deprecated alias** for GET_INTENTIONS |
| `GET_PROJECT_DETAIL` | JS→Swift | **Deprecated alias** for GET_INTENTION |
| `CREATE_PROJECT` | JS→Swift | **Deprecated alias** for CREATE_INTENTION |
| `UPDATE_PROJECT` | JS→Swift | **Deprecated alias** for UPDATE_INTENTION |
| `DELETE_PROJECT` | JS→Swift | **Deprecated alias** for DELETE_INTENTION |
| `PROMOTE_LEARNED_SITE` | JS→Swift | Add learned-override host to always-relevant |
| `GET_INTENTIONS` | JS→Swift | Return `IntentionStore.snapshot` |
| `GET_INTENTION` | JS→Swift | Single intention by id |
| `CREATE_INTENTION` | JS→Swift | `POST /intentions` |
| `UPDATE_INTENTION` | JS→Swift | `PUT /intentions/{id}` |
| `DELETE_INTENTION` | JS→Swift | `DELETE /intentions/{id}` |
| `START_INTENTION_SESSION` | JS→Swift | Start a focus session bound to an intention |
| `UPDATE_INTENTION_STRICTNESS` | JS→Swift | `PUT /intentions/{id}/strictness` (instant tighten / 24h soften / partner gate Strict→…) |
| `CANCEL_PENDING_STRICTNESS_CHANGE` | JS→Swift | `POST /intentions/{id}/strictness/cancel` |
| `OPEN_INTENTION_STRICTNESS_UNLOCK_SHEET` | JS→Swift | Open partner-unlock floating window |
| `OPEN_INTENTION_EDITOR` | JS→Swift | Deep-link from block editor caption → intentions tab |
| `FOCUS_MODE_TOGGLE` | JS→Swift | Manual on/off via dashboard `#focus-mode-toggle` |
| `INTERVENTION_TOGGLE_SET` | JS→Swift | Per-intervention enforcement toggle |

### 5.2 Swift → JS receivers (`window._<name>`)

| Receiver | Pushed by | Payload purpose |
|---|---|---|
| `_onboardingSaveResult` | SAVE_ONBOARDING | success/error |
| `_extensionStatusResult` | GET_EXTENSION_STATUS + diff push | per-browser status |
| `_dashboardDataResult` | GET_DASHBOARD_DATA | aggregated bundle |
| `_settingsResult` | GET_SETTINGS | settings file contents |
| `_lockStateResult` | GET_PARTNER_STATUS / SAVE_LOCK_SETTINGS / RELOCK_SETTINGS | lock card render |
| `_lockSettingsResult` | SAVE_LOCK_SETTINGS | save outcome |
| `_strictModeResult` | SAVE_STRICT_MODE | success/error |
| `_unlockResult` | REQUEST_UNLOCK | request outcome |
| `_verifyUnlockResult` | VERIFY_UNLOCK | verify outcome + temporary unlock window |
| `_partnerStatusResult` | GET_PARTNER_STATUS, PartnerSyncService periodic | live partner display |
| `_resendInviteResult` | RESEND_PARTNER_INVITE | success/error |
| `_removePartnerResult` | REMOVE_PARTNER | success |
| `_authStateResult` | GET_AUTH_STATE | login/account info |
| `_authLoginResult` | AUTH_LOGIN | magic-link sent |
| `_authVerifyResult` | AUTH_VERIFY | sign-in done |
| `_authLogoutResult` | AUTH_LOGOUT | success |
| `_authDeleteResult` | AUTH_DELETE | success |
| `_uninstallResult` | UNINSTALL_APP / VERIFY_UNINSTALL | success/error |
| `_usageHistoryResult` | GET_USAGE_HISTORY | history rows |
| `_journalResult` | GET_JOURNAL | sessions for the day |
| `_scheduleStateResult` | GET_SCHEDULE_STATE / push on block change | schedule + state |
| `_scheduleResult` | SET_SCHEDULE | save outcome |
| `_scheduleForDateResult` | GET_SCHEDULE_FOR_DATE | day's blocks |
| `_focusEnabledResult` | SET_FOCUS_ENABLED | success |
| `_profileResult` | SET_PROFILE | success |
| `_focusScoreResult` | GET_FOCUS_SCORE | score breakdown |
| `_relevanceLogResult` | GET_RELEVANCE_LOG | latest assessments |
| `_blockAssessmentsResult` | GET_BLOCK_ASSESSMENTS | per-block log |
| `_earnedStatusResult` | GET_EARNED_STATUS | pool + usage |
| `_extraTimeRequestResult` / `_extraTimeVerifyResult` | REQUEST_EXTRA_TIME / VERIFY_EXTRA_TIME_CODE | flow |
| `_installedAppsResult` | GET_INSTALLED_APPS | LSAppCheck list |
| `_blockingProfilesResult` | GET_BLOCKING_PROFILES + after CRUD | profile list |
| `_intentionsList` | GET_INTENTIONS / pushIntentions | array of intentions |
| `_intentionResult` | GET_INTENTION / CREATE / UPDATE / DELETE_INTENTION | single intention or error |
| `_navigateToIntentionEditor` | OPEN_INTENTION_EDITOR | deep-link nav |
| `_focusModeUpdate` | onStateChanged push | focus state for UI |
| `_pushScheduleUpdate` (`pushScheduleUpdate`) | block changes | schedule re-render |
| `_pushEarnedUpdate` (`pushEarnedUpdate`) | TimeTracker callback | earned widget |
| `_daemonAvailable` | enforcement Phase A result | degraded-mode banner |

---

## 6. Backend API calls

`BackendClient.swift`. Base URL: `https://api.intentional.social`. Auth: JWT (Keychain) + `X-Device-ID` for hot polling.

| Method | Endpoint | When it fires |
|---|---|---|
| `sendEvent` | `POST /system-event` | App started + heartbeat (every 2 min) |
| `setPartner` | `POST /partner` | onboarding finalize + accountability page edit |
| `removePartner` | `DELETE /partner` | accountability page Remove |
| `setLockMode` | `POST /lock` | onboarding + accountability lock-mode change |
| `requestUnlock` | `POST /unlock/request` | dashboard Request Unlock |
| `verifyUnlock` | `POST /unlock/verify` | dashboard Verify Code |
| `requestExtraTime` | `POST /extra-time/request` | earned-browse extra-time flow (currently hidden UI) |
| `verifyExtraTime` | `POST /extra-time/verify` | as above |
| `requestOverride` | `POST /override/request` | (referenced — used for AI overrides, not surfaced in current UI) |
| `verifyOverride` | `POST /override/verify` | as above |
| `relockSettings` | `POST /unlock/status` (toggle) | dashboard Re-lock |
| `getUnlockStatus` | `GET /unlock/status` | launch sync, post-foreground |
| `getBedtimeConfig` | `GET /bedtime/config` | `BedtimeConfigSync` on launch + foreground + 60s |
| `putBedtimeConfig` | `PUT /bedtime/config` | dashboard saves bedtime |
| `bedtimeUnlockRequest` | `POST /bedtime/unlock-request` | bedtime "Ask partner" sheet |
| `getPartnerStatus` | `GET /partner/status` | `PartnerSyncService` on launch + foreground + 60s |
| `registerDevice` | `POST /register` | launch (idempotent) |
| `recordSession` | `POST /sessions` | TimeTracker session boundaries |
| `syncUsage` | `POST /usage/sync` | TimeTracker periodic sync |
| `getUsageHistory` | `GET /usage/history?days=N` | dashboard GET_USAGE_HISTORY |
| `getJournal` | `GET /sessions/journal` | dashboard GET_JOURNAL |
| `syncSettings` | `POST /settings/sync` | dashboard SAVE_SETTINGS / Onboarding save |
| `getSettings` | `GET /settings/sync` | fresh-install settings restore |
| `authLogin` | `POST /auth/login` | login.html email submit |
| `authVerify` | `POST /auth/verify` | login.html code submit |
| `authRefresh` | `POST /auth/refresh` | 401 retry / WS auth-expired |
| `authLogout` | `POST /auth/logout` | settings → Sign out |
| `authMe` | `GET /auth/me` | GET_AUTH_STATE |
| `authDelete` | `POST /auth/delete` | settings → Delete account |
| `reportContentSafety` | `POST /content-safety/report` | NSFW 3rd-detection-in-1hr partner notification |
| `fetchEnforcement` | `GET /device/enforcement` | EnforcementReconciler Phase B |
| `reportContentSafetyTamper` | `POST /content-safety/tamper` | tamper detection (settings changed outside dashboard) |
| `getIntentions` | `GET /intentions` | IntentionStore pull (launch + foreground + 60s) |
| `getIntention` | `GET /intentions/{id}` | GET_INTENTION |
| `createIntention` | `POST /intentions` | CREATE_INTENTION |
| `updateIntention` | `PUT /intentions/{id}` | UPDATE_INTENTION |
| `deleteIntention` | `DELETE /intentions/{id}` | DELETE_INTENTION |
| `postFocusToggle` | `POST /focus/toggle` | FocusModeController.onStateChanged when locally originated |
| `updateIntentionStrictness` | `PUT /intentions/{id}/strictness` | UPDATE_INTENTION_STRICTNESS |
| `getPendingStrictnessChange` | `GET /intentions/{id}/strictness/pending` | dashboard render of pending state |
| `cancelPendingStrictnessChange` | `POST /intentions/{id}/strictness/cancel` | CANCEL_PENDING_STRICTNESS_CHANGE |
| `requestIntentionStrictnessUnlock` | `POST /intention_strictness_unlock_requests` | unlock sheet (backend NOT YET DEPLOYED — see §9/§10) |
| `verifyIntentionStrictnessUnlock` | `POST /intention_strictness_unlock_requests/{id}/verify` | unlock sheet (backend NOT YET DEPLOYED) |
| `getTimeBlocks` | `GET /time_blocks` | ScheduleManager Spec 2 pull |
| `putTimeBlocks` | `PUT /time_blocks` | ScheduleManager Spec 2 push |

WebSocket: `FocusWebSocketClient` connects to a WS endpoint to receive `start`/`stop` focus signals from Puck/iPhone (path not exposed via BackendClient — see `FocusWebSocketClient.swift`).

Polling: `FocusStatePoller` hits `/focus/active` every 2s with `X-Device-ID` (no JWT TTL pain).

---

## 7. Persistence files

All under `~/Library/Application Support/Intentional/` unless noted.

| File | Owner | Purpose | Cross-device? |
|---|---|---|---|
| `onboarding_settings.json` | MainWindow + AppDelegate + CS + Reconciler | Top-level settings: platforms, partner, lockMode, theme, distractingSites/Apps (legacy), alwaysRelevantSites, contentSafety, enforcement, intervention toggles | yes (`/settings/sync`) |
| `focus_profile.json` | ScheduleManager | User's work profile text (AI context) | local-only |
| `focus_settings.json` | ScheduleManager | enabled, focusEnforcement, aiModel | local-only |
| `daily_schedule.json` | ScheduleManager | Today's blocks + goals + dailyPlan (Spec 2 also `/time_blocks`) | yes (Spec 2) |
| `daily_schedule.legacy.json` | ScheduleManager | Pre-Spec-2 archive (one-time migrated) | n/a |
| `schedule_history.json` | ScheduleManager | Past blocks for analytics | local-only |
| `daily_usage.json` | TimeTracker | Per-platform usage stats today | partial (`/usage/sync`) |
| `platform_sessions.json` | TimeTracker | Canonical sessions per platform | partial |
| `earned_browse.json` | EarnedBrowseManager | Pool state + per-block focus stats | local-only |
| `relevance_log.jsonl` | RelevanceScorer + FocusMonitor + BlockEndRitualController | Append-only AI assessment log | local-only |
| `content_safety_log.jsonl` | ContentSafetyMonitor | Detection events + emails sent | local-only |
| `intentions.json` | IntentionStore | Cache of backend-resident intentions | yes (canonical = backend) |
| `bedtime_settings.json` | BedtimeEnforcer + BedtimeConfigSync | Wind-down/lock config + active days | yes (`/bedtime/config`) |
| `blocking_profiles.json` | BlockingProfileManager | Distractions page profiles | **no — local-only** |
| `projects.json` | ProjectStore (legacy) | Pre-intentions local projects | migrated → backend (kept after migration as cache) |
| `projects.legacy.json` | IntentionMigration | Pre-migration archive | n/a |
| `migration_intentions_v1.json` | IntentionMigration | One-time migration receipt | local-only |
| `migration_profiles_to_intentions_v1.json` | BlockingProfilesToIntentionsMigration | Receipt for block.profileIds → block.intentionId rebind | local-only |
| `focus_mode_state.json` | FocusModeController | Persisted focus state for restart safety | partial (cache; backend wins via poller) |
| `enforcement_cache.json` | EnforcementCache | Cached `/device/enforcement` for offline | local cache |
| `registered_extension_ids.json` | NativeMessagingSetup | Discovered extension IDs per browser | local-only |
| `strict-mode` (flag file) | AppDelegate | Presence = strict mode active | local-only |
| `focus_session.json` | (deleted — wiped by `runFocusModeMigrationIfNeeded`) | (was FocusSessionManager; deleted) | n/a |
| `intentional_mode_state.json` | (defensive cleanup target) | (never actually written, but cleanup checks for it) | n/a |
| `blocklist.json` (FilterExtension container) | FilterManager | System extension blocklist | local-only |
| `filter_state.json` (FilterExtension container) | FilterManager | System extension state | local-only |

Temp files (`/tmp/` or `$TMPDIR`):

| File | Purpose |
|---|---|
| `intentional-app.lock` | PID of primary process |
| `intentional-no-relaunch` | 30s TTL marker preventing relaunch loops |
| `intentional-native-messaging-{UID}.sock` | Unix domain socket for extension relay |
| `intentional-debug.log` | Debug log (50 MB rotation) |
| `intentional-launches.log` | Launch diagnostic |
| `intentional-focus-state.json` | 5s state dump for `scripts/focus-debug.py` |

UserDefaults (selected, non-trivial):
- `onboardingComplete`, `lockMode`
- `strictModeEnabled` (flag file mirrors)
- `intentionalModeEnabled` / `…Schedule` / `…GracePeriod` / `…CustomSchedule` (**dead — wiped on launch**, see §9)
- `aiScoringEnabled`
- `defaultIfThenPlan`, `blockRitualDesign`
- `pillWindowTopRight`
- `learnedOverrideSummary` (LearnedOverrideStore cache)
- `focus_mode_v1_migration_complete` (migration receipt)

---

## 8. Cross-device state

Categorized by sync model.

### 8.1 Local-only (never leaves this Mac)
- **Distractions / `BlockingProfileManager` profiles** — `blocking_profiles.json`
- **EarnedBrowseManager** pool & block focus stats — `earned_browse.json`
- **TimeTracker** historical usage — beyond what gets `/usage/sync`'d
- **AI relevance log** — `relevance_log.jsonl`
- **Content Safety detection log** — `content_safety_log.jsonl`
- **Schedule engine enable / AI model / focus enforcement** — `focus_settings.json`
- **Focus profile (AI context)** — `focus_profile.json`
- **Calendar zoom level**
- **Pill position / ritual variant**
- **Strict-mode flag file**
- **`intentionalModeEnabled` cluster** — written by SAVE_INTENTIONAL_MODE, wiped on next launch (see §9)

### 8.2 Pulled-on-launch, pushed-on-change (`POST/PUT` settings sync)
- **`onboarding_settings.json`** — pushed via `BackendClient.syncSettings`. Pulled via `getSettings` on fresh install (no local file).
- Includes: theme, partner email/name, lockMode, alwaysRelevantSites, contentSafety.enabled, enforcement.{deepWork,focusHours}.{nudge,redshift,redirect,overlay,intervention,audio,contextswitch}, intervention toggles, overridePartnerRequired, soundTone.

### 8.3 Pulled on launch + foreground + 60s + pushed on change (sibling-sync pattern)
- **Partner status** (`PartnerSyncService` → `/partner/status`) — fans out to dashboard via `_partnerStatusResult`.
- **Bedtime config** (`BedtimeConfigSync` → `/bedtime/config`) — pushed on dashboard save; one-time migration of legacy local file → backend.
- **Intentions** (`IntentionStore` → `/intentions`) — pulled on launch + foreground + 60s; written through to `intentions.json` as cache; pushed on every CRUD.
- **Time blocks (Spec 2)** (`ScheduleManager` → `/time_blocks`) — pulled on launch + foreground + 60s; pushed on `SET_SCHEDULE`.

### 8.4 Cross-device via APNs + 2s polling + WS push
- **Focus session state** (`focus_sessions` table). Backend canonical. Mac:
  - Poll `/focus/active` every 2s (`FocusStatePoller`)
  - Subscribe via WS (`FocusWebSocketClient`)
  - Both paths drive `FocusModeController.activate/.deactivate`
  - On local activation, post `/focus/toggle` with intention_id (if originator is `.manual` / `.schedule`)
  - Backend pushes silent APNs to peer iOS for ≤5s propagation
- **Intention strictness changes** — propagated via standard intentions sync (60s pull cadence, no APNs).

### 8.5 Bedtime cross-device caveats
- Bedtime *config* cross-device (per §8.3).
- Bedtime *active state* (wind-down phase, locked) is **local-only per device** today. AppDelegate comment line 884: "Bedtime is phone-and-Mac local for now".
- iPhone has its own DeviceActivityMonitor schedule path (`PuckBedtimeMonitor`). Shared blocklist via App Group is iOS-internal.

---

## 9. Suspected dead code

Concrete candidates with file:line references.

| # | Item | Where | Why suspected dead |
|---|---|---|---|
| 1 | **Settings → Focus Mode → Screen Lock toggle** + Schedule selector + grace-period select | `dashboard.html:5002–5045` + `MainWindow.swift:1734` (handleSaveIntentionalMode) | UserDefault keys it writes (`intentionalModeEnabled`, `intentionalModeSchedule`, `intentionalModeGracePeriod`, `intentionalModeCustomSchedule`) are **wiped every launch** by `AppDelegate.runFocusModeMigrationIfNeeded` (line 320–362). `IntentionalModeController` is deleted (comment line 328: "Settings written by the now-deleted IntentionalModeController"). The handler is described in source as "documented dead code" (line 330). |
| 2 | **`BlockRitualController` full-screen path** | `AppDelegate.swift:591` `// focusMonitor?.ritualController = BlockRitualController()  // Now pill-centric` | Class still exists, `endRitualController` still wired, but the full-screen start ritual was replaced by the pill's `.startRitual` mode. Class compiles but never instantiated for the start path. |
| 3 | **`force-a-plan` / no-plan overlay in FocusMonitor** | `FocusMonitor.swift:1634–1638` `// TODO (Task 5): When FocusModeController.isOn replaces TimeState gates, restore noPlan pill-card logic…` | Comment admits the noPlan/unplanned floating-pill path was deleted in TimeState consolidation. Restoration is a TODO. |
| 4 | **`BlockingProfileManager` UI in calendar block editor** | `dashboard.html` calendar block editor | Per CLAUDE.md Spec 1 D14: chips UI hidden, replaced by Intention picker. `BlockingProfileManager` retained for ≥2 weeks of stability. Distractions page is the only surviving UI for the type. |
| 5 | **Legacy `*_PROJECT_*` bridge handlers** | `MainWindow.swift:549–584` (START_PROJECT_SESSION, GET_PROJECTS, GET_PROJECT_DETAIL, CREATE/UPDATE/DELETE_PROJECT) | Per CLAUDE.md: "deprecated aliases for one release cycle". The Intentions migration ran already. Dashboard JS still calls some of these. |
| 6 | **`.allCaughtUp` NoPlanData state** | `DeepWorkTimerController.swift` (referenced in MEMORY.md but enum at line 86 only has `.noPlan`, `.gap`, `.doneForDay`) | Either the enum was reduced and the consumer wasn't, or the state is rendered via a different mechanism. Worth a closer look. |
| 7 | **Earned Browse widget** | `dashboard.html:4479` (`<div class="earned-browse-widget" … style="display:none;">`, comment "stripped for Puck model") | Inline comment: "(hidden — stripped for Puck model)". GET_EARNED_STATUS, REQUEST_EXTRA_TIME, VERIFY_EXTRA_TIME_CODE, the entire flow + sub-step DOM, all hidden. Backend endpoints + Swift handlers + EarnedBrowseManager all still active. |
| 8 | **`page-schedule` orphan div** | `dashboard.html:4389–4390, 4610` (sidebar item removed, `page-schedule` div retained "in case a deep link still routes there") | Sidebar Schedule item removed in commit `eaeb80b`; div kept defensively. |
| 9 | **`BlockingProfilesToIntentionsMigration` after first run** | Migration runs idempotently behind a receipt. Once stable on every install, the runner can be deleted. |
| 10 | **`projects.json`** + ProjectStore detail dashboard | `ProjectStore.swift:169` + `dashboard.html` legacy "rich detail view" | Per inline comment: legacy local-only projects archive. After IntentionStore migration, `projects.json` is no longer authoritative. The dashboard renderSetup path still uses it (`_backendOnly: !localMatch` flag, line 10675). |
| 11 | **"self" lock mode** | `MainWindow.swift:679, 1034, 1514, 1566` (4 places: `if lockMode == "self" { lockMode = "none" }` — `// "self" lock mode removed`) | Old self-lock mode removed; defensive translation kept in 4 locations. |
| 12 | **`focus_session.json` + `intentional_mode_state.json` cleanup pass** | `AppDelegate.swift:348` | Defensive removal of legacy state files on every fresh-install path. |
| 13 | **`requestIntentionStrictnessUnlock` / `verifyIntentionStrictnessUnlock`** in BackendClient | `BackendClient.swift:1747, 1781` | CLAUDE.md notes the backend endpoints are "DEFERRED on backend (Plan A 'What this plan does NOT do')". Mac client method exists but always errors at runtime. UI throws "Couldn't reach partner". |
| 14 | **AppDelegate `activeProjectSession`** | `AppDelegate.swift` (search "activeProjectSession") | CLAUDE.md notes: "retained as in-RAM cache, now driven by both manual-start (optimistic) and FocusStatePoller (canonical)." Now redundant with IntentionStore + FocusModeController state. Open question whether the manual-start optimistic path is still needed. |
| 15 | **Bedtime time labels in Settings → Bedtime detail** | `dashboard.html:5069` (`11:00 PM` hard-coded) and 5073 (`7:00 AM` hard-coded) | Display values are hard-coded strings, not bound to `bedtime_settings.json`. The actual edit lives elsewhere (the Settings → Bedtime detail panel doesn't surface time pickers). |
| 16 | **Debug Monitor window** | `LegacyMonitorView.swift` + AppDelegate Cmd+M handler | Tagged "legacy SwiftUI views" in MainWindow.swift comments. |
| 17 | **`main.swift.disabled`** | `Intentional/main.swift.disabled` | Disabled file shipped in tree. |
| 18 | **`ScheduleManager.BlockType.freeTime`** | FocusMonitor.swift:3530 `_ = isFree  // unused now; retained in signature for legacy callers` | Per Spec 2, free time is the absence of a block. `isFree` flag retained in API surface for legacy callers. |
| 19 | **Distracting sites/apps in onboarding_settings.json** | Multiple files reference `distractingSites` / `distractingApps` keys with comments "blocking is now driven by BlockingProfileManager (always-active profiles + focus session profiles)" | AppDelegate line 464: "Legacy distractingSites loading removed". The keys are persisted on save round-trips but no longer feed enforcement. |

---

## 10. Open observations

1. **"Focus Mode" name collisions — at least 4 distinct concepts share the word.**
   - **(a) `FocusModeController.state`** — the master state machine (off/focus/bedtime). The runtime "is the app enforcing right now" answer.
   - **(b) Sidebar "Focus Modes" item** — alias for *Intentions* (`data-page="intentions"`). Cards represent named intention presets like "Coding · Standard". Different from (a).
   - **(c) Settings → Focus Mode** detail panel — the dead `IntentionalModeController` UI plus the still-live Interventions toggle list. Different from both (a) and (b).
   - **(d) Today page → Focus Mode toggle** (`#focus-mode-toggle`) — manually toggles (a). Drawn near "Focus Mode" labels but the user might confuse with (c).
   - The dashboard sidebar uses **"Focus Modes"** even though CLAUDE.md uses **"Intentions"** — vocabulary not consistent across sidebar / spec / code identifiers.

2. **Three "Bedtime" surfaces with different dismiss models.**
   - Wind-down notifications (passive)
   - Pill `.bedtimeLocked` mode + Ask-Partner button
   - The actual `BedtimeLockLoop` triggering the OS lock screen (no UI of its own)
   
   When the lock loop fires, the user can't see the pill or notifications — they hit the OS lock screen. After password entry, the loop fires again 10s later. The Ask-Partner exit path requires the user to act fast.

3. **Two "Sensitive Content" surfaces**, identical controls.
   - `page-sensitive` (sidebar) and `settings-detail-safety` (Settings drill-down) both render the same toggle + permission banner + Test button. JS populates both via the same path.

4. **`NoPlanData.CardState`** — code references `.allCaughtUp` (per MEMORY.md), but the enum at `DeepWorkTimerController.swift:86` only has `.noPlan`, `.gap`, `.doneForDay`. Either MEMORY.md is stale or the rendering code branches off another flag (e.g. `currentHour < 21`). Worth confirming during product brainstorm — there's likely product intent here that isn't currently delivered.

5. **Earned Browse pipeline is fully alive but UI is hidden.**
   - Bridge handlers work, EarnedBrowseManager is wired into TimeTracker callbacks, backend endpoints live, REQUEST_EXTRA_TIME flow exists.
   - Only the visible widget is `display:none` (comment "stripped for Puck model").
   - The whole earning/spending budget mechanic is invisible to the user but firing every block transition.

6. **Two strictness paths with opposite auth models.**
   - Tightening (Soft → Standard / Soft → Strict / Standard → Strict): instant.
   - Standard → Soft: 24h server-side cool-down, cancellable, warm-tone copy.
   - Strict → anywhere: requires partner unlock (BACKEND ENDPOINTS NOT YET DEPLOYED — Plan A defers).
   - Net effect: a user on Strict cannot soften today. The UI sheet exists, the BackendClient method exists, the call always fails.

7. **`BlockingProfileManager` is the only material thing that's truly local-only on a multi-device account.**
   - The Distractions page's profiles don't sync. A user setting up "Coding distractions" on Mac sees nothing on iPhone.
   - This contradicts the principle "Backend is Source of Truth for Cross-Device State".
   - Spec 1 hides chips in the calendar editor but didn't migrate the data type. Per D14 the cleanup is deferred.

8. **Two pill positions for two state machines.**
   - Bedtime pill modes (`.bedtimeWindDown`, `.bedtimeLocked`) live in the same `DeepWorkTimerController` window as the focus pill, but are driven by `BedtimeEnforcer.onStateChanged` instead of FocusMonitor. The class blends two unrelated state machines into one widget. Adding a third use (e.g. session reflection prompt) would tangle them further.

9. **WebSocket auth refresh + 2s polling overlap.**
   - WS subscribes for cross-device focus signals; poller hits `/focus/active` every 2s as fallback. Both drive the same activate/deactivate. CLAUDE.md notes both are deliberately redundant ("whichever path detects the transition first wins"). Combined effective latency is bounded by 2s in the worst case but produces double the network traffic on every transition.

10. **`GET_FOCUS_MODE` returns Mac local state, not backend `/focus/active`.**
    - The dashboard's "is focus on" indicator uses `_focusModeUpdate` push (driven by FocusModeController's onStateChanged). On the Mac, that closely tracks the poller, so they line up. But there's no UI surface that exposes "what does the backend think" — useful for cross-device debugging.

11. **`sensitivecontentanalysis.client` entitlement is stripped from PKG builds**, so OpenNSFW is the production detection engine. Apple's SCSensitivityAnalyzer initialization survives but never produces real results in the production binary. The `analyzer` instance variable still exists. Worth knowing for the brainstorm — production "Content Safety" is fully on OpenNSFW.

12. **`SAVE_IF_THEN_PLAN` writes one number to UserDefaults** (`defaultIfThenPlan`) and is used by exactly one surface (BlockRitualController). Tiny but kept around.

13. **AppDelegate has both `dismissFocusStartOverlay` AND `BedtimeLockLoop.bind`-style singletons.** Pattern is inconsistent — some overlays are singletons (`bedtimeUnlockWindow`, `intentionStrictnessUnlockWindow`), others are stored as arrays per-screen. Refactor target.

14. **Spec 1 dialog in `dashboard.html`** still has "legacy" branches throughout (search "legacy" — 14 hits in dashboard.html). The Intentions tab logic dispatches between "if local Project row exists, show legacy detail" and "else show new intentions form". A user who completes the migration cleanly never hits the legacy branch — but partial-migration users do. Code becomes simpler once legacy is removed, but timing depends on receipts being universally stamped.

15. **The "Schedule" sidebar item removal is recent** (commit eaeb80b, May 2026). All the calendar functionality moved to Today. But the Schedule detail panel still exists with full Day/Week toggle logic and "Week view — coming soon" placeholder. Could be removed, or could be promoted as a Schedule v1.5 surface — open product question.

16. **Onboarding can't currently change the partner alone** — the partner lives behind `SAVE_LOCK_SETTINGS` which expects email + name + lockMode together, even though under the hood `setPartner` is its own backend call. UI flow couples the two ideas tightly.

17. **`PartnerSyncService.shared` is a singleton, but `BedtimeConfigSync` and `IntentionStore` follow different patterns.** Consistency could be improved but it's cosmetic.

18. **Focus state debug dump (`/tmp/intentional-focus-state.json`)** writes every 5s. This is for `scripts/focus-debug.py`. Useful in development. In production it's dead I/O on the user's machine. Probably worth gating behind DEBUG.

19. **Settings save debounce (800ms) lost-changes bug** (CLAUDE.md Known Bug #6) — fix only applied to Content Safety toggle. Every other settings toggle still has the bug.

20. **`pushBack` in BlockRitualController** — there's a "Push Back" callback that delays the block. Where it's surfaced and what UX it produces is worth tracing for the brainstorm. May be related to the snooze concept on the noPlan card.

21. **Watchdog plist** at `Intentional/com.intentional.watchdog.plist` is a LaunchAgent that re-opens Intentional if the strict-mode flag exists. That's the user-facing strictness backbone. Disabling strict mode unregisters the agent — but the flag file is gated by partner unlock, so this works as designed.

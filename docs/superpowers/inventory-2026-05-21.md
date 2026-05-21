# Intentional Mac App — Feature Inventory (2026-05-21)

Source pass: read of `Intentional/*.swift` + `dashboard.html` sidebar/page structure + `MainWindow.swift` bridge switch + `BackendClient.swift` URL strings + `main.swift` + entitlements/Info.plist on `slice-13-cleanup` (HEAD `3d15f80`). Cross-checked against `docs/*.md` to avoid duplicate doc proposals.

## Summary

- **Swift source files in `Intentional/`**: 66 (excludes `main.swift.disabled`, `SimpleTest.swift` looks like a debug stub).
- **Total top-level types** (`class | struct | enum | actor`): ~155 declarations across ~65 files (mix of public service types + SwiftUI view structs + DTO structs).
- **Top-level non-view *services / controllers / managers / actors / stores*** (the things that matter for the docs set): ~50 (full list in §1 below).
- **Existing `docs/*.md` reference docs** (evergreen, `UPPER_SNAKE_CASE.md`): 24 — listed in §2. The cross-repo / overnight / dated reports are *not* counted as "reference" docs.
- **Bridge messages** (`MainWindow.swift` web→Swift `switch type`): **84 cases**.
- **Native-Messaging bridge messages** (extension→Swift via `NativeMessagingHost.swift`): **20 cases**.
- **Backend endpoints called by the Mac**: ~40 distinct paths (full table in §5).
- **Other targets in the Xcode project**: 3 — `FilterExtension/` (NEFilterDataProvider system extension), `IntentionalDaemon/` (root daemon, `syspolicyd_helper/` is its source dir), `IntentionalTests/`.
- **Entitlements declared**: 8 unique keys in `Intentional.entitlements`.

[VERIFY] "Total Swift files" only counts the main app target; FilterExtension + syspolicyd_helper add a handful more. I treated only the main app target as in-scope for the feature doc set.

---

## 1. Top-level types in `Intentional/*.swift`

Grouped by file. **Bold** items are the load-bearing service/controller/store/manager classes the doc set will revolve around; the rest (DTO structs, SwiftUI view structs, ViewModels) are listed to acknowledge they exist but won't each get a doc.

### Core enforcement & focus

- `Intentional/FocusMonitor.swift:FocusMonitor` (4041 lines, ~16 public methods) — The big one. Owns the active-block enforcement loop, distraction nudge tiers, work-block timer, recovery state, override flow, browser tab scoring routing, app-vs-website verdict.
- `Intentional/FocusModeController.swift:FocusModeController` — Three-state controller (OFF / FOCUS / BEDTIME); single source of truth for "is the app enforcing right now," persists to disk, fans state changes out to FocusMonitor, EarnedBrowseManager, SocketRelayServer, dashboard.
- `Intentional/ScheduleManager.swift:ScheduleManager` — Owns the dated `FocusBlock` list, computes `currentBlock`, emits `onBlockChanged`; serialized to local schedule JSON.
- `Intentional/SwitchInterventionCoordinator.swift:SwitchInterventionCoordinator` + `SwitchOverlayController` — Context-switching countdown overlay system. Coordinator decides whether to suppress/show; controller hosts the SwiftUI NSWindow.
- `Intentional/EarnedBrowseManager.swift:EarnedBrowseManager` — Earn-Your-Browse pool: accrues minutes on work ticks, deducts on social-media sessions, broadcasts to extension.
- `Intentional/SleepWakeMonitor.swift:SleepWakeMonitor` — Observes `NSWorkspace.willSleepNotification` / `didWakeNotification`, surfaces them to consumers.
- `Intentional/ProcessMonitor.swift:ProcessMonitor` — Polls running processes / front app, frontmost-app changes; FocusMonitor consumes.
- `Intentional/PermissionManager.swift:PermissionManager` — Accessibility + Screen Recording + Automation permission probing; surfaces missing-permission alerts.
- `Intentional/TrustedClock.swift:TrustedClock` — Wraps clock reads in a way that resists clock-skew tampering. [VERIFY: is this still being used everywhere `Date()` would be?]

### Block start/end ritual + pill + overlays (the "Deep Work UX")

- `Intentional/DeepWorkTimerController.swift:DeepWorkTimerController` (+ `DeepWorkTimerViewModel`, `KeyablePanel`, `TransparentHostingView`) — The floating Pill widget. Modes: timer / blockComplete / celebration / startRitual / startRitualEdit / noPlan.
- `Intentional/BlockRitualController.swift:BlockRitualController` — Full-screen block-start ritual (separate from in-pill version).
- `Intentional/BlockEndRitualController.swift:BlockEndRitualController` — Full-screen end-of-block celebration carousel.
- `Intentional/FocusStartOverlay.swift:FocusStartOverlayViewModel` (+ SwiftUI view) — Larger overlay shown when entering a Focus session.
- `Intentional/FocusOverlayWindow.swift:FocusOverlayWindowController` (+ `KeyableWindow`, `FocusOverlayViewModel`, SwiftUI view, `DurationOption`, `VisualEffectBlur`) — The blocking overlay shown when a non-relevant app/site is foreground during work.
- `Intentional/InterventionOverlayController.swift:InterventionOverlayController` (+ `InterventionOverlayViewModel`, `InterventionType` enum, SwiftUI games) — 60/90/120s mandatory intervention exercises after repeated distraction.
- `Intentional/NudgeWindowController.swift:NudgeWindowController` (+ `NudgeViewModel`) — Toast-style external nudge for escalated/warning tiers.
- `Intentional/GrayscaleOverlayController.swift:GrayscaleOverlayController` — Display gamma / desaturation overlay (used by wind-down before lock-loop replaced full-screen bedtime overlay).
- `Intentional/TamperOverlayController.swift:TamperOverlayController` — Full-screen "Content Safety has been tampered with" overlay.

### AI / scoring / browsing

- `Intentional/RelevanceScorer.swift:RelevanceScorer` — AI-content scorer (keyword→cache→LLM). Qwen3-4B path via MLX; Apple Foundation Models is wired but user's path is Qwen per MEMORY.
- `Intentional/ConfidenceGate.swift:enum ConfidenceGate` — Thresholding helpers around scorer output.
- `Intentional/ConstraintEvaluator.swift:enum Constraint / ConstraintResult / ConstraintEvaluator` — Rule engine that converts a verdict into an enforcement action (allow / nudge / block).
- `Intentional/ScoringPath.swift:enum ScoringPath` + `ScoringTracer` — Telemetry for which scoring branch fired (keyword vs cache vs LLM).
- `Intentional/LearnedOverrideStore.swift:actor LearnedOverrideStore` — Records sites the user has overridden so the scorer's verdict is sticky.

### Content Safety

- `Intentional/ContentSafetyMonitor.swift:ContentSafetyMonitor` (+ `ContentSafetyOverlayViewModel`, `PermissionRequiredOverlayViewModel`, SwiftUI views) — Periodic per-window screen capture, runs detector, draws overlay, reports to backend.
- `Intentional/ScreenCapture.swift:actor ScreenCapture` — `CGWindowList` + `SCStream` capture wrapper.
- `Intentional/OCREngine.swift:actor OCREngine` — Vision OCR for two-pass capture text extraction.
- `Intentional/NudeNetDetector.swift:NudeNetDetector` — CoreML wrapper around `NudeNetV3.mlpackage` + `OpenNSFW.mlmodel`. Per MEMORY: OpenNSFW is the production path; NudeNet is the fallback/test path.
- `Intentional/EnforcementCache.swift:EnforcementCache` (+ `EnforcementCacheData`, `AnyCodable`) — Disk cache of `/device/enforcement` response so partner-locked CS settings survive offline restart.
- `Intentional/EnforcementReconciler.swift:EnforcementReconciler` (+ `EnforcementSnapshot`) — Compares current local CS state to backend's desired state; reverts tampering.

### Bedtime

- `Intentional/BedtimeEnforcer.swift:BedtimeEnforcer` (+ `WindDownPhase`, `BedtimeState`, `enum BedtimeLogic`, `TimeOfDay`, `BedtimeSettings`) — State machine `inactive | windDown(...) | locked | released`.
- `Intentional/BedtimeLockLoop.swift:BedtimeLockLoop` — 10s lock-loop using `SACLockScreenImmediate` via `dlopen` on `login.framework`. Replaces full-screen overlay per April 2026 fix.
- `Intentional/BedtimeWindDownController.swift:BedtimeWindDownController` — T-30/T-15/T-10/T-5/T-1 native notifications.
- `Intentional/BedtimeConfigSync.swift:BedtimeConfigSync` — Pulls/pushes `/bedtime/config`; migrates legacy `bedtime_settings.json`.
- `Intentional/BedtimeUnlockRequestView.swift:BedtimeUnlockRequestView` + `enum UnlockRequestKind` — SwiftUI sheet generalized for bedtime AND `intentionStrictness` partner-unlock flows.

### Cross-device sync

- `Intentional/FocusStatePoller.swift:FocusStatePoller` — Polls `/focus/active` every 2s using `X-Device-ID`. Drives FocusModeController state transitions.
- `Intentional/FocusWebSocketClient.swift:FocusWebSocketClient` — WebSocket `/ws/focus` for low-latency cross-device push (complements the 2s poller).
- `Intentional/PartnerSyncService.swift:PartnerSyncService` — Pulls `/partner/status` on launch + `didBecomeActive` + 60s.
- `Intentional/EntitlementClient.swift:EntitlementClient` (+ `Entitlement` struct) — Subscription entitlement client (`/me/entitlements`), cached to disk.
- `Intentional/LapsedSubscriberBanner.swift:LapsedSubscriberBanner` — Renders the in-dashboard banner when entitlement is lapsed.
- `Intentional/IntentionalDeviceRegistration.swift:IntentionalDeviceRegistration` — `POST /devices/register` once per install for cross-device routing.

### Intentions / Projects / Profiles (data + migrations)

- `Intentional/Intention.swift:struct Intention` (+ `PendingStrictnessChange`, `IntentionCreatePayload`, `IntentionUpdatePayload`, `IntentionListResponse`, `enum StrictnessPreset`) — DTOs for Spec 1 cross-device intentions.
- `Intentional/IntentionStore.swift:actor IntentionStore` — Cache + in-memory store; refreshed on launch / foreground / 60s timer.
- `Intentional/IntentionMigration.swift:IntentionMigration` — One-shot migration of local Project → backend Intention with receipt at `migration_intentions_v1.json`.
- `Intentional/BlockingProfileManager.swift:BlockingProfileManager` + `BlockingProfile` + `MergedBlockList` — **Marked `@available(*, deprecated, message: ".. Will be removed in slice 13.")`** — Old named-profiles concept; still loaded because schedule blocks may reference profileIds via the legacy `profileIds` field on a `FocusBlock`.
- `Intentional/BlockingProfilesToIntentionsMigration.swift:BlockingProfilesToIntentionsMigration` — Idempotent rebind block→profile to block→intention.
- `Intentional/ProjectStore.swift:actor ProjectStore` (+ `enum HostKind`) — The pre-Intentions project concept. Per CLAUDE.md "Intentions (Spec 1)": still alive as project sessions cache; `BlockingProfileManager` is *not* removed in spec 1.

### Browser integration / extension surface (ALL on the deletion list)

- `Intentional/BrowserMonitor.swift:BrowserMonitor` (572 lines) — Cross-checks socket-connected browsers against file-based detection.
- `Intentional/BrowserDiscovery.swift:BrowserDiscovery` (+ `InstalledBrowser`) — Walks `~/Library/Application Support/<browser>/` to find install paths.
- `Intentional/BrowserDatabase.swift:struct BrowserDatabase / BrowserInfo` (+ `enum BrowserEngine`, `enum NativeMessagingType`) — Static metadata table for 12 browsers (bundle IDs + nativeMessaging paths).
- `Intentional/WebsiteBlocker.swift:WebsiteBlocker` (1222 lines) — AppleScript tab-close fallback for browsers without an installed extension. **Background queue is critical (bug fix #9).**
- `Intentional/NativeMessagingHost.swift:NativeMessagingHost` (1107 lines, 20 message handlers) — Per-extension-connection message dispatcher.
- `Intentional/NativeMessagingSetup.swift:NativeMessagingSetup` — Auto-discovers extensions; installs manifests at startup; tracks per-browser connection status.
- `Intentional/SocketRelayServer.swift:SocketRelayServer` (385 lines) — Unix-domain socket the primary app listens on; `main.swift`'s extension-launched relay path connects to it.

### Web shell / dashboard host

- `Intentional/MainWindow.swift:MainWindow` (3604 lines) — WKWebView host, single bridge switch (84 cases), title-bar theming, dashboard navigation, all `handle…` methods.
- `Intentional/LegacyMonitorView.swift:LegacyMonitorWindow` (+ `MonitorMainView`, `LogEntry`) — Legacy debug log window. [VERIFY: still wired or dead?]

### Backend client / time tracking / usage

- `Intentional/BackendClient.swift:BackendClient` (2152 lines, ~50 async methods) — JWT + `X-Device-ID` API client; cert-pinning delegate (`CertPinningDelegate`) — pinning fingerprint still has a `TODO(ops)` marker.
- `Intentional/TimeTracker.swift:TimeTracker` — Cross-browser per-platform aggregation; emits `onSocialMediaTimeRecorded`, `onSessionChanged`.

### Anti-tamper / persistence

- `Intentional/DaemonXPCClient.swift:DaemonXPCClient` — XPC to `syspolicyd_helper` daemon for strict-mode authority.
- `Intentional/EnforcementDaemonClient.swift:EnforcementDaemonClient` — Distinct from `DaemonXPCClient` — wraps daemon's enforcement-config writes.
- `Intentional/QuitPolicy.swift:enum QuitPolicy / QuitDecision` — Cmd-Q decision logic (allow vs block based on strict mode + daemon availability).
- `Intentional/Library/LaunchAgents/com.intentional.watchdog.plist` — Watchdog LaunchAgent bundled at app launch.
- `IntentionalDaemon/main.swift` + sources in `syspolicyd_helper/` (`AppWatchdog`, `ConfigManager`, `EnforcementHMAC`, `HeartbeatService`, `HostsWatcher`) — The privileged daemon target.
- `Shared/DaemonXPCProtocol.swift` — Shared XPC protocol used by both app + daemon.

### Network Extension (system-level blocking)

- `Intentional/FilterManager.swift:FilterManager` (+ `FilterState`) — Wraps `NEFilterManager.shared()` to install/enable the system extension.
- `FilterExtension/FilterDataProvider.swift:FilterDataProvider` + `FilterExtension/main.swift` — The system-extension target.

### App lifecycle / orchestration

- `Intentional/AppDelegate.swift:AppDelegate` (1922 lines) — Init order (24 numbered steps per CLAUDE.md), callback wiring, all `handle…` callees for bridge messages, strict-mode handlers, project-session orchestration.
- `Intentional/main.swift` (398 lines) — Entry point. Single-instance lock + extension relay + Xcode-debug takeover + SIGTERM handler.
- `Intentional/SimpleTest.swift:SimpleTestApp` — [VERIFY: looks like a manual debug entry; not referenced from main.swift; possibly dead.]

### Static HTML / resources

- `Intentional/dashboard.html` (12492 lines) — Main settings UI + Today/Plan/Intentions/Sensitive/Lock pages.
- `Intentional/onboarding.html`, `Intentional/login.html`, `Intentional/blocked.html`, `Intentional/focus-blocked.html` — Other WKWebView surfaces.

---

## 2. Existing `docs/*.md` reference set (don't duplicate)

Evergreen (UPPER_SNAKE_CASE.md) reference docs in `docs/`:

`AI_SCORING.md` · `ARCHITECTURE.md` · `BLOCK_DELETION_RESEARCH.md` · `BLOCK_TYPE_ENFORCEMENT_SETTINGS.md` · `BRAINSTORMING_CONTEXT.md` · `CALENDAR_BLOCK_RULES.md` · `CONTENT_SAFETY_MONITOR.md` · `CONTEXT_SWITCHING_OVERLAY.md` · `CROSS_DEVICE_FOCUS_DEBUGGING.md` · `CS_TESTING_WINDOW_PLAYBOOK.md` · `EARN_YOUR_BROWSE_IMPLEMENTATION.md` · `EARNED_BROWSE_SYSTEM.md` · `EXTENSION_PROTOCOL.md` · `FLOATING_PILL_AND_RITUALS_REDESIGN.md` · `FOCUS_CONCEPTS_SIMPLIFICATION.md` · `FOCUS_ENFORCEMENT.md` · `FOCUS_MONITOR_LOGGING.md` · `GAMIFICATION_BRAINSTORM.md` · `PARTNER_DASHBOARD.md` · `PARTNER_EMAIL_REGISTRY.md` · `PKG_BUILD_GUIDE.md` · `PRIORITY_TODOS.md` · `PROJECTS.md` · `PSYCHOLOGY_ANALYSIS.md` · `PUCK_SPEC.md` · `ROADMAP.md` · `STRICT_MODE.md` · `TIMELINE_BAR_PLAN.md` · `UNIFIED_BUDGET_DESIGN.md`.

Reasonably current. Several are stale-leaning (e.g. `EXTENSION_PROTOCOL.md` is normative for the integration that's being deleted; `BLOCK_TYPE_ENFORCEMENT_SETTINGS.md` describes the per-block toggle matrix that was partially superseded by intentions). [VERIFY each for currency before the doc run.]

The big gap-vs-code-surface I see: there is **no doc** for `FocusModeController` (it's referenced in `FOCUS_CONCEPTS_SIMPLIFICATION.md` but that's a one-time consolidation report, not the reference doc); **no doc** for `EnforcementReconciler` + `EnforcementCache` + tamper-overlay pipeline as a unit; **no doc** for the cross-device sync pattern beyond the bedtime/focus/partner one-off cross-repo logs; **no doc** for the entitlement/lapsed-banner flow; **no doc** for `RelevanceScorer`'s internal pipeline beyond `AI_SCORING.md` (which is fine but stale).

---

## 3. Dashboard pages / sidebar nav (`dashboard.html`)

Sidebar items (5 — Slice 10 reduction):

1. **Today** (`data-page="today"`, `#page-today` line 4679) — primary view; embeds a `Today/Week` toggle.
2. **Focus Modes** (`data-page="intentions"`, `#page-intentions` line 4861) — list of Intentions + per-Intention strictness control.
3. **Sensitive Content** (`data-page="sensitive"`, `#page-sensitive` line 4887) — content-safety opt-in/toggle/permissions.
4. **Accountability** (`data-page="lock"`, `#page-lock` line 4942) — partner-locking flow + unlock requests.
5. **Settings** (`data-page="settings"`, `#page-settings` line 4952) — strict mode, sounds, themes, defaults.

DOM pages still present but **not in sidebar (slice-13 cleanup target)**:

- `#page-schedule` (line 4868)
- `#page-weekly` (line 4898) — Weekly Planning placeholder, "killed" per comment.
- `#page-distractions` (line 4913) — list-management folded into Settings.

The comment at line 4632 explicitly flags these as legacy: *"Killed: Weekly Planning (placeholder, no real UI), Distractions (list-management folded into Settings; budget meter lives on Today). Old DOM pages (page-distractions, page-weekly) retained until slice 13 cleanup."*

---

## 4. Bridge messages (`MainWindow.swift switch type` — 84 cases)

Grouped by feature category. Every case-line and target handler verified against `MainWindow.swift` lines 344–688.

### Onboarding + dashboard plumbing (6)

`DIAGNOSTIC_LOG`, `SAVE_ONBOARDING` → `handleSaveOnboarding`, `GET_DASHBOARD_DATA` → `handleGetDashboardData`, `GET_SETTINGS` → `handleGetSettings`, `SAVE_SETTINGS` → `handleSaveSettings`, `NAVIGATE_TO_DASHBOARD`.

### Auth (6)

`GET_AUTH_STATE`, `AUTH_LOGIN`, `AUTH_VERIFY`, `AUTH_LOGOUT`, `AUTH_DELETE`, `AUTH_COMPLETE`.

### Partner / lock / unlock (8)

`SAVE_LOCK_SETTINGS`, `REQUEST_UNLOCK`, `VERIFY_UNLOCK`, `RELOCK_SETTINGS`, `GET_PARTNER_STATUS`, `REMOVE_PARTNER`, `RESEND_PARTNER_INVITE`, `END_SESSION` (partner-confirmed end of a focus session).

### Reset / uninstall (3)

`RESET_SETTINGS`, `UNINSTALL_APP`, `VERIFY_UNINSTALL`.

### Schedule + focus enforcement (10)

`GET_SCHEDULE_STATE`, `SET_FOCUS_ENABLED`, `SET_PROFILE`, `SET_SCHEDULE`, `GET_SCHEDULE_FOR_DATE`, `GET_FOCUS_MODE`, `FOCUS_MODE_TOGGLE`, `SET_FOCUS_ENFORCEMENT`, `SET_ENFORCEMENT_SETTINGS`, `SET_CALENDAR_ZOOM`.

### Earned-browse / extra-time (4)

`GET_EARNED_STATUS`, `REQUEST_EXTRA_TIME`, `VERIFY_EXTRA_TIME_CODE`, `INTERVENTION_TOGGLE_SET`.

### AI scoring (3)

`SET_AI_MODEL`, `GET_RELEVANCE_LOG`, `EXPORT_RELEVANCE_LOG`.

### Content Safety (2)

`TEST_CONTENT_SAFETY`, `OPEN_CONTENT_SAFETY_SETTINGS`.

### Bedtime (2)

`GET_BEDTIME_SETTINGS`, `SAVE_BEDTIME_SETTINGS`.

### Strict mode / persistence (2)

`SAVE_STRICT_MODE`, `SAVE_INTENTIONAL_MODE` (legacy — still routed for old dashboard JS).

### Usage / history (2)

`GET_USAGE_HISTORY`, `GET_JOURNAL`, `GET_BLOCK_ASSESSMENTS`, `GET_FOCUS_SCORE` (4 actually).

### Distractions / always-blocked / budget (7)

`GET_DISTRACTIONS`, `ADD_DISTRACTION`, `REMOVE_DISTRACTION`, `GET_ALWAYS_BLOCKED`, `ADD_ALWAYS_BLOCKED`, `REMOVE_ALWAYS_BLOCKED`, `GET_BUDGET_STATE`, `SET_BUDGET_CONFIG` (8 actually).

### Blocking profiles (legacy, slice-13 cleanup) (4)

`GET_BLOCKING_PROFILES`, `CREATE_BLOCKING_PROFILE`, `UPDATE_BLOCKING_PROFILE`, `DELETE_BLOCKING_PROFILE`.

### Projects (legacy aliases) (6)

`START_PROJECT_SESSION`, `GET_PROJECTS`, `GET_PROJECT_DETAIL`, `CREATE_PROJECT`, `UPDATE_PROJECT`, `DELETE_PROJECT`, `PROMOTE_LEARNED_SITE` (7 actually).

### Intentions (Spec 1 + Spec 3 strictness) (10)

`GET_INTENTIONS`, `GET_INTENTION`, `CREATE_INTENTION`, `UPDATE_INTENTION`, `DELETE_INTENTION`, `START_INTENTION_SESSION`, `UPDATE_INTENTION_STRICTNESS`, `CANCEL_PENDING_STRICTNESS_CHANGE`, `OPEN_INTENTION_STRICTNESS_UNLOCK_SHEET`, `OPEN_INTENTION_EDITOR`.

### Misc (4)

`SAVE_IF_THEN_PLAN`, `PREVIEW_SOUND`, `OPEN_EXTENSIONS_PAGE`, `GET_INSTALLED_APPS`, `GET_EXTENSION_STATUS` (5 actually).

(Counts above are approximate per-bucket; the **total of 84** comes from `grep -c "case \"[A-Z_]+\":" MainWindow.swift`.)

---

## 5. Backend endpoints called by the Mac

Source: `BackendClient.swift` URL-string grep + `AppDelegate.swift:1700` (`/focus/active` localhost-vs-prod toggle) + `FocusStatePoller.swift` + `FocusWebSocketClient.swift` + `IntentionalDeviceRegistration.swift`.

| Endpoint | Method | Direction | Trigger | iPhone also touches? | Notes / TTL |
|---|---|---|---|---|---|
| `/system-event` | POST | Mac→backend | Various lifecycle / tamper events | unknown | Telemetry |
| `/devices/register` | POST | Mac→backend | First launch (once per install) | yes (puck-ios) | Registers device row for routing |
| `/register` | POST | Mac→backend | App init | unknown | Older device register variant — [VERIFY which is canonical] |
| `/auth/login` | POST | Mac→backend | User email entry | yes | OTP send |
| `/auth/verify` | POST | Mac→backend | User code entry | yes | Returns JWT |
| `/auth/refresh` | POST | Mac→backend | 401 on JWT-auth call | yes | |
| `/auth/me` | GET | Mac→backend | Profile load | yes | |
| `/auth/logout` | POST | Mac→backend | Sign-out | yes | |
| `/auth/delete` | POST | Mac→backend | Account delete | yes | |
| `/me/entitlements` | GET | Mac→backend | Launch + foreground + 60s | yes | EntitlementClient; cached on disk |
| `/partner` | POST/DELETE | Mac→backend | Partner add/remove | yes | Writes to all sibling rows in account |
| `/partner/status` | GET | Mac→backend | Launch + foreground + 60s | yes | PartnerSyncService — sibling-fallback |
| `/lock` | POST | Mac→backend | User locks settings | yes | Sets `lockMode` |
| `/unlock/request` | POST | Mac→backend | User clicks "Ask partner" | yes (read) | Partner gets push |
| `/unlock/verify` | POST | Mac→backend | User enters partner code | yes | |
| `/unlock/status` | GET | Mac→backend | Poll while unlock pending | yes | |
| `/extra-time/request` | POST | Mac→backend | Earned-pool exhausted | unknown | |
| `/extra-time/verify` | POST | Mac→backend | User enters code | unknown | |
| `/override/request` | POST | Mac→backend | "Override" on focus overlay | yes (read) | |
| `/override/verify` | POST | Mac→backend | Code entry | yes | |
| `/bedtime/config` | GET/PUT | both | Launch + foreground + 60s; user edit | yes (BedtimeConfigSync mirror) | Account-scoped LWW upsert |
| `/bedtime/unlock-request` | POST | Mac→backend | Bedtime partner-unlock flow | yes | |
| `/sessions` | POST | Mac→backend | End-of-session report | yes | |
| `/sessions/journal` | GET | Mac→backend | Dashboard journal view | unknown | |
| `/usage/sync` | POST | Mac→backend | Periodic TimeTracker flush | unknown | |
| `/usage/history?days=N` | GET | Mac→backend | History view | unknown | |
| `/settings/sync` | GET/POST | both | Launch + on-change | yes | Account settings |
| `/content-safety/report` | POST | Mac→backend | NSFW detection fires | no | Per-detection; uploads blurred PNG |
| `/content-safety/tamper` | POST | Mac→backend | Permission revoked / monitor disabled | no | Triggers partner email |
| `/device/enforcement` | GET | Mac→backend | Launch + reconcile tick | no | Returns partner-locked CS config — `EnforcementCache.json` |
| `/intentions` | GET/POST | both | Launch + foreground + 60s (GET); user edit (POST) | yes | IntentionStore — account-scoped |
| `/intentions/{id}` | GET/PUT/DELETE | both | User edits | yes | Includes 409 stale-version error |
| `/intentions/{id}/strictness` | PUT | Mac→backend | Strictness change (instant tighten) | yes | |
| `/intentions/{id}/strictness/pending` | GET | Mac→backend | Show pending change badge | yes | |
| `/intentions/{id}/strictness/cancel` | POST | Mac→backend | User cancels 24h cool-down | yes | |
| `/intention_strictness_unlock_requests` | POST | Mac→backend | Strict-step-down partner flow | yes | Backend endpoint **DEFERRED** per CLAUDE.md — request stage fails |
| `/intention_strictness_unlock_requests/{id}/verify` | POST | Mac→backend | Code entry | yes | Deferred |
| `/focus/active` | GET | backend→Mac (poll) | Every 2s while running | yes (iPhone foreground/boot reconcile) | `X-Device-ID` auth; canonical session state |
| `/focus/toggle` | POST | Mac→backend | Manual session start/stop | yes (silent APNs fan-out to peers) | |
| `/ws/focus` | WS | both | Subscribe at launch | yes (puck-ios) | Low-latency push complement to 2s poll |
| `/time_blocks` | GET/PUT | both | [VERIFY when used] | yes (iPhone schedule tab is canonical) | Schedule Spec 2; Mac may not be fully reading yet per CLAUDE.md bug #13 |
| `/budget_state` | GET | Mac→backend | Dashboard render | unknown | |
| `/budget_state/consume` | POST | Mac→backend | Distraction time recorded | unknown | |
| `/budget_state/earn` | POST | Mac→backend | Work tick | unknown | |
| `/budget_config` | PUT | Mac→backend | User edit | unknown | Baseline + lock state |
| `/distractions` | GET/POST/DELETE | Mac→backend | App taxonomy edits | unknown | |
| `/always_blocked` | GET/POST/DELETE | Mac→backend | App taxonomy edits | unknown | |

Total distinct paths: ~45.

[VERIFY]: "iPhone also touches?" column is best-effort from sibling-repo CLAUDE rules + cross-repo docs in `docs/cross-repo-*.md`. Several rows marked "unknown" need a quick puck-ios grep before publishing.

---

## 6. Cross-device sync surfaces (the picture, not the full table)

Five distinct sync patterns are visible in the code:

1. **Account-state pull on launch + foreground + 60s**, with disk cache + last-write-wins on push.
   - `BedtimeConfigSync` → `/bedtime/config`
   - `PartnerSyncService` → `/partner/status`
   - `IntentionStore` → `/intentions`
   - `EntitlementClient` → `/me/entitlements`
   - `EnforcementReconciler` → `/device/enforcement`
2. **Fast-poll for session state**: `FocusStatePoller` at 2s, `X-Device-ID` auth, drives `FocusModeController`.
3. **WebSocket push** for the same session state: `FocusWebSocketClient` → `/ws/focus`. Used as complement to the 2s poll (low-latency, but poll is the safety net).
4. **APNs silent push fan-out**: backend pushes to peer iOS devices when Mac POSTs `/focus/toggle` (so iPhone updates in ≤5s without polling its own backend).
5. **One-shot migrations**: `BedtimeConfigSync` legacy file→backend, `IntentionMigration` Project→Intention, `BlockingProfilesToIntentionsMigration` block.profileIds→block.intentionId. Each idempotent via a receipt file at `~/Library/Application Support/Intentional/migration_*.json`.

TTL safety net the code relies on: backend `focus_sessions.expires_at` is 12h, so even if the Mac dies mid-session and no STOP is ever sent, the session self-expires server-side.

---

## 7. Extension surface (the deletion target list)

Everything in this section exists ONLY because of the Chrome/Firefox extension integration. Confirmed by grep + cross-checking which classes are referenced by AppDelegate and which functionalities go away if the extension is removed.

### Swift files (delete entirely)

- `Intentional/SocketRelayServer.swift` (385) — Unix-domain socket server *only* used by extension-launched relay processes.
- `Intentional/NativeMessagingHost.swift` (1107) — Per-extension message handler + all 20 of its `case` branches.
- `Intentional/NativeMessagingSetup.swift` (786) — Auto-discovery + manifest install for browsers.
- `Intentional/BrowserMonitor.swift` (572) — Cross-checks socket-connected browsers against file detection.
- `Intentional/BrowserDiscovery.swift` (415) — Walks browser application-support dirs.
- `Intentional/BrowserDatabase.swift` (1623) — 12-browser metadata table (most of which is only used for nativeMessagingType / supportsNativeMessaging fields).
- `Intentional/WebsiteBlocker.swift` (1222) — AppleScript tab-close, **only invoked for browsers without an installed extension**. If the extension is gone, every browser is "unprotected" and this becomes the *only* enforcement path — so [VERIFY] whether this is part of the deletion target or whether it stays as the now-canonical browser enforcement path.

**Total Swift LOC to delete (excluding WebsiteBlocker which may stay)**: ~4,888 lines across 6 files.

### Adjacent assets (delete)

- `NativeMessaging/install.sh`
- `NativeMessaging/com.intentional.social.json`
- `Intentional/AppDelegate.swift` lines that init `socketRelayServer`, `nativeMessagingHost`, `NativeMessagingSetup.shared.autoDiscoverExtensions()`, `installManifestsIfNeeded()`, and the extension-rescan timer (lines ~1071–1108, ~1190–1191, ~1386).
- All references in `BrowserMonitor` to `NativeMessagingSetup.shared.hasCompletedInitialScan` / `getBrowserStatus()` / `getConnectedBrowserBundleIds()`.

### `main.swift` extension-launched branch (lines 184–366)

Delete the entire `if launchedViaExtension { ... dispatchMain() }` block — ~180 lines. Once gone, `main.swift` is purely single-instance + xcode-takeover + SIGTERM handler.

The `launchedViaExtension` detection at lines 16–18 also goes.

### Bridge messages used by extension (delete from `NativeMessagingHost.handleMessage`)

All 20: `PING`, `SESSION_START`, `SESSION_END`, `SESSION_UPDATE`, `GET_STATUS`, `USAGE_HEARTBEAT`, `GET_USAGE`, `OPEN_DASHBOARD`, `SCORE_RELEVANCE`, `GET_SCHEDULE`, `SET_SCHEDULE`, `ADD_BLOCK`, `SNOOZE_PLAN`, `SET_FOCUS_ENABLED`, `SET_PROFILE`, `FOCUS_OVERLAY_ACTION`, `GET_WORK_BLOCK_STATE`, `SOCIAL_MEDIA_SESSION_END`, `REQUEST_EXTRA_TIME`, `VERIFY_EXTRA_TIME_CODE`, `REQUEST_OVERRIDE`, `VERIFY_OVERRIDE_CODE`.

### `MainWindow.swift` bridge cases that become dead

- `GET_EXTENSION_STATUS` → `handleGetExtensionStatus`
- `OPEN_EXTENSIONS_PAGE`
- `SCORE_RELEVANCE` (only sender is extension)

(The dashboard's own `OPEN_EXTENSIONS_PAGE` button in settings would also be removed.)

### `SocketRelayServer` broadcast methods that become dead

All broadcasters that fan state to the extension: `broadcastSessionSync`, `broadcastScheduleSync`, `broadcastFocusOverlay`, `broadcastHideFocusOverlay`, `broadcastPoolExhausted`, `broadcastMuteBackgroundTab`, `broadcastEarnedMinutesUpdate`. Callers in FocusMonitor / EarnedBrowseManager / AppDelegate also drop these calls.

### Entitlement / Info.plist impact

None. Apple-events temporary-exception entitlement (for AppleScript tab close) stays only if `WebsiteBlocker` stays.

### Existing reference doc that becomes obsolete

- `docs/EXTENSION_PROTOCOL.md` — full deletion.
- `docs/AGENT_PROMPT_DASHBOARD.md` — [VERIFY relevance after deletion]
- `docs/EARN_YOUR_BROWSE_IMPLEMENTATION.md` — mentions extension flows; need a re-read to scope what survives.

### Open question for the user (not for me to decide)

If the extension is gone, **how does in-browser content get scored?** Two paths visible in the current code:

1. Extension scrapes DOM content → sends `SCORE_RELEVANCE` to native → RelevanceScorer.
2. AppleScript reads tab URL+title → blocked-list check (no LLM scoring of in-page content).

Without an extension, the app loses semantic per-page scoring inside browsers. This is a scope question, not an inventory one — flagging for the planning phase.

---

## 8. Execution-mode map (`main.swift`)

Five distinct modes are reachable from `main.swift`:

1. **Primary (manual launch)** — Finder, Dock, login item, or Xcode "Run". Path: skip lock check (or take over from existing PID if Xcode launch), write lock file, set `isPrimaryProcess = true`, fall through to `NSApplicationMain`. Lines ~104–182 + ~368–396.

2. **Extension relay (Chrome/Firefox-launched)** — detected via `CommandLine.arguments.contains { $0.hasPrefix("chrome-extension://") || $0.hasPrefix("moz-extension://") }`. Path: check `allowAutoLaunchFromExtension` UserDefaults + `intentional-no-relaunch` marker file → if both clear, ensure primary is alive (NSWorkspace launch if missing) → connect to Unix socket → bidirectional stdin↔socket forwarding via GCD sources → `dispatchMain()`. Lines 184–366.

3. **Watchdog-relaunched (strict mode)** — Same code-path as Primary, but parent is `com.intentional.agent` LaunchAgent or root daemon. The SIGTERM handler at lines 71–101 specifically does NOT write the no-relaunch marker when strict mode is on, so the watchdog can pick it back up.

4. **Xcode debug takeover** — detected via `ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"]`. Path: kill existing PID via SIGTERM, bootout LaunchAgent + any `com.intentional.*` / `application.com.arayan.intentional` launchctl entries (so launchd doesn't immediately relaunch the PKG version), wait up to 2s for old PID to die, rewrite lock file, clear no-relaunch marker, fall through to Primary. Lines 113–168.

5. **Duplicate-silent-exit** — Manual launch when another primary already holds the lock: log and `exit(0)` silently (no `NSApp.activate()` because the KeepAlive LaunchAgent respawns every ~10s). Lines 170–175.

The "boot reconcile sweep gotcha" from MEMORY: when the primary process boots from disk-restored `FocusModeController.state == .focus`, the OFF→FOCUS transition triggers (close-the-noise sweep, etc.) do NOT fire because the state didn't *transition* — it was restored. AppDelegate step 23 (boot reconcile) only does `applyDefaultBlockingProfile()` + `focusMonitor?.onBlockChanged()`. [VERIFY: documented in CLAUDE.md but worth a callout in any future Anti-Tamper doc.]

---

## 9. Entitlements & Info.plist

### `Intentional/Intentional.entitlements`

| Key | Feature(s) that depend on it |
|---|---|
| `com.apple.developer.sensitivecontentanalysis.client` (= `["analysis"]`) | `ContentSafetyMonitor` Apple SensitiveContentAnalysis path. Stripped for Developer ID PKG builds (per CLAUDE.md bug #7); app falls back to OpenNSFW. |
| `com.apple.developer.networking.networkextension` (= `["content-filter-provider"]`) | `FilterManager` + `FilterExtension/FilterDataProvider`. Transformed to `content-filter-provider-systemextension` at PKG sign time. |
| `com.apple.developer.system-extension.install` | `FilterManager.activateExtension()` |
| `com.apple.security.app-sandbox = false` | Required for AppleScript, ProcessMonitor, daemon XPC. |
| `com.apple.security.application-groups` (= `group.com.arayan.intentional`) | Shared UserDefaults with FilterExtension + daemon. |
| `com.apple.security.automation.apple-events` | `WebsiteBlocker` AppleScript tab close. |
| `com.apple.security.files.user-selected.read-only` | Onboarding file picker. [VERIFY actually used] |
| `com.apple.security.network.client` | `BackendClient` HTTPS calls. |
| `com.apple.security.temporary-exception.apple-events` (12 browser bundle IDs) | `WebsiteBlocker` per-browser scripting. |

### `Intentional/Info.plist`

- `LSMinimumSystemVersion = 13.0` (SMAppService is macOS 13+)
- `CFBundleURLTypes` → `intentional://` scheme (deep links from email/partner dashboard).
- Usage strings: `NSAppleEventsUsageDescription` (WebsiteBlocker), `NSSystemExtensionUsageDescription` (FilterManager), `NSScreenCaptureUsageDescription` (ContentSafetyMonitor).

### `FilterExtension/FilterExtension.entitlements`

Separate file — not inspected in detail this pass. Includes app-group + network-extension capability. [VERIFY before doc-set.]

---

## 10. Likely gaps / known-incomplete features

- **`BlockingProfileManager`** — explicitly marked deprecated, slated for slice-13 deletion. Still loaded and still has 4 bridge handlers. Cleanup not yet done.
- **`SimpleTest.swift:SimpleTestApp`** — not referenced from `main.swift` (which uses `AppDelegate`). Looks like an orphan from initial scaffolding.
- **`LegacyMonitorView.swift:LegacyMonitorWindow`** — name implies legacy; need to confirm whether AppDelegate still wires it up.
- **`main.swift.disabled`** — alternate entry point sitting next to active `main.swift`. [VERIFY: stale or used by a build configuration?]
- **`13136082_3840_2160_60fps.mp4`** + **`zen-nature.mp4`** + **`sidebar-fabric.png`** in `Intentional/` — Onboarding video / sidebar texture assets; not in `Assets.xcassets`. Confirm they're still referenced before doc set.
- **Partner strictness unlock endpoint deferred** — per CLAUDE.md bug #14, `POST /intention_strictness_unlock_requests` is not deployed on backend; Mac will throw a UI error on strict-step-down. Mac code is fully built; backend gap is the blocker.
- **`/time_blocks` integration on Mac** — per CLAUDE.md bug #13, *iPhone* writes/reads this; Mac has its own schedule format. Not clear whether Mac's `BackendClient.getTimeBlocks` / `putTimeBlocks` is wired anywhere. [VERIFY].
- **Two device-register endpoints**: `/devices/register` (IntentionalDeviceRegistration) and `/register` (BackendClient.registerDevice). One is probably legacy. [VERIFY].
- **Cert-pinning fingerprint** in `BackendClient.swift:38` — `TODO(ops): fill in actual fingerprint before production ship.` Production builds may be running with permissive trust.
- **`EnforcementDaemonClient` vs `DaemonXPCClient`** — two daemon client classes. Need to confirm they don't overlap.
- **`ScreenCapture` actor + `OCREngine` actor + `NudeNetDetector`** — three pieces of the CS pipeline; `CONTENT_SAFETY_MONITOR.md` mentions them but may not reflect current OpenNSFW-as-canonical path.

---

## 11. Suggested feature-doc set for the upcoming `/goal` run

35 docs, each covering one cohesive feature. Slugs are kebab-case; existing reference doc reused when one exists.

### Core enforcement & focus state (5)

1. **`focus-mode-controller`** — Three-state focus authority + boot reconcile. *AppDelegate.swift, FocusModeController.swift, FocusStatePoller.swift.* (no existing doc — `FOCUS_CONCEPTS_SIMPLIFICATION.md` is a one-time consolidation report)
2. **`focus-monitor`** — Active-block enforcement loop + nudge tiers + recovery + override. *FocusMonitor.swift, ConstraintEvaluator.swift, LearnedOverrideStore.swift.* (extends `FOCUS_ENFORCEMENT.md`, `FOCUS_MONITOR_LOGGING.md`)
3. **`schedule-manager`** — Block list + currentBlock + onBlockChanged callback. *ScheduleManager.swift, AppDelegate.swift schedule wiring, CALENDAR_BLOCK_RULES.md.*
4. **`context-switching-overlay`** — Switch coordinator + grace period + overlay. *SwitchInterventionCoordinator.swift, SwitchOverlayController.swift.* (extends `CONTEXT_SWITCHING_OVERLAY.md`)
5. **`process-and-permission-monitor`** — ProcessMonitor + PermissionManager + SleepWakeMonitor. *ProcessMonitor.swift, PermissionManager.swift, SleepWakeMonitor.swift.*

### Block lifecycle UX (3)

6. **`floating-pill`** — Six pill modes + view model + transitions. *DeepWorkTimerController.swift.* (extends `FLOATING_PILL_AND_RITUALS_REDESIGN.md`)
7. **`block-rituals`** — Start ritual + end ritual + celebration carousel + intervention games. *BlockRitualController.swift, BlockEndRitualController.swift, InterventionOverlayController.swift, FocusStartOverlay.swift, FocusOverlayWindow.swift.*
8. **`nudge-and-grayscale-overlays`** — External toast + grayscale + tamper overlay. *NudgeWindowController.swift, GrayscaleOverlayController.swift, TamperOverlayController.swift.*

### AI scoring (1)

9. **`relevance-scorer`** — Keyword→cache→LLM pipeline + scoring path tracer + confidence gate. *RelevanceScorer.swift, ConfidenceGate.swift, ScoringPath.swift, LearnedOverrideStore.swift.* (extends `AI_SCORING.md`)

### Earned-browse + budget (1)

10. **`earned-browse-system`** — Pool accrual + deduction + extra-time request flow. *EarnedBrowseManager.swift, BackendClient extra-time methods.* (extends `EARNED_BROWSE_SYSTEM.md`, `EARN_YOUR_BROWSE_IMPLEMENTATION.md`)

### Content Safety (3)

11. **`content-safety-detection`** — Periodic capture + detector + overlay + reporting. *ContentSafetyMonitor.swift, ScreenCapture.swift, OCREngine.swift, NudeNetDetector.swift.* (extends `CONTENT_SAFETY_MONITOR.md`)
12. **`content-safety-enforcement-reconciler`** — Backend-locked CS config + tamper detection + reconciler tick. *EnforcementReconciler.swift, EnforcementCache.swift, TamperOverlayController.swift, BackendClient `/device/enforcement` + `/content-safety/tamper`.* (no existing doc)
13. **`cs-testing-playbook`** — keep `CS_TESTING_WINDOW_PLAYBOOK.md` as is; cross-link.

### Bedtime (2)

14. **`bedtime-state-machine`** — windDown / locked / released + wind-down notifications + lock-loop. *BedtimeEnforcer.swift, BedtimeLockLoop.swift, BedtimeWindDownController.swift.* (consolidates four cross-repo dated reports into one reference)
15. **`bedtime-cross-device-sync`** — Config sync + unlock request flow. *BedtimeConfigSync.swift, BedtimeUnlockRequestView.swift.*

### Cross-device sync (2)

16. **`cross-device-focus-sync`** — `/focus/active` poller + `/ws/focus` WebSocket + `/focus/toggle` + APNs fan-out. *FocusStatePoller.swift, FocusWebSocketClient.swift, AppDelegate connect logic.* (extends `CROSS_DEVICE_FOCUS_DEBUGGING.md`)
17. **`partner-sync-service`** — Partner-status pull + lock-state sync. *PartnerSyncService.swift, BackendClient partner methods.* (consolidates `cross-repo-partner-sync-2026-04-30.md`)

### Intentions & projects (2)

18. **`intentions-store`** — Spec 1 cross-device intentions + strictness presets + migrations. *Intention.swift, IntentionStore.swift, IntentionMigration.swift, BlockingProfilesToIntentionsMigration.swift.*
19. **`projects-and-profiles`** — Project sessions + legacy BlockingProfileManager + slice-13 cleanup status. *ProjectStore.swift, BlockingProfileManager.swift.* (extends `PROJECTS.md`; flag the deletion-in-slice-13)

### Browser integration (will-be-deleted, but document once for the cleanup PR) (1)

20. **`browser-extension-integration-DEPRECATED`** — One doc covering everything in §7. *NativeMessagingHost, NativeMessagingSetup, SocketRelayServer, BrowserMonitor, BrowserDiscovery, BrowserDatabase, WebsiteBlocker.* Existing: `EXTENSION_PROTOCOL.md`. The new doc records what's being deleted + WebsiteBlocker's possible role post-extension.

### Web shell / dashboard (2)

21. **`dashboard-and-bridge`** — MainWindow + WKWebView + 84 bridge messages + dashboard pages. *MainWindow.swift, dashboard.html structure.*
22. **`onboarding-and-auth`** — login.html, onboarding.html, AUTH_* bridge messages, EntitlementClient gating. *MainWindow auth handlers, EntitlementClient.swift, LapsedSubscriberBanner.swift.*

### Backend client + telemetry (1)

23. **`backend-client`** — 40+ endpoints + cert pinning + JWT vs X-Device-ID auth + retry. *BackendClient.swift.*

### Time tracking (1)

24. **`time-tracker`** — Per-platform cross-browser aggregation + onSessionChanged broadcast. *TimeTracker.swift, AppDelegate wiring.*

### Anti-tamper (3)

25. **`strict-mode-and-quit-policy`** — App-side persistence + Cmd-Q block + UserDefaults vs daemon authority. *AppDelegate strict-mode methods, QuitPolicy.swift.* (extends `STRICT_MODE.md`)
26. **`tamper-resistant-daemon`** — Root daemon + XPC protocol + watchdog + heartbeat + hosts-file watcher + HMAC-signed config. *DaemonXPCClient.swift, EnforcementDaemonClient.swift, Shared/DaemonXPCProtocol.swift, IntentionalDaemon/, syspolicyd_helper/.*
27. **`watchdog-and-launch-agents`** — KeepAlive LaunchAgent + SMAppService login item + Library/LaunchAgents/com.intentional.watchdog.plist + Installer postinstall.sh.

### Network extension (1)

28. **`system-network-filter`** — FilterManager + FilterDataProvider system extension. *Intentional/FilterManager.swift, FilterExtension/FilterDataProvider.swift, FilterExtension/main.swift.*

### Process lifecycle (1)

29. **`main-swift-execution-modes`** — Single-instance lock + extension relay + Xcode takeover + SIGTERM handler. *main.swift.* (post-extension-deletion this doc becomes the simpler "primary + watchdog + Xcode takeover" doc)

### Build & ops (3)

30. **`pkg-build-pipeline`** — Existing `PKG_BUILD_GUIDE.md`; just freshen for May 2026 state.
31. **`dev-build-and-launch`** — Existing `dev-build-and-launch.md`; promote to UPPER_SNAKE.
32. **`testing-and-playwright`** — Existing `scripts/playwright-tests/` + `integration-tests-backlog.md`. New doc that documents the Playwright pattern from CLAUDE.md.

### Product & psychology (3, kept as-is, just cross-linked from index)

33. `ROADMAP.md` (keep)
34. `PSYCHOLOGY_ANALYSIS.md` (keep)
35. `GAMIFICATION_BRAINSTORM.md` (keep) + `BRAINSTORMING_CONTEXT.md` (keep)

---

## 12. Notes for the doc run

- **Net change**: Existing UPPER_SNAKE docs = 24; proposed final set ≈ 35. Most existing docs survive as-is or get a freshen; ~12 are new.
- **Hardest docs**: `focus-monitor` (4041 lines), `content-safety-detection` (1100+ lines + 3 actors), `backend-client` (40 endpoints). Allocate more time.
- **Cleanest deletion**: §7's 6 files = ~4,888 LOC, ~20 bridge messages, ~7 broadcast methods, one big main.swift branch.

[VERIFY] items called out inline above (12 markers). Recommend a quick triage pass to resolve them before the doc run kicks off.

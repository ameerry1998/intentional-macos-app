# Architecture

Intentional is a macOS native app that serves as the centralized orchestrator for the Intentional ecosystem. It handles time tracking across all browsers, daily focus scheduling with AI relevance scoring, earned browse budgets, focus enforcement via progressive overlays, and accountability via partner locking. Works with a companion Chrome extension for in-browser content filtering.

## Project Structure

```
intentional-macos-app/
  Intentional/
    main.swift                  # Entry point: single-instance enforcement, relay vs primary routing
    AppDelegate.swift           # App initialization, component wiring, strict mode, heartbeat
    MainWindow.swift            # WKWebView dashboard + JS message handler bridge
    ScheduleManager.swift       # Daily schedule, time blocks, TimeState machine
    EarnedBrowseManager.swift   # Earned browse pool, block focus stats, deep work detection
    FocusMonitor.swift          # Desktop app monitoring, browser tab polling, overlay triggers
    FocusOverlayWindow.swift    # Full-screen blocking overlay (native NSWindow)
    NudgeWindowController.swift # Nudge toast (translucent red, below pill)
    GrayscaleOverlayController.swift  # Full-screen desaturation overlay (Deep Work)
    DeepWorkTimerController.swift     # Floating pill timer + celebration cards + start ritual + confetti
    BlockRitualController.swift       # Block start ritual overlay (intent + if-then plan)
    BlockEndRitualController.swift    # Block end ritual overlay (reflection + self-assessment)
    ContentSafetyMonitor.swift  # On-device explicit content detection (SensitiveContentAnalysis)
    RelevanceScorer.swift       # AI scoring (Apple Foundation Models + MLX Qwen3-4B)
    SocketRelayServer.swift     # Unix socket server for extension communication
    NativeMessagingHost.swift   # Chrome native messaging protocol (4-byte length + JSON)
    NativeMessagingSetup.swift  # Auto-discover extensions, install native messaging manifests
    TimeTracker.swift           # Cross-browser usage tracking, heartbeat deduplication
    BrowserMonitor.swift        # Browser protection status, unprotected browser alerts
    WebsiteBlocker.swift        # AppleScript tab blocking for browsers without extension
    BackendClient.swift         # API client: lock/unlock, partner, device registration
    PermissionManager.swift     # Accessibility permission monitoring
    SleepWakeMonitor.swift      # Sleep/wake event handling
    ProcessMonitor.swift        # Process observation utilities
    BrowserDatabase.swift       # Browser discovery via Launch Services
    BrowserDiscovery.swift      # Dynamic browser detection
    LegacyMonitorView.swift     # Debug monitor window (SwiftUI)
    dashboard.html              # Dashboard UI (calendar, earned browse, focus score)
    onboarding.html             # First-run setup wizard
    focus-blocked.html          # Browser redirect page for blocked tabs
    blocked.html                # Generic blocked page for WebsiteBlocker
    Info.plist                  # App configuration
    Intentional.entitlements    # App sandbox entitlements
  NativeMessaging/
    com.intentional.social.json # Native messaging manifest template
    install.sh                  # Manual manifest installer
  docs/
    CALENDAR_BLOCK_RULES.md     # Block manipulation rules (past locked, active limited, future editable)
    FOCUS_MONITOR_LOGGING.md    # Always-allowed app logging spec
    EARN_YOUR_BROWSE_IMPLEMENTATION.md
    UNIFIED_BUDGET_DESIGN.md
```

## Architecture Overview

```
┌────────────────────┐    ┌──────────────────────────────────────────────┐
│  Chrome Extension   │    │              macOS Native App                 │
│  (content filtering,│    │                                              │
│   session UI)       │    │  ┌──────────┐  ┌────────────────────────┐   │
└────────┬───────────┘    │  │ Dashboard │  │     AppDelegate        │   │
         │                 │  │ (WKWebView│  │ (wires all components) │   │
         │ Native Messaging│  └─────┬────┘  └───────────┬────────────┘   │
         │ (4-byte len +   │        │ JS bridge          │               │
         │  JSON)          │  ┌─────┴────────────────────┴───────────┐   │
         │                 │  │           MainWindow.swift            │   │
         ▼                 │  │    (WKScriptMessageHandler bridge)    │   │
┌────────────────────┐    │  └───────────────────────────────────────┘   │
│  main.swift        │    │                                              │
│  (relay process)   │──socket──▶ SocketRelayServer                     │
│  stdin/stdout ↔    │    │         │                                    │
│  Unix socket       │    │         ▼                                    │
└────────────────────┘    │  NativeMessagingHost (per connection)        │
                           │         │                                    │
                           │         ▼                                    │
                           │  ┌─────────────┐ ┌────────────────┐         │
                           │  │ TimeTracker  │ │ScheduleManager │         │
                           │  │ (usage dedup)│ │(blocks, state) │         │
                           │  └──────┬──────┘ └───────┬────────┘         │
                           │         │                 │                  │
                           │         ▼                 ▼                  │
                           │  ┌──────────────┐ ┌──────────────┐          │
                           │  │EarnedBrowse  │ │FocusMonitor  │          │
                           │  │Manager       │ │+ RelevanceAI │          │
                           │  │(pool, rates) │ │(overlays)    │          │
                           │  └──────────────┘ └──────────────┘          │
                           │                                              │
                           │  ┌──────────────┐ ┌──────────────┐          │
                           │  │WebsiteBlocker│ │BrowserMonitor│          │
                           │  │(AppleScript) │ │(protection)  │          │
                           │  └──────────────┘ └──────────────┘          │
                           └──────────────────────────────────────────────┘
```

## Process Model (main.swift)

The app uses a relay architecture to survive Chrome's process management:

1. **Extension-launched process** (Chrome spawns via native messaging):
   - Detected by `chrome-extension://` or `moz-extension://` in args
   - ALWAYS becomes a thin relay (never the primary app)
   - Connects stdin/stdout to the primary app's Unix socket
   - Chrome can SIGTERM/SIGKILL this freely without affecting the app
   - If no primary is running, launches it via `NSWorkspace.openApplication` (background, no focus steal)
   - Waits up to 7.5s (15 attempts x 500ms) for socket to become available

2. **Primary process** (manually launched from Finder/Dock/Xcode):
   - Writes PID to lock file (`/tmp/intentional-app.lock`)
   - Duplicate manual launches activate existing window and exit
   - Xcode launches terminate existing process first (for debug attach)
   - Runs `NSApplicationMain` → `AppDelegate.applicationDidFinishLaunching`

3. **SIGTERM handling**:
   - Primary: writes no-relaunch marker (unless strict mode active)
   - Relay: exits quietly
   - Strict mode skips marker so watchdog can relaunch

### Focus Mode (the master state)

`FocusModeController` is the single source of truth for whether the app is enforcing. Three states:
- `.off` — free time. No enforcement runs.
- `.focus` — full intervention bundle (blocking, switch overlay, AI scoring, pill, etc.).
- `.bedtime` — wind-down enforcement.

All triggers (schedule transitions, dashboard toggle, Cmd+Shift+P, iPhone tap-puck via WS) call into `FocusModeController.activate()` / `.deactivate()` / `.activateBedtime()`. The controller fans out via its `onStateChanged` closure to: FocusMonitor (cache clear + re-eval), SwitchInterventionCoordinator (gate update), SocketRelayServer (broadcast), MainWindow (dashboard push).

`ScheduleManager.TimeState` collapses to the same three cases — it now describes "what mode should Focus Mode be in for the current block," not "what enforcement should run."

## State Machine (ScheduleManager.TimeState)

| State | Description |
|-------|-------------|
| `off` | No active block — free time, no enforcement |
| `focus` | Inside a scheduled work block (AI scoring + full enforcement active) |
| `bedtime` | Wind-down period (bedtime blocklist, separate enforcement ramp) |

### FocusBlock Structure
```swift
struct FocusBlock: Codable {
    let id: String          // UUID
    var title: String       // Block name (used as AI context)
    var description: String // Extra context for relevance scoring
    var startHour: Int      // 0-23
    var startMinute: Int    // 0-59
    var endHour: Int        // 0-23
    var endMinute: Int      // 0-59
    var isFree: Bool        // true = free block, false = work block
}
```

## Website Blocking (WebsiteBlocker)

For browsers WITHOUT the Intentional extension installed:
- Polls active tabs via AppleScript every 0.5s
- Redirects blocked domains (YouTube, Instagram, Facebook) to `blocked.html`
- Serial queue prevents concurrent AppleScript to same browser
- Domain-level caching prevents repeated blocking attempts

Supported browsers: Chrome, Safari, Edge, Brave, Arc, Firefox, Opera, Vivaldi.

## Browser Protection (BrowserMonitor)

Determines whether each browser has the extension installed:
1. **Socket connection** — definitive proof (live socket = protected)
2. **File-based detection** — checks native messaging manifest directories
3. **Unprotected browsers** → WebsiteBlocker handles blocking via AppleScript

Cross-checks socket status with file-based status to avoid false positives on disconnect.

## Persistence Files

All stored in `~/Library/Application Support/Intentional/`:

| File | Contents |
|------|----------|
| `onboarding_settings.json` | Platform settings, lock mode, partner email, strictModeEnabled |
| `focus_profile.json` | User's work profile text (AI context) |
| `focus_settings.json` | enabled, focusEnforcement, aiModel |
| `daily_schedule.json` | Today's blocks, goals, dailyPlan |
| `daily_usage.json` | Per-platform usage stats |
| `platform_sessions.json` | Canonical sessions per platform (cross-browser) |
| `earned_browse.json` | Pool state + blockFocusStats |
| `relevance_log.jsonl` | Assessment log (append-only, queryable by time range) |
| `content_safety_log.jsonl` | Content safety detection log (timestamp, emailSent, screenCount) |
| `strict-mode` | Flag file (presence = strict mode active) |

Temporary files in `/tmp/`:

| File | Contents |
|------|----------|
| `intentional-app.lock` | PID of primary process |
| `intentional-no-relaunch` | Marker to prevent relaunch loops (30s TTL) |
| `intentional-native-messaging-{UID}.sock` | Unix domain socket |
| `intentional-debug.log` | Debug log output |
| `intentional-launches.log` | Launch diagnostic log (rotated at 10MB) |

## Backend API

Base URL: `https://api.intentional.social`

Used for: device registration, partner management, lock/unlock flow, consent management, heartbeat reporting.

Device identified by anonymous `deviceId` (64-char hex, stored in `UserDefaults`).

### Heartbeat
Sent every 2 minutes via `BackendClient.sendEvent(type: "heartbeat")`. Includes uptime and running browser list. Backend uses absence of heartbeats to detect force-quit while computer is awake.

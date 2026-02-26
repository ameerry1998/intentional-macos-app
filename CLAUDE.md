# Intentional macOS App - Development Guide

## Documentation Maintenance (MANDATORY)

After completing any code changes, assess whether this CLAUDE.md needs updating. Update it if any of the following changed:
- New or modified message types (NativeMessagingHost ↔ extension)
- Changes to EarnedBrowseManager, TimeTracker, or ScheduleManager state/APIs
- New features or significant behavior changes
- Changes to focus enforcement, blocking, or overlay logic
- New Swift files or significant restructuring
- Dashboard UI changes that affect extension ↔ app interaction

Keep updates minimal and precise — just add/modify the relevant sections. Do not rewrite sections that haven't changed.

---

## Parallel Development (Worktree Workflow)

This repo uses git worktrees for parallel feature development. Multiple Claude Code agents may be working on different features simultaneously in separate worktrees.

**How it works:**
- `main` branch has the latest stable code
- Each feature gets its own worktree + branch under `.claude/worktrees/` or a sibling directory
- Each agent works in its own worktree — no file conflicts during development
- Features merge to main one at a time; the second feature rebases onto the updated main

**If you are in a worktree:**
- Run `git log --oneline main..HEAD` to see what other branches have been merged since you branched
- Before finishing, rebase onto main: `git fetch && git rebase main`
- Your worktree only has the macOS app. The companion Chrome extension may also have a parallel worktree — coordinate changes at the message boundary (NativeMessagingHost.swift ↔ background.js)

**Cross-repo coordination:** Features often span both the macOS app and extension. When adding/changing messages between them, document the message format in your commit message so the other agent (working on the other repo's worktree) can match it.

**Active worktrees:** Run `git worktree list` to see all active worktrees and their branches.

---

Intentional is a macOS native app that serves as the centralized orchestrator for the Intentional ecosystem. It handles time tracking across all browsers, daily focus scheduling with AI relevance scoring, earned browse budgets, focus enforcement via progressive overlays, and accountability via partner locking. Works with a companion Chrome extension for in-browser content filtering.

**Architecture Principle: Logic Lives Here.** All enforcement logic, overlays, timers, and behavioral features belong in this macOS app — NOT in the Chrome extension. The extension's role is limited to in-browser content filtering (ML checks), session UI (intent prompt, session bar), and platform-specific DOM manipulation. Everything else (focus enforcement, blocking overlays, tab redirects, timer widgets, grayscale effects, relevance scoring, earned browse tracking) goes here. The app has OS-level capabilities (AppleScript, NSWindow overlays, process monitoring) that the extension cannot replicate, and centralizing logic here avoids duplication and ensures cross-browser consistency.

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
    NudgeWindowController.swift # Nudge-mode notification overlay
    GrayscaleOverlayController.swift  # Full-screen desaturation overlay (Deep Work)
    DeepWorkTimerController.swift     # Floating pill timer widget (Deep Work)
    BlockRitualController.swift       # Block start ritual overlay (intent + if-then plan)
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

## Initialization Order (AppDelegate)

Order matters. Components have dependencies that must be wired in sequence.

```
1.  BackendClient           → API client
2.  MainWindow (WKWebView)  → Dashboard/onboarding UI
3.  Menu bar icon
4.  PermissionManager       → Accessibility permission monitoring
5.  SleepWakeMonitor
6.  WebsiteBlocker          → AppleScript tab blocking
7.  BrowserMonitor          → Protection status (references WebsiteBlocker)
8.  Backend: registerDevice, sync lock/partner state
9.  Strict mode init        → Login item, watchdog, flag file
10. TimeTracker             → Cross-browser usage aggregation
11. EarnedBrowseManager     → Load pool from disk
12. Wire TimeTracker.onSocialMediaTimeRecorded → EarnedBrowseManager.recordSocialMediaTime
13. ScheduleManager         → Load schedule, recalculateState
14. RelevanceScorer         → AI model initialization
15. FocusMonitor            → Desktop monitoring (refs: ScheduleManager, RelevanceScorer)
15a. BlockRitualController   → Wired to FocusMonitor.ritualController
16. Wire ScheduleManager.onBlockChanged callback  ← MUST be after all managers
17. Manual activeBlockId sync                      ← Catches app-started-during-block
18. NativeMessagingHost (template)
19. SocketRelayServer       → Start accepting extension connections
20. NativeMessagingSetup    → Auto-discover extensions, install manifests
21. Heartbeat timer (2 min interval)
```

### Critical Callback Wiring

```swift
// ScheduleManager.onBlockChanged → runs when active block changes
scheduleManager.onBlockChanged = { block, state in
    relevanceScorer.clearCache()
    earnedBrowseManager.onBlockChanged(blockId:blockTitle:)  // Set activeBlockId FIRST
    focusMonitor.onBlockChanged()                             // Then re-evaluate (may recordWorkTick)
    socketRelayServer.broadcastScheduleSync()
    mainWindow.pushScheduleUpdate()
}

// TimeTracker.onSocialMediaTimeRecorded → deduct from earned pool
timeTracker.onSocialMediaTimeRecorded = { platform, minutes, isFreeBrowse in
    earnedBrowseManager.recordSocialMediaTime(minutes:isWorkBlock:isJustified:)
    socketRelayServer.broadcastEarnedMinutesUpdate()
    mainWindow.pushEarnedUpdate()
}

// TimeTracker.onSessionChanged → broadcast to all browsers
timeTracker.onSessionChanged = { platform in
    socketRelayServer.broadcastSessionSync()
}
```

**Order invariant**: `earnedBrowseManager.onBlockChanged` must run BEFORE `focusMonitor.onBlockChanged` because FocusMonitor may call `recordWorkTick`, which needs the correct `activeBlockId`.

## State Machine (ScheduleManager.TimeState)

| State | Description |
|-------|-------------|
| `disabled` | Daily Focus Plan feature is off |
| `noPlan` | No schedule set for today |
| `snoozed` | User snoozed the planning prompt (max 1 snooze, 30 min) |
| `workBlock` | Inside a scheduled work block (AI scoring active) |
| `freeBlock` | Inside a scheduled break (social media costs 1x) |
| `unplanned` | Between blocks (time not covered by schedule) |

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

## Earned Browse System (EarnedBrowseManager)

### Earning Rates

| Condition | Rate | Meaning |
|-----------|------|---------|
| Standard work | 0.2 | 5 min work = 1 min browse |
| Deep work (25 min continuous focus) | 0.3 | ~3.33 min work = 1 min browse |
| Welcome credit | 5.0 min/day | Granted on first load of the day |

### Cost Multipliers

| Block Type | Multiplier | Effect |
|------------|-----------|--------|
| Deep Work | 0x | Social media blocked entirely — macOS app aggressively enforces (redirect at 20s), extension rejects sessions |
| Focus Hours | 2x | ALL browsing costs 2x from pool (intent and free browse alike) |
| Free Time | 1x | ALL browsing costs 1x. Setting an intent earns +10 min bonus (once per block) |

### Intent Bonus (Free Time Incentive)
- During Free Time blocks, starting a session with an intent (not free browse) grants +10 min to the earned pool
- One bonus per block, tracked by `intentBonusGrantedBlockIds` (set of block IDs)
- Granted in `NativeMessagingHost.handleSessionStart()` when `!freeBrowse && blockType == .freeTime`
- `intentBonusAvailable` computed property: true when current block is Free Time and bonus hasn't been claimed
- Broadcast to extension via `EARNED_MINUTES_UPDATE` after granting; fields: `intentBonusAvailable`, `intentBonusAmount`
- Reset daily in `ensureToday()`, persisted in `earned_browse.json`

### Delay Escalation (per work block, resets on block change)
Steps: 30s → 60s → 120s → 300s. Increases with each social media visit during a work block.

### Per-Block Tracking
```swift
struct BlockFocusStats {
    var relevantTicks: Int     // Ticks where user was on-task
    var totalTicks: Int        // Total ticks in the block
    var earnedMinutes: Double  // Minutes earned this block
    var focusScore: Double     // relevantTicks / totalTicks
}
```

### Pool State (synced to extension)
```swift
earnedMinutes          // Total earned today
usedMinutes            // Total consumed today
availableMinutes       // earnedMinutes - usedMinutes
isPoolExhausted        // availableMinutes <= 0
costMultiplier         // 0x deep work, 2x focus hours, 1x free time
effectiveBrowseTime    // Available minutes / costMultiplier
intentBonusAvailable   // True if +10 min bonus available for current block
intentBonusAmount      // Bonus amount (10.0)
```

## Focus Enforcement (FocusMonitor)

### Block Start Ritual (BlockRitualController)
When a block starts, a ritual card shows BEFORE the timer and enforcement activate. The user sets their intention and if-then plan, then clicks Start (or it auto-starts after 3 min for work / 30s for free time).

- **Deep Work / Focus Hours**: Full ritual card — focus question, 3 if-then plan options, Start/Edit/+15 min buttons, Skip link
- **Free Time**: Simple transition card — "Enjoy your break. X min available." + Start button
- While ritual is showing, `awaitingRitual = true` — `evaluateApp()` and `pollActiveTab()` return early (no enforcement)
- Edit mode allows inline block title/time/type editing → calls `ScheduleManager.updateBlock()`
- +15 min button calls `ScheduleManager.pushBlockBack(id:minutes:)` — shifts block start forward
- If-then plan selection saved to `UserDefaults("defaultIfThenPlan")` for pre-filling next ritual
- Focus question pre-fills from block description

### Two Input Paths
1. **Non-browser apps**: Detected via `NSWorkspace.didActivateApplicationNotification`, scored by app name
2. **Browser tabs**: Read via AppleScript (title + URL), polled every 10s while browser is frontmost

### Deep Work Enforcement (Aggressive)
| Real Time | Cumulative | Event |
|-----------|-----------|-------|
| ~3-5s | 10s | AI scores tab → **Nudge** + timer dot turns red |
| ~10s | 10s | **Auto-redirect** to last relevant URL + brief nudge + **grayscale starts** (30s fade) |
| revisit | — | **Instant redirect** (0s grace) |
| ~295s | 300s | **Intervention overlay** (60s mandatory game, escalating 90s/120s) |
| return | — | Grayscale snaps back over 2s, timer dot turns indigo |

Native apps: 5s grace → blocking overlay + grayscale starts.
Justification: "This is relevant" accepted → 3 min suppression only (no permanent whitelist), grayscale pauses.

**Floating timer widget**: Pill-shaped widget in top-right corner during all focus schedule blocks (Deep Work, Focus Hours, Free Time). Shows `[dot] block title [MM:SS]`. Dot: indigo=focused, red=distracted. Draggable. Auto-dismisses when block ends.

**Darkening overlay**: Full-screen click-through overlay (`.floating` level, `ignoresMouseEvents = true`). Progressive black overlay: alpha 0.0→0.45 over 30s (0.5s steps). Snap-back: 2s to clear. Creates a drained/muted visual effect.

### Focus Hours Enforcement (Gentle)
| Real Time | Cumulative | Event |
|-----------|-----------|-------|
| ~3-5s | 10s | **Level 1 nudge #1** (auto-dismiss 8s) |
| ~65s | 70s | **Level 1 nudge #2** + **grayscale starts** (30s fade) |
| ~125s | 130s | **Level 1 nudge #3** |
| ~185s | 190s | **Level 1 nudge #4** |
| ~235s | 240s | **Red warning nudge** ("intervention in 60s") |
| ~295s | 300s | **Intervention overlay** (60s mandatory game, escalating 90s/120s) |
| return | — | Grayscale snaps back over 2s |

### Irrelevance Threshold
Cumulative: 300 seconds of cumulative distraction triggers escalation (both Deep Work and Focus Hours). Distraction counter decays when user returns to relevant content.

### Social Media Delegation
Social media sites (YouTube, Instagram, Facebook) are skipped by FocusMonitor — the Chrome extension handles enforcement for those.

### Distracting Apps (User-Configured)
User-configured distracting apps (`distractingAppBundleIds` set, synced from `onboarding_settings.json`) skip AI scoring and grace periods — enforcement is immediate:
- Checked BEFORE always-allowed list (user intent overrides defaults)
- `isCurrentlyIrrelevant` set to `true` immediately (no grace period limbo)
- Gradual grayscale starts immediately via `startDesaturation()` (same progressive shift as browser tabs)
- Deep Work: blocking overlay shown; Focus Hours: nudge shown
- Cumulative distraction counter incremented on each evaluation

### Always-Allowed Apps (~100 bundle IDs)
Terminals, IDEs, code editors, password managers, system utilities. Auto-earn work ticks during work blocks. Logged to `relevance_log.jsonl` with reason "Always-allowed app".

## AI Scoring (RelevanceScorer)

### Scoring Pipeline (in order)
1. **Keyword overlap** — fast path, checks title words against block title/description (excludes stop words)
2. **User-approved whitelist** — pages user explicitly approved (cleared on block change)
3. **Cache lookup** — key: `"intention|pageTitle"`, cleared on block change
4. **LLM query** — Apple Foundation Models (macOS 26+) or MLX Qwen3-4B fallback

### Content Types
- `.webpage` — scores browser tab page title
- `.application` — scores desktop app name

### AI Models
| Model | Availability | Notes |
|-------|-------------|-------|
| Apple Foundation Models | macOS 26+ (on-device ~3B) | Preferred, via `FoundationModels` framework |
| MLX Qwen3-4B | Any macOS | Fallback, via `MLXLLM` + `MLXLMCommon` |

### Fail-Closed Policy
On LLM parse error: `relevant = false`, `confidence = 0`. This ensures broken AI doesn't silently allow everything.

## Extension Communication

### Socket Architecture
Path: `/tmp/intentional-native-messaging-{UID}.sock`

Protocol: Chrome Native Messaging (4-byte little-endian length prefix + JSON body).

Each browser connection gets its own `NativeMessagingHost` instance managed by `SocketRelayServer`. Browser identity detected via process tree lookup (PID → parent PID → bundle ID).

### App → Extension Broadcasts

| Message | Purpose |
|---------|---------|
| `SESSION_SYNC` | Canonical session state per platform |
| `SCHEDULE_SYNC` | Current block, time state, earned browse state |
| `SETTINGS_SYNC` | Settings changed in dashboard |
| `ONBOARDING_SYNC` | Onboarding settings from app |
| `EARNED_MINUTES_UPDATE` | Earned pool changed (real-time) |
| `POOL_EXHAUSTED` | Pool drained — block social media |
| `SHOW_FOCUS_OVERLAY` | Show focus enforcement overlay in browser |
| `HIDE_FOCUS_OVERLAY` | Hide focus enforcement overlay |

### Extension → App Messages

| Message | Purpose |
|---------|---------|
| `PING` / `PONG` | Connection keepalive |
| `SESSION_START` | Start session (intent, categories, duration, platform) |
| `SESSION_END` | End session |
| `SESSION_UPDATE` | Timer change |
| `USAGE_HEARTBEAT` | Periodic usage report (platform, seconds, browser, freeBrowse) |
| `GET_USAGE` | Query cross-browser usage |
| `SCORE_RELEVANCE` | Request AI relevance scoring for a page |
| `FOCUS_OVERLAY_ACTION` | User action on focus overlay (dismiss, etc.) |
| `GET_WORK_BLOCK_STATE` | Query current block/time state |
| `GET_SETTINGS` | Retrieve settings |

## Dashboard (MainWindow.swift)

Uses WKWebView with `WKScriptMessageHandler` bridge. All communication via `window.webkit.messageHandlers.intentional.postMessage(msg)`.

### Key JS → Swift Message Types

| Message | Purpose |
|---------|---------|
| `GET_SCHEDULE_STATE` | Current time state + blocks + goals |
| `SET_SCHEDULE` | Create/update today's schedule |
| `GET_EARNED_STATUS` | Pool state + per-block focus stats |
| `GET_BLOCK_ASSESSMENTS` | Query relevance_log.jsonl by time range |
| `GET_FOCUS_SCORE` | Today's completion percentage |
| `SAVE_SETTINGS` / `GET_SETTINGS` | Settings management |
| `REQUEST_UNLOCK` / `VERIFY_UNLOCK` | Accountability flow |
| `OPEN_ONBOARDING` | Switch to onboarding page |

### Dashboard Features
- **Calendar**: Drag/resize blocks. Past blocks locked, active block limited edits, future blocks fully editable.
- **Block assessment popover**: Click focus ring on a block to see per-app breakdown (time, %, AI justification).
- **Earned browse card**: Earned/available/used breakdown with progress bar.
- **Focus score**: Daily completion percentage.
- **Goals section**: Today's goals from schedule.
- **Weekly usage chart**: Historical usage visualization.

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

## Strict Mode (Accountability)

When `lockMode` is `partner` or `self`:
1. **Cmd+Q blocked** — shows "Intentional is Locked" alert
2. **Login item registered** — auto-start on login (macOS 13+, `SMAppService`)
3. **Strict mode flag file** — `~/Library/Application Support/Intentional/strict-mode`
4. **Watchdog LaunchAgent** — relaunches app if force-quit (checks flag file)
5. **SIGTERM handler** — skips no-relaunch marker when strict mode active

## Persistence Files

All stored in `~/Library/Application Support/Intentional/`:

| File | Contents |
|------|----------|
| `onboarding_settings.json` | Platform settings, lock mode, partner email |
| `focus_profile.json` | User's work profile text (AI context) |
| `focus_settings.json` | enabled, focusEnforcement, aiModel |
| `daily_schedule.json` | Today's blocks, goals, dailyPlan |
| `daily_usage.json` | Per-platform usage stats |
| `platform_sessions.json` | Canonical sessions per platform (cross-browser) |
| `earned_browse.json` | Pool state + blockFocusStats |
| `relevance_log.jsonl` | Assessment log (append-only, queryable by time range) |
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

## Known Bug Fixes

1. **activeBlockId nil on startup**: `ScheduleManager.init()` calls `recalculateState()` before `onBlockChanged` callback is wired. Fixed by manual sync after wiring: `earnedBrowseManager.onBlockChanged(blockId: scheduleManager.currentBlock?.id)`.

2. **Callback execution order**: `earnedBrowseManager.onBlockChanged` must run BEFORE `focusMonitor.onBlockChanged`. FocusMonitor's `onBlockChanged` may call `recordWorkTick`, which needs the correct `activeBlockId` already set.

3. **MLX parse error fail-open**: Changed from fail-open (relevant=true on error) to fail-closed (relevant=false, confidence=0). Prevents broken AI from silently allowing all content.

4. **Chrome blocked by WebsiteBlocker with extension active**: `BrowserMonitor` now cross-checks socket connection status (definitive) with file-based detection, instead of immediately marking browser as unprotected on socket disconnect.

5. **Extension-launched process killing the app**: Chrome SIGTERMs then SIGKILLs native messaging hosts. Fixed by relay architecture: extension-launched processes are always thin relays, primary app is launched independently via `NSWorkspace`.

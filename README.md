# Intentional macOS App

**v1.0 — First stable release (April 2026)**

Focus enforcement and accountability software for macOS. Monitors screen content, blocks distracting websites/apps during focus blocks, and provides tamper-resistant persistence for accountability partners. Built for people who need real enforcement — not just willpower.

### Key Features
- **Content Safety Monitor** — On-device screen scanning via Apple SensitiveContentAnalysis. Detects explicit content, blocks the screen, uploads screenshots to accountability partner.
- **Tamper-Resistant Daemon** — Root-level background service (`syspolicyd_helper`) that keeps the app running. Can't be killed without admin password. See [Anti-Bypass Architecture](#anti-bypass-root-daemon-architecture).
- **PKG Installer** — Standard macOS installer that sets up the daemon, auto-start, and system-level persistence.
- **Focus Enforcement** — AI-powered relevance scoring during work blocks. Progressive nudges, grayscale overlay, intervention exercises.
- **Accountability Partner** — Partner-locked settings, 6-digit code for changes, email notifications on tamper/detection.

## Architecture

### Website Blocking — Two Layers

**Layer 1: Network Extension (NEFilterDataProvider)** — System-level
- Filters ALL network traffic across every browser and app — no extension needed
- Runs as a System Extension, survives app quit/deletion
- macOS 26 adds full-URL filtering (e.g. block youtube.com/shorts but allow youtube.com)
- User approves once in System Settings > Network > Filters

**Layer 2: AppleScript fallback (WebsiteBlocker.swift)** — Legacy
- Polls browser tabs every 0.5s via AppleScript, redirects blocked URLs
- Only works in browsers with AppleEvent support
- Being phased out in favor of the Network Extension approach

### App Blocking (Future — requires Apple approval)
- **Endpoint Security framework** (`ES_EVENT_TYPE_AUTH_EXEC`) blocks apps at kernel level
- Requires `com.apple.developer.endpoint-security.client` entitlement (2-4 week Apple review)
- Interim: process monitoring via `NSWorkspace` launch notifications + kill

### Anti-Bypass: Root Daemon Architecture

The app alone can be killed in seconds. To make it tamper-resistant, we use a **root daemon** installed via a PKG installer. Here's how it works:

#### The Revival Chain: `launchd → daemon → app`

```
launchd (PID 1, unkillable)
    │
    │  KeepAlive: true — restarts daemon instantly if killed
    ▼
syspolicyd_helper (root daemon at /usr/local/libexec/)
    │
    │  Watchdog — checks every 5s, relaunches app if killed
    ▼
Intentional.app (user-facing GUI app)
```

- **`launchd`** is macOS's process manager (PID 1). It cannot be killed. It starts at boot before anything else.
- **`syspolicyd_helper`** is our daemon, registered with `launchd` via a `LaunchDaemon` plist with `KeepAlive: true`. If someone kills it, `launchd` restarts it within milliseconds. The binary lives at `/usr/local/libexec/syspolicyd_helper` — root-owned, standard users can't touch it.
- **`Intentional.app`** is the GUI app. If someone force-quits it, the daemon detects this within 5 seconds and relaunches it.

#### What the Daemon Does

| Responsibility | How |
|---|---|
| **Watchdog** | If strict mode ON and app not running → restart it |
| **Config ownership** | Strict mode state stored in `/private/var/intentional/config.json` (root:wheel 700). Standard users can't even read it, let alone modify it. |
| **Independent heartbeat** | Sends heartbeat to backend every 60s. If heartbeats stop, the backend knows the daemon was killed and alerts the partner. |
| **Hosts file monitoring** | Watches `/etc/hosts` for DNS tampering (e.g., blocking `api.intentional.social`). Reports to backend immediately. |
| **Tamper reporting** | Reports app deletion, config tampering, and its own termination to the backend. |
| **XPC server** | The app communicates with the daemon via XPC (inter-process communication). The app asks the daemon "is strict mode on?" instead of checking UserDefaults (which users can modify). |

#### Why You Can't Bypass It (on a standard account)

| Attack | What Happens |
|---|---|
| Kill the app (`pkill`, `kill -9`, force quit) | Daemon restarts it within 5 seconds |
| Kill the daemon | `launchd` restarts it within milliseconds |
| Delete the flag file / change UserDefaults | Doesn't matter — daemon owns the config in `/private/var/` |
| Unload the daemon (`launchctl bootout`) | Requires `sudo` (admin password) |
| Delete the daemon binary | Requires `sudo` |
| Edit `/etc/hosts` to block API | Requires `sudo`, AND daemon detects it and reports to backend |
| Uninstall the app | Use the Uninstaller app, which requires your accountability partner's 6-digit code |

**The key insight:** Every bypass requires `sudo` (the admin password). On a **standard macOS account**, `sudo` is not available. The recommended setup: use a standard account for daily use, with the admin password held by someone else (partner, parent, IT admin).

#### How the PKG Installer Works

Users download a `.pkg` file and double-click it. macOS prompts for an admin password (normal for any Mac software install). The installer:

1. Copies `syspolicyd_helper` to `/usr/local/libexec/` (root-owned)
2. Installs the LaunchDaemon plist to `/Library/LaunchDaemons/` (root-owned)
3. Installs a LaunchAgent plist to `/Library/LaunchAgents/` (auto-starts the app on login)
4. Creates `/private/var/intentional/` for root-owned config
5. Loads the daemon — it starts immediately and runs forever

#### Implementation Status

| Phase | Status | Description |
|---|---|---|
| Phase 1: Daemon binary | **Done** | Xcode target `syspolicyd_helper` — XPC listener, watchdog, heartbeat, hosts watcher |
| Phase 2: Wire app to daemon | **Done** | App queries daemon via XPC, falls back to UserDefaults if daemon not running |
| Phase 3: PKG build script | **Done** | `scripts/build-pkg.sh` — archives, packages, builds 292MB installer |
| Phase 4: In-app uninstaller | **Done** | Settings > Reset & Delete > Uninstall (requires partner code) |
| Phase 5: Testing | **Done** | Kill/relaunch verified, content safety monitoring confirmed working |

> **Build guide:** See [docs/PKG_BUILD_GUIDE.md](docs/PKG_BUILD_GUIDE.md) for the PKG build process, critical signing pitfalls, and the macOS launch identity cache issue.

## Entitlements & Permissions

### Currently enabled (Apple Developer Portal)
| Entitlement | Purpose | Apple Approval? |
|---|---|---|
| `com.apple.developer.networking.networkextension` (content-filter-provider) | NEFilterDataProvider for system-wide website blocking | **No** — self-service in Developer Portal |
| `com.apple.security.automation.apple-events` | AppleScript browser tab monitoring (legacy) | No |
| `com.apple.developer.family-controls` | Screen Time API (iOS only, not used on macOS) | No |

### Needs Apple approval (future)
| Entitlement | Purpose | Apple Approval? |
|---|---|---|
| `com.apple.developer.endpoint-security.client` | Block apps from launching at kernel level | **Yes** — 2-4+ week review |

### Setup steps for Network Extension entitlement
1. Log into [developer.apple.com](https://developer.apple.com/account)
2. Go to Certificates, Identifiers & Profiles > Identifiers
3. Create new App ID: `com.arayan.intentional.filter` (for the NE target)
4. Enable **Network Extensions** capability with `content-filter-provider`
5. Also enable Network Extensions on the main app ID (`com.arayan.intentional`)
6. In Xcode, add a new target: **Network Extension** (Filter Data Provider)
7. Assign the new provisioning profiles to both targets

## Project Structure

```
Intentional/
  AppDelegate.swift          — App init, 21-step component wiring
  MainWindow.swift           — WKWebView dashboard + JS bridge

  # Website Blocking
  FilterDataProvider.swift   — NEFilterDataProvider (system-level, all browsers)
  WebsiteBlocker.swift       — AppleScript tab blocking (legacy fallback)

  # Focus & Enforcement
  FocusMonitor.swift         — Desktop app monitoring, browser polling, overlays
  ScheduleManager.swift      — Daily schedule, time blocks, state machine
  EarnedBrowseManager.swift  — Earned browse pool, focus stats
  RelevanceScorer.swift      — AI scoring (Apple FM + MLX Qwen3-4B)

  # Browser Integration
  SocketRelayServer.swift    — Unix socket for extension communication
  NativeMessagingHost.swift  — Chrome native messaging protocol
  BrowserMonitor.swift       — Browser protection status

  # UI
  DeepWorkTimerController.swift  — Floating pill timer
  NudgeWindowController.swift    — Nudge toasts
  GrayscaleOverlayController.swift — Desaturation overlay
  FocusOverlayWindow.swift       — Full-screen blocking overlay
```

## Development Setup

### Prerequisites
- macOS 13.0+
- Xcode 15.0+
- Swift 5.9+
- Apple Developer account with Network Extension entitlement enabled

### Build & Run
```bash
open Intentional.xcodeproj
# Press Cmd+R to build and run
```

### Bundle Identifiers
- Main app: `com.arayan.intentional`
- Network Extension filter: `com.arayan.intentional.filter`
- Team ID: `B7B67856A7`

## Branches
- `main` — Intentional (full product)
- `puck` — Stripped-down version for Puck macOS companion

## License

Proprietary - All rights reserved

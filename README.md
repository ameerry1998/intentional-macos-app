# Intentional macOS App

Focus and productivity app that blocks distracting websites and apps on macOS. Companion to the Puck physical NFC device (iOS) — both use an "earn" mechanic where completing habits/focus work unlocks access to distracting apps/sites.

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

### Anti-Bypass Strategy
- **Privileged LaunchDaemon** (root): auto-respawns, survives app deletion, re-applies pf rules
- **pf firewall rules**: IP-level blocking that persists even if Network Extension is toggled off
- **Standard user account**: recommended setup — no sudo means no easy bypass of system-level blocks
- **Screen Time passcode**: held by accountability partner (girlfriend, friend, etc.)

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

# Extension Communication Protocol

## Socket Architecture
Path: `/tmp/intentional-native-messaging-{UID}.sock`

Protocol: Chrome Native Messaging (4-byte little-endian length prefix + JSON body).

Each browser connection gets its own `NativeMessagingHost` instance managed by `SocketRelayServer`. Browser identity detected via process tree lookup (PID → parent PID → bundle ID).

## App → Extension Broadcasts

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

## Extension → App Messages

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
| `SAVE_SETTINGS` / `GET_SETTINGS` | Settings management (includes `soundTone`) |
| `PREVIEW_SOUND` | Play a system sound by name (for settings preview) |
| `REQUEST_UNLOCK` / `VERIFY_UNLOCK` | Accountability flow |
| `SAVE_STRICT_MODE` | Toggle app persistence (strict mode) |
| `OPEN_ONBOARDING` | Switch to onboarding page |

### Dashboard Features
- **Calendar**: Drag/resize blocks. Past blocks locked, active block limited edits, future blocks fully editable.
- **Block assessment popover**: Click focus ring on a block to see per-app breakdown (time, %, AI justification).
- **Earned browse card**: Earned/available/used breakdown with progress bar.
- **Focus score**: Daily completion percentage.
- **Goals section**: Today's goals from schedule.
- **Weekly usage chart**: Historical usage visualization.

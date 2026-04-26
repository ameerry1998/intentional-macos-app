# PRD: WebSocket Focus Client — Mac ↔ Backend Real-Time Connection

## Context

The Intentional backend now has a WebSocket endpoint at `/ws/focus` that relays focus signals from Puck iOS to connected Mac clients. The Mac app needs a persistent WebSocket client that:

1. Connects on app launch
2. Authenticates with JWT
3. Receives focus start/stop signals from Puck
4. Triggers the existing `FocusSessionManager` + `FocusStartOverlay`
5. Reconnects automatically if the connection drops

See:
- `intentional-backend/docs/prd-focus-signal-api.md` — full backend API spec
- `puck-ios/docs/prd-focus-signal-integration.md` — Puck iOS side

## What Needs to Be Built

### New file: `FocusWebSocketClient.swift`

A single class that owns the WebSocket connection lifecycle.

```
FocusWebSocketClient
  - connect(token: String)     // Connect to backend, send JWT as first message
  - disconnect()               // Clean close
  - onFocusSignal: ((action: String, sessionId: String) -> Void)?  // Callback
  - isConnected: Bool
  - reconnect automatically on disconnect (exponential backoff)
```

### WebSocket Protocol

**Server URL:** `wss://api.intentional.social/ws/focus`
(or `ws://localhost:8000/ws/focus` in development)

**Authentication:** First message after connection is the raw JWT access token string.

**Server responses:**
```json
// Auth success
{"type": "authenticated", "account_id": "uuid"}

// Auth failure
{"type": "error", "message": "Invalid token"}

// Focus signal (the main event)
{"type": "focus_signal", "action": "start", "session_id": "uuid", "timestamp": "ISO8601"}
{"type": "focus_signal", "action": "stop", "session_id": "uuid", "timestamp": "ISO8601"}
```

**Client messages (optional heartbeat):**
```json
{"type": "focus_heartbeat", "session_id": "uuid", "state": "active"}
```

### Connection Lifecycle

```
App launches
    ↓
Check if user is logged in (has JWT)
    ↓ yes
Connect to /ws/focus
    ↓
Send JWT token as first message
    ↓
Receive {"type": "authenticated"} → connection active
    ↓
Listen for focus_signal messages
    ↓
On "start": call AppDelegate.showFocusStartOverlay(isPuckTriggered: true)
On "stop": call AppDelegate.endFocusSession()
    ↓
On disconnect: wait 5s, reconnect (exponential backoff: 5s, 10s, 20s, 40s, max 60s)
    ↓
On token refresh: reconnect with new token
```

### Integration with Existing Code

**AppDelegate.swift** wiring:
```swift
// In applicationDidFinishLaunching, after auth check:
if let token = getAccessToken() {
    focusWebSocketClient = FocusWebSocketClient()
    focusWebSocketClient?.onFocusSignal = { [weak self] action, sessionId in
        DispatchQueue.main.async {
            if action == "start" {
                self?.showFocusStartOverlay(isPuckTriggered: true)
            } else if action == "stop" {
                self?.endFocusSession()
            }
        }
    }
    focusWebSocketClient?.connect(token: token)
}
```

**On "start" signal from Puck:**
- `showFocusStartOverlay(isPuckTriggered: true)` is already built
- This shows the overlay with default profile pre-selected, no free time option
- User picks profiles / sets intention → focus starts
- OR user clicks "Just Block Distractions" → default profile enforced immediately

**On "stop" signal from Puck:**
- `endFocusSession()` is already built
- Stops enforcement, restores to always-active profiles only

**Fallback — Mac was offline when Puck tapped:**
- On WebSocket connect (or reconnect), call `GET /focus/active` to check for pending sessions
- If an active session exists that the Mac doesn't know about, trigger `showFocusStartOverlay(isPuckTriggered: true)`

### Device Registration

On first successful WebSocket connection (or on login), call `POST /devices/register`:
```json
{
    "device_type": "mac",
    "device_name": "Arayan's MacBook Pro"
}
```
This registers the Mac so the backend knows which devices to relay signals to.

### Token Management

The JWT access token expires after 15 minutes. The WebSocket connection will break when the server validates a stale token during reconnect.

**Solution:** When the Mac app refreshes its JWT (via `/auth/refresh`), also reconnect the WebSocket with the new token. The `FocusWebSocketClient` should expose a `reconnect(token: String)` method.

### Error Handling

| Scenario | Behavior |
|----------|----------|
| No network | Don't connect. Retry when network becomes available. |
| Auth failure (4001 close code) | Don't reconnect. Token is invalid. Wait for user to re-login. |
| Server disconnect | Reconnect with exponential backoff (5s → 10s → 20s → 40s → 60s max) |
| Server unreachable | Same backoff. Log but don't alert user. |
| Token expired during connection | Refresh token, reconnect with new one. |

### Implementation Notes

**URLSessionWebSocketTask** (Foundation) is the right choice for macOS — no third-party dependencies needed:

```swift
let url = URL(string: "wss://api.intentional.social/ws/focus")!
let task = URLSession.shared.webSocketTask(with: url)
task.resume()

// Send auth token
task.send(.string(jwtToken)) { error in ... }

// Receive messages
func receiveMessage() {
    task.receive { result in
        switch result {
        case .success(.string(let text)):
            // Parse JSON, handle focus_signal
        case .failure(let error):
            // Handle disconnect, schedule reconnect
        }
        self.receiveMessage() // Keep listening
    }
}
```

### What NOT to Build

- No UI for WebSocket status (the connection is invisible to the user)
- No manual connect/disconnect button
- No WebSocket for non-focus features (heartbeat, settings sync stay REST)
- No push notification fallback yet (future enhancement)

## Priority

This is what makes Puck → Mac actually work. Without this, the Mac uses the keyboard shortcut mock (Cmd+Shift+P). With this, tapping the physical Puck device controls the Mac in real-time.

## Dependencies

1. Backend: `/ws/focus` endpoint (already built)
2. Backend: `POST /devices/register` (already built)
3. Backend: `GET /focus/active` (already built)
4. Mac app: `FocusSessionManager` (already built)
5. Mac app: `showFocusStartOverlay()` (already built)
6. Mac app: JWT auth (needs to exist — check if Mac app has auth/login)

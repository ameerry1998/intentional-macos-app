# Cross-Device Focus Session Debugging Runbook

> **Read me when:** an iPhone-initiated focus session doesn't fully engage
> Mac enforcement (focus gate, distractions blocking, context switching
> protection, pill, ritual). This runbook walks the full activation chain
> end-to-end and tells you exactly where to look at each boundary.

The chain has **three components and three boundaries**. Almost every bug in
this path is a boundary failure. Identify which boundary, fix that boundary,
move on.

```
┌─────────────┐  ① POST   ┌──────────────┐  ② WS push  ┌─────────────┐
│   iPhone    │──────────▶│   Backend    │────────────▶│     Mac     │
│  (Puck app) │           │   (FastAPI)  │             │ (Intentional│
│             │  /focus/  │              │  /ws/focus  │     app)    │
│             │  toggle   │              │             │             │
└─────────────┘           └──────────────┘             └──────────────┘
       │                          │                            │
   local                     focus_sessions              applyFocusSession
   FamilyControls            table + broadcast           → enforcement
```

**Each boundary can fail silently.** The bugs we have hit (and the ones we
will hit) live at the seams.

---

## The activation chain in detail

### iPhone side — `puck-ios`

User starts a session via:
- Long-press a Mode tile → "Start [Mode]" confirmation → `startSessionDirectly(mode:)`
- Tap an NFC puck → `PuckCoordinator.handleNFCSlug(slug)`
- Alarm dismiss with post-alarm mode → `activatePostAlarmMode(modeId:duration:)`

All paths funnel through `PuckCoordinator.activateMode(...)`:

```swift
case .blocking:
    blockingService.activate(mode: mode, duration: mode.defaultDuration)
    // Mirror to Mac via Intentional backend (fire-and-forget).
    IntentionalFocusSignalClient.shared.toggleFocus(action: .start)
```

**Two things happen in parallel:**
1. **Local enforcement (always):** `BlockingService.activate` applies a
   `ManagedSettingsStore` shield with the mode's app/category tokens. Strict
   mode and pairing have no guards on this — it always fires.
2. **Cross-device signal (fire-and-forget):** `IntentionalFocusSignalClient`
   posts `POST /focus/toggle {action: "start"}` to backend. Bearer auth (Supabase
   JWT). Failures are logged but never block the user.

**Logs to look for** (Console.app filtered to "Puck"):
```
[BlockingService] Activating blocking: mode=…, apps=N, categories=M, duration=…
[BlockingService] ManagedSettingsStore applied: …
[PuckCoordinator] Mode activated: … (type: blocking, slug: …)
[NFCInfo] Intentional focus toggle: action=start status=success session=…
```

If the last line is missing → iOS sent the signal but didn't get a response,
OR didn't send it at all (network issue, no JWT). Look for:
```
[NFCError] Intentional focus toggle failed: …
```

### Backend side — `intentional-backend`

`POST /focus/toggle` does:
1. Resolves account from JWT (Supabase or Intentional, both accepted).
2. Inserts `focus_sessions` row: `{account_id, started_at, triggered_by:"puck", status:"active"}`.
3. Broadcasts to all connected WebSocket clients for the account:
   ```json
   {"type":"focus_signal","action":"start","session_id":"…","timestamp":"…","triggered_by":"puck"}
   ```
4. Returns `{session_id, status:"started", started_at, message}` to iPhone.

**Two delivery channels:**
- **WebSocket push** to `/ws/focus` (real-time, used when Mac is online).
- **`/focus/active` polling endpoint** for offline recovery — Mac queries this
  on WebSocket reconnect.

**Inspect the live state** via the script we already have:
```bash
cd /Users/arayan/Documents/GitHub/intentional-backend
python scripts/check_active_session.py
```
This prints the most recent 5 focus sessions for `ameer.rayan@gmail.com`. If
your latest start signal isn't there, the bug is at boundary ①.

### Mac side — `intentional-macos-app`

`FocusWebSocketClient.swift` connects to `/ws/focus` on app launch (if a JWT
exists in Keychain). On `focus_signal` message, it fires `onFocusSignal`
callback in `AppDelegate`.

**The handler** (`AppDelegate.swift:573`) — as of fix `1287d7f`:

```swift
focusWebSocketClient?.onFocusSignal = { [weak self] action, sessionId, triggeredBy in
    DispatchQueue.main.async {
        guard let self = self else { return }
        if action == "start" {
            self.postLog("🔌 Focus signal: START (session: …)")
            self.focusWebSocketClient?.startHeartbeat(sessionId: sessionId)
            self.dismissFocusStartOverlay()  // dismiss any stale picker
            let defaultProfileIds = self.blockingProfileManager?.profiles
                .filter { $0.isDefault }
                .map { $0.id } ?? []
            self.startFocusSession(
                profileIds: defaultProfileIds,
                intention: "Focus session (started on phone)",
                aiEnabled: false,
                triggeredByPuck: triggeredBy == "puck"
            )
        } // …
    }
}
```

`startFocusSession` → `applyFocusSession` is the gate that engages
enforcement. **All four user-facing features depend on it:**

| Feature | Lives in | Activated by |
|---|---|---|
| Distractions blocking (websites + apps) | `WebsiteBlocker`, `FocusMonitor.distractingAppBundleIds` | `applyFocusSession` lines 1141-1142 |
| Schedule block injection | `ScheduleManager.injectFocusSessionBlock` | `applyFocusSession` line 1157 |
| Focus gate / planning ritual | `BlockRitualController` (wired to FocusMonitor) | `focusMonitor?.onBlockChanged()` line 1159 (when block enters its start window) |
| Context-switching protection | `SwitchInterventionCoordinator` (wired to FocusMonitor) | `focusMonitor?.onBlockChanged()` line 1159 |
| Pill widget | `DeepWorkTimerController` (wired to FocusMonitor) | Same |

**Key gate:** `applyFocusSession` has an early-return guard at line 1136:
```swift
guard hasProfiles || hasIntention else {
    postLog("🎯 Focus session has no profiles and no intention — skipping enforcement")
    return
}
```
**If neither profiles nor intention is provided, the entire enforcement chain
silently no-ops.** This is the trap the prior bug fell into.

---

## Boundary failure cheat sheet

When a cross-device session doesn't fully engage Mac enforcement, walk the
boundaries top-to-bottom. The first one that fails is the bug.

### Boundary ① — iPhone → Backend

**Symptom:** No new row in `focus_sessions` after iPhone starts a session.

**Check:**
1. iPhone Console.app for `[NFCInfo] Intentional focus toggle: action=start
   status=success` line.
2. Backend logs / DB:
   ```bash
   cd /Users/arayan/Documents/GitHub/intentional-backend
   python scripts/check_active_session.py
   ```
3. iPhone's Bearer auth: was it sending a valid Supabase JWT? If iPhone's
   Supabase session expired, the POST returns 401 silently (fire-and-forget).

**Past root causes:**
- iOS not signed in (no Supabase session, no Bearer token).
- iOS legacy device row not linked to account (only matters for `/partner`
  endpoints, not focus, but easy to confuse).

### Boundary ② — Backend → Mac WebSocket

**Symptom:** `focus_sessions` row exists but Mac shows nothing.

**Check:**
1. Mac's WebSocket connection state. Console.app filtered to "Intentional":
   - `🔌 WebSocket connecting with stored token` — connect attempt
   - `🔌 WebSocket connected` — success
   - `🔌 WebSocket disconnected` — failure (will auto-reconnect)
2. If Mac is connected but no `focus_signal` arrives:
   - Backend's broadcast loop iterates `connected_focus_ws[account_id]`. Verify
     Mac registered itself with the SAME account_id as iPhone. If they're on
     different accounts (orphaned legacy device row, etc.), broadcast misses.
3. Polling fallback: when WebSocket reconnects, Mac calls `checkForActiveFocusSession()`
   which hits `GET /focus/active`. Look for that log line.

**Past root causes:**
- Mac and iPhone authenticated to different accounts (the partner sync
  investigation root cause — same root, different bug surface here).
- Mac's WebSocket auth message used a stale token after Mac's session expired.

### Boundary ③ — Mac WebSocket → enforcement chain

**Symptom:** Mac receives the signal (`🔌 Focus signal: START` log line fires)
but enforcement doesn't engage.

**Check:**
1. Look for `🎯 Focus session has no profiles and no intention — skipping enforcement`.
   That's the early-return in `applyFocusSession`. Means neither default profile
   nor intention was provided.
2. Look for `🎯 Focus session started (profiles=N, intention=…, puck=true)`.
   That confirms `startFocusSession` ran. If THIS line fires but enforcement
   still doesn't engage, the bug is downstream in `applyFocusSession`.
3. Look for `🧘 Block ritual (pill): showing for deepWork block`. That confirms
   `onBlockChanged` fired and FocusMonitor saw the new block.

**Past root causes** (this very bug):
- `onFocusSignal` handler called `showFocusStartOverlay()` (interactive picker)
  instead of `startFocusSession()` directly. User on iPhone never clicks Start
  → enforcement never engages. **Fixed in commit `1287d7f`.**
- Default profile not set in `BlockingProfileManager` → `defaultProfileIds`
  is empty → no domains → `hasProfiles=false` → only `hasIntention` matters.
  If intention is `nil` (which the old code passed), guard fails, enforcement
  skips. (The fix passes a placeholder intention so the guard passes even
  without a default profile.)

---

## Quick-reference inspection commands

Print the live state of every component in <30 seconds:

```bash
# Boundary ① — what iPhone sent
# Open iPhone Console.app, filter "Puck", look for [NFCInfo] Intentional focus toggle

# Boundary ② — what backend has
cd /Users/arayan/Documents/GitHub/intentional-backend
python scripts/check_active_session.py

# Boundary ③ — what Mac saw
# Console.app, filter "Intentional", look for the 4 log lines:
#   🔌 Focus signal: START
#   🎯 Focus session started
#   🎯 Focus session has no profiles and no intention   ← skip line
#   🧘 Block ritual (pill): showing for deepWork block
```

---

## When you can't reproduce

If iPhone sends but Mac doesn't react and nothing's in the logs:
1. **Mac's WebSocket may be disconnected.** Check for the auto-reconnect line.
   If WebSocket is dead, restart the Mac app.
2. **Mac's account differs from iPhone's.** Check `/auth/me` from each device
   and compare account_ids.
3. **Background bug:** The WebSocket reconnect logic uses backoff. After many
   failures it could be in a long backoff window. Force restart the Mac app.

If the chain works once but fails on the next try:
1. **Stale focus_session in DB:** The previous session might still be `active`.
   Backend's `/focus/active` returns the most recent, so a stale session can
   confuse Mac into thinking it's already in a session.
   ```bash
   python scripts/check_active_session.py
   ```
   Manually mark old sessions ended via Supabase SQL if needed.

---

## Adding instrumentation when this isn't enough

If the boundaries above are all green but the bug persists, the issue is
deeper. Add instrumentation at the gate functions:

- `BlockingService.activate` — log app/category counts, store name, whether
  store apply succeeded.
- `IntentionalFocusSignalClient.toggleFocus` — log HTTP status, response body.
- `FocusWebSocketClient.handleMessage` — log every received frame.
- `applyFocusSession` — log `hasProfiles`, `hasIntention`, `domains.count`,
  `appBundleIds.count` before the guard.
- `FocusMonitor.onBlockChanged` — log the current block id, what tier of
  enforcement it engaged.

Then re-run the scenario, collect Console output, and compare against the
expected log sequence above.

---

## Architecture notes worth knowing

- **The "puck" trigger is a label, not a privileged auth path.** Both Mac
  Cmd+Shift+P and iPhone-started sessions use `triggered_by="puck"`. There's
  no way for the backend to distinguish "user is at this Mac" from "user is
  remote." Mac's handler decides UX based on whether the signal is local
  (Cmd+Shift+P → call `showFocusStartOverlay` to let user confirm) or remote
  (WebSocket → auto-engage with default profile).
- **The intention picker (FocusStartOverlayView) is for Mac-local starts only.**
  Cross-device signals must auto-engage. If you find yourself reintroducing
  the picker for cross-device, ask: "is there any way the iPhone user is also
  at the Mac right now?" Almost always: no.
- **`focus_sessions` table is account-scoped, not device-scoped.** Same
  pattern we converged on for partner sync. If you see code keying on
  `device_id` for any of the focus features, that's a smell — flag it.
- **iOS local enforcement is independent of backend.** Even if the cross-
  device signal fails, the iPhone session itself works. The cross-device
  layer is purely for Mac mirroring.
- **`/focus/active` polling is the offline-recovery path.** When Mac comes
  online after being offline, it asks the backend "is there an active
  session?" and engages enforcement if so. This means the WebSocket isn't
  the only path — even if WS push fails, polling catches up.

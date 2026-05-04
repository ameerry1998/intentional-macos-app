# Focus Session State Sync Audit
**Date:** April 27, 2026  
**Scope:** macOS app, iOS Puck app, Intentional backend  
**Issue:** Single boolean "is focus session active" fails to stay in sync across three clients

---

## Section 1: State Map

### Where "Is Focus Active" Lives

#### **Backend (Python/FastAPI + Supabase Postgres)**

| Aspect | Details |
|--------|---------|
| **File/Location** | `/intentional-backend/main.py:3086-3102` (GET `/focus/active`); database: `focus_sessions` table |
| **Storage Type** | Postgres row in `focus_sessions` table (Supabase) |
| **Column(s)** | `status` (TEXT, 'active' \| 'ended'); `id` (UUID); `account_id` (UUID); `started_at` (TIMESTAMPTZ); `ended_at` (TIMESTAMPTZ nullable); `triggered_by` (TEXT, 'puck' etc.) |
| **Lifetime** | Persistent until end of database session lifetime (no TTL, no auto-expiry) |
| **Who Reads** | Mac poller (2s polling on `GET /focus/active`); WebSocket clients on re-connect or dashboard |
| **Who Writes** | `POST /focus/toggle` endpoint (lines 3024-3028: starts new session, ends existing); Puck iOS via NFC tap → `POST /focus/toggle` |
| **Current Behavior** | Sessions marked `status='active'` remain in that state forever until explicit `POST /focus/toggle?action=stop` is issued. No mechanism to auto-expire stale sessions. |
| **Known Problem** | Today's incident: iPhone local session wiped but backend row remained `active` for 5+ hours, preventing other devices from starting new sessions. |

**Migration Reference:** `/intentional-backend/migrations/009_add_focus_sessions.sql` (table created with no TTL/expiry logic)

---

#### **macOS App (Swift)**

| Aspect | Details |
|--------|---------|
| **File/Location** | `/Intentional/FocusModeController.swift:40-41` (in-memory state); `/Intentional/AppDelegate.swift:36` (holds instance) |
| **Storage Type** | In-memory Swift class properties (`state: State`, `currentPeriod: Period?`); **no persistent storage** |
| **Type** | Enum `State { case off, focus, bedtime }`; struct `Period { id, startedAt, intention, source }` |
| **Lifetime** | Process lifetime only. Lost on app restart. |
| **Who Reads** | `FocusMonitor` (checks `focusModeController.isOn`); enforcement engine; `FocusStatePoller` (line 139); `ScheduleManager` callbacks; UI components |
| **Who Writes** | `FocusStatePoller.applyTransition()` (lines 116-125); `ScheduleManager.onBlockChanged` callback (AppDelegate line 702-716); manual dashboard toggle (line 1239); WS client callbacks (AppDelegate line 659) |
| **Source of Truth for Mac** | **Backend via polling** — Mac polls `GET /focus/active` every 2 seconds and trusts that response as truth for sessions started by Puck or other devices. |
| **Idempotency Note** | `activate()` is idempotent: calling while `.focus` already active updates intention but doesn't re-notify unless intention changed (lines 66-84). |

---

#### **iOS Puck App (Swift)**

| Aspect | Details |
|--------|---------|
| **File/Location** | `/Puck/Models/Sessions.swift:13-60` (SwiftData model `FocusSession`); `/Puck/Core/Coordinator/PuckCoordinator.swift:19` (in-memory active session tracking) |
| **Storage Type** | SwiftData persistent model (SQLite on device, app-group container `group.com.getpuck.app`); in-memory `@Published` property on coordinator |
| **Model Details** | `FocusSession { id, modeName, modeIconName, modeSlug, modeType, startTime, endTime, scheduledDuration, endReason }` |
| **Lifetime** | Persistent in SwiftData; can be queried/restored on app launch (line 69: `restoreActiveSession()`) |
| **Who Reads** | `PuckCoordinator.activeFocusSession` (published, drives UI); `BlockingService` (checks for active session); alarm handling |
| **Who Writes** | `PuckCoordinator.activateMode()` (creates session); `endActiveFocusSession()` (sets `endTime`); NFC tap handlers (line 143: `endActiveFocusSession(reason: .nfcTap)`) |
| **Source of Truth for iOS** | **Local SwiftData model** — session state is local-first. Backend `POST /focus/toggle` is fire-and-forget (via `IntentionalFocusSignalClient`). |
| **Known Vulnerability** | SwiftData store can be wiped (line 43-46 in `PuckApp.swift`). If store deletion occurs between NFC tap and backend POST, local session is lost but backend row persists. No re-sync mechanism. |

---

### Summary: Three Different Sources of Truth

| Client | Primary Truth | Backup/Secondary | Polling | Persistence |
|--------|---------------|------------------|---------|-------------|
| **macOS** | Backend (via polling) | Nothing (loses state on restart) | Every 2s via `GET /focus/active` | **None** |
| **iOS** | Local SwiftData model | None (doesn't read backend) | No polling; fire-and-forget to backend | **Persistent** (SwiftData) |
| **Backend** | Postgres `focus_sessions` row | Nothing | Queries on demand | **Persistent** (Postgres) |

**Critical Design Issue:** Each client independently owns truth. No canonical sync protocol.

---

## Section 2: Sync Paths

### State Change Propagation Routes

#### **Route 1: Puck NFC Tap → Backend → Mac Poller**

**Flow:**
1. User taps NFC on iPhone running Puck app
2. `PuckCoordinator.handleNFCSlug()` (line 83) → `activateMode()` (creates local `FocusSession`, saves to SwiftData)
3. `BlockingService.activate()` triggers
4. `IntentionalFocusSignalClient.toggleFocus(action: .start)` enqueues operation (line 56: `IntentionalFocusSignalClient.swift`)
5. Persistent queue drains (line 128: `.drain()`), sends `POST /focus/toggle` with `action=start`
6. Backend stores session in `focus_sessions` table with `status='active'`, broadcasts to WebSocket clients
7. Mac's `FocusStatePoller` polls `GET /focus/active` every 2s (line 55: `FocusStatePoller.swift`)
8. Poller receives `active=true`, calls `applyTransition(active: true)` (line 99)
9. `FocusStatePoller` calls `focusModeController.activate()` (line 133)
10. Mac UI updates via `FocusModeController.onStateChanged` callback fanout

**File References:**
- iPhone: `/puck-ios/Puck/Core/Network/IntentionalFocusSignalClient.swift:56-61` (enqueue)
- iPhone: `/puck-ios/Puck/Core/Network/IntentionalFocusSignalClient.swift:128-160` (drain with retry queue)
- Backend: `/intentional-backend/main.py:3024-3055` (POST /focus/toggle)
- Mac: `/Intentional/FocusStatePoller.swift:55-106` (poll)
- Mac: `/Intentional/FocusStatePoller.swift:128-134` (engage, activate)

**Failure Modes:**
- iPhone app suspended before drain completes → operation stays in UserDefaults queue. Recovered on next foreground (iOS 13+ allows ~30s background task). **Fixed recently via persistent retry queue.**
- Network timeout during POST → `IntentionalFocusSignalClient` retries up to 10 attempts (line 41: `maxAttempts`).
- Backend unreachable → op stays queued indefinitely (no timeout on individual ops).
- Mac offline during backend session creation → poller won't see it until reconnected. Polling resumes when network available.
- Backend crash → session row lost (no backup). Mac keeps polling, gets `active=false`, deactivates.

**Recovery:**
- iPhone: Retry queue survives app suspension and process exit. Drains on next foreground.
- Mac: Polling loop automatically recovers when network available. No explicit reconciliation.
- Backend: No recovery. Fire-and-forget model.

---

#### **Route 2: Mac Manual Dashboard Toggle → (No Backend Sync)**

**Flow:**
1. User clicks "Focus On" button in Mac dashboard (AppDelegate, around line 1239)
2. `FocusModeController.activate(intention:source:.manual)` called directly
3. Mac enters `.focus` state in memory
4. `FocusModeController.onStateChanged` fires, triggers `FocusMonitor` re-evaluation
5. **Backend is NOT notified.** No POST to backend.
6. iPhone never learns about this session. Puck shows no active session.
7. If user taps NFC on Puck, coordinator sees no local session, allows start, posts to backend, creates new backend session
8. Mac's poller detects the new backend session 2s later

**File References:**
- Mac: `/Intentional/AppDelegate.swift:1239` (manual activation source)
- Mac: `/Intentional/FocusModeController.swift:64-95` (activate logic; no backend sync)

**Failure Modes:**
- Mac and Puck can both believe they're in different focus states simultaneously
- User on Mac thinks they're focused. Puck shows free. Backend has Mac's session. iPhone never learns.
- No mechanism to sync Mac's local-only state to backend

**Recovery:**
- None. Requires manual re-sync (user ends session on one device, starts on other).

---

#### **Route 3: Backend WebSocket Broadcast → Mac WS Client**

**Flow:**
1. Some trigger (Puck POST, another Mac, or external API) changes backend session state
2. Backend broadcasts to all connected WebSocket clients via `broadcast_focus_signal()` (line 2963)
3. Mac's `FocusWebSocketClient` receives message (line 149: `case "focus_signal"`)
4. Calls `onFocusSignal?(action, sessionId, triggeredBy)` callback (line 155)
5. AppDelegate's callback handler (line 659) calls `focusModeController.activate()` or `.deactivate()`
6. UI updates

**File References:**
- Backend: `/intentional-backend/main.py:2963-2981` (broadcast function)
- Backend: `/intentional-backend/main.py:3050-3054, 3078-3082` (broadcast on toggle)
- Mac: `/Intentional/FocusWebSocketClient.swift:149-156` (handle focus_signal)
- Mac: `/Intentional/AppDelegate.swift:647-659` (WS signal callback wiring)

**Failure Modes:**
- WS reconnect logic doesn't recover from boot-time offline-then-online sequence (documented in `FocusStatePoller.swift:8-11`)
- If Mac reboots while offline, WS may never re-establish, leaving Mac unaware of backend changes
- Polling exists **precisely because WS is unreliable**
- WS connection loss → no real-time updates until poller next ticks (up to 2s delay)

**Recovery:**
- Polling fallback (every 2s)
- Manual reconnect on token refresh
- User must restart app in some cases

---

#### **Route 4: Schedule Block Start/End → Mac Local State**

**Flow:**
1. `ScheduleManager` detects current time enters/exits a work block (via periodic evaluation, AppDelegate line 651)
2. Calls `onBlockChanged` callback (line 702-716)
3. If entering work block: `focusModeController.activate(intention:source:.schedule)`
4. If exiting work block: `focusModeController.deactivate(source:.schedule)`
5. Enforcement engine re-evaluates

**File References:**
- Mac: `/Intentional/ScheduleManager.swift` (block detection)
- Mac: `/Intentional/AppDelegate.swift:702-716` (onBlockChanged routing)
- Mac: `/Intentional/FocusModeController.swift:64-95, 112-119` (activate/deactivate)

**Failure Modes:**
- Schedule changes are **local-only**. No backend sync.
- Puck never learns about schedule-driven enforcement on Mac
- If Mac has a 9-5 focus block and user taps Puck at 8:55am, Puck starts a session. At 9:00am, Mac also activates (from schedule). Mac and Puck are both on, but source differs.
- Source tracking (line 72-79 in `FocusModeController.swift`) preserves original source, but only on same client.

**Recovery:**
- None explicit. Schedule can override polling state if timing aligns.

---

#### **Route 5: Puck NFC Stop Tap → Backend → Mac Poller**

**Flow:**
1. User taps NFC on Puck while session active (same puck slug)
2. `PuckCoordinator.handleNFCSlug()` detects `activeModeSlug == slug` (line 136)
3. Calls `endActiveFocusSession(reason: .nfcTap)` (line 143)
4. `IntentionalFocusSignalClient.toggleFocus(action: .stop)` enqueued
5. Drain sends `POST /focus/toggle?action=stop`
6. Backend marks session `status='ended'`, broadcasts stop signal
7. Mac's poller detects `active=false` (line 119), calls `disengageIfRemoteOriginated()` (line 121)
8. If session source was `.puck` or `.crossDevice`, deactivates (line 139-141)
9. If session source was `.manual` or `.schedule`, **does not deactivate** (idempotent guard on line 139)

**File References:**
- iPhone: `/puck-ios/Puck/Core/Coordinator/PuckCoordinator.swift:143` (endActiveFocusSession)
- Backend: `/intentional-backend/main.py:3057-3083` (stop logic)
- Mac: `/Intentional/FocusStatePoller.swift:119-121, 136-142` (deactivate logic)

**Failure Modes:**
- If Puck stop tap's backend POST fails (network), iPhone marks session ended locally but backend still shows active
- Mac's poller won't see the stop (backend hasn't changed), keeps enforcing
- Puck shows "no active session" but Mac enforces and backend believes session is active
- **This is the core problem in today's incident**

**Recovery:**
- User must manually stop on Mac dashboard
- Or backend session must be manually cleared (admin script)

---

## Section 3: Divergence Scenarios

### Scenario 1: Puck Fire-and-Forget POST Fails (Today's Real Incident)

**Initial State:**
- All three clients: no active session (`active=false`)

**Sequence of Events:**
1. iPhone user taps NFC puck at 2:30 PM
2. `IntentionalFocusSignalClient.toggleFocus(.start)` enqueues operation in UserDefaults
3. `drain()` attempts `POST /focus/toggle?action=start`
4. Network request succeeds, backend creates row in `focus_sessions`, broadcasts WS signal
5. Backend response received, op removed from queue
6. iPhone local: `FocusSession` created in SwiftData, `isActive=true`
7. Mac poller ticks at 2:30:01 PM: receives `active=true` from backend, calls `activate()`, Mac shows "Focusing"
8. **Everything in sync so far** ✓

9. User locks iPhone immediately (before SwiftData write completes or crashes on save)
10. SwiftData model container experiences I/O failure or database file is corrupted
11. `activeFocusSession` in `PuckCoordinator` is cleared from memory (app backgrounded)
12. SwiftData recovery mechanism (line 39-56 in `PuckApp.swift`) detects corruption and **deletes the entire store**
13. `restoreActiveSession()` finds no active sessions (line 75)

**End State (at 2:35 PM):**

| Client | State | Details |
|--------|-------|---------|
| **iPhone local** | No active session | SwiftData wiped, `activeFocusSession = nil` |
| **Backend** | `active=true` | Row in `focus_sessions` still marked `status='active'` (no TTL, no expiry) |
| **Mac** | Enforcing | `FocusModeController.state = .focus`, triggered by last successful poll |

**Severity:** **HIGH** — User sees "focus off" on iPhone but Mac is locked in focus enforcement, blocking work

**Enforcement Impact:** Mac incorrectly enforces for 5+ hours until user notices or manually stops on dashboard

---

### Scenario 2: Puck Stop Tap Network Failure

**Initial State:**
- All three: active session from Puck (from Scenario 1)

**Sequence:**
1. User taps NFC to end session at 3:00 PM
2. `PuckCoordinator.endActiveFocusSession()` called, session marked `endTime = Date()` in SwiftData
3. `IntentionalFocusSignalClient.toggleFocus(.stop)` enqueued
4. `drain()` attempts `POST /focus/toggle?action=stop`
5. **Network unreachable** (WiFi disconnected, cellular down)
6. Retry loop in `incrementAttempts()` fires (line 118: max 10 attempts)
7. After 10 failures, operation dropped with log message (line 119)
8. Backend never receives stop request

**End State (immediately after tap):**

| Client | State | Details |
|--------|-------|---------|
| **iPhone local** | No active session | `FocusSession.endTime` set locally, UI shows "off" |
| **Backend** | `active=true` | Session still `status='active'`, no stop event received |
| **Mac** | Enforcing | Poller still sees `active=true` from last successful poll (could be stale by minutes if last poll was before network loss) |

**Severity:** **MEDIUM-HIGH** — Puck UI lies (says "off"), Mac enforces based on stale backend state, backend waits forever

**Timeline Divergence:**
- If Puck network recovers within 2s of Mac's next poll tick, Mac might see the session end before it catches up
- If Puck stays offline, gap widens indefinitely

---

### Scenario 3: Simultaneous Taps from Two Pucks (Multi-Device Race)

**Initial State:**
- No active session on any device

**Sequence:**
1. User taps Puck A (Deep Work) at 10:00:00 AM
2. iPhone enqueues `POST /focus/toggle?action=start`
3. Simultaneously, user taps Puck B (Bedtime) at 10:00:01 AM
4. iPhone enqueues second `POST /focus/toggle?action=start`
5. `drain()` processes both, sends both POSTs in sequence (line 145-159: loop processes all ops)
6. First POST succeeds: backend creates session for Puck A
7. Second POST succeeds: backend's toggle logic (line 3026-3028) **ends session for Puck A**, then creates session for Puck B
8. Broadcasts happen for both transitions
9. Mac receives two separate poll results over next 2-4 seconds

**End State:**

| Client | State | Details |
|--------|-------|---------|
| **iPhone local** | Active session for Puck B | SwiftData has only the most recent `FocusSession` |
| **Backend** | `active=true` for Puck B | Earlier session ended by the second toggle |
| **Mac** | Active session for Puck B (eventually) | Poller sees Puck A first, then Puck B; final state settles on B |

**Severity:** **LOW** — Ends up consistent, but intermediate state (brief moment where A was active) is lost. User might see brief flicker in UI.

**Enforcement Impact:** Enforcement switches from A to B seamlessly (or with 2-4s lag)

---

### Scenario 4: Mac Schedule Block + Puck NFC Simultaneous (Source Confusion)

**Initial State:**
- No active session

**Sequence:**
1. Mac's schedule manager detects 9:00 AM work block start (line 702-716 in AppDelegate)
2. Calls `focusModeController.activate(intention: "Deep Work", source: .schedule)`
3. Mac enforces locally, **does not notify backend or iPhone**
4. User immediately taps Puck NFC at 9:00:05 AM (happened to pick that moment)
5. iPhone enqueues `POST /focus/toggle?action=start`
6. Backend creates session with `triggered_by='puck'`
7. Mac's poller at 9:00:06 sees `active=true, triggered_by='puck'`
8. `FocusStatePoller.applyTransition()` called with `triggeredBy='puck'` (line 91)
9. Calls `engage(triggeredBy: 'puck')` (line 118)
10. Calls `focusModeController.activate(source: .puck)` (line 133)
11. Source is overwritten from `.schedule` to `.puck`

**End State:**

| Client | State | Source | Details |
|--------|-------|--------|---------|
| **iPhone** | Active session, Puck | — | Correct |
| **Backend** | Active, `triggered_by='puck'` | — | Correct |
| **Mac** | Active session, source=**.puck** | `.puck` (should be `.schedule`) | **Source wrong!** If user taps NFC again to stop, Mac **will** deactivate (line 139: source is `.puck`, passes guard). But schedule says 9:00-9:30, user intended to enforce until 9:30. |

**Severity:** **MEDIUM** — Source mismatch. If user taps NFC to stop session at 9:15 (within schedule block), Mac deactivates even though schedule would enforce. Breaks schedule+NFC coordination.

---

### Scenario 5: Account Switch / App Reinstall

**Initial State:**
- User logged in, active session on all three clients

**Sequence:**
1. User logs out of backend account on iPhone (clears auth token)
2. User logs in with different account
3. iPhone's `PuckCoordinator.restoreActiveSession()` still finds old `FocusSession` in SwiftData (line 75)
4. **Treats it as active session for the new account** (no account_id field on `FocusSession` model to disambiguate)
5. iPhone shows old account's mode name, slug, etc.
6. User taps NFC, sends `POST /focus/toggle?action=start` with new account's device ID
7. Backend creates session for new account
8. Mac polls for new account (different `X-Device-ID`), sees active session, enforces
9. Puck UI still shows mode name from old account's session (local SwiftData is account-agnostic)

**Severity:** **HIGH** — State corruption. User sees UI from one account while data flows to another.

**Root Cause:** `FocusSession` SwiftData model lacks `accountId` field. No account-scoped lifecycle management.

---

### Scenario 6: Time Skew / DST Change

**Initial State:**
- Active session started at 10:30 AM local time

**Sequence:**
1. System clock jumps forward 1 hour (DST, or NTP resync)
2. Mac's `ScheduleManager` re-evaluates current time
3. May think user is in a different block (e.g., "Free Time" block if jump crosses into free time)
4. Calls `focusModeController.deactivate(source: .schedule)` (line 116-119)
5. Concurrently, iPhone is still in active session (uses device time)
6. Backend session still `active` (uses server time in UTC)
7. Mac deactivates while Backend + iPhone think session ongoing

**End State:**

| Client | State | Time Context |
|--------|-------|-------------|
| **iPhone** | Active (local time-based) | Local 11:30 AM (but clock wrong) |
| **Backend** | Active (UTC) | UTC 14:30 (actual time, session started 40 min ago per server clock) |
| **Mac** | Off (deactivated by schedule logic) | Local time 11:30 (after jump) |

**Severity:** **MEDIUM** — Transient. Resolves when time re-syncs or user manually intervenes. But a few minutes of divergence possible.

---

### Scenario 7: No Active Session on iPhone, Active on Backend (Hit Today)

Already covered in detail in Scenario 1. This is the real-world incident.

---

## Section 4: Architectural Assessment

### Current "Source of Truth" on Each Client

**Backend: Postgres `focus_sessions` row is truth**
- Endpoint: `GET /focus/active` returns latest active session
- No reconciliation: once written, row stays until explicit `POST /focus/toggle?action=stop`
- No TTL/heartbeat/expiry

**Mac: Backend is the truth for cross-device sessions**
- But **local-only sessions (manual, schedule) have no backend representation**
- Polling consensus: whatever backend says, Mac believes (line 99: `applyTransition()` applies backend state)
- Caveat: doesn't override `.manual` or `.schedule` source sessions on incoming `STOP` (line 139)
- On restart: **loses all state**, even if backend still thinks session active (user must manually stop on dashboard or iPhone must end it)

**iPhone: Local SwiftData is the truth**
- Backend is advisory (fire-and-forget via `IntentionalFocusSignalClient`)
- No mechanism to sync back from backend state
- On app crash/reinstall: SwiftData wiped, local state lost forever
- No fallback to backend state (app never reads `GET /focus/active`)

### Broken Invariants

1. **"Session state must be consistent across backend and at least one client"**  
   **Broken:** iPhone can have no session locally while backend has active session. No enforcement, no error.

2. **"If backend says session is active, at least one client knows about it"**  
   **Broken:** Backend session can persist for hours with zero clients aware (see Scenario 1).

3. **"Session started by device X can only be stopped by device X or the backend"**  
   **Broken:** Mac can stop a Puck-started session via poller if network timing aligns oddly. No ownership lock.

4. **"Session state changes are idempotent across clients"**  
   **Partially broken:** `FocusModeController.activate()` is idempotent on Mac. But poller applies all backend state transitions, risking races with schedule logic.

5. **"No two clients disagree on whether a session is active"**  
   **Actively broken:** Scenario 1 shows iPhone says "off", backend says "on", Mac enforces "on".

### Offline vs. Online Behavior

**Offline:**
- **Mac:** Polling fails, but cached `lastKnownActive` state persists in memory (line 24). Keeps enforcing based on last known state. Can be stale by hours if device rebooted.
- **iPhone:** Local SwiftData is source of truth. Backend POST fails, queued for retry. Enforcement (BlockingService) uses local state.
- **Backend:** Not applicable (is always on).

**Online:**
- **Mac:** Polling succeeds, backend state wins. WS provides real-time updates if available.
- **iPhone:** Local state is primary. Backend sync is best-effort (fire-and-forget, 10 retries max, then dropped).
- **Backend:** State is canonical, broadcasts to connected WS clients.

**Problem:** Online and offline behavior are fundamentally different. A device offline for 2 hours, then back online, may have stale session state cached. Mac has no recovery; iPhone relies on manual re-sync or SwiftData restore.

### Schedule Integration as Fourth Source of Truth

**Yes, schedule is a de facto source of truth on Mac:**
- `ScheduleManager.onBlockChanged` (line 702-716) directly calls `focusModeController.activate/deactivate`
- Can override polling state (if schedule says focus, Mac enforces, backend doesn't know)
- Can conflict with Puck state (Scenario 4)
- No backend awareness: schedule is purely local
- Creates asymmetry: Mac can be in `.focus` state while backend `active=false` and iPhone idle

**Architectural consequence:** Mac has **two independent state machines**:
1. Polling from backend
2. Schedule-driven local state

These can diverge. No mutual exclusion or priority system (only source preservation: line 139 checks if source is `.puck` or `.crossDevice`, otherwise ignores remote stop).

---

## Section 5: Specific Code Smells and Bugs Found

### Bug 1: No Session TTL / Auto-Expiry on Backend

**File:** `/intentional-backend/migrations/009_add_focus_sessions.sql`  
**Issue:** Table `focus_sessions` has no TTL, no `expires_at` column, no cleanup job  
**Impact:** Sessions marked `status='active'` can sit forever  
**Example:** Scenario 1 — session active for 5+ hours after iPhone crashed  
**Fix Needed:** Add TTL logic (e.g., mark sessions inactive after 12 hours of no heartbeat, or auto-expire stale sessions)

---

### Bug 2: SwiftData Model Has No Account ID

**File:** `/puck-ios/Puck/Models/Sessions.swift:13-60` (`FocusSession` model)  
**Issue:** No `accountId` field to scope sessions to the logged-in account  
**Impact:** Account switch (Scenario 5) causes UI to show old account's session while new account's backend state is active  
**Symptom:** User logs in with new account, sees old account's mode name in UI  
**Fix Needed:** Add `accountId` field, clear sessions on account switch

---

### Bug 3: iOS App Never Reads Backend Session State

**File:** `/puck-ios/Puck/Core/Network/IntentionalFocusSignalClient.swift`  
**Issue:** Client only sends POSTs, never reads `GET /focus/active` to sync back  
**Impact:** If backend session created by another device, iPhone doesn't know  
**Scenario:** User on Mac starts session via dashboard (local-only, no backend sync). iPhone shows "off" because it never polls backend.  
**Fix Needed:** Add periodic sync-back from backend, or at least on foreground.

---

### Bug 4: Mac Loses All State on Restart

**File:** `/Intentional/FocusModeController.swift:40-41`  
**Issue:** `state` and `currentPeriod` are in-memory only, not persisted  
**Impact:** Mac restarts during active session → state lost even though backend still has it  
**Symptom:** User reboots Mac, backend says session still active, but Mac shows "off" and doesn't enforce  
**Timeline:** Mac is unaware until next `FocusStatePoller` tick, which corrects it. But app startup might trigger schedule evaluation before polling begins, creating brief inconsistency.  
**Fix Needed:** Persist last-known state to disk, restore on launch, then reconcile with backend poll.

---

### Bug 5: Poller Doesn't Handle "stale" Sessions

**File:** `/Intentional/FocusStatePoller.swift:108-126`  
**Issue:** No detection of sessions that are "too old" (e.g., > 12 hours)  
**Impact:** If backend row is leftover from a crash, Mac will keep enforcing based on stale session  
**Example:** Scenario 1 — session 5+ hours old, Mac still enforcing  
**Fix Needed:** Poller should check `started_at` timestamp, reject sessions > max duration (e.g., 12h), auto-stop them.

---

### Bug 6: Race Condition in FocusStatePoller.disengageIfRemoteOriginated()

**File:** `/Intentional/FocusStatePoller.swift:136-142`  
**Issue:** 
```swift
if period.source == .puck || period.source == .crossDevice {
    controller.deactivate(source: .crossDevice)
}
```
This assumes `currentPeriod.source` reflects the true origin. But line 79 in `activate()` preserves the original source:
```swift
source: existing.source  // Keeps original source even if re-activated by schedule
```
So a Puck-started session re-activated by schedule will still have source `.puck`, and poller will deactivate it on a later STOP from backend. But the user intended schedule to keep it active.

**Symptom:** (Scenario 4 variant) User has 9-5 schedule. Puck taps at 8:55. At 9:00, schedule reactivates same session (idempotent, source stays `.puck`). If something triggers poller's STOP path (e.g., another device ends), Mac deactivates even though schedule says focus until 5 PM.

**Fix Needed:** Distinguish "who started" from "who is currently responsible." Track both.

---

### Bug 7: IntentionalFocusSignalClient Has Silent Drop After Max Retries

**File:** `/puck-ios/Puck/Core/Network/IntentionalFocusSignalClient.swift:118-121`  
**Issue:** After 10 failed attempts, operation is dropped with only a log message. No notification, no error callback, no UI indication.
```swift
if ops[idx].attempts >= maxAttempts {
    AppLogger.nfcError("Intentional focus toggle dropped after \(maxAttempts) attempts: ...")
    ops.remove(at: idx)
}
```

**Impact:** User might tap NFC, see it activate locally (SwiftData updated), but backend POST silently fails after 10 retries. User thinks it worked, but server doesn't know.

**Symptom:** (Scenario 2 variant) iPhone offline for extended period, user taps NFC. Local session created. Network fails. After ~10 attempts over an hour, operation dropped. iPhone thinks focus is active, backend never receives start.

**Fix Needed:** Add error callback to UI layer; show "sync failed" state; offer manual retry.

---

### Bug 8: FocusStatePoller Doesn't Validate sessionId Consistency

**File:** `/Intentional/FocusStatePoller.swift:116-125`  
**Issue:** When a session ID changes (`sessionId != prevSessionId`, line 122), poller assumes a new session started and re-engages. But no validation that the old session ended properly.

**Scenario:** Backend has two sessions somehow (race condition, or manual intervention). Poller alternates between them on each tick.

**Impact:** UI flickers between modes; enforcement switches inconsistently.

**Fix Needed:** Validate old session has `status='ended'` before accepting new one.

---

### Bug 9: WebSocket Reconnect Logic Broken After Boot-Time Offline

**File:** `/Intentional/FocusWebSocketClient.swift:79-96` and comments  
**Issue:** From comment in `FocusStatePoller.swift:8-11`:
> "WS reconnect logic doesn't recover from a boot-time offline-then-online sequence, leaving Mac silently desubscribed for the rest of the session."

**Diagnosis:** 
- On boot, `establishConnection()` is called (line 79)
- If network is down, `webSocketTask?.resume()` enqueues but never completes auth
- No explicit timeout or fallback to manually retry
- When network comes back, no callback triggers reconnect attempt
- Polling compensates, but WS stays dead

**Impact:** Real-time updates don't work. User relies entirely on 2s polling (degraded performance).

**Fix Needed:** Add explicit timeout on WS auth handshake; add reachability observer to trigger reconnect on network state change.

---

### Bug 10: iOS Doesn't Handle Backend Session Ending

**File:** `/puck-ios/Puck/Models/Sessions.swift` + `/puck-ios/Puck/Core/Network/IntentionalFocusSignalClient.swift`  
**Issue:** iPhone never reads backend. If backend session ended (by another device, or timeout), iPhone doesn't know.

**Scenario:** User starts session on iPhone at 10 AM. Closes the app. Backend server has no heartbeat mechanism to invalidate session. User re-opens app at 11 AM. App restores `activeFocusSession` from SwiftData (which was written at 10 AM and marked `endTime=nil`). App thinks session is still active, even though backend ended it due to idle 1+ hour.

**Impact:** iPhone UI shows "Focusing" but backend says session is inactive. BlockingService might continue to enforce based on stale local state.

**Fix Needed:** Add `GET /focus/active` poll on app foreground to sync back from backend.

---

### Bug 11: FocusModeController Notification Uses Deprecated Notification.Name

**File:** `/Intentional/FocusModeController.swift:127-131`  
**Issue:** Uses `NotificationCenter.default.post()` in addition to callback. Some observers might be registered to the Notification but not the callback, or vice versa. Creates two independent dispatch paths that can go out of sync.

**Impact:** UI observers might miss state changes if they only listen to callbacks but not notifications, or vice versa. Hard to debug.

**Fix Needed:** Use single dispatch mechanism (callback or notification, not both).

---

### Bug 12: Backend Toggle Endpoint Doesn't Check if Already Active

**File:** `/intentional-backend/main.py:3024-3028`  
**Issue:** When `action='start'`, backend unconditionally ends all existing active sessions, then creates new one. No check for idempotency.

**Race:** If two iPhone POSTs arrive in rapid succession (or multiple devices), both succeed, both end the previous session and start new. Last one wins.

**Impact:** Session ID might change unexpectedly. Clients expecting a stable session ID get surprised.

**Fix Needed:** Check if a session is already active for this account; if so, return current session ID (idempotent start).

---

## Summary Table: Risk Assessment

| Bug | Severity | Likelihood | Impact | Affected Clients |
|-----|----------|-----------|--------|------------------|
| No session TTL | HIGH | HIGH | Sessions sit forever, preventing new ones | Backend, Mac, all |
| No account ID on SwiftData model | HIGH | MEDIUM | Account switch UI corruption | iPhone |
| iPhone never syncs back | HIGH | HIGH | Stale local state, no recovery | iPhone, Mac |
| Mac loses state on restart | MEDIUM | MEDIUM | Transient inconsistency on boot | Mac |
| Poller doesn't reject stale sessions | MEDIUM | MEDIUM | Old sessions enforced indefinitely | Mac |
| disengageIfRemoteOriginated source confusion | MEDIUM | MEDIUM | Schedule sessions incorrectly stopped | Mac |
| Silent drop after max retries | MEDIUM-HIGH | MEDIUM | Failed syncs go unnoticed | iPhone |
| SessionID change not validated | LOW | LOW | Rare flicker/enforcement switch | Mac |
| WS reconnect broken post-boot | MEDIUM | MEDIUM | Real-time updates fail offline | Mac |
| iPhone doesn't handle backend session end | MEDIUM | HIGH | Enforcement continues on stale session | iPhone |
| Dual Notification + Callback dispatch | LOW | LOW | Observers out of sync | Mac |
| Toggle endpoint not idempotent | LOW | MEDIUM | Rapid-fire requests cause churn | Backend, iPhone |

---

## Conclusion

The three-client sync problem stems from:

1. **Three independent sources of truth** (iPhone SwiftData, Mac in-memory state, Backend Postgres), with no canonical arbiter or reconciliation protocol.
2. **Fire-and-forget architecture** (iPhone → backend), with no guarantee of delivery or feedback. Retries are best-effort.
3. **No session lifecycle management** on backend (no TTL, no heartbeat, no expiry).
4. **No state restoration** on Mac (loss on restart, no persistent store).
5. **No state sync-back** from backend to iPhone (iPhone never reads `GET /focus/active`).
6. **Multiple state machines on Mac** (poller vs. schedule), with fragile source-tracking coordination.
7. **No mutual exclusion or priority** between concurrent state changes (e.g., schedule vs. Puck, or two devices simultaneously).

Today's incident (iPhone local state wiped, backend state persisted) exposed the core problem: **no fallback to backend truth when local state is corrupted**.

A robust solution would establish a clear canonical state machine (likely backend-as-truth with local caching), add mutual exclusion around state transitions, implement session lifecycle (TTL, heartbeat, expiry), and ensure all clients can reconcile from a known-good backend state.

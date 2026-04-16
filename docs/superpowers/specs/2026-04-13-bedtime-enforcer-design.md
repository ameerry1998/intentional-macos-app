# Bedtime Enforcer — Design Spec

## Problem

macOS Screen Time bedtime is trivially bypassable (kill process, change clock, switch user). Users with ADHD or compulsive late-night screen habits need enforcement that actually holds — the same level of tamper resistance Intentional already provides for focus blocks.

## Solution

A fixed nightly bedtime with a 15-minute wind-down progression, one 10-minute snooze per night, and a 3-minute auto-sleep timer on the lockout screen. Only escape is a partner unlock code.

## Configuration

Stored in `~/Library/Application Support/Intentional/bedtime_settings.json`:

```json
{
  "enabled": true,
  "bedtimeStart": "23:00",
  "wakeTime": "07:00",
  "activeDays": [0, 1, 2, 3, 4, 5, 6],
  "partnerLocked": true
}
```

- **Bedtime start / wake time**: time pickers in Settings > Bedtime
- **Active days**: checkboxes (0=Sun, 6=Sat). Default: every night.
- **Partner-locked**: once set, requires partner code to modify settings. Uses existing partner lock system.
- **Wind-down duration**: fixed 15 minutes. Not user-configurable.

## Wind-Down Progression (fixed 15 min before bedtime start)

| Time | Phase | What Happens |
|------|-------|-------------|
| T-15 min | Notification | macOS notification: "Bedtime in 15 minutes — start wrapping up" |
| T-10 min | Red shift | Screen goes warm (reuse GrayscaleOverlayController red shift) |
| T-5 min | Grayscale | Screen desaturates (reuse GrayscaleOverlayController grayscale) |
| T-0 | Lockout | Full-screen overlay. Snooze available (if unused). |

## Lockout Overlay

Full-screen, non-dismissible, `.screenSaver` level window (reuse KeyableWindow pattern from FocusOverlayWindow).

### If snooze is available (first lockout of the night):

- Message: "Bedtime. Time to sleep."
- **"Snooze 10 min"** button — dismisses overlay, resets red shift/grayscale, returns to lockout after 10 min with snooze exhausted
- **"Sleep Now"** button — runs `pmset sleepnow`
- **"Enter Partner Code"** button — 6-digit code entry, dismisses overlay until wake time

### If snooze is exhausted (or wake-during-bedtime):

- Message: "Bedtime. Mac will sleep in 3:00"
- Countdown timer: 3 minutes → `pmset sleepnow` via shell
- **"Sleep Now"** button — immediate sleep
- **"Enter Partner Code"** button — dismisses overlay until wake time
- No snooze button

## Wake During Bedtime

If the Mac wakes (laptop opened, mouse moved) during bedtime hours after lockout has been shown:

- Skip wind-down entirely (already happened)
- Show lockout overlay immediately with 3-minute auto-sleep timer
- Snooze is NOT available (already used or this is a re-wake)
- Every wake = same 3-minute countdown to forced sleep

## Partner Code Flow

- User taps "Enter Partner Code" on lockout overlay
- 6-digit text field appears
- Code validated against existing `DaemonXPCClient.verifyUnlockCode()` system
- On success: overlay dismissed, bedtime enforcement paused until wake time
- On failure: "Invalid code" message, overlay stays

## State Machine

```
BedtimeState enum:
  .inactive        — outside bedtime hours, or bedtime disabled
  .windDown(phase) — within 15 min of bedtime (notification/redShift/grayscale)
  .lockedOut       — bedtime active, overlay shown
  .snoozed         — 10-min snooze active (one per night)
  .overridden      — partner code entered, free until wake time
  .sleeping        — pmset sleepnow issued
```

## Architecture

### New file: `BedtimeEnforcer.swift`

Single class that owns all bedtime logic. NOT integrated into ScheduleManager (bedtime is independent of the daily schedule).

**Responsibilities:**
- 10-second timer checks current time against bedtime settings
- Manages wind-down progression (delegates to existing GrayscaleOverlayController)
- Shows/dismisses lockout overlay
- Tracks snooze state (one per night, resets at wake time)
- Runs 3-minute auto-sleep countdown
- Listens for wake events from SleepWakeMonitor
- Calls `pmset sleepnow` via Process() shell command

**Integration points:**
- `AppDelegate` creates and owns `BedtimeEnforcer`
- `SleepWakeMonitor.onWake` callback triggers `bedtimeEnforcer.onMacWoke()`
- `GrayscaleOverlayController` reused for red shift and grayscale phases
- `DaemonXPCClient.verifyUnlockCode()` reused for partner code validation
- Settings UI in MainWindow adds Bedtime tab/section

### New file: `BedtimeOverlayView.swift`

SwiftUI view for the lockout overlay. Follows existing KeyableWindow + NSHostingView pattern.

### Modified files:
- `AppDelegate.swift` — instantiate BedtimeEnforcer, wire to SleepWakeMonitor
- `SleepWakeMonitor.swift` — add `onWake` callback for bedtime re-enforcement
- `MainWindow.swift` — add Bedtime settings section

### NOT modified:
- `ScheduleManager.swift` — bedtime is independent
- `DaemonXPCProtocol.swift` — no new XPC calls needed
- `FocusMonitor.swift` — bedtime doesn't interact with focus blocks

## Persistence

- `bedtime_settings.json` — config (bedtime/wake times, active days, partner lock)
- In-memory only: snooze state, current phase, override status (resets on app launch / wake time)
- Snooze-used flag resets daily at wake time

## Force Sleep Implementation

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
process.arguments = ["sleepnow"]
try? process.run()
```

Requires no special entitlements — `pmset sleepnow` works from any process.

## Clock Tamper Detection

macOS Screen Time's #1 bypass is changing the system clock. Intentional defends against this with a dual-layer approach.

### Layer 1: Monotonic drift detection (instant, offline)

On app launch, record an anchor: `(Date(), ProcessInfo.processInfo.systemUptime)`.

Every 10-second bedtime tick:
```
expectedTime = anchorDate + (currentUptime - anchorUptime)
drift = abs(Date().timeIntervalSince(expectedTime))
if drift > 120 seconds: clock was tampered with
```

`systemUptime` is a kernel monotonic counter — cannot be faked without a kernel exploit. Detects clock changes within 10 seconds.

On tamper detection: **fail-safe to bedtime active**, show lockout overlay, log tamper event.

### Layer 2: NTP re-anchoring (periodic, online)

Every hour (and on app launch, and on network change): query `time.apple.com` via NTP to get real UTC time. Update the monotonic anchor with verified time.

This prevents long-term monotonic drift from accumulating over days, and handles legitimate time zone changes from travel (NTP confirms the new clock is correct → no false positive).

### Combined flow

```
Every 10s tick:
  1. realTime = lastNTPTime + (currentUptime - uptimeAtLastNTP)
  2. if abs(Date() - realTime) > 2 min → TAMPER DETECTED → enforce bedtime
  3. if network available AND last NTP > 1 hour ago → refresh NTP anchor
  4. Use realTime (not Date()) for all bedtime checks
```

### Edge cases

| Scenario | Behavior |
|----------|----------|
| Travel (legit timezone change) | NTP confirms clock is correct → no false positive |
| Clock changed while online | NTP vs Date() mismatch → tamper detected within 10s |
| Clock changed while offline | Monotonic drift detected within 10s |
| Clock changed + app restarted | App startup does NTP check → catches it immediately |
| Clock changed + app restarted + offline | Monotonic anchor is fresh from restart, but NTP last-known-good is stale. If stale NTP + monotonic diverge from Date() by >2 min → tamper. If truly no NTP ever (first launch offline with wrong clock) → trust Date() as fallback (no defense possible) |

### Implementation: `TrustedClock.swift`

Pure utility, no UI dependencies. Testable.

```swift
class TrustedClock {
    func now() -> Date           // Returns best-known real time
    func isTampered() -> Bool    // True if system clock diverges from trusted time
    func refreshNTP()            // Async NTP query to re-anchor
}
```

All bedtime checks use `TrustedClock.now()` instead of `Date()`.

## Settings UI

Bedtime settings live inside the existing Schedule settings section (below daily schedule blocks). Fields:
- Bedtime start: time picker
- Wake time: time picker
- Active days: day-of-week checkboxes
- Enable/disable toggle
- Partner-locked indicator (when accountability partner is set)

## Lockout Overlay Design

Dark, sleep-friendly design (not glassmorphism). Minimal brightness — appropriate for 2 AM.
- Near-black background with subtle gradient
- Dim white text
- Buttons with low-contrast borders
- Moon/sleep iconography

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Bedtime spans midnight (11 PM → 7 AM) | Standard — check if current time is after start OR before end |
| App launched during bedtime | Skip wind-down, show lockout immediately |
| Partner code entered, then Mac sleeps and wakes | Stay overridden until wake time |
| User changes system clock | Detected by TrustedClock within 10s, fail-safe to bedtime active |
| Bedtime settings changed while bedtime is active | Take effect next night (current night's bedtime continues) |
| Multiple monitors | Overlay on ALL screens (same pattern as existing overlays) |

## Testing Strategy (TDD)

Pure logic extracted into testable units:

1. `BedtimeState` state machine — test all transitions
2. `shouldBeInBedtime(currentTime, settings)` — pure function, test with various times/days
3. `windDownPhase(currentTime, bedtimeStart)` — pure function, returns notification/redShift/grayscale/lockout
4. Snooze tracking — test one-per-night limit, reset at wake time
5. Auto-sleep countdown — test timer behavior
6. `TrustedClock` — test drift detection with simulated monotonic/NTP values
7. Clock tamper detection — test fail-safe behavior when Date() diverges from trusted time

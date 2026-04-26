# Bedtime Enforcer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tamper-resistant bedtime enforcer with 15-min wind-down, one snooze per night, 3-min auto-sleep lockout, partner code override, and clock tamper detection.

**Architecture:** Independent `BedtimeEnforcer` class (not in ScheduleManager). Reuses existing `GrayscaleOverlayController` for wind-down, `KeyableWindow` pattern for lockout overlay, `DaemonXPCClient.verifyUnlockCode()` for partner codes. New `TrustedClock` utility prevents system clock bypass via monotonic drift detection + NTP re-anchoring.

**Tech Stack:** Swift, SwiftUI, AppKit (NSWindow), Foundation (Process, Timer, NTP via UDP)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Intentional/TrustedClock.swift` | Create | Clock tamper detection: monotonic drift + NTP anchoring |
| `Intentional/BedtimeEnforcer.swift` | Create | Core bedtime logic: state machine, timer, snooze, wind-down |
| `Intentional/BedtimeOverlayView.swift` | Create | SwiftUI lockout overlay (dark, sleep-friendly) |
| `IntentionalTests/TrustedClockTests.swift` | Create | Tests for clock tamper detection |
| `IntentionalTests/BedtimeLogicTests.swift` | Create | Tests for bedtime state machine and time checks |
| `Intentional/SleepWakeMonitor.swift` | Modify | Add `onWake` callback closure |
| `Intentional/AppDelegate.swift` | Modify | Instantiate BedtimeEnforcer, wire to SleepWakeMonitor |
| `Intentional.xcodeproj/project.pbxproj` | Modify | Add new files to build |

---

## Task 1: TrustedClock — Pure Time Logic (TDD)

**Files:**
- Create: `Intentional/TrustedClock.swift`
- Create: `IntentionalTests/TrustedClockTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// IntentionalTests/TrustedClockTests.swift
import Foundation

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b { passed += 1 }
    else { failed += 1; print("  FAIL (\(file):\(line)): expected \(b), got \(a). \(msg)") }
}

func test(_ name: String, _ body: () -> Void) {
    print("  ▸ \(name)")
    body()
}

@main
struct TrustedClockTests {
    static func main() {
        print("\n🧪 TrustedClockTests\n")

        test("no drift when clocks agree") {
            let clock = TrustedClock()
            let anchor = Date()
            clock.setAnchor(date: anchor, uptime: 1000.0)
            let result = clock.detectDrift(currentDate: anchor.addingTimeInterval(60), currentUptime: 1060.0)
            assertEqual(result.isTampered, false)
        }

        test("detects forward clock change") {
            let clock = TrustedClock()
            let anchor = Date()
            clock.setAnchor(date: anchor, uptime: 1000.0)
            // System clock jumped 3 hours forward, but only 60s of real time passed
            let result = clock.detectDrift(
                currentDate: anchor.addingTimeInterval(3 * 3600),
                currentUptime: 1060.0
            )
            assertEqual(result.isTampered, true, "3-hour jump in 60s should be tampered")
        }

        test("detects backward clock change") {
            let clock = TrustedClock()
            let anchor = Date()
            clock.setAnchor(date: anchor, uptime: 1000.0)
            // System clock went back 2 hours, but 60s of real time passed
            let result = clock.detectDrift(
                currentDate: anchor.addingTimeInterval(-2 * 3600),
                currentUptime: 1060.0
            )
            assertEqual(result.isTampered, true, "2-hour backward jump should be tampered")
        }

        test("small drift under threshold is not tampered") {
            let clock = TrustedClock()
            let anchor = Date()
            clock.setAnchor(date: anchor, uptime: 1000.0)
            // 90 seconds of drift (under 120s threshold)
            let result = clock.detectDrift(
                currentDate: anchor.addingTimeInterval(60 + 90),
                currentUptime: 1060.0
            )
            assertEqual(result.isTampered, false, "90s drift should be within tolerance")
        }

        test("trustedNow uses monotonic offset from anchor") {
            let clock = TrustedClock()
            let anchor = Date()
            clock.setAnchor(date: anchor, uptime: 1000.0)
            let trusted = clock.trustedNow(currentUptime: 1300.0)
            let expected = anchor.addingTimeInterval(300.0)
            let diff = abs(trusted.timeIntervalSince(expected))
            assertEqual(diff < 1.0, true, "trustedNow should be anchor + elapsed uptime")
        }

        test("NTP anchor updates trusted time base") {
            let clock = TrustedClock()
            let oldAnchor = Date().addingTimeInterval(-3600) // 1 hour ago
            clock.setAnchor(date: oldAnchor, uptime: 1000.0)

            // NTP says real time is now (not 1 hour ago + elapsed)
            let ntpTime = Date()
            clock.updateFromNTP(ntpDate: ntpTime, uptime: 2000.0)

            let trusted = clock.trustedNow(currentUptime: 2060.0)
            let expected = ntpTime.addingTimeInterval(60.0)
            let diff = abs(trusted.timeIntervalSince(expected))
            assertEqual(diff < 1.0, true, "After NTP update, trustedNow should use new anchor")
        }

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed > 0 ? 1 : 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swiftc -o /tmp/clock-test Intentional/TrustedClock.swift IntentionalTests/TrustedClockTests.swift && /tmp/clock-test`
Expected: Compile error — `TrustedClock` not defined yet

- [ ] **Step 3: Write minimal TrustedClock implementation**

```swift
// Intentional/TrustedClock.swift
import Foundation

struct DriftResult {
    let isTampered: Bool
    let driftSeconds: TimeInterval
}

class TrustedClock {
    private var anchorDate: Date = Date()
    private var anchorUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private let tamperThresholdSeconds: TimeInterval = 120.0 // 2 minutes

    /// Set anchor explicitly (used in tests and on NTP refresh)
    func setAnchor(date: Date, uptime: TimeInterval) {
        anchorDate = date
        anchorUptime = uptime
    }

    /// Update anchor from a verified NTP response
    func updateFromNTP(ntpDate: Date, uptime: TimeInterval) {
        anchorDate = ntpDate
        anchorUptime = uptime
    }

    /// Compute trusted time from monotonic clock offset
    func trustedNow(currentUptime: TimeInterval? = nil) -> Date {
        let uptime = currentUptime ?? ProcessInfo.processInfo.systemUptime
        let elapsed = uptime - anchorUptime
        return anchorDate.addingTimeInterval(elapsed)
    }

    /// Detect if system clock has drifted from monotonic expectation
    func detectDrift(currentDate: Date? = nil, currentUptime: TimeInterval? = nil) -> DriftResult {
        let sysDate = currentDate ?? Date()
        let trusted = trustedNow(currentUptime: currentUptime)
        let drift = abs(sysDate.timeIntervalSince(trusted))
        return DriftResult(isTampered: drift > tamperThresholdSeconds, driftSeconds: drift)
    }

    /// Whether the system clock appears tampered right now
    func isTampered() -> Bool {
        return detectDrift().isTampered
    }

    /// Best-known real time
    func now() -> Date {
        return trustedNow()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swiftc -o /tmp/clock-test Intentional/TrustedClock.swift IntentionalTests/TrustedClockTests.swift && /tmp/clock-test`
Expected: 6 passed, 0 failed

- [ ] **Step 5: Commit**

```bash
git add Intentional/TrustedClock.swift IntentionalTests/TrustedClockTests.swift
git commit -m "feat: add TrustedClock with monotonic drift detection (TDD)"
```

---

## Task 2: Bedtime Time Logic — Pure Functions (TDD)

**Files:**
- Create: `IntentionalTests/BedtimeLogicTests.swift`
- Modify: `Intentional/BedtimeEnforcer.swift` (create with logic only, no UI)

- [ ] **Step 1: Write failing tests for bedtime time checks**

```swift
// IntentionalTests/BedtimeLogicTests.swift
import Foundation

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b { passed += 1 }
    else { failed += 1; print("  FAIL (\(file):\(line)): expected \(b), got \(a). \(msg)") }
}

func test(_ name: String, _ body: () -> Void) {
    print("  ▸ \(name)")
    body()
}

func makeDate(hour: Int, minute: Int) -> Date {
    var cal = Calendar.current
    cal.timeZone = TimeZone.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = hour
    comps.minute = minute
    comps.second = 0
    return cal.date(from: comps)!
}

@main
struct BedtimeLogicTests {
    static func main() {
        print("\n🧪 BedtimeLogicTests\n")

        let settings = BedtimeSettings(
            enabled: true,
            bedtimeStart: TimeOfDay(hour: 23, minute: 0),
            wakeTime: TimeOfDay(hour: 7, minute: 0),
            activeDays: [0, 1, 2, 3, 4, 5, 6],
            partnerLocked: false
        )

        // -- isInBedtime --

        test("11:30 PM is in bedtime (23:00-07:00)") {
            let result = BedtimeLogic.isInBedtime(at: makeDate(hour: 23, minute: 30), settings: settings)
            assertEqual(result, true)
        }

        test("2:00 AM is in bedtime (past midnight)") {
            let result = BedtimeLogic.isInBedtime(at: makeDate(hour: 2, minute: 0), settings: settings)
            assertEqual(result, true)
        }

        test("6:59 AM is in bedtime") {
            let result = BedtimeLogic.isInBedtime(at: makeDate(hour: 6, minute: 59), settings: settings)
            assertEqual(result, true)
        }

        test("7:00 AM is NOT in bedtime (wake time)") {
            let result = BedtimeLogic.isInBedtime(at: makeDate(hour: 7, minute: 0), settings: settings)
            assertEqual(result, false)
        }

        test("3:00 PM is NOT in bedtime") {
            let result = BedtimeLogic.isInBedtime(at: makeDate(hour: 15, minute: 0), settings: settings)
            assertEqual(result, false)
        }

        test("10:44 PM is NOT in bedtime (before 11 PM start)") {
            let result = BedtimeLogic.isInBedtime(at: makeDate(hour: 22, minute: 44), settings: settings)
            assertEqual(result, false)
        }

        // -- windDownPhase --

        test("22:45 is notification phase (T-15)") {
            let phase = BedtimeLogic.windDownPhase(at: makeDate(hour: 22, minute: 45), settings: settings)
            assertEqual(phase, .notification)
        }

        test("22:50 is redShift phase (T-10)") {
            let phase = BedtimeLogic.windDownPhase(at: makeDate(hour: 22, minute: 50), settings: settings)
            assertEqual(phase, .redShift)
        }

        test("22:55 is grayscale phase (T-5)") {
            let phase = BedtimeLogic.windDownPhase(at: makeDate(hour: 22, minute: 55), settings: settings)
            assertEqual(phase, .grayscale)
        }

        test("22:30 is no wind-down phase") {
            let phase = BedtimeLogic.windDownPhase(at: makeDate(hour: 22, minute: 30), settings: settings)
            assertEqual(phase, .none)
        }

        test("23:00 is no wind-down (bedtime started, not wind-down)") {
            let phase = BedtimeLogic.windDownPhase(at: makeDate(hour: 23, minute: 0), settings: settings)
            assertEqual(phase, .none)
        }

        // -- disabled --

        test("disabled settings returns not in bedtime") {
            let disabled = BedtimeSettings(
                enabled: false,
                bedtimeStart: TimeOfDay(hour: 23, minute: 0),
                wakeTime: TimeOfDay(hour: 7, minute: 0),
                activeDays: [0, 1, 2, 3, 4, 5, 6],
                partnerLocked: false
            )
            let result = BedtimeLogic.isInBedtime(at: makeDate(hour: 23, minute: 30), settings: disabled)
            assertEqual(result, false)
        }

        // -- day filtering --

        test("inactive day returns not in bedtime") {
            let weekdaysOnly = BedtimeSettings(
                enabled: true,
                bedtimeStart: TimeOfDay(hour: 23, minute: 0),
                wakeTime: TimeOfDay(hour: 7, minute: 0),
                activeDays: [1, 2, 3, 4, 5], // Mon-Fri only
                partnerLocked: false
            )
            // Find next Sunday
            var cal = Calendar.current
            var date = makeDate(hour: 23, minute: 30)
            while cal.component(.weekday, from: date) != 1 { // 1 = Sunday
                date = cal.date(byAdding: .day, value: 1, to: date)!
                var comps = cal.dateComponents([.year, .month, .day], from: date)
                comps.hour = 23; comps.minute = 30
                date = cal.date(from: comps)!
            }
            let result = BedtimeLogic.isInBedtime(at: date, settings: weekdaysOnly)
            assertEqual(result, false, "Sunday should not be in bedtime for weekdays-only")
        }

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed > 0 ? 1 : 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swiftc -o /tmp/bedtime-test IntentionalTests/BedtimeLogicTests.swift && /tmp/bedtime-test`
Expected: Compile error — `BedtimeSettings`, `BedtimeLogic`, `TimeOfDay`, `WindDownPhase` not defined

- [ ] **Step 3: Write minimal implementation**

```swift
// Intentional/BedtimeEnforcer.swift (initial — logic only, no UI yet)
import Foundation

struct TimeOfDay: Equatable, Codable {
    let hour: Int    // 0-23
    let minute: Int  // 0-59

    /// Minutes since midnight
    var minutesSinceMidnight: Int { hour * 60 + minute }
}

struct BedtimeSettings: Codable {
    var enabled: Bool
    var bedtimeStart: TimeOfDay
    var wakeTime: TimeOfDay
    var activeDays: [Int]  // 0=Sun, 1=Mon, ..., 6=Sat
    var partnerLocked: Bool
}

enum WindDownPhase: Equatable {
    case none
    case notification  // T-15 to T-10
    case redShift      // T-10 to T-5
    case grayscale     // T-5 to T-0
}

enum BedtimeState: Equatable {
    case inactive
    case windDown(WindDownPhase)
    case lockedOut
    case snoozed
    case overridden
}

enum BedtimeLogic {

    /// Is the given time within bedtime hours?
    static func isInBedtime(at date: Date, settings: BedtimeSettings) -> Bool {
        guard settings.enabled else { return false }

        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date) - 1 // 0=Sun
        guard settings.activeDays.contains(weekday) || settings.activeDays.contains(cal.component(.weekday, from: date.addingTimeInterval(-3600 * 6)) - 1) else {
            // Check if we're in the early-morning portion of a previous day's bedtime
            // e.g., Tuesday 2 AM is still Monday night's bedtime
            return false
        }

        let nowMinutes = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        let startMin = settings.bedtimeStart.minutesSinceMidnight
        let endMin = settings.wakeTime.minutesSinceMidnight

        if startMin > endMin {
            // Spans midnight: 23:00 → 07:00
            return nowMinutes >= startMin || nowMinutes < endMin
        } else {
            // Same day: 01:00 → 06:00 (unusual but valid)
            return nowMinutes >= startMin && nowMinutes < endMin
        }
    }

    /// What wind-down phase are we in? (15 min before bedtime)
    static func windDownPhase(at date: Date, settings: BedtimeSettings) -> WindDownPhase {
        guard settings.enabled else { return .none }

        let cal = Calendar.current
        let nowMinutes = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        let startMin = settings.bedtimeStart.minutesSinceMidnight

        let minutesBefore = startMin - nowMinutes
        // Handle wrap-around (if bedtime is at 00:30 and now is 23:50, minutesBefore would be negative)
        let adjustedMinutesBefore = minutesBefore < -720 ? minutesBefore + 1440 : minutesBefore

        if adjustedMinutesBefore <= 0 || adjustedMinutesBefore > 15 {
            return .none
        }

        if adjustedMinutesBefore > 10 {
            return .notification  // T-15 to T-10
        } else if adjustedMinutesBefore > 5 {
            return .redShift      // T-10 to T-5
        } else {
            return .grayscale     // T-5 to T-0
        }
    }
}
```

- [ ] **Step 4: Compile both and run tests**

Run: `swiftc -o /tmp/bedtime-test Intentional/BedtimeEnforcer.swift IntentionalTests/BedtimeLogicTests.swift && /tmp/bedtime-test`
Expected: All tests pass

- [ ] **Step 5: Fix day-filtering edge case if needed and re-run**

The `isInBedtime` day check needs to handle early-morning hours correctly (2 AM Tuesday is Monday night's bedtime). Verify the test for inactive days passes. If not, fix the day-of-week calculation for pre-midnight vs post-midnight checks.

Run: `swiftc -o /tmp/bedtime-test Intentional/BedtimeEnforcer.swift IntentionalTests/BedtimeLogicTests.swift && /tmp/bedtime-test`
Expected: All 12 tests pass, 0 failed

- [ ] **Step 6: Commit**

```bash
git add Intentional/BedtimeEnforcer.swift IntentionalTests/BedtimeLogicTests.swift
git commit -m "feat: add BedtimeLogic pure functions with time checks and wind-down phases (TDD)"
```

---

## Task 3: BedtimeOverlayView — Dark Lockout Screen

**Files:**
- Create: `Intentional/BedtimeOverlayView.swift`

- [ ] **Step 1: Create the SwiftUI overlay view**

```swift
// Intentional/BedtimeOverlayView.swift
import SwiftUI

class BedtimeOverlayViewModel: ObservableObject {
    @Published var countdownSeconds: Int = 180  // 3 minutes
    @Published var snoozeAvailable: Bool = true
    @Published var showCodeEntry: Bool = false
    @Published var codeText: String = ""
    @Published var codeError: String = ""

    var onSnooze: (() -> Void)?
    var onSleepNow: (() -> Void)?
    var onCodeSubmit: ((String) -> Void)?

    var countdownFormatted: String {
        let min = countdownSeconds / 60
        let sec = countdownSeconds % 60
        return String(format: "%d:%02d", min, sec)
    }
}

struct BedtimeOverlayView: View {
    @ObservedObject var viewModel: BedtimeOverlayViewModel

    var body: some View {
        ZStack {
            // Near-black background
            LinearGradient(
                colors: [Color(white: 0.04), Color(white: 0.02)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 32) {
                Spacer()

                // Moon icon
                Text("🌙")
                    .font(.system(size: 64))

                // Heading
                if viewModel.snoozeAvailable {
                    Text("Bedtime")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundColor(Color(white: 0.7))
                    Text("Time to sleep.")
                        .font(.system(size: 22))
                        .foregroundColor(Color(white: 0.4))
                } else {
                    Text("Bedtime")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundColor(Color(white: 0.7))
                    Text("Mac will sleep in")
                        .font(.system(size: 22))
                        .foregroundColor(Color(white: 0.4))
                    Text(viewModel.countdownFormatted)
                        .font(.system(size: 72, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                }

                Spacer()

                // Buttons
                if !viewModel.showCodeEntry {
                    VStack(spacing: 16) {
                        if viewModel.snoozeAvailable {
                            Button(action: { viewModel.onSnooze?() }) {
                                Text("Snooze 10 min")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(Color(white: 0.6))
                                    .frame(width: 280, height: 50)
                                    .background(Color(white: 0.12))
                                    .cornerRadius(12)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.2), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: { viewModel.onSleepNow?() }) {
                            Text("Sleep Now")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(Color(white: 0.8))
                                .frame(width: 280, height: 50)
                                .background(Color(white: 0.08))
                                .cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Button(action: { viewModel.showCodeEntry = true }) {
                            Text("Enter Partner Code")
                                .font(.system(size: 14))
                                .foregroundColor(Color(white: 0.35))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    // Code entry
                    VStack(spacing: 12) {
                        TextField("6-digit code", text: $viewModel.codeText)
                            .font(.system(size: 28, weight: .medium, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.plain)
                            .frame(width: 200, height: 50)
                            .background(Color(white: 0.08))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.2), lineWidth: 1))
                            .foregroundColor(Color(white: 0.7))

                        if !viewModel.codeError.isEmpty {
                            Text(viewModel.codeError)
                                .font(.system(size: 14))
                                .foregroundColor(.red.opacity(0.7))
                        }

                        HStack(spacing: 12) {
                            Button("Cancel") { viewModel.showCodeEntry = false; viewModel.codeText = ""; viewModel.codeError = "" }
                                .font(.system(size: 14))
                                .foregroundColor(Color(white: 0.4))
                                .buttonStyle(.plain)

                            Button("Submit") { viewModel.onCodeSubmit?(viewModel.codeText) }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color(white: 0.7))
                                .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()
                    .frame(height: 80)
            }
        }
        .ignoresSafeArea()
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -target Intentional -destination 'platform=macOS,arch=arm64' 2>&1 | grep "error:" | grep -v "mlx-swift\|swift-transformers\|Info.plist" | head -5`
Expected: No errors from our files (mlx-swift errors are pre-existing)

- [ ] **Step 3: Commit**

```bash
git add Intentional/BedtimeOverlayView.swift
git commit -m "feat: add BedtimeOverlayView dark lockout screen"
```

---

## Task 4: BedtimeEnforcer — Full Controller Class

**Files:**
- Modify: `Intentional/BedtimeEnforcer.swift` (add the controller class below the existing logic)

- [ ] **Step 1: Add BedtimeEnforcer controller class**

Append to `Intentional/BedtimeEnforcer.swift` after the existing `BedtimeLogic` enum:

```swift
class BedtimeEnforcer {
    weak var appDelegate: AppDelegate?
    private var grayscaleController: GrayscaleOverlayController?

    // State
    private(set) var state: BedtimeState = .inactive
    private var settings: BedtimeSettings?
    private var snoozeUsedTonight: Bool = false
    private var overlayWindows: [NSWindow] = []
    private var overlayViewModel: BedtimeOverlayViewModel?

    // Timers
    private var tickTimer: Timer?
    private var countdownTimer: Timer?
    private var snoozeTimer: Timer?
    private var countdownSeconds: Int = 180

    // Clock
    private let trustedClock = TrustedClock()

    // Persistence
    private var settingsURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bedtime_settings.json")
    }

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
        loadSettings()
    }

    // MARK: - Settings Persistence

    func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONDecoder().decode(BedtimeSettings.self, from: data) else {
            settings = nil
            return
        }
        settings = decoded
        appDelegate?.postLog("🌙 Bedtime settings loaded: \(decoded.bedtimeStart.hour):\(String(format: "%02d", decoded.bedtimeStart.minute)) → \(decoded.wakeTime.hour):\(String(format: "%02d", decoded.wakeTime.minute))")
    }

    func saveSettings(_ newSettings: BedtimeSettings) {
        settings = newSettings
        if let data = try? JSONEncoder().encode(newSettings) {
            try? data.write(to: settingsURL)
        }
        recalculate()
    }

    // MARK: - Lifecycle

    func start() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.recalculate()
        }
        recalculate()
        appDelegate?.postLog("🌙 BedtimeEnforcer started")
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        dismissOverlay()
        grayscaleController?.restoreSaturation()
        state = .inactive
    }

    // MARK: - Core Tick

    private func recalculate() {
        guard let settings = settings, settings.enabled else {
            if state != .inactive {
                transition(to: .inactive)
            }
            return
        }

        // Check clock tamper
        if trustedClock.isTampered() {
            appDelegate?.postLog("🚨 Clock tamper detected — enforcing bedtime")
            if state != .lockedOut && state != .overridden {
                transition(to: .lockedOut)
            }
            return
        }

        let now = trustedClock.now()

        // Don't override partner code or snooze states
        if state == .overridden || state == .snoozed { return }

        // Check if bedtime is active
        if BedtimeLogic.isInBedtime(at: now, settings: settings) {
            if state != .lockedOut {
                transition(to: .lockedOut)
            }
            return
        }

        // Check wind-down
        let phase = BedtimeLogic.windDownPhase(at: now, settings: settings)
        if phase != .none {
            transition(to: .windDown(phase))
            return
        }

        // Outside bedtime — reset nightly state
        if state != .inactive {
            snoozeUsedTonight = false
            transition(to: .inactive)
        }
    }

    // MARK: - State Transitions

    private func transition(to newState: BedtimeState) {
        let oldState = state
        state = newState
        appDelegate?.postLog("🌙 Bedtime state: \(oldState) → \(newState)")

        switch newState {
        case .inactive:
            dismissOverlay()
            grayscaleController?.restoreSaturation()
            countdownTimer?.invalidate()

        case .windDown(let phase):
            dismissOverlay()
            switch phase {
            case .notification:
                if oldState != .windDown(.notification) {
                    sendNotification("Bedtime in 15 minutes — start wrapping up")
                }
                grayscaleController?.restoreSaturation()
            case .redShift:
                if grayscaleController == nil {
                    grayscaleController = GrayscaleOverlayController()
                }
                grayscaleController?.startDesaturation()
            case .grayscale:
                if grayscaleController == nil {
                    grayscaleController = GrayscaleOverlayController()
                }
                grayscaleController?.startDesaturation()
            case .none:
                break
            }

        case .lockedOut:
            grayscaleController?.restoreSaturation()
            showLockoutOverlay(snoozeAvailable: !snoozeUsedTonight)
            if snoozeUsedTonight {
                startAutoSleepCountdown()
            }

        case .snoozed:
            dismissOverlay()
            grayscaleController?.restoreSaturation()
            countdownTimer?.invalidate()
            snoozeUsedTonight = true
            snoozeTimer = Timer.scheduledTimer(withTimeInterval: 600.0, repeats: false) { [weak self] _ in
                self?.appDelegate?.postLog("🌙 Snooze expired — returning to lockout")
                self?.transition(to: .lockedOut)
            }

        case .overridden:
            dismissOverlay()
            grayscaleController?.restoreSaturation()
            countdownTimer?.invalidate()
            snoozeTimer?.invalidate()
        }
    }

    // MARK: - Wake Handler

    func onMacWoke() {
        guard let settings = settings, settings.enabled else { return }
        if state == .overridden { return }

        let now = trustedClock.now()
        if BedtimeLogic.isInBedtime(at: now, settings: settings) {
            appDelegate?.postLog("🌙 Mac woke during bedtime — immediate lockout")
            snoozeUsedTonight = true // No snooze on re-wake
            transition(to: .lockedOut)
        }
    }

    // MARK: - Overlay

    private func showLockoutOverlay(snoozeAvailable: Bool) {
        guard overlayWindows.isEmpty else { return }

        let vm = BedtimeOverlayViewModel()
        vm.snoozeAvailable = snoozeAvailable
        vm.onSnooze = { [weak self] in self?.transition(to: .snoozed) }
        vm.onSleepNow = { [weak self] in self?.forceSleep() }
        vm.onCodeSubmit = { [weak self] code in self?.verifyCode(code) }
        self.overlayViewModel = vm

        for screen in NSScreen.screens {
            let view = BedtimeOverlayView(viewModel: vm)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = screen.frame

            let window = KeyableWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }

        appDelegate?.postLog("🌙 Bedtime lockout overlay shown on \(NSScreen.screens.count) screen(s)")
    }

    private func dismissOverlay() {
        for window in overlayWindows { window.close() }
        overlayWindows.removeAll()
        overlayViewModel = nil
    }

    // MARK: - Auto-Sleep Countdown

    private func startAutoSleepCountdown() {
        countdownSeconds = 180
        overlayViewModel?.countdownSeconds = 180
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.countdownSeconds -= 1
            self.overlayViewModel?.countdownSeconds = self.countdownSeconds
            if self.countdownSeconds <= 0 {
                self.countdownTimer?.invalidate()
                self.forceSleep()
            }
        }
    }

    // MARK: - Force Sleep

    private func forceSleep() {
        appDelegate?.postLog("🌙 Forcing Mac to sleep via pmset")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        try? process.run()
    }

    // MARK: - Partner Code

    private func verifyCode(_ code: String) {
        appDelegate?.daemonClient.verifyUnlockCode(code) { [weak self] valid in
            DispatchQueue.main.async {
                if valid {
                    self?.appDelegate?.postLog("🌙 Partner code accepted — bedtime overridden")
                    self?.transition(to: .overridden)
                } else {
                    self?.overlayViewModel?.codeError = "Invalid code"
                    self?.appDelegate?.postLog("🌙 Invalid partner code entered")
                }
            }
        }
    }

    // MARK: - Notification

    private func sendNotification(_ message: String) {
        let notification = NSUserNotification()
        notification.title = "Intentional"
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -target Intentional -destination 'platform=macOS,arch=arm64' 2>&1 | grep "error:" | grep -v "mlx-swift\|swift-transformers\|Info.plist" | head -5`
Expected: No errors from our files. If `NSUserNotification` is deprecated, switch to `UNUserNotificationCenter`.

- [ ] **Step 3: Commit**

```bash
git add Intentional/BedtimeEnforcer.swift
git commit -m "feat: add BedtimeEnforcer controller with state machine, snooze, auto-sleep"
```

---

## Task 5: Wire Into AppDelegate + SleepWakeMonitor

**Files:**
- Modify: `Intentional/SleepWakeMonitor.swift` — add `onWake` callback
- Modify: `Intentional/AppDelegate.swift` — instantiate and wire BedtimeEnforcer

- [ ] **Step 1: Add onWake callback to SleepWakeMonitor**

In `SleepWakeMonitor.swift`, add after the existing property declarations (around line 20):

```swift
var onWake: (() -> Void)?
```

In `computerDidWake()` (around line 89), add after the existing `contentSafetyMonitor?.onWake()` call:

```swift
onWake?()
```

- [ ] **Step 2: Add BedtimeEnforcer to AppDelegate**

In `AppDelegate.swift`, add property declaration (around line 46, near other controllers):

```swift
var bedtimeEnforcer: BedtimeEnforcer?
```

In `applicationDidFinishLaunching`, after the IntentionalModeController initialization block (around line 415), add:

```swift
// Bedtime Enforcer
bedtimeEnforcer = BedtimeEnforcer(appDelegate: self)
sleepWakeMonitor?.onWake = { [weak self] in
    self?.bedtimeEnforcer?.onMacWoke()
}
bedtimeEnforcer?.start()
postLog("🌙 BedtimeEnforcer initialized and started")
```

- [ ] **Step 3: Add new files to Xcode project**

Add `TrustedClock.swift`, `BedtimeEnforcer.swift`, and `BedtimeOverlayView.swift` to `project.pbxproj` following the QuitPolicy.swift pattern (A400000X for BedtimeEnforcer, A500000X for BedtimeOverlayView, A600000X for TrustedClock):

PBXBuildFile, PBXFileReference, PBXGroup, and PBXSourcesBuildPhase entries for each.

- [ ] **Step 4: Build full project**

Run: `xcodebuild build -target Intentional -destination 'platform=macOS,arch=arm64' 2>&1 | grep "error:" | grep -v "mlx-swift\|swift-transformers\|Info.plist" | head -10`
Expected: BUILD SUCCEEDED (ignoring pre-existing mlx-swift errors)

- [ ] **Step 5: Commit**

```bash
git add Intentional/SleepWakeMonitor.swift Intentional/AppDelegate.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat: wire BedtimeEnforcer into AppDelegate and SleepWakeMonitor"
```

---

## Task 6: NTP Refresh for TrustedClock

**Files:**
- Modify: `Intentional/TrustedClock.swift` — add NTP query via UDP

- [ ] **Step 1: Add NTP query method**

Add to `TrustedClock`:

```swift
/// Query NTP server and update anchor. Call on app launch and periodically.
func refreshFromNTP(completion: ((Bool) -> Void)? = nil) {
    DispatchQueue.global().async { [weak self] in
        guard let self = self else { return }
        guard let ntpDate = self.queryNTP(host: "time.apple.com") else {
            completion?(false)
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            self.updateFromNTP(ntpDate: ntpDate, uptime: uptime)
            completion?(true)
        }
    }
}

/// Minimal NTP client (RFC 4330) — returns server timestamp
private func queryNTP(host: String, port: Int = 123, timeout: TimeInterval = 5) -> Date? {
    let socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard socket >= 0 else { return nil }
    defer { close(socket) }

    // Set timeout
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // Resolve host
    guard let hostEntry = gethostbyname(host) else { return nil }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    memcpy(&addr.sin_addr, hostEntry.pointee.h_addr_list[0], Int(hostEntry.pointee.h_length))

    // Build NTP packet (48 bytes, LI=0, VN=4, Mode=3 client)
    var packet = [UInt8](repeating: 0, count: 48)
    packet[0] = 0x23 // LI=0, VN=4, Mode=3

    // Send
    let sent = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            sendto(socket, &packet, packet.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard sent == packet.count else { return nil }

    // Receive
    var response = [UInt8](repeating: 0, count: 48)
    let received = recv(socket, &response, response.count, 0)
    guard received == 48 else { return nil }

    // Extract transmit timestamp (bytes 40-47): seconds since 1900-01-01
    let seconds = UInt32(response[40]) << 24 | UInt32(response[41]) << 16 | UInt32(response[42]) << 8 | UInt32(response[43])
    let fraction = UInt32(response[44]) << 24 | UInt32(response[45]) << 16 | UInt32(response[46]) << 8 | UInt32(response[47])

    // NTP epoch is 1900-01-01, Unix epoch is 1970-01-01 (diff: 2208988800 seconds)
    let ntpEpochDiff: TimeInterval = 2208988800.0
    let timestamp = TimeInterval(seconds) - ntpEpochDiff + TimeInterval(fraction) / 4294967296.0

    return Date(timeIntervalSince1970: timestamp)
}
```

- [ ] **Step 2: Add periodic NTP refresh in BedtimeEnforcer**

In `BedtimeEnforcer.start()`, add after the tick timer setup:

```swift
// Initial NTP anchor
trustedClock.refreshFromNTP()

// Hourly NTP refresh
Timer.scheduledTimer(withTimeInterval: 3600.0, repeats: true) { [weak self] _ in
    self?.trustedClock.refreshFromNTP()
}
```

- [ ] **Step 3: Build and verify**

Run: `xcodebuild build -target Intentional -destination 'platform=macOS,arch=arm64' 2>&1 | grep "error:" | grep -v "mlx-swift\|swift-transformers\|Info.plist" | head -5`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add Intentional/TrustedClock.swift Intentional/BedtimeEnforcer.swift
git commit -m "feat: add NTP refresh to TrustedClock for anti-clock-tamper"
```

---

## Task 7: Settings UI Integration

**Files:**
- Modify: `Intentional/MainWindow.swift` — add bedtime settings to Schedule section

- [ ] **Step 1: Add bedtime settings handlers**

Add JavaScript message handlers for bedtime settings in `MainWindow.swift`, following the existing `GET_SCHEDULE_STATE` / `SET_SCHEDULE` pattern. Add:

- `GET_BEDTIME_SETTINGS` — returns current bedtime config JSON
- `SAVE_BEDTIME_SETTINGS` — validates partner lock, saves new settings, calls `bedtimeEnforcer.saveSettings()`

Wire these in the `userContentController(_:didReceive:)` method alongside existing Schedule handlers.

- [ ] **Step 2: Build and verify**

Run: `xcodebuild build -target Intentional -destination 'platform=macOS,arch=arm64' 2>&1 | grep "error:" | grep -v "mlx-swift\|swift-transformers\|Info.plist" | head -5`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add Intentional/MainWindow.swift
git commit -m "feat: add bedtime settings UI handlers in Schedule section"
```

---

## Verification

After all tasks complete:

1. Build PKG: `./scripts/build-pkg.sh`
2. Install PKG on test Mac
3. Open Settings > Schedule > Bedtime, set 11 PM → 7 AM
4. Wait for wind-down (or temporarily set bedtime to 2 min from now for testing)
5. Verify: notification at T-15, red shift at T-10, grayscale at T-5, lockout at T-0
6. Verify: snooze works once, second lockout has 3-min countdown
7. Verify: Sleep Now puts Mac to sleep
8. Verify: wake during bedtime → instant lockout with countdown
9. Verify: partner code overrides until wake time
10. Verify: changing system clock triggers tamper detection and enforces bedtime

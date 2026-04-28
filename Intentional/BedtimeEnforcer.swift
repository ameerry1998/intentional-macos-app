// Intentional/BedtimeEnforcer.swift
// Bedtime time-checking logic as pure, testable functions.
// No UI, no timers, no AppKit — just data types and deterministic computations.

import Foundation
import AppKit
import SwiftUI
import UserNotifications

// MARK: - Data Types

struct TimeOfDay: Equatable, Codable {
    let hour: Int    // 0-23
    let minute: Int  // 0-59

    var minutesSinceMidnight: Int { hour * 60 + minute }
}

struct BedtimeSettings: Codable {
    var enabled: Bool
    var bedtimeStart: TimeOfDay
    var wakeTime: TimeOfDay
    var activeDays: [Int]   // 0=Sun, 1=Mon, ..., 6=Sat
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

// MARK: - Pure Logic

enum BedtimeLogic {

    /// Is the given time within bedtime hours? Handles midnight crossover.
    ///
    /// For midnight-crossing bedtimes (e.g. 23:00-07:00):
    /// - If current time >= bedtimeStart, the relevant day is TODAY.
    /// - If current time < wakeTime (after midnight), the relevant day is YESTERDAY
    ///   (because we're still in last night's bedtime window).
    static func isInBedtime(at date: Date, settings: BedtimeSettings) -> Bool {
        guard settings.enabled else { return false }

        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let currentMinutes = hour * 60 + minute

        let startMinutes = settings.bedtimeStart.minutesSinceMidnight
        let endMinutes = settings.wakeTime.minutesSinceMidnight

        let inRange: Bool
        if startMinutes > endMinutes {
            // Midnight crossover: e.g. 23:00 (1380) to 07:00 (420)
            // In range if current >= start OR current < end
            inRange = currentMinutes >= startMinutes || currentMinutes < endMinutes
        } else {
            // Same-day range: e.g. 22:00 to 23:30
            inRange = currentMinutes >= startMinutes && currentMinutes < endMinutes
        }

        guard inRange else { return false }

        // Day-of-week check: figure out which day "started" this bedtime window.
        let relevantDay: Int
        if startMinutes > endMinutes && currentMinutes < endMinutes {
            // We're past midnight — this is yesterday's bedtime.
            // Calendar weekday: 1=Sun ... 7=Sat. Our format: 0=Sun ... 6=Sat.
            let yesterday = cal.date(byAdding: .day, value: -1, to: date)!
            let weekday = cal.component(.weekday, from: yesterday) // 1-7
            relevantDay = weekday - 1 // 0-6
        } else {
            let weekday = cal.component(.weekday, from: date) // 1-7
            relevantDay = weekday - 1 // 0-6
        }

        return settings.activeDays.contains(relevantDay)
    }

    /// What wind-down phase for the given time? (15 minutes before bedtime)
    ///
    /// Phases:
    /// - T-15 to T-10: .notification
    /// - T-10 to T-5:  .redShift
    /// - T-5 to T-0:   .grayscale
    /// - Otherwise:     .none
    ///
    /// Returns .none if already in bedtime or if disabled.
    static func windDownPhase(at date: Date, settings: BedtimeSettings) -> WindDownPhase {
        guard settings.enabled else { return .none }

        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let currentMinutes = hour * 60 + minute

        let startMinutes = settings.bedtimeStart.minutesSinceMidnight

        // Minutes until bedtime (handle wrap-around for midnight).
        var minutesUntilBedtime = startMinutes - currentMinutes
        if minutesUntilBedtime < 0 {
            minutesUntilBedtime += 1440  // wrap around midnight
        }

        // If bedtime has started (minutesUntilBedtime == 0 or we're in bedtime), no wind-down.
        // Wind-down is only the 15 minutes BEFORE bedtime.
        if minutesUntilBedtime == 0 || minutesUntilBedtime > 15 {
            return .none
        }

        // Also return .none if it wrapped around and we're actually far away
        // (e.g. at 2 AM, bedtime 23:00 => minutesUntilBedtime = 1260, which is > 15)
        // Already handled above.

        // minutesUntilBedtime is in 1...15
        if minutesUntilBedtime > 10 {
            // 11-15 minutes before: notification
            return .notification
        } else if minutesUntilBedtime > 5 {
            // 6-10 minutes before: redShift
            return .redShift
        } else {
            // 1-5 minutes before: grayscale
            return .grayscale
        }
    }
}

// MARK: - Controller

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
    private var ntpTimer: Timer?
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

    /// Apply settings pulled from the backend. Distinct from saveSettings(_:)
    /// (the legacy "user edited locally on Mac" path). The cross-device source
    /// of truth is the backend, fed via BedtimeConfigSync. The on-disk cache
    /// is overwritten with the DTO format by BedtimeConfigSync, so we don't
    /// rewrite it here. Just take the new values and recalculate.
    func applyRemoteSettings(_ newSettings: BedtimeSettings) {
        self.settings = newSettings
        recalculate()
    }

    // MARK: - Lifecycle

    func start() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.recalculate()
        }
        recalculate()

        // NTP refresh at startup
        trustedClock.refreshFromNTP()

        // Hourly NTP re-anchor
        ntpTimer = Timer.scheduledTimer(withTimeInterval: 3600.0, repeats: true) { [weak self] _ in
            self?.trustedClock.refreshFromNTP()
        }

        appDelegate?.postLog("🌙 BedtimeEnforcer started")
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        ntpTimer?.invalidate()
        ntpTimer = nil
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
        let content = UNMutableNotificationContent()
        content.title = "Intentional"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

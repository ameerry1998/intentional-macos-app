// Intentional/BedtimeEnforcer.swift
// Bedtime time-checking logic (pure functions) + state-machine controller.
//
// Apr 2026 rewrite — per
// docs/superpowers/plans/2026-04-29-bedtime-lock-loop-and-duration-extensions.md:
//   - Full-screen blanket overlay (BedtimeOverlayView) deleted; replaced by
//     BedtimeLockLoop which triggers macOS's native Lock Screen every 10s.
//   - State machine simplified: inactive / windDown / locked / released.
//     `snoozed` and `overridden` are gone (the unlock flow is now duration-
//     limited via partner code; release status comes from backend
//     bedtime_unlock_requests.released_until).
//   - `forceSleep` (pmset) removed; the OS lock screen IS the enforcement.
//   - Wind-down notification cascade is owned by BedtimeWindDownController.
//   - GrayscaleOverlayController references for the windDown phases are
//     removed; that controller still ships for FocusMonitor's distraction
//     desaturation, but bedtime no longer drives it.

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

/// Wind-down phase relative to bedtime. The legacy redShift / grayscale
/// phases are gone (handled — or not — by global enforcement in
/// FocusMonitor); bedtime wind-down is now purely informational
/// (notifications + pill mode change). Phase reflects how close we are.
enum WindDownPhase: Equatable {
    case none
    case t30   // T-30 to T-15 — minimizable pill
    case t15   // T-15 to T-5  — pill stays
    case t5    // T-5 to T-1   — pill stays, no minimize
    case t1    // T-1 to T-0   — countdown
}

/// Simplified bedtime state machine. The legacy `.snoozed` and
/// `.overridden` cases are gone — release status now lives in backend
/// `bedtime_unlock_requests.released_until` and is treated as `.released`
/// while in effect.
enum BedtimeState: Equatable {
    case inactive
    case windDown(WindDownPhase)
    /// Active bedtime — BedtimeLockLoop drives the system lock screen.
    case locked
    /// Partner code verified; backend released_until covers a duration
    /// window. While released, no lock loop, no wind-down.
    case released
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

    /// What wind-down phase for the given time?
    /// - T-30 to T-15: .t30
    /// - T-15 to T-5:  .t15
    /// - T-5 to T-1:   .t5
    /// - T-1 to T-0:   .t1
    /// Returns .none if outside the 30-minute wind-down window.
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

        // No wind-down outside [1, 30] minutes before bedtime.
        if minutesUntilBedtime <= 0 || minutesUntilBedtime > 30 {
            return .none
        }

        if minutesUntilBedtime > 15 {
            return .t30  // 16-30 min — minimizable
        } else if minutesUntilBedtime > 5 {
            return .t15  // 6-15 min — pill stays
        } else if minutesUntilBedtime > 1 {
            return .t5   // 2-5 min — pill stays, no minimize
        } else {
            return .t1   // 1 min — countdown
        }
    }

    /// Minutes until bedtime from `date`. Returns 0 if already in bedtime
    /// or wind-down past bedtimeStart. Bounded to [0, 1440).
    static func minutesUntilBedtime(at date: Date, settings: BedtimeSettings) -> Int {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let currentMinutes = hour * 60 + minute
        let startMinutes = settings.bedtimeStart.minutesSinceMidnight
        var diff = startMinutes - currentMinutes
        if diff < 0 {
            diff += 1440
        }
        return diff
    }
}

// MARK: - Controller

class BedtimeEnforcer {
    weak var appDelegate: AppDelegate?

    /// Notified on every state transition. AppDelegate uses this to drive
    /// the pill widget (windDown / locked / dismiss). Old → New.
    var onStateChanged: ((BedtimeState, BedtimeState) -> Void)?

    // State
    private(set) var state: BedtimeState = .inactive
    private var settings: BedtimeSettings?

    // Cached for clients (e.g. pill rendering) so they don't have to read
    // the file from disk again.
    var currentSettings: BedtimeSettings? { settings }

    // Timers
    private var tickTimer: Timer?
    private var ntpTimer: Timer?

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

    /// Apply settings pulled from the backend by `BedtimeConfigSync`. Distinct
    /// from `saveSettings(_:)` (the legacy "user edited locally on Mac" path).
    /// The cross-device source of truth is the backend; the on-disk cache is
    /// overwritten with the DTO format by `BedtimeConfigSync` so we don't
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
        ntpTimer?.invalidate()
        ntpTimer = nil
        Task { @MainActor in
            BedtimeLockLoop.shared.stop()
            await BedtimeWindDownController.shared.clearPending()
        }
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

        // Check clock tamper — defensively force locked while tampered.
        if trustedClock.isTampered() {
            appDelegate?.postLog("🚨 Clock tamper detected — enforcing bedtime")
            if state != .locked {
                transition(to: .locked)
            }
            return
        }

        let now = trustedClock.now()

        // Released state is owned externally (markReleased sets it). Stay
        // released until released_until passes — caller will transition us
        // back to .inactive / .locked via recalculate or explicit reset.
        if state == .released { return }

        // In bedtime → locked
        if BedtimeLogic.isInBedtime(at: now, settings: settings) {
            if state != .locked {
                transition(to: .locked)
            }
            return
        }

        // Wind-down phase
        let phase = BedtimeLogic.windDownPhase(at: now, settings: settings)
        if phase != .none {
            // Only transition when phase actually changed; otherwise the
            // pill mode would re-render every tick.
            if case .windDown(let current) = state, current == phase {
                return
            }
            transition(to: .windDown(phase))
            return
        }

        // Outside bedtime + outside wind-down — schedule tonight's
        // notifications (idempotent) and ensure inactive.
        scheduleWindDownForTonight(settings: settings, now: now)
        if state != .inactive {
            transition(to: .inactive)
        }
    }

    private func scheduleWindDownForTonight(settings: BedtimeSettings, now: Date) {
        let cal = Calendar.current
        guard let nextBedtime = cal.date(
            bySettingHour: settings.bedtimeStart.hour,
            minute: settings.bedtimeStart.minute,
            second: 0,
            of: now
        ) else { return }
        let target = nextBedtime > now
            ? nextBedtime
            : (cal.date(byAdding: .day, value: 1, to: nextBedtime) ?? nextBedtime)
        Task { @MainActor in
            await BedtimeWindDownController.shared.schedule(forBedtime: target)
        }
    }

    // MARK: - State Transitions

    private func transition(to newState: BedtimeState) {
        let oldState = state
        state = newState
        appDelegate?.postLog("🌙 Bedtime state: \(oldState) → \(newState)")

        switch newState {
        case .inactive:
            Task { @MainActor in BedtimeLockLoop.shared.stop() }

        case .windDown:
            // Wind-down notifications are pre-scheduled by
            // scheduleWindDownForTonight(); pill mode transitions are driven
            // by onStateChanged → AppDelegate (Phase 3). Stop the lock
            // loop just in case (defensive — should already be stopped).
            Task { @MainActor in BedtimeLockLoop.shared.stop() }

        case .locked:
            Task { @MainActor in
                BedtimeLockLoop.shared.start()
                await BedtimeWindDownController.shared.clearPending()
            }

        case .released:
            Task { @MainActor in BedtimeLockLoop.shared.stop() }
        }

        // Broadcast to UI layer (pill, dashboard) — last so Lock-loop
        // start/stop happens before the UI react.
        onStateChanged?(oldState, newState)
    }

    /// Mark the user as released until the given timestamp (e.g. partner
    /// code accepted; backend returned released_until). The state stays
    /// `.released` until cleared via `clearReleased()` — typically when
    /// the released_until clock passes (poller-driven).
    func markReleased() {
        if state != .released {
            transition(to: .released)
        }
    }

    /// Clear release state — bedtime resumes its normal recalculation.
    /// Called when backend reports released_until is in the past.
    func clearReleased() {
        if state == .released {
            transition(to: .inactive)
        }
        recalculate()
    }

    // MARK: - Wake Handler

    func onMacWoke() {
        guard let settings = settings, settings.enabled else { return }

        let now = trustedClock.now()
        if BedtimeLogic.isInBedtime(at: now, settings: settings) {
            appDelegate?.postLog("🌙 Mac woke during bedtime — re-locking")
            transition(to: .locked)
        }
    }
}

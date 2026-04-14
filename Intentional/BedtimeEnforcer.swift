// Intentional/BedtimeEnforcer.swift
// Bedtime time-checking logic as pure, testable functions.
// No UI, no timers, no AppKit — just data types and deterministic computations.

import Foundation

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

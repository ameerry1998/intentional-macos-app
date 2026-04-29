// Intentional/BedtimeWindDownController.swift
// Schedules the wind-down notification cascade leading up to bedtime.
//
// Cascade per the user's spec (verbatim, see plan §0):
//   T-30 → "Bedtime in 30 minutes" — minimizable
//   T-15 → "Bedtime in 15 minutes" — pill stays
//   T-10 → "Bedtime in 10 minutes" — every 5 min thereafter
//   T-5  → "Bedtime in 5 minutes"
//   T-1  → "Bedtime in 1 minute" — countdown
//
// All notifications use `.timeSensitive` interruption level so they bypass
// Do Not Disturb (R3 mitigation in the plan). Idempotent — re-scheduling
// for the same bedtime cancels prior pending requests first.

import Foundation
import UserNotifications

@MainActor
final class BedtimeWindDownController {
    static let shared = BedtimeWindDownController()
    private init() {}

    /// Identifier prefix shared by all wind-down notification requests so
    /// `clearPending()` can wipe just our cascade without disturbing other
    /// app notifications.
    static let identifierPrefix = "bedtime.winddown."

    /// Pure: returns the timestamps at which to fire wind-down notifications,
    /// 30 / 15 / 10 / 5 / 1 minutes before the given bedtime. Past timestamps
    /// (already elapsed) are filtered out so re-scheduling at T-12 doesn't
    /// queue a notification for T-30.
    static func milestones(beforeBedtime bedtime: Date, now: Date = Date()) -> [Date] {
        let offsets: [TimeInterval] = [-30 * 60, -15 * 60, -10 * 60, -5 * 60, -1 * 60]
        return offsets
            .map { bedtime.addingTimeInterval($0) }
            .filter { $0 > now && $0 < bedtime }
    }

    /// Schedule notifications for tonight's bedtime. Idempotent — clears
    /// stale pending requests first. Safe to call on every recalculate tick.
    func schedule(forBedtime bedtime: Date) async {
        await clearPending()

        let center = UNUserNotificationCenter.current()
        for milestone in Self.milestones(beforeBedtime: bedtime) {
            let minutesBefore = Int((bedtime.timeIntervalSince(milestone) / 60).rounded())
            let content = UNMutableNotificationContent()
            content.title = minutesBefore == 1
                ? "Bedtime in 1 minute"
                : "Bedtime in \(minutesBefore) minutes"
            content.body = minutesBefore >= 15
                ? "Wrap up what you're doing — laptop locks at \(formatTime(bedtime))."
                : "Laptop locks at \(formatTime(bedtime))."
            content.sound = .default
            // Bypass DND so the user actually sees the warning during a
            // late-night work crunch (R3 mitigation).
            content.interruptionLevel = .timeSensitive
            content.categoryIdentifier = "BEDTIME_WINDDOWN"

            let interval = milestone.timeIntervalSinceNow
            // UN trigger requires positive interval. milestones() already
            // filters past times but be defensive against clock skew.
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, interval),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: "\(Self.identifierPrefix)\(minutesBefore)min",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    /// Cancel all pending wind-down notifications. Called at .locked
    /// transition (no point firing T-1 after T-0) and on stop().
    func clearPending() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

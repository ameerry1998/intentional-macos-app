// Intentional/TrustedClock.swift
// Monotonic-clock-based tamper detection.
// Uses kernel systemUptime (unfakeable) to detect when the user changes Date().

import Foundation

/// Result of a drift detection check.
struct DriftResult {
    let isTampered: Bool
    let driftSeconds: TimeInterval
}

/// A clock that anchors wall-clock time to the kernel's monotonic uptime counter.
/// If the user changes their system clock, the drift between wall-clock elapsed time
/// and monotonic elapsed time will exceed the threshold, and isTampered becomes true.
class TrustedClock {

    // MARK: - Configuration

    /// Maximum allowed drift (in seconds) between wall-clock and monotonic elapsed time
    /// before we consider the clock tampered.
    static let tamperThresholdSeconds: TimeInterval = 120.0

    // MARK: - State

    private var anchorDate: Date?
    private var anchorUptime: TimeInterval?

    // MARK: - Anchoring

    /// Set the initial anchor point: a known-good wall-clock date paired with the
    /// monotonic uptime at that moment.
    func setAnchor(date: Date, uptime: TimeInterval) {
        anchorDate = date
        anchorUptime = uptime
    }

    /// Re-anchor from an NTP response. This replaces the anchor entirely so that
    /// trustedNow() and detectDrift() use the NTP-corrected time going forward.
    func updateFromNTP(ntpDate: Date, uptime: TimeInterval) {
        setAnchor(date: ntpDate, uptime: uptime)
    }

    // MARK: - Trusted Time

    /// Returns a trusted "now" computed from the anchor plus monotonic elapsed time.
    /// This value cannot be faked by changing the system clock.
    ///
    /// - Parameter currentUptime: The current monotonic uptime. Defaults to
    ///   `ProcessInfo.processInfo.systemUptime` when nil.
    /// - Returns: The trusted current date.
    func trustedNow(currentUptime: TimeInterval? = nil) -> Date {
        guard let anchorDate = anchorDate, let anchorUptime = anchorUptime else {
            // No anchor set yet -- fall back to system date.
            return Date()
        }
        let uptime = currentUptime ?? ProcessInfo.processInfo.systemUptime
        let elapsed = uptime - anchorUptime
        return anchorDate.addingTimeInterval(elapsed)
    }

    /// Convenience alias for `trustedNow()`.
    func now() -> Date {
        return trustedNow()
    }

    // MARK: - Drift Detection

    /// Compare wall-clock elapsed time against monotonic elapsed time.
    ///
    /// - Parameters:
    ///   - currentDate: The current wall-clock date. Defaults to `Date()` when nil.
    ///   - currentUptime: The current monotonic uptime. Defaults to
    ///     `ProcessInfo.processInfo.systemUptime` when nil.
    /// - Returns: A `DriftResult` indicating whether tampering was detected and
    ///   the raw drift in seconds.
    func detectDrift(currentDate: Date? = nil, currentUptime: TimeInterval? = nil) -> DriftResult {
        guard let anchorDate = anchorDate, let anchorUptime = anchorUptime else {
            // No anchor -- can't detect drift, assume clean.
            return DriftResult(isTampered: false, driftSeconds: 0)
        }

        let date = currentDate ?? Date()
        let uptime = currentUptime ?? ProcessInfo.processInfo.systemUptime

        let wallElapsed = date.timeIntervalSince(anchorDate)
        let monotonicElapsed = uptime - anchorUptime
        let drift = wallElapsed - monotonicElapsed

        let tampered = abs(drift) > TrustedClock.tamperThresholdSeconds
        return DriftResult(isTampered: tampered, driftSeconds: drift)
    }

    /// Quick check: is the clock currently tampered?
    /// Uses live system values.
    func isTampered() -> Bool {
        return detectDrift().isTampered
    }
}

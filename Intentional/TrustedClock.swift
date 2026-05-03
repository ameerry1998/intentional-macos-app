// Intentional/TrustedClock.swift
// Monotonic-clock-based tamper detection.
// Uses mach_continuous_time (unfakeable AND advances during sleep) to detect
// when the user changes Date().
//
// Why mach_continuous_time, not ProcessInfo.systemUptime: systemUptime stops
// counting while the Mac is asleep. After a 3-minute sleep, wallElapsed
// includes the sleep duration but monotonicElapsed does not — so drift
// (= wallElapsed - monotonicElapsed) ≈ sleep duration, and any sleep over
// 120s (the tamper threshold) gets flagged as a clock-tamper false positive.
// mach_continuous_time DOES advance during sleep, so wall and monotonic
// elapsed match across sleep events, no false positive.

import Foundation
import Darwin

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

    // MARK: - NTP Refresh

    /// Query NTP server and update anchor. Call on app launch and periodically.
    func refreshFromNTP(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { completion?(false); return }
            guard let ntpDate = self.queryNTP(host: "time.apple.com") else {
                completion?(false)
                return
            }
            let uptime = TrustedClock.continuousSecondsSinceBoot()
            DispatchQueue.main.async {
                self.updateFromNTP(ntpDate: ntpDate, uptime: uptime)
                completion?(true)
            }
        }
    }

    // MARK: - Sleep-aware monotonic clock

    /// Seconds since boot, INCLUDING time the system was asleep. Backed by
    /// `mach_continuous_time` (the only Darwin clock that advances during
    /// sleep — `systemUptime`, `mach_absolute_time`, and `CLOCK_MONOTONIC`
    /// all stop). This is what "monotonic elapsed" must use so a sleep
    /// event doesn't look like a clock tamper.
    static func continuousSecondsSinceBoot() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        let nanos = Double(ticks) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000.0
    }

    /// Minimal NTP client (RFC 4330) — returns server transmit timestamp
    private func queryNTP(host: String, port: Int = 123, timeout: TimeInterval = 5) -> Date? {
        // Create UDP socket
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        // Set receive timeout
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Resolve host
        guard let hostEntry = gethostbyname(host) else { return nil }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        memcpy(&addr.sin_addr, hostEntry.pointee.h_addr_list[0]!, Int(hostEntry.pointee.h_length))

        // Build NTP request packet (48 bytes, LI=0, VN=4, Mode=3)
        var packet = [UInt8](repeating: 0, count: 48)
        packet[0] = 0x23  // LI=0, VN=4, Mode=3 (client)

        // Send
        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                sendto(sock, &packet, packet.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return nil }

        // Receive
        var response = [UInt8](repeating: 0, count: 48)
        let received = recv(sock, &response, response.count, 0)
        guard received == 48 else { return nil }

        // Extract transmit timestamp from bytes 40-47
        let seconds = UInt32(response[40]) << 24 | UInt32(response[41]) << 16 |
                      UInt32(response[42]) << 8  | UInt32(response[43])
        let fraction = UInt32(response[44]) << 24 | UInt32(response[45]) << 16 |
                       UInt32(response[46]) << 8  | UInt32(response[47])

        // NTP epoch is 1900-01-01, Unix epoch is 1970-01-01 (2208988800 seconds apart)
        let ntpEpochOffset: TimeInterval = 2208988800.0
        let timestamp = TimeInterval(seconds) - ntpEpochOffset + TimeInterval(fraction) / 4294967296.0

        return Date(timeIntervalSince1970: timestamp)
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
        let uptime = currentUptime ?? TrustedClock.continuousSecondsSinceBoot()
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
        let uptime = currentUptime ?? TrustedClock.continuousSecondsSinceBoot()

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

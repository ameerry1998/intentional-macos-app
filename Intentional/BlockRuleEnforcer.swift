//
//  BlockRuleEnforcer.swift
//  Intentional
//
//  Created May 14, 2026 — Opal-style Blocks enforcement.
//
//  Closes the gap where BlockingProfile rules with schedules + an `enabled`
//  toggle never actually engaged enforcement outside of a focus session.
//
//  Composes with focus-session enforcement via UNION:
//    - During a focus session, the existing session-driven blocklists apply.
//    - When a BlockingProfile is in its scheduled window AND enabled, ITS
//      blocklists ALSO apply.
//    - Both can be active simultaneously — the user gets the strictest of both.
//

import Foundation
import AppKit

/// Engages a Mac's existing blocking machinery (WebsiteBlocker + FocusMonitor)
/// when a BlockingProfile's schedule says "now is in this rule's active window."
///
/// Runs on the main run loop with a 30s ticker. On every tick:
///   1. Snapshots BlockingProfileManager.profiles
///   2. Filters to those where isCurrentlyActive == true AND enabled == true
///      AND not snoozed
///   3. Unions blockedDomains + blockedAppBundleIds across them
///   4. Pushes the union into the standalone enforcement layer of
///      WebsiteBlocker (setStandaloneBlocklist) and FocusMonitor
///      (setStandaloneBlockedBundleIds)
@MainActor
final class BlockRuleEnforcer {
    static let shared = BlockRuleEnforcer()

    private weak var profileManager: BlockingProfileManager?
    private weak var websiteBlocker: WebsiteBlocker?
    private weak var focusMonitor: FocusMonitor?
    private var tickTimer: Timer?
    private let evaluator = StandaloneBlockEvaluator()

    /// User-initiated snoozes — keyed by profile id. Value = the Date at which
    /// the rule re-engages. While snoozed, isCurrentlyActive is overridden to false.
    private var snoozedUntil: [UUID: Date] = [:]

    /// Persists snoozes to disk so they survive app restarts (otherwise user
    /// reopens app at noon, snooze is gone, rule re-blocks immediately).
    private let snoozeReceiptURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Intentional", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("block_rule_snoozes.json")
    }()

    func wire(profileManager: BlockingProfileManager,
              websiteBlocker: WebsiteBlocker?,
              focusMonitor: FocusMonitor?) {
        self.profileManager = profileManager
        self.websiteBlocker = websiteBlocker
        self.focusMonitor = focusMonitor
        loadSnoozes()
    }

    func start() {
        tickTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 3.0
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
        tick()  // immediate eval
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Re-evaluate immediately. Call this whenever a BlockingProfile is created /
    /// updated / deleted / toggled so the user doesn't wait up to 30s for the
    /// next tick to engage their change.
    func reevaluateNow() {
        tick()
    }

    /// Snooze a rule for the remainder of its current active window.
    /// If the rule has no time window (always-active), snooze for the rest of today.
    func snoozeForRemainderOfWindow(profileId: UUID) {
        guard let profile = profileManager?.profiles.first(where: { $0.id == profileId }) else { return }
        let now = Date()
        let cal = Calendar.current
        var releaseDate: Date

        if let endHour = profile.endHour {
            let endMin = profile.endMinute ?? 0
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = endHour
            comps.minute = endMin
            releaseDate = cal.date(from: comps) ?? cal.date(byAdding: .hour, value: 1, to: now)!
            // If the window's already passed today (somehow we're here at 6pm for a 9-5 rule),
            // bump to the same end tomorrow.
            if releaseDate <= now {
                releaseDate = cal.date(byAdding: .day, value: 1, to: releaseDate) ?? releaseDate
            }
        } else {
            // Always-active: snooze until end of day
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = 23
            comps.minute = 59
            comps.second = 59
            releaseDate = cal.date(from: comps) ?? cal.date(byAdding: .hour, value: 6, to: now)!
        }
        snoozedUntil[profileId] = releaseDate
        persistSnoozes()
        reevaluateNow()
    }

    func clearSnooze(profileId: UUID) {
        snoozedUntil.removeValue(forKey: profileId)
        persistSnoozes()
        reevaluateNow()
    }

    /// Returns the set of profile ids currently snoozed (for UI display).
    func currentlySnoozedIds() -> Set<UUID> {
        let now = Date()
        return Set(snoozedUntil.filter { $0.value > now }.keys)
    }

    /// Returns the release Date for a snoozed profile, or nil if not snoozed (or expired).
    func snoozeReleaseDate(profileId: UUID) -> Date? {
        guard let d = snoozedUntil[profileId], d > Date() else { return nil }
        return d
    }

    /// Returns true iff this profile is in its scheduled window, enabled, AND not snoozed.
    func isEffectivelyActive(_ profile: BlockingProfile) -> Bool {
        if let until = snoozedUntil[profile.id], until > Date() { return false }
        return profile.isCurrentlyActive
    }

    // MARK: - Tick

    private func tick() {
        guard let profileManager else { return }
        // Sweep expired snoozes opportunistically
        let now = Date()
        let beforeCount = snoozedUntil.count
        snoozedUntil = snoozedUntil.filter { $0.value > now }
        if snoozedUntil.count != beforeCount { persistSnoozes() }

        let active = profileManager.profiles.filter { isEffectivelyActive($0) }
        var domains = Set<String>()
        var bundleIds = Set<String>()
        for p in active {
            for d in p.blockedDomains { domains.insert(d.lowercased()) }
            for b in p.blockedAppBundleIds { bundleIds.insert(b) }
        }
        evaluator.update(activeDomains: domains, activeBundleIds: bundleIds)
        // Push into the existing enforcement components.
        websiteBlocker?.setStandaloneBlocklist(domains: Array(domains))
        focusMonitor?.setStandaloneBlockedBundleIds(Array(bundleIds))
    }

    // MARK: - Snooze persistence

    private func loadSnoozes() {
        guard let data = try? Data(contentsOf: snoozeReceiptURL),
              let dict = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        let now = Date()
        snoozedUntil = Dictionary(uniqueKeysWithValues: dict.compactMap { (k, v) in
            guard let uuid = UUID(uuidString: k), v > now else { return nil }
            return (uuid, v)
        })
    }

    private func persistSnoozes() {
        let dict = Dictionary(uniqueKeysWithValues: snoozedUntil.map { ($0.key.uuidString, $0.value) })
        let data = (try? JSONEncoder().encode(dict)) ?? Data()
        try? data.write(to: snoozeReceiptURL, options: .atomic)
    }
}

/// Holds the most recent evaluation result. Used by clients that want to know
/// "what is the rule enforcer telling us is currently blocked" — separate from
/// focus-session enforcement.
@MainActor
final class StandaloneBlockEvaluator {
    private(set) var lastDomains: Set<String> = []
    private(set) var lastBundleIds: Set<String> = []
    func update(activeDomains: Set<String>, activeBundleIds: Set<String>) {
        self.lastDomains = activeDomains
        self.lastBundleIds = activeBundleIds
    }
}

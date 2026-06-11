//
//  EnforcementResolver.swift
//  Intentional
//
//  Rules Consolidation R4 (June 2026) — ONE precedence, same for sites and apps:
//
//      per-goal allow  >  ✅ allow rule  >  🚫 block rule / ⏳ limit gate
//                      >  goal blocklist  >  default-profile blocklist
//
//  Pure functions, no I/O — fully unit-testable
//  (IntentionalTests/EnforcementResolverTests.swift).
//
//  ⏳ (limited) targets behave as 🚫 DURING a focus session — focus time is
//  focus time (spec 2026-06-10-rules-consolidation-design.md). Outside a
//  session they defer to the shared allowance. TODO(R5): wire allowance
//  metering for the out-of-session case; until R5 lands they are
//  allowed-for-now outside sessions (.noDecision → falls through).
//
//  Consumers:
//    - FocusMonitor.evaluateApp / processActiveTabInfo → resolveApp/resolveSite
//    - WebsiteBlocker.effectiveBlockedDomains → effectiveSiteBlocklist
//      (the AppleScript sweep is domain-list-driven, so the precedence is
//      applied as set algebra over the blocklist; equivalent to calling
//      resolveSite per matching host — see EnforcementResolverTests for the
//      equivalence cases).
//

import Foundation

struct EnforcementResolver {

    /// Treatment-split rule targets, already filtered to enabled + inside
    /// their schedule window (see `activeRuleSets`). Sites are bare lowercase
    /// domains (backend-normalized); apps are bundle ids.
    struct RuleSets: Equatable {
        var allowedSites: Set<String> = []
        var allowedApps: Set<String> = []
        var blockedSites: Set<String> = []
        var blockedApps: Set<String> = []
        var limitedSites: Set<String> = []
        var limitedApps: Set<String> = []
    }

    struct Inputs {
        var inFocusSession: Bool = false
        /// Per-goal lists (Intention.allowWebsites/allowBundleIds and
        /// macWebsites/macBundleIds, via FocusMonitor.ProjectEnforcement).
        var goalAllowedDomains: Set<String> = []
        var goalAllowedBundleIds: Set<String> = []
        var goalBlockedDomains: Set<String> = []
        var goalBlockedBundleIds: Set<String> = []
        /// Unified rules (RuleStore cache via RuleEnforcementMirror).
        var rules: RuleSets = RuleSets()
        /// Legacy bottom layer: default blocking profile (session-fed) +
        /// BlockRuleEnforcer standalone unions.
        var defaultBlockedDomains: Set<String> = []
        var defaultBlockedBundleIds: Set<String> = []
    }

    enum Source: Equatable {
        case goalAllow      // Intention.allow*
        case allowRule      // ✅ rule
        case blockRule      // 🚫 rule
        case limitGate      // ⏳ rule during a focus session
        case goalBlock      // Intention.mac*
        case defaultList    // default profile / distracting / standalone union
    }

    enum Verdict: Equatable {
        case allow(Source)
        case block(Source)
        case noDecision     // fall through (AI scoring / neutral handling)

        var isAllow: Bool { if case .allow = self { return true }; return false }
        var isBlock: Bool { if case .block = self { return true }; return false }
    }

    // MARK: - The one precedence

    static func resolveSite(host rawHost: String, inputs: Inputs) -> Verdict {
        let host = rawHost.lowercased()
        if matches(host, inputs.goalAllowedDomains) { return .allow(.goalAllow) }
        if matches(host, inputs.rules.allowedSites) { return .allow(.allowRule) }
        if matches(host, inputs.rules.blockedSites) { return .block(.blockRule) }
        if matches(host, inputs.rules.limitedSites), inputs.inFocusSession {
            // ⏳ acts as 🚫 in-session. TODO(R5): out-of-session allowance metering.
            return .block(.limitGate)
        }
        if matches(host, inputs.goalBlockedDomains) { return .block(.goalBlock) }
        if matches(host, inputs.defaultBlockedDomains) { return .block(.defaultList) }
        return .noDecision
    }

    static func resolveApp(bundleId: String, inputs: Inputs) -> Verdict {
        if inputs.goalAllowedBundleIds.contains(bundleId) { return .allow(.goalAllow) }
        if inputs.rules.allowedApps.contains(bundleId) { return .allow(.allowRule) }
        if inputs.rules.blockedApps.contains(bundleId) { return .block(.blockRule) }
        if inputs.rules.limitedApps.contains(bundleId), inputs.inFocusSession {
            // ⏳ acts as 🚫 in-session. TODO(R5): out-of-session allowance metering.
            return .block(.limitGate)
        }
        if inputs.goalBlockedBundleIds.contains(bundleId) { return .block(.goalBlock) }
        if inputs.defaultBlockedBundleIds.contains(bundleId) { return .block(.defaultList) }
        return .noDecision
    }

    /// Exact-or-subdomain-suffix matching — the single domain semantic
    /// (matches ProjectEnforcement.matchesDomain and WebsiteBlocker.shouldBlock).
    static func matches(_ host: String, _ domains: Set<String>) -> Bool {
        if domains.contains(host) { return true }
        for d in domains where host.hasSuffix("." + d) { return true }
        return false
    }

    // MARK: - WebsiteBlocker adapter (set algebra over the domain blocklist)

    /// R4(a): the AppleScript tab sweep is driven by a flat domain list (it has
    /// no per-host callback — domains are inlined into the scripts), so the
    /// precedence is applied by construction: union all block layers, then
    /// remove every domain the allow layers would clear. Equivalent to
    /// `resolveSite(host:)` for any host that suffix-matches a list entry.
    static func effectiveSiteBlocklist(sessionDomains: [String],
                                       standaloneDomains: Set<String>,
                                       inputs: Inputs) -> [String] {
        var seen = Set<String>()
        var union: [String] = []
        for d in sessionDomains where seen.insert(d).inserted { union.append(d) }
        for d in standaloneDomains where seen.insert(d).inserted { union.append(d) }
        for d in inputs.rules.blockedSites where seen.insert(d).inserted { union.append(d) }
        if inputs.inFocusSession {
            // ⏳ acts as 🚫 in-session. TODO(R5): out-of-session allowance metering.
            for d in inputs.rules.limitedSites where seen.insert(d).inserted { union.append(d) }
        }
        return union.filter { d in
            !matches(d, inputs.goalAllowedDomains) && !matches(d, inputs.rules.allowedSites)
        }
    }

    // MARK: - Rule → RuleSets (enabled + schedule-window filtering)

    /// Split cached rules into treatment sets, dropping disabled rules and
    /// rules outside their schedule window.
    static func activeRuleSets(rules: [Rule], at date: Date = Date(),
                               calendar: Calendar = .current) -> RuleSets {
        var out = RuleSets()
        for r in rules {
            guard r.enabled, scheduleActive(r.schedule, at: date, calendar: calendar) else { continue }
            switch (r.targetKind, r.treatment) {
            case (.site, .allowed): out.allowedSites.insert(r.target.lowercased())
            case (.site, .blocked): out.blockedSites.insert(r.target.lowercased())
            case (.site, .limited): out.limitedSites.insert(r.target.lowercased())
            case (.app, .allowed):  out.allowedApps.insert(r.target)
            case (.app, .blocked):  out.blockedApps.insert(r.target)
            case (.app, .limited):  out.limitedApps.insert(r.target)
            }
        }
        return out
    }

    /// R3 schedule blob: `{ start: "HH:MM", end: "HH:MM", days: [1..7] }`
    /// (ISO weekdays, Mon=1). nil or unparseable = always in effect — a
    /// malformed schedule must not silently disable a rule the user sees as ON.
    static func scheduleActive(_ schedule: [String: AnyCodable]?, at date: Date,
                               calendar: Calendar = .current) -> Bool {
        guard let schedule else { return true }
        guard let startStr = schedule["start"]?.value as? String,
              let endStr = schedule["end"]?.value as? String,
              let start = minutesOfDay(startStr),
              let end = minutesOfDay(endStr) else { return true }
        if let daysAny = schedule["days"]?.value as? [Any] {
            let days = daysAny.compactMap { $0 as? Int }
            if !days.isEmpty {
                // ISO 8601 weekday: Mon=1 … Sun=7. Calendar.weekday is Sun=1 … Sat=7.
                let weekday = calendar.component(.weekday, from: date)
                let isoWeekday = weekday == 1 ? 7 : weekday - 1
                if !days.contains(isoWeekday) { return false }
            }
        }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let nowMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return nowMin >= start && nowMin < end
    }

    private static func minutesOfDay(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }
}

// MARK: - RuleEnforcementMirror

/// Thread-safe mirror of RuleStore's cache for the synchronous enforcement hot
/// path (WebsiteBlocker's 0.5s sweep, FocusMonitor.evaluateApp). RuleStore is
/// an actor — awaiting it per-tab/per-app-switch is not an option on these
/// paths. RuleStore publishes here on every cache mutation
/// (load / pull / create / update / revert / delete).
final class RuleEnforcementMirror: @unchecked Sendable {
    static let shared = RuleEnforcementMirror()

    private let lock = NSLock()
    private var rules: [Rule] = []

    func publish(_ newRules: [Rule]) {
        lock.lock()
        rules = newRules
        lock.unlock()
    }

    func snapshot() -> [Rule] {
        lock.lock()
        defer { lock.unlock() }
        return rules
    }

    /// Treatment-split sets for "now" (enabled + in-window rules only).
    func activeSets(at date: Date = Date()) -> EnforcementResolver.RuleSets {
        EnforcementResolver.activeRuleSets(rules: snapshot(), at: date)
    }
}

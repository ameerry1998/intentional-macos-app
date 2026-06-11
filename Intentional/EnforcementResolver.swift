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
//  session they defer to the shared allowance (R5): time on a ⏳ target is
//  metered by FocusMonitor's allowance meter and spent against the backend
//  allowance; while balance remains they fall through (.noDecision), and when
//  `allowanceExhausted` flips (server available minus locally-pending spend
//  ≤ 0, see AllowanceBalance) they gate as blocked with the earn-path wall.
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
        /// R5: true when the shared allowance is spent (server available
        /// minutes minus locally-pending unsent spend ≤ 0). Makes ⏳ targets
        /// gate as blocked OUTSIDE sessions too. Sourced from
        /// AllowanceBalance.shared.isExhausted by both consumers.
        var allowanceExhausted: Bool = false
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
        if matches(host, inputs.rules.limitedSites),
           inputs.inFocusSession || inputs.allowanceExhausted {
            // ⏳ acts as 🚫 in-session, and out-of-session once the shared
            // allowance is exhausted (R5). With balance left it falls through.
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
        if inputs.rules.limitedApps.contains(bundleId),
           inputs.inFocusSession || inputs.allowanceExhausted {
            // ⏳ acts as 🚫 in-session, and out-of-session once the shared
            // allowance is exhausted (R5). With balance left it falls through.
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
        if inputs.inFocusSession || inputs.allowanceExhausted {
            // ⏳ acts as 🚫 in-session, and out-of-session once the shared
            // allowance is exhausted (R5).
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

// MARK: - AllowanceBalance (R5)

/// Thread-safe holder for the shared daily allowance on the synchronous
/// enforcement hot paths (same rationale as RuleEnforcementMirror — RuleStore
/// is an actor and can't be awaited from WebsiteBlocker's 0.5s sweep or
/// FocusMonitor's evaluation path).
///
/// Two writers:
///   - RuleStore publishes SERVER truth (available/base/rate) on every
///     allowance cache mutation (load / refresh / earn / spend / config).
///   - FocusMonitor's allowance meter publishes locally-pending unsent spend
///     seconds between whole-minute POSTs, and stamps ⏳ usage timestamps
///     (drives the "show the pill balance" heuristic).
final class AllowanceBalance: @unchecked Sendable {
    static let shared = AllowanceBalance()

    private let lock = NSLock()
    private var serverAvailableMinutes: Int?
    private var serverBaseMinutes: Int = 15
    private var serverEarnRate: Int = 5
    private var pendingSpendSeconds: Double = 0
    private var lastLimitedUseAt: Date?

    /// How recently a ⏳ target must have been used for the pill balance to
    /// show ("used in the last N minutes" heuristic).
    static let recentUseWindow: TimeInterval = 15 * 60

    func publishServer(availableMinutes: Int, baseMinutes: Int, earnRate: Int) {
        lock.lock()
        serverAvailableMinutes = availableMinutes
        serverBaseMinutes = baseMinutes
        serverEarnRate = max(1, earnRate)
        lock.unlock()
    }

    /// Meter-owned: seconds spent on ⏳ targets that haven't been POSTed yet.
    func setPendingSpendSeconds(_ seconds: Double) {
        lock.lock()
        pendingSpendSeconds = max(0, seconds)
        lock.unlock()
    }

    func recordLimitedUse(at date: Date = Date()) {
        lock.lock()
        lastLimitedUseAt = date
        lock.unlock()
    }

    /// Server available minus whole minutes of locally-pending spend.
    /// nil = never synced with the backend.
    var availableMinutesAfterPending: Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let server = serverAvailableMinutes else { return nil }
        return max(0, server - Int(pendingSpendSeconds / 60.0))
    }

    /// ⏳ targets hard-block when this is true. Fails OPEN when the backend
    /// has never been seen (nil server state): don't wall the user on a guess.
    var isExhausted: Bool {
        guard let available = availableMinutesAfterPending else { return false }
        return available <= 0
    }

    var earnRate: Int {
        lock.lock()
        defer { lock.unlock() }
        return serverEarnRate
    }

    var baseMinutes: Int {
        lock.lock()
        defer { lock.unlock() }
        return serverBaseMinutes
    }

    var usedLimitedRecently: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastLimitedUseAt else { return false }
        return Date().timeIntervalSince(last) < Self.recentUseWindow
    }
}

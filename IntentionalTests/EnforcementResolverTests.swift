// EnforcementResolverTests.swift
//
// NOTE: As of Spec 1 ship, this codebase has no wired XCTest target — these
// test files live under IntentionalTests/ but aren't compiled by the default
// Intentional scheme. Kept here so they're trivial to wire up when someone
// adds an XCTest target. Until then, treat them as manual smoke specs.
//
// Covers: R4(c) — the ONE precedence for sites and apps
//   per-goal allow > ✅ allow rule > 🚫 block rule / ⏳ limit gate
//                  > goal blocklist > default-profile blocklist
// plus:
//   - ⏳ semantics: blocks during a focus session, defers (noDecision) outside
//   - exact-or-subdomain suffix matching (m.youtube.com vs youtube.com,
//     notyoutube.com must NOT match)
//   - effectiveSiteBlocklist equivalence with resolveSite (the WebsiteBlocker
//     set-algebra adapter)
//   - activeRuleSets: disabled rules dropped, schedule windows honored
//     (R3 blob { start: "HH:MM", end: "HH:MM", days: [1..7 ISO Mon=1] }),
//     malformed schedules treated as always-active
//   - the research §8.4 conflict-matrix rows that R4 flips

import XCTest
@testable import Intentional

final class EnforcementResolverTests: XCTestCase {

    // MARK: - Helpers

    private func inputs(
        inFocusSession: Bool = true,
        goalAllowedDomains: Set<String> = [],
        goalAllowedBundleIds: Set<String> = [],
        goalBlockedDomains: Set<String> = [],
        goalBlockedBundleIds: Set<String> = [],
        rules: EnforcementResolver.RuleSets = .init(),
        defaultBlockedDomains: Set<String> = [],
        defaultBlockedBundleIds: Set<String> = []
    ) -> EnforcementResolver.Inputs {
        var i = EnforcementResolver.Inputs()
        i.inFocusSession = inFocusSession
        i.goalAllowedDomains = goalAllowedDomains
        i.goalAllowedBundleIds = goalAllowedBundleIds
        i.goalBlockedDomains = goalBlockedDomains
        i.goalBlockedBundleIds = goalBlockedBundleIds
        i.rules = rules
        i.defaultBlockedDomains = defaultBlockedDomains
        i.defaultBlockedBundleIds = defaultBlockedBundleIds
        return i
    }

    private func rule(_ kind: RuleTargetKind, _ target: String,
                      _ treatment: RuleTreatment, enabled: Bool = true,
                      schedule: [String: AnyCodable]? = nil) -> Rule {
        Rule(id: UUID(), targetKind: kind, target: target,
             treatment: treatment, schedule: schedule, enabled: enabled)
    }

    /// A fixed Wednesday 10:30 local time (ISO weekday 3).
    private func wednesday1030() -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 10   // Wed Jun 10 2026
        comps.hour = 10; comps.minute = 30
        return Calendar.current.date(from: comps)!
    }

    // MARK: - Precedence: sites

    func testGoalAllowBeatsEverything() {
        let i = inputs(
            goalAllowedDomains: ["youtube.com"],
            goalBlockedDomains: ["youtube.com"],
            rules: .init(blockedSites: ["youtube.com"], limitedSites: ["youtube.com"]),
            defaultBlockedDomains: ["youtube.com"]
        )
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "youtube.com", inputs: i),
                       .allow(.goalAllow))
    }

    func testAllowRuleBeatsBlockRuleGoalBlockAndDefault() {
        let i = inputs(
            goalBlockedDomains: ["twitch.tv"],
            rules: .init(allowedSites: ["twitch.tv"], blockedSites: ["twitch.tv"]),
            defaultBlockedDomains: ["twitch.tv"]
        )
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "twitch.tv", inputs: i),
                       .allow(.allowRule))
    }

    func testBlockRuleBeatsGoalBlockAndDefault() {
        let i = inputs(
            goalBlockedDomains: ["reddit.com"],
            rules: .init(blockedSites: ["reddit.com"]),
            defaultBlockedDomains: ["reddit.com"]
        )
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "reddit.com", inputs: i),
                       .block(.blockRule))
    }

    func testGoalBlockBeatsDefault() {
        let i = inputs(
            goalBlockedDomains: ["netflix.com"],
            defaultBlockedDomains: ["netflix.com"]
        )
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "netflix.com", inputs: i),
                       .block(.goalBlock))
    }

    func testDefaultBlocksWhenNothingElseDecides() {
        let i = inputs(defaultBlockedDomains: ["tiktok.com"])
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "tiktok.com", inputs: i),
                       .block(.defaultList))
    }

    func testUnknownHostIsNoDecision() {
        let i = inputs(
            goalAllowedDomains: ["github.com"],
            defaultBlockedDomains: ["youtube.com"]
        )
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "stackoverflow.com", inputs: i),
                       .noDecision)
    }

    // MARK: - Research §8.4 rows this slice flips

    /// Row 1: goal allow_websites vs default profile blockedDomains —
    /// pre-R4 the tab was closed (WebsiteBlocker consulted no allow source).
    func testGoalAllowedDomainSurvivesDefaultProfile() {
        let i = inputs(
            goalAllowedDomains: ["twitch.tv"],
            defaultBlockedDomains: ["twitch.tv", "youtube.com"]
        )
        XCTAssertTrue(EnforcementResolver.resolveSite(host: "twitch.tv", inputs: i).isAllow)
        // ...and the sibling default-profile domain still blocks.
        XCTAssertTrue(EnforcementResolver.resolveSite(host: "youtube.com", inputs: i).isBlock)
    }

    /// Apps and domains had OPPOSITE precedence pre-R4 (apps: goal allow won;
    /// domains: block won). Now both allow.
    func testAppsAndSitesShareThePrecedence() {
        let i = inputs(
            goalAllowedDomains: ["figma.com"],
            goalAllowedBundleIds: ["com.figma.Desktop"],
            defaultBlockedDomains: ["figma.com"],
            defaultBlockedBundleIds: ["com.figma.Desktop"]
        )
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "figma.com", inputs: i),
                       .allow(.goalAllow))
        XCTAssertEqual(EnforcementResolver.resolveApp(bundleId: "com.figma.Desktop", inputs: i),
                       .allow(.goalAllow))
    }

    // MARK: - Precedence: apps

    func testAppPrecedenceChain() {
        // goal allow > ✅
        var i = inputs(
            goalAllowedBundleIds: ["com.spotify.client"],
            rules: .init(allowedApps: ["com.spotify.client"])
        )
        XCTAssertEqual(EnforcementResolver.resolveApp(bundleId: "com.spotify.client", inputs: i),
                       .allow(.goalAllow))
        // ✅ > 🚫 rule
        i = inputs(rules: .init(allowedApps: ["com.spotify.client"],
                                blockedApps: ["com.spotify.client"]))
        XCTAssertEqual(EnforcementResolver.resolveApp(bundleId: "com.spotify.client", inputs: i),
                       .allow(.allowRule))
        // 🚫 rule > goal block
        i = inputs(goalBlockedBundleIds: ["com.spotify.client"],
                   rules: .init(blockedApps: ["com.spotify.client"]))
        XCTAssertEqual(EnforcementResolver.resolveApp(bundleId: "com.spotify.client", inputs: i),
                       .block(.blockRule))
        // goal block > default
        i = inputs(goalBlockedBundleIds: ["com.spotify.client"],
                   defaultBlockedBundleIds: ["com.spotify.client"])
        XCTAssertEqual(EnforcementResolver.resolveApp(bundleId: "com.spotify.client", inputs: i),
                       .block(.goalBlock))
        // default alone
        i = inputs(defaultBlockedBundleIds: ["com.spotify.client"])
        XCTAssertEqual(EnforcementResolver.resolveApp(bundleId: "com.spotify.client", inputs: i),
                       .block(.defaultList))
        // nothing
        i = inputs()
        XCTAssertEqual(EnforcementResolver.resolveApp(bundleId: "com.spotify.client", inputs: i),
                       .noDecision)
    }

    // MARK: - ⏳ limited semantics

    func testLimitedBlocksDuringFocusSession() {
        let i = inputs(inFocusSession: true,
                       rules: .init(limitedSites: ["youtube.com"],
                                    limitedApps: ["com.apple.TV"]))
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "youtube.com", inputs: i),
                       .block(.limitGate))
        XCTAssertEqual(EnforcementResolver.resolveApp(bundleId: "com.apple.TV", inputs: i),
                       .block(.limitGate))
    }

    func testLimitedDefersOutsideFocusSession() {
        // R5 semantics: outside a session with allowance remaining, ⏳ is
        // allowed-for-now — resolver returns .noDecision and the meter spends.
        let i = inputs(inFocusSession: false,
                       rules: .init(limitedSites: ["youtube.com"],
                                    limitedApps: ["com.apple.TV"]))
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "youtube.com", inputs: i),
                       .noDecision)
        XCTAssertEqual(EnforcementResolver.resolveApp(bundleId: "com.apple.TV", inputs: i),
                       .noDecision)
    }

    func testLimitedBlocksOutsideSessionWhenAllowanceExhausted() {
        // R5: exhausted allowance gates ⏳ as blocked even with no session.
        var i = inputs(inFocusSession: false,
                       rules: .init(limitedSites: ["youtube.com"],
                                    limitedApps: ["com.apple.TV"]))
        i.allowanceExhausted = true
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "youtube.com", inputs: i),
                       .block(.limitGate))
        XCTAssertEqual(EnforcementResolver.resolveApp(bundleId: "com.apple.TV", inputs: i),
                       .block(.limitGate))
    }

    func testAllowLayersBeatExhaustedLimitGate() {
        // ✅ rule still wins over the ⏳-at-zero gate (one precedence).
        var i = inputs(inFocusSession: false,
                       rules: .init(allowedSites: ["youtube.com"],
                                    limitedSites: ["youtube.com"]))
        i.allowanceExhausted = true
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "youtube.com", inputs: i),
                       .allow(.allowRule))
    }

    func testLimitedStillLosesToAllowLayers() {
        let i = inputs(inFocusSession: true,
                       goalAllowedDomains: ["youtube.com"],
                       rules: .init(limitedSites: ["youtube.com"]))
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "youtube.com", inputs: i),
                       .allow(.goalAllow))
    }

    // MARK: - Domain matching semantics

    func testSubdomainSuffixMatching() {
        let i = inputs(defaultBlockedDomains: ["youtube.com"])
        XCTAssertTrue(EnforcementResolver.resolveSite(host: "m.youtube.com", inputs: i).isBlock)
        XCTAssertTrue(EnforcementResolver.resolveSite(host: "www.youtube.com", inputs: i).isBlock)
        // NOT a substring match — notyoutube.com must not block.
        XCTAssertEqual(EnforcementResolver.resolveSite(host: "notyoutube.com", inputs: i),
                       .noDecision)
    }

    func testHostMatchingIsCaseInsensitive() {
        let i = inputs(goalAllowedDomains: ["github.com"])
        XCTAssertTrue(EnforcementResolver.resolveSite(host: "GitHub.com", inputs: i).isAllow)
    }

    func testAllowMatchesSubdomainOfAllowedDomain() {
        let i = inputs(goalAllowedDomains: ["google.com"],
                       defaultBlockedDomains: ["mail.google.com"])
        XCTAssertTrue(EnforcementResolver.resolveSite(host: "mail.google.com", inputs: i).isAllow)
    }

    // MARK: - effectiveSiteBlocklist (WebsiteBlocker adapter)

    func testEffectiveBlocklistRemovesAllowedDomains() {
        var i = inputs(goalAllowedDomains: ["twitch.tv"],
                       rules: .init(allowedSites: ["discord.com"]))
        i.inFocusSession = true
        let out = EnforcementResolver.effectiveSiteBlocklist(
            sessionDomains: ["youtube.com", "twitch.tv", "discord.com"],
            standaloneDomains: ["reddit.com"],
            inputs: i
        )
        XCTAssertEqual(Set(out), ["youtube.com", "reddit.com"])
    }

    /// www./m. expansions of an allowed base domain are removed too (suffix
    /// matching) — WebsiteBlocker expands every session domain to www./m.
    func testEffectiveBlocklistRemovesExpandedVariantsOfAllowedDomain() {
        let i = inputs(goalAllowedDomains: ["twitch.tv"])
        let out = EnforcementResolver.effectiveSiteBlocklist(
            sessionDomains: ["twitch.tv", "www.twitch.tv", "m.twitch.tv", "youtube.com"],
            standaloneDomains: [],
            inputs: i
        )
        XCTAssertEqual(Set(out), ["youtube.com"])
    }

    func testEffectiveBlocklistAddsRuleBlockedAndInSessionLimited() {
        var i = inputs(rules: .init(blockedSites: ["reddit.com"],
                                    limitedSites: ["youtube.com"]))
        i.inFocusSession = true
        var out = EnforcementResolver.effectiveSiteBlocklist(
            sessionDomains: [], standaloneDomains: [], inputs: i)
        XCTAssertEqual(Set(out), ["reddit.com", "youtube.com"])

        // Outside a session with allowance left, the ⏳ site is NOT blocked.
        i.inFocusSession = false
        out = EnforcementResolver.effectiveSiteBlocklist(
            sessionDomains: [], standaloneDomains: [], inputs: i)
        XCTAssertEqual(Set(out), ["reddit.com"])

        // R5: exhausted allowance pulls the ⏳ site into the blocklist.
        i.allowanceExhausted = true
        out = EnforcementResolver.effectiveSiteBlocklist(
            sessionDomains: [], standaloneDomains: [], inputs: i)
        XCTAssertEqual(Set(out), ["reddit.com", "youtube.com"])
    }

    /// Set-algebra adapter must agree with the per-host resolver for hosts
    /// that match list entries (the equivalence WebsiteBlocker relies on).
    ///
    /// The equivalence that IS guaranteed: membership in
    /// `effectiveSiteBlocklist(sessionDomains:standaloneDomains:inputs:)`
    /// equals `resolveSite(host:inputs:).isBlock` for inputs whose
    /// `defaultBlockedDomains` is the union of those two parameters — that's
    /// the layer they represent (Inputs.defaultBlockedDomains: "default
    /// blocking profile (session-fed) + BlockRuleEnforcer standalone unions").
    /// What is NOT guaranteed (by design, not a hole): the set-algebra call
    /// ignores `inputs.defaultBlockedDomains` / `inputs.goalBlockedDomains` —
    /// the former arrives as the explicit parameters above, the latter is
    /// enforced by FocusMonitor's per-host path only (WebsiteBlocker never
    /// sets it; see FocusMonitor.enforcementInputs which symmetrically leaves
    /// defaultBlockedDomains empty because the sweep owns that layer). So a
    /// resolveSite call with bottom layers the adapter never received cannot
    /// be compared against the adapter's output.
    func testEffectiveBlocklistAgreesWithResolveSite() {
        var i = inputs(
            goalAllowedDomains: ["twitch.tv"],
            rules: .init(allowedSites: ["discord.com"], blockedSites: ["reddit.com"],
                         limitedSites: ["youtube.com"])
        )
        i.inFocusSession = true
        let union = ["twitch.tv", "discord.com", "facebook.com"]
        let out = Set(EnforcementResolver.effectiveSiteBlocklist(
            sessionDomains: union, standaloneDomains: [], inputs: i))
        // Model reality: the sessionDomains the adapter received ARE the
        // per-host resolver's bottom layer (WebsiteBlocker's session-fed
        // default profile). Without this the comparison is between two
        // different worlds, not two implementations of one precedence.
        var perHost = i
        perHost.defaultBlockedDomains = Set(union)
        for host in union + ["reddit.com", "youtube.com"] {
            let v = EnforcementResolver.resolveSite(host: host, inputs: perHost)
            XCTAssertEqual(out.contains(host), v.isBlock,
                           "blocklist membership and resolveSite disagree for \(host): \(v)")
        }
    }

    // MARK: - activeRuleSets (enabled + schedule filtering)

    func testDisabledRulesAreDropped() {
        let sets = EnforcementResolver.activeRuleSets(rules: [
            rule(.site, "youtube.com", .blocked, enabled: false),
            rule(.site, "reddit.com", .blocked, enabled: true),
            rule(.app, "com.apple.TV", .limited, enabled: false),
        ])
        XCTAssertEqual(sets.blockedSites, ["reddit.com"])
        XCTAssertTrue(sets.limitedApps.isEmpty)
    }

    func testTreatmentSplitAndSiteLowercasing() {
        let sets = EnforcementResolver.activeRuleSets(rules: [
            rule(.site, "YouTube.com", .blocked),
            rule(.site, "github.com", .allowed),
            rule(.site, "twitter.com", .limited),
            rule(.app, "com.hnc.Discord", .blocked),
            rule(.app, "com.figma.Desktop", .allowed),
            rule(.app, "com.spotify.client", .limited),
        ])
        XCTAssertEqual(sets.blockedSites, ["youtube.com"])
        XCTAssertEqual(sets.allowedSites, ["github.com"])
        XCTAssertEqual(sets.limitedSites, ["twitter.com"])
        XCTAssertEqual(sets.blockedApps, ["com.hnc.Discord"])
        XCTAssertEqual(sets.allowedApps, ["com.figma.Desktop"])
        XCTAssertEqual(sets.limitedApps, ["com.spotify.client"])
    }

    func testScheduleWindowHonored() {
        let wed = wednesday1030()
        let inWindow: [String: AnyCodable] = [
            "start": AnyCodable("09:00"), "end": AnyCodable("17:00"),
            "days": AnyCodable([1, 2, 3, 4, 5]),
        ]
        let outOfWindow: [String: AnyCodable] = [
            "start": AnyCodable("12:00"), "end": AnyCodable("17:00"),
            "days": AnyCodable([1, 2, 3, 4, 5]),
        ]
        let wrongDay: [String: AnyCodable] = [
            "start": AnyCodable("09:00"), "end": AnyCodable("17:00"),
            "days": AnyCodable([6, 7]),   // weekend only; wed = ISO 3
        ]
        let sets = EnforcementResolver.activeRuleSets(rules: [
            rule(.site, "a.com", .blocked, schedule: inWindow),
            rule(.site, "b.com", .blocked, schedule: outOfWindow),
            rule(.site, "c.com", .blocked, schedule: wrongDay),
            rule(.site, "d.com", .blocked, schedule: nil),       // always
        ], at: wed)
        XCTAssertEqual(sets.blockedSites, ["a.com", "d.com"])
    }

    func testMalformedScheduleIsAlwaysActive() {
        // A schedule blob the parser can't read must NOT silently disable a
        // rule the user sees as ON.
        let garbage: [String: AnyCodable] = ["start": AnyCodable("whenever")]
        let sets = EnforcementResolver.activeRuleSets(rules: [
            rule(.site, "a.com", .blocked, schedule: garbage),
        ], at: wednesday1030())
        XCTAssertEqual(sets.blockedSites, ["a.com"])
    }

    func testScheduleActiveBoundaries() {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 10   // Wed
        let sched: [String: AnyCodable] = [
            "start": AnyCodable("09:00"), "end": AnyCodable("17:00"),
            "days": AnyCodable([3]),
        ]
        comps.hour = 9; comps.minute = 0    // inclusive start
        XCTAssertTrue(EnforcementResolver.scheduleActive(sched, at: cal.date(from: comps)!))
        comps.hour = 17; comps.minute = 0   // exclusive end
        XCTAssertFalse(EnforcementResolver.scheduleActive(sched, at: cal.date(from: comps)!))
        comps.hour = 8; comps.minute = 59
        XCTAssertFalse(EnforcementResolver.scheduleActive(sched, at: cal.date(from: comps)!))
    }

    // MARK: - RuleEnforcementMirror

    func testMirrorPublishAndActiveSets() {
        let mirror = RuleEnforcementMirror()
        XCTAssertTrue(mirror.snapshot().isEmpty)
        mirror.publish([
            rule(.site, "youtube.com", .blocked),
            rule(.site, "github.com", .allowed, enabled: false),
        ])
        XCTAssertEqual(mirror.snapshot().count, 2)
        let sets = mirror.activeSets()
        XCTAssertEqual(sets.blockedSites, ["youtube.com"])
        XCTAssertTrue(sets.allowedSites.isEmpty)   // disabled → not active
    }
}

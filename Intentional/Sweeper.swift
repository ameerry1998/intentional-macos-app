import Foundation

/// Resolved per-session scope — apps/sites the sweep should keep open.
/// Built from the Intention's saved context + voice-intent additions.
/// The global Always-Allowed list is consulted SEPARATELY, not merged here,
/// so it can't be accidentally lost.
struct ResolvedScope: Equatable {
    var domains: Set<String>
    var bundleIds: Set<String>
    var voiceIntent: String

    static let empty = ResolvedScope(domains: [], bundleIds: [], voiceIntent: "")

    /// Suffix match — "github.com" matches "gist.github.com".
    func containsDomain(_ host: String) -> Bool {
        let h = host.lowercased()
        for d in domains {
            if h == d || h.hasSuffix("." + d) { return true }
        }
        return false
    }
}

enum TabVerdict: Equatable {
    case keep       // explicit allow OR pinned OR in scope
    case stash      // explicit deny (block rule) OR AI verdict false
    case needsAI    // not classified — caller must batch-score
}

enum AppVerdict: Equatable {
    case keep
    case hide
}

/// Stateless decision logic. Async sweep orchestration lives in
/// AppDelegate / a small Sweeper.run(...) coroutine, not here, so the
/// pure logic stays trivially testable.
enum Sweeper {

    /// Three-tier per-tab decision. `blockedHosts` should contain only
    /// hosts from BlockRules that are CURRENTLY ENFORCING (toggle on,
    /// inside their scheduled window).
    static func decideTab(host: String,
                          isPinned: Bool,
                          blockedHosts: Set<String>,
                          scope: ResolvedScope,
                          alwaysAllowed: AlwaysAllowedList) -> TabVerdict {
        if isPinned { return .keep }
        let h = host.lowercased()
        // Always-allowed (global) takes precedence over everything.
        for d in alwaysAllowed.domains {
            if h == d || h.hasSuffix("." + d) { return .keep }
        }
        // Active block rule — overrides AI.
        for d in blockedHosts {
            if h == d || h.hasSuffix("." + d) { return .stash }
        }
        // In-scope (voice/Intention-derived).
        if scope.containsDomain(h) { return .keep }
        return .needsAI
    }

    /// Native app decision. No AI involvement for apps in v1 — the user-named
    /// list (scope.bundleIds) plus always-allowed plus block rules is enough.
    /// Anything outside those three buckets gets hidden by default.
    static func decideApp(bundleId: String,
                          blockedBundleIds: Set<String>,
                          scope: ResolvedScope,
                          alwaysAllowed: AlwaysAllowedList) -> AppVerdict {
        if alwaysAllowed.bundleIds.contains(bundleId) { return .keep }
        if blockedBundleIds.contains(bundleId) { return .hide }
        if scope.bundleIds.contains(bundleId) { return .keep }
        return .hide
    }
}

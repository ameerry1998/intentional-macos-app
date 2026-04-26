import Foundation

/// Pure decision logic for whether the app should allow or block a quit attempt.
/// Extracted from applicationShouldTerminate for testability.
enum QuitDecision: Equatable {
    case allowQuit
    case blockQuit
}

enum QuitPolicy {
    /// Determine whether a quit attempt should be allowed or blocked.
    ///
    /// - Parameters:
    ///   - strictModeEnabled: Whether strict mode (tamper-resistant persistence) is active
    ///   - daemonAvailable: Whether the root daemon (syspolicyd_helper) is running and reachable
    /// - Returns: `.allowQuit` if the app should terminate, `.blockQuit` if it should refuse
    static func decide(strictModeEnabled: Bool, daemonAvailable: Bool) -> QuitDecision {
        if !strictModeEnabled {
            return .allowQuit
        }
        // Strict mode ON: allow quit only if daemon will relaunch us
        if daemonAvailable {
            return .allowQuit
        }
        return .blockQuit
    }
}

import Foundation

enum SwitchTarget: Hashable, Equatable {
    case app(bundleId: String)
    case tab(bundleId: String, host: String)

    var bundleId: String {
        switch self {
        case .app(let b), .tab(let b, _): return b
        }
    }
}

enum SuppressReason: String, Equatable {
    case notInWorkSession
    case onBreak
    case inGracePeriod
    case sameTarget
    case returningToKnown
    case sessionEnded
    case exemptApp
}

enum SwitchDecision: Equatable {
    case showOverlay(countdownSeconds: Int)
    case suppress(reason: SuppressReason)
}

enum SwitchResolution: Equatable {
    case backToWork
    case continued
    case sessionEndedMidCountdown
}

/// Pure-logic coordinator for the context-switching overlay.
/// All state is session-scoped. No AppKit / no UI — fully unit-testable.
final class SwitchInterventionCoordinator {

    // MARK: - Configuration

    static let gracePeriodSeconds: TimeInterval = 60
    static let knownTargetDwellSeconds: TimeInterval = 60
    static let tierCountdowns: [Int] = [10, 15, 20]
    static let tierGraduationCount: [Int] = [3, 6]
    static let tierDecayDwellSeconds: TimeInterval = 15 * 60

    // MARK: - State (session-scoped)

    private let exemptBundleIds: Set<String>
    private var sessionStart: Date?
    private var inWorkSession: Bool = false
    private var onBreak: Bool = false
    private var lastBreakEnd: Date?
    private var completedSwitchCount: Int = 0
    private(set) var dwellLedger: [SwitchTarget: TimeInterval] = [:]
    /// Ordered history of targets seen in the session, oldest first. Used for fallback return target.
    private var targetHistory: [SwitchTarget] = []
    private var currentTarget: SwitchTarget?
    private var currentTargetSince: Date?

    init(exemptBundleIds: Set<String>) {
        self.exemptBundleIds = exemptBundleIds
    }

    // MARK: - Lifecycle

    func sessionStarted(at now: Date) {
        sessionStart = now
        completedSwitchCount = 0
        dwellLedger = [:]
        targetHistory = []
        currentTarget = nil
        currentTargetSince = nil
        onBreak = false
        lastBreakEnd = nil
    }

    func sessionEnded() {
        sessionStart = nil
        inWorkSession = false
        onBreak = false
        completedSwitchCount = 0
        dwellLedger = [:]
        targetHistory = []
        currentTarget = nil
        currentTargetSince = nil
        lastBreakEnd = nil
    }

    func setInWorkSession(_ on: Bool) {
        inWorkSession = on
    }

    func breakStarted(at now: Date) {
        onBreak = true
        flushDwell(at: now)
    }

    func breakEnded(at now: Date) {
        onBreak = false
        lastBreakEnd = now
        currentTargetSince = now
    }

    // MARK: - Decision

    func onSwitch(to target: SwitchTarget, at now: Date) -> SwitchDecision {
        flushDwell(at: now)

        if !inWorkSession { return .suppress(reason: .notInWorkSession) }
        if onBreak { return .suppress(reason: .onBreak) }
        if exemptBundleIds.contains(target.bundleId) {
            beginDwell(target: target, at: now)
            return .suppress(reason: .exemptApp)
        }
        if let cur = currentTarget {
            if cur == target {
                return .suppress(reason: .sameTarget)
            }
            // Same-app refinement/re-selection: if current is .tab(X, _) and incoming is .app(X),
            // or current is .app(X) and incoming is .tab(X, _), it's the same app — either macOS
            // re-activating a browser we're already tracking, or the first tab read after landing
            // on an app. Neither is a fresh context switch. Promote currentTarget to the more
            // specific value (prefer .tab over .app).
            if cur.bundleId == target.bundleId {
                beginDwell(target: target, at: now)
                return .suppress(reason: .sameTarget)
            }
        }
        if inGracePeriod(at: now) {
            beginDwell(target: target, at: now)
            return .suppress(reason: .inGracePeriod)
        }
        if (dwellLedger[target] ?? 0) >= Self.knownTargetDwellSeconds {
            beginDwell(target: target, at: now)
            return .suppress(reason: .returningToKnown)
        }
        return .showOverlay(countdownSeconds: countdownForCurrentTier(at: now))
    }

    func resolve(outcome: SwitchResolution, intendedTarget: SwitchTarget?, returnTarget: SwitchTarget?, at now: Date) {
        switch outcome {
        case .continued:
            completedSwitchCount += 1
            if let t = intendedTarget { beginDwell(target: t, at: now) }
        case .backToWork:
            if let t = returnTarget { beginDwell(target: t, at: now) }
        case .sessionEndedMidCountdown:
            // No counter change. Dwell tracking stops because sessionEnded() clears state.
            break
        }
    }

    // MARK: - Return Target

    /// Returns the best target to navigate back to when the user taps "Back to work".
    /// Prefers the known target (dwell >= 60s) with the longest cumulative dwell.
    /// Falls back to the most recent non-excluded target in history.
    func preferredReturnTarget(excluding: SwitchTarget, at now: Date) -> SwitchTarget? {
        flushDwell(at: now)
        let known = dwellLedger
            .filter { $0.key != excluding && $0.value >= Self.knownTargetDwellSeconds }
            .sorted { $0.value > $1.value }
        if let first = known.first { return first.key }
        return targetHistory.reversed().first { $0 != excluding }
    }

    // MARK: - Queries

    func currentTier(at now: Date) -> Int {
        let decayed = decayedCounter(at: now)
        if decayed >= Self.tierGraduationCount[1] { return 3 }
        if decayed >= Self.tierGraduationCount[0] { return 2 }
        return 1
    }

    func countdownForCurrentTier(at now: Date = Date()) -> Int {
        return Self.tierCountdowns[currentTier(at: now) - 1]
    }

    var switchCountForTesting: Int { completedSwitchCount }

    // MARK: - Private

    private func inGracePeriod(at now: Date) -> Bool {
        guard let s = sessionStart else { return false }
        if now.timeIntervalSince(s) < Self.gracePeriodSeconds { return true }
        if let b = lastBreakEnd, now.timeIntervalSince(b) < Self.gracePeriodSeconds { return true }
        return false
    }

    private func beginDwell(target: SwitchTarget, at now: Date) {
        if currentTarget != target {
            targetHistory.removeAll { $0 == target }
            targetHistory.append(target)
        }
        currentTarget = target
        currentTargetSince = now
    }

    private func flushDwell(at now: Date) {
        guard let t = currentTarget, let since = currentTargetSince else {
            currentTargetSince = now
            return
        }
        let delta = now.timeIntervalSince(since)
        if delta > 0 {
            dwellLedger[t, default: 0] += delta
        }
        currentTargetSince = now
    }

    private func decayedCounter(at now: Date) -> Int {
        guard let t = currentTarget, let since = currentTargetSince else { return completedSwitchCount }
        let priorDwell = dwellLedger[t] ?? 0
        let totalDwell = priorDwell + max(0, now.timeIntervalSince(since))
        guard totalDwell >= Self.knownTargetDwellSeconds else { return completedSwitchCount }
        let continuousSeconds = max(0, now.timeIntervalSince(since))
        let decayUnits = Int(continuousSeconds / Self.tierDecayDwellSeconds)
        let reduced = max(0, completedSwitchCount - decayUnits * 3)
        return reduced
    }
}

import Foundation
import AppKit

/// Single source of truth for "is the app enforcing right now."
///
/// Replaces IntentionalModeController + FocusSessionManager. All enforcement
/// components (FocusMonitor, SwitchInterventionCoordinator, blocking) consult
/// `isOn` instead of inferring state from TimeState / session presence.
///
/// Three states:
///   - .off      — free time. Enforcement dormant.
///   - .focus    — full intervention bundle active. Optional intention metadata.
///   - .bedtime  — wind-down enforcement. Different blocklist, no AI scoring.
final class FocusModeController {

    enum State: String {
        case off
        case focus
        case bedtime
    }

    enum ActivationSource: String {
        case manual          // dashboard toggle, Cmd+Shift+P
        case schedule        // ScheduleManager.onBlockChanged
        case puck            // iPhone / Puck physical
        case crossDevice     // any other client via WS
        case bedtimeSchedule
    }

    /// Lightweight metadata describing the current FOCUS / BEDTIME period.
    struct Period {
        let id: UUID
        let startedAt: Date
        let intention: String?
        let source: ActivationSource
    }

    // MARK: State

    private(set) var state: State = .off
    private(set) var currentPeriod: Period?

    var isOn: Bool { state == .focus }
    var isBedtime: Bool { state == .bedtime }

    // MARK: Callbacks

    /// Fired whenever state transitions. Always called on the main queue.
    /// Subscribers: FocusMonitor (clear cache, re-evaluate), BlockingProfileManager
    /// (recompute merged blocklist), SwitchInterventionCoordinator (update gate),
    /// dashboard push, menu bar pill.
    var onStateChanged: ((_ old: State, _ new: State, _ period: Period?) -> Void)?

    // MARK: Lifecycle

    init() {}

    // MARK: API

    /// Transition to .focus. Idempotent — calling while already in .focus updates
    /// the intention/source on the current period without re-firing onStateChanged.
    func activate(intention: String?, source: ActivationSource) {
        let old = state
        if state == .focus {
            // Already on; refresh metadata only.
            if let existing = currentPeriod {
                currentPeriod = Period(
                    id: existing.id,
                    startedAt: existing.startedAt,
                    intention: intention ?? existing.intention,
                    source: source
                )
            }
            return
        }
        let period = Period(
            id: UUID(),
            startedAt: Date(),
            intention: intention,
            source: source
        )
        state = .focus
        currentPeriod = period
        notify(old: old, new: state, period: period)
    }

    /// Transition to .bedtime. Same idempotency as activate().
    func activateBedtime(source: ActivationSource = .bedtimeSchedule) {
        let old = state
        if state == .bedtime { return }
        let period = Period(
            id: UUID(),
            startedAt: Date(),
            intention: nil,
            source: source
        )
        state = .bedtime
        currentPeriod = period
        notify(old: old, new: state, period: period)
    }

    /// Transition to .off. Idempotent.
    func deactivate(source: ActivationSource) {
        let old = state
        if state == .off { return }
        state = .off
        currentPeriod = nil
        notify(old: old, new: state, period: nil)
    }

    // MARK: Internal

    private func notify(old: State, new: State, period: Period?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onStateChanged?(old, new, period)
            NotificationCenter.default.post(
                name: .focusModeChanged,
                object: self,
                userInfo: ["old": old.rawValue, "new": new.rawValue]
            )
        }
    }
}

extension Notification.Name {
    static let focusModeChanged = Notification.Name("focusModeChanged")
}

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
        let intentionId: UUID?   // Spec 1 — backend-resident Intention id (nil for legacy/manual no-id activations)
        let source: ActivationSource

        init(id: UUID, startedAt: Date, intention: String?, intentionId: UUID? = nil, source: ActivationSource) {
            self.id = id
            self.startedAt = startedAt
            self.intention = intention
            self.intentionId = intentionId
            self.source = source
        }
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

    init() {
        loadFromDisk()
    }

    // MARK: Persistence

    /// Persistence schema. Versioned so we can evolve without breaking existing
    /// installs. Bump `schemaVersion` when changing the disk shape.
    private struct PersistedState: Codable {
        let schemaVersion: Int
        let stateRaw: String
        let periodId: String?
        let periodStartedAt: Date?
        let periodIntention: String?
        let periodIntentionId: String?   // Spec 1 — added in schemaVersion=2
        let periodSourceRaw: String?
    }
    /// schemaVersion=2 added periodIntentionId (Spec 1). v1 deserialization is forward-compat
    /// because all new fields are optional Strings — older blobs decode with nil intentionId.
    private static let persistenceSchemaVersion = 2

    /// Cached path. Resolved (with directory creation) once per process; nil if
    /// the Application Support directory itself is unreachable (sandbox edge
    /// case). Reused for every saveToDisk()/loadFromDisk() to avoid a syscall
    /// per state transition.
    private static let persistencePath: URL? = {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = support.appendingPathComponent("Intentional", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("focus_mode_state.json")
    }()

    private static let persistenceEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let persistenceDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Read the last-persisted state on init. If a session was active when the
    /// app was last killed (force quit, crash, OS restart), this rehydrates it
    /// immediately so enforcement engages on the very first frame after launch
    /// rather than waiting up to 2s for the first /focus/active poll. The poll
    /// will reconcile if disk and backend disagree (backend wins).
    private func loadFromDisk() {
        guard let path = Self.persistencePath,
              let data = try? Data(contentsOf: path),
              let persisted = try? Self.persistenceDecoder.decode(PersistedState.self, from: data),
              // Accept both v1 and v2 — v2 added an optional field.
              persisted.schemaVersion <= Self.persistenceSchemaVersion,
              let restoredState = State(rawValue: persisted.stateRaw),
              restoredState != .off else { return }
        state = restoredState
        if let id = persisted.periodId.flatMap(UUID.init),
           let startedAt = persisted.periodStartedAt {
            let source = persisted.periodSourceRaw.flatMap(ActivationSource.init(rawValue:)) ?? .crossDevice
            currentPeriod = Period(
                id: id,
                startedAt: startedAt,
                intention: persisted.periodIntention,
                intentionId: persisted.periodIntentionId.flatMap(UUID.init),
                source: source
            )
        }
    }

    private func saveToDisk() {
        guard let path = Self.persistencePath else { return }
        let persisted = PersistedState(
            schemaVersion: Self.persistenceSchemaVersion,
            stateRaw: state.rawValue,
            periodId: currentPeriod?.id.uuidString,
            periodStartedAt: currentPeriod?.startedAt,
            periodIntention: currentPeriod?.intention,
            periodIntentionId: currentPeriod?.intentionId?.uuidString,
            periodSourceRaw: currentPeriod?.source.rawValue
        )
        if let data = try? Self.persistenceEncoder.encode(persisted) {
            try? data.write(to: path, options: .atomic)
        }
    }

    // MARK: API

    /// Transition to .focus. Idempotent on state — calling while already in .focus
    /// updates the intention/source on the current period. Fires onStateChanged if
    /// the intention changes (e.g., Deep Work A → Deep Work B with same .focus state)
    /// so downstream consumers (cache clear, focusMonitor re-eval) still run.
    func activate(intention: String?, intentionId: UUID? = nil, source: ActivationSource) {
        let old = state
        if state == .focus {
            // Already on; refresh metadata. Notify only if intention actually
            // changed — same-state idempotent reactivations don't re-fan-out.
            guard let existing = currentPeriod else { return }
            let newIntention = intention ?? existing.intention
            let newIntentionId = intentionId ?? existing.intentionId
            let intentionChanged = newIntention != existing.intention || newIntentionId != existing.intentionId
            // Preserve the ORIGINAL source — represents "what kicked off this session."
            // If puck started a session, a subsequent schedule tick that refreshes
            // intention shouldn't relabel it as schedule-driven (Task 8 review #1).
            currentPeriod = Period(
                id: existing.id,
                startedAt: existing.startedAt,
                intention: newIntention,
                intentionId: newIntentionId,
                source: existing.source
            )
            if intentionChanged {
                notify(old: old, new: state, period: currentPeriod)
            }
            return
        }
        let period = Period(
            id: UUID(),
            startedAt: Date(),
            intention: intention,
            intentionId: intentionId,
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
        // Persist BEFORE dispatching to main: writing happens on whatever queue
        // notify was called from, so even if main is blocked we don't lose the
        // transition on a crash. atomic write keeps it consistent.
        saveToDisk()
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
    static let interventionToggleChanged = Notification.Name("interventionToggleChanged")
}

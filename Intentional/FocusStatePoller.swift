import Foundation

/// Polls `GET /focus/active` every 2s and routes backend state transitions
/// through `FocusModeController`. Parallel to `FocusWebSocketClient` — whichever
/// path detects the transition first wins; the controller's `activate` /
/// `deactivate` are idempotent.
///
/// Why polling exists alongside WS: WS reconnect logic doesn't recover from a
/// boot-time offline-then-online sequence, leaving Mac silently desubscribed
/// for the rest of the session. Polling has no connection state to keep alive
/// — a network blip means "miss one tick," recover on the next.
///
/// Polling does NOT clobber locally-driven sessions: `STOP` from the poll only
/// deactivates if the current `currentPeriod.source` is `.puck` or
/// `.crossDevice`. A manual or schedule-driven session is untouched.
final class FocusStatePoller {

    private weak var appDelegate: AppDelegate?
    private weak var focusModeController: FocusModeController?
    private var timer: Timer?
    private let interval: TimeInterval = 2.0

    private var lastKnownActive: Bool = false
    private var lastKnownSessionId: String?

    init(appDelegate: AppDelegate, focusModeController: FocusModeController) {
        self.appDelegate = appDelegate
        self.focusModeController = focusModeController
    }

    func start() {
        stop()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        appDelegate?.postLog("🔄 FocusStatePoller started (interval=\(interval)s)")
        Task { await poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var pollCount = 0

    /// Polls /focus/active using `X-Device-ID` header (long-lived, account-linked
    /// via /auth/verify). Does NOT use Bearer JWT — that 15-min TTL caused
    /// constant 401s and any auto-refresh-on-401 races with Supabase's
    /// token-reuse detector, which revoked all sessions. Device-ID auth has
    /// no expiry, no refresh, no race.
    private func poll() async {
        pollCount += 1
        let n = pollCount

        guard let appDelegate = appDelegate else { return }
        guard let deviceId = appDelegate.backendClient?.getDeviceId() else {
            if n <= 3 || n % 30 == 0 {
                appDelegate.postLog("🔄 FocusStatePoller poll #\(n): no deviceId, skipping")
            }
            return
        }

        let urlString = "https://api.intentional.social/focus/active"
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            if status == 401 {
                if n <= 3 || n % 30 == 0 {
                    appDelegate.postLog("🔄 FocusStatePoller poll #\(n): HTTP 401 — device not linked to account (sign in once)")
                }
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                appDelegate.postLog("🔄 FocusStatePoller poll #\(n) BAD JSON (HTTP \(status)): \(preview)")
                return
            }

            let active = json["active"] as? Bool ?? false
            let sessionId = json["session_id"] as? String
            let triggeredBy = (json["triggered_by"] as? String) ?? "puck"
            let intentionIdStr = json["intention_id"] as? String
            let intentionId = intentionIdStr.flatMap { UUID(uuidString: $0) }

            let shouldLog = (n <= 5) || (status >= 400) || (n % 30 == 0)
            if shouldLog {
                appDelegate.postLog("🔄 FocusStatePoller poll #\(n): HTTP \(status) active=\(active) session=\(sessionId ?? "-") triggeredBy=\(triggeredBy) intentionId=\(intentionIdStr ?? "-")")
            }

            await MainActor.run {
                self.applyTransition(active: active, sessionId: sessionId, triggeredBy: triggeredBy, intentionId: intentionId)
            }
        } catch {
            if n <= 3 || n % 30 == 0 {
                appDelegate.postLog("🔄 FocusStatePoller poll #\(n) ERROR: \(error.localizedDescription)")
            }
        }
    }

    private func applyTransition(active: Bool, sessionId: String?, triggeredBy: String, intentionId: UUID?) {
        guard focusModeController != nil else { return }
        let prevActive = lastKnownActive
        let prevSessionId = lastKnownSessionId

        lastKnownActive = active
        lastKnownSessionId = sessionId

        if active && !prevActive {
            appDelegate?.postLog("🔄 FocusStatePoller: detected START (session: \(sessionId ?? "-"), triggeredBy: \(triggeredBy), intentionId: \(intentionId?.uuidString ?? "-"))")
            engage(triggeredBy: triggeredBy, intentionId: intentionId, sessionId: sessionId)
        } else if !active && prevActive {
            appDelegate?.postLog("🔄 FocusStatePoller: detected STOP (was session: \(prevSessionId ?? "-"))")
            disengageIfRemoteOriginated()
        } else if active && prevActive && sessionId != prevSessionId {
            appDelegate?.postLog("🔄 FocusStatePoller: session changed \(prevSessionId ?? "-") → \(sessionId ?? "-")")
            engage(triggeredBy: triggeredBy, intentionId: intentionId, sessionId: sessionId)
        }
    }

    /// Engage local enforcement. Spec 1: looks up the Intention name from
    /// IntentionStore using the intention_id stamped on the backend session.
    /// Cache miss falls through with a generic name and triggers an out-of-band
    /// pull so the next session lookup hits.
    /// Also mirrors the resolved intention into AppDelegate.activeProjectSession,
    /// so the in-RAM cache stays canonically driven by the backend.
    private func engage(triggeredBy: String, intentionId: UUID?, sessionId: String?) {
        Task { @MainActor in
            let intentionName: String?
            if let id = intentionId {
                if let cached = await IntentionStore.shared.intention(id: id) {
                    intentionName = cached.name
                } else {
                    intentionName = "Focus session"
                    Task { await IntentionStore.shared.pull() }
                }
                if let sessionId = sessionId {
                    self.appDelegate?.setActiveProjectSession(projectId: id, blockId: sessionId)
                }
            } else {
                intentionName = triggeredBy == "puck"
                    ? "Focus session (started on phone)"
                    : "Focus session"
            }
            let source: FocusModeController.ActivationSource =
                triggeredBy == "puck" ? .puck : .crossDevice
            self.focusModeController?.activate(
                intention: intentionName,
                intentionId: intentionId,
                source: source
            )
        }
    }

    private func disengageIfRemoteOriginated() {
        guard let controller = focusModeController,
              let period = controller.currentPeriod else { return }
        if period.source == .puck || period.source == .crossDevice {
            controller.deactivate(source: .crossDevice)
        }
    }
}

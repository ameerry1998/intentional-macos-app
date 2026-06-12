import Foundation
import AppKit

/// Focus Agent S2 (shadow mode): samples abstracted activity — app/host names
/// and durations only, never titles or content — buffers it, and flushes to
/// the backend every few minutes. Privacy gate: `coachTelemetryLevel`
/// UserDefaults ("names" default | "off").
/// Spec: docs/superpowers/specs/2026-06-12-focus-agent-design.md
final class CoachTelemetry {

    struct Event {
        let ts: Date
        let kind: String          // sample | session_start | session_end | allowance_zero | idle
        let payload: [String: Any]
    }

    private var buffer: [Event] = []
    private let lock = NSLock()
    private var sampleTimer: Timer?
    private var flushTimer: Timer?
    private weak var backendClient: BackendClient?
    private weak var focusModeController: FocusModeController?
    private weak var focusMonitor: FocusMonitor?

    static let sampleInterval: TimeInterval = 60
    static let flushInterval: TimeInterval = 180

    var enabled: Bool {
        (UserDefaults.standard.string(forKey: "coachTelemetryLevel") ?? "names") != "off"
    }

    init(backendClient: BackendClient?, focusModeController: FocusModeController?,
         focusMonitor: FocusMonitor?) {
        self.backendClient = backendClient
        self.focusModeController = focusModeController
        self.focusMonitor = focusMonitor
    }

    func start() {
        guard sampleTimer == nil else { return }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(sampleTimer!, forMode: .common)
        RunLoop.main.add(flushTimer!, forMode: .common)
        NSLog("📡 CoachTelemetry started (sample \(Int(Self.sampleInterval))s, flush \(Int(Self.flushInterval))s)")
    }

    func stop() {
        sampleTimer?.invalidate(); sampleTimer = nil
        flushTimer?.invalidate(); flushTimer = nil
    }

    /// Boundary events pushed by AppDelegate's onStateChanged fanout.
    func recordBoundary(kind: String, payload: [String: Any] = [:]) {
        guard enabled else { return }
        append(Event(ts: Date(), kind: kind, payload: payload))
        flush()  // boundaries flush immediately — they're the agent's trigger moments
    }

    private func sample() {
        guard enabled else { return }
        var payload: [String: Any] = [:]
        let frontmost = NSWorkspace.shared.frontmostApplication
        payload["app"] = frontmost?.bundleIdentifier ?? "unknown"
        // Host only (never title/path) — privacy level "names".
        if let host = focusMonitor?.currentTabHost {
            payload["host"] = host
        }
        payload["in_session"] = focusModeController?.isOn == true
        if let mins = AllowanceBalance.shared.availableMinutesAfterPending {
            payload["allowance_minutes_left"] = mins
        }
        append(Event(ts: Date(), kind: "sample", payload: payload))
    }

    private func append(_ e: Event) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(e)
        if buffer.count > 400 { buffer.removeFirst(buffer.count - 400) }  // bound memory
    }

    func flush() {
        guard enabled else { return }
        lock.lock()
        let toSend = buffer
        buffer.removeAll()
        lock.unlock()
        guard !toSend.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        let events: [[String: Any]] = toSend.map {
            ["ts": iso.string(from: $0.ts), "kind": $0.kind, "payload": $0.payload]
        }
        Task { [weak self] in
            let ok = await self?.backendClient?.postCoachTelemetry(events: events) ?? false
            if !ok {
                // Put the batch back (front) so nothing is lost on transient failures.
                self?.reinsert(toSend)
            } else {
                NSLog("📡 CoachTelemetry flushed \(events.count) events")
            }
        }
    }

    /// Re-queue a failed batch at the front of the buffer (sync — safe to call
    /// from the flush Task without async-context lock warnings).
    private func reinsert(_ events: [Event]) {
        lock.lock(); defer { lock.unlock() }
        buffer.insert(contentsOf: events, at: 0)
        if buffer.count > 400 { buffer.removeLast(buffer.count - 400) }
    }
}

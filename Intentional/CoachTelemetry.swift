import Foundation
import AppKit

/// Focus Agent S2 (shadow mode): samples abstracted activity — app/host names,
/// window/tab titles, and (at the default tier) one locally-generated sentence
/// describing what's on screen — buffers it, and flushes to the backend every
/// few minutes. Privacy gate: `coachTelemetryLevel` UserDefaults
/// ("descriptions" default | "titles" | "names" | "off").
/// Descriptions are produced fully on-device: ScreenCapture → Qwen3-VL vision
/// model (OCR+Qwen3-4B text as fallback — see
/// RelevanceScorer.describeScreenForTelemetry; the event payload's "engine"
/// field says which pipeline produced each one). Never in-session (the scorer
/// already produces relevance data there) and never racing scoring.
/// Triggers: 60s sample timer (60s min-gap floor) + app-switch (different
/// bundle id than the last described one, 2s settle delay, 15s min-gap).
/// Spec: docs/superpowers/specs/2026-06-12-focus-agent-design.md
final class CoachTelemetry {

    struct Event {
        let ts: Date
        let kind: String          // sample | session_start | session_end | allowance_zero | idle | description
        let payload: [String: Any]
    }

    private var buffer: [Event] = []
    private let lock = NSLock()
    private var sampleTimer: Timer?
    private var flushTimer: Timer?
    private weak var backendClient: BackendClient?
    private weak var focusModeController: FocusModeController?
    private weak var focusMonitor: FocusMonitor?
    private weak var relevanceScorer: RelevanceScorer?

    // Screen-description single-flight + throttle (timer floor 60s;
    // app-switch trigger may shrink the gap to 15s, never below).
    private var descriptionInFlight = false
    private var lastDescriptionAt: Date?
    /// Bundle id the most recent description event covered — app-switch
    /// triggers only fire when the activated app differs from this.
    private var lastDescribedBundleId: String?
    /// 2s settle delay after app activation before describing — rapid
    /// Cmd-Tab chains keep pushing it out so only the landing app is described.
    /// Main-thread only (observer queue is .main).
    private var appSwitchSettleTimer: Timer?
    private var appActivationObserver: NSObjectProtocol?

    static let sampleInterval: TimeInterval = 60
    static let flushInterval: TimeInterval = 180
    static let descriptionInterval: TimeInterval = 60          // timer-driven floor
    static let appSwitchDescriptionMinGap: TimeInterval = 15   // app-switch-triggered
    static let appSwitchSettleDelay: TimeInterval = 2
    static let decisionPollInterval: TimeInterval = 60

    // Focus Agent S3: pending coach-decision poll (plan_prompt card).
    // Set by AppDelegate. Invoked on the MAIN thread with the decision dict;
    // returns true only when the card was actually presented (guards may
    // refuse: session active, bedtime, pill busy). We only mark a decision
    // id as presented on true, so refused decisions retry next poll.
    var onCoachDecision: (([String: Any]) -> Bool)?
    private var decisionTimer: Timer?
    private var decisionPollInFlight = false
    /// In-memory only — deliberately NOT persisted. Survival rule: a decision
    /// the backend still serves with outcome=="shown" re-presents exactly once
    /// after app restart (the set starts empty), then lands here again.
    private var presentedDecisionIds: Set<String> = []

    /// Current privacy tier. Default is "descriptions" (new top tier).
    private var level: String {
        UserDefaults.standard.string(forKey: "coachTelemetryLevel") ?? "descriptions"
    }

    var enabled: Bool { level != "off" }

    init(backendClient: BackendClient?, focusModeController: FocusModeController?,
         focusMonitor: FocusMonitor?, relevanceScorer: RelevanceScorer? = nil) {
        self.backendClient = backendClient
        self.focusModeController = focusModeController
        self.focusMonitor = focusMonitor
        self.relevanceScorer = relevanceScorer
    }

    func start() {
        guard sampleTimer == nil else { return }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
            self?.flush()
        }
        // S3: parallel 60s check for a pending coach decision (plan_prompt).
        decisionTimer = Timer.scheduledTimer(withTimeInterval: Self.decisionPollInterval, repeats: true) { [weak self] _ in
            self?.pollPendingDecision()
        }
        RunLoop.main.add(sampleTimer!, forMode: .common)
        RunLoop.main.add(flushTimer!, forMode: .common)
        RunLoop.main.add(decisionTimer!, forMode: .common)
        // App-switch description trigger: a different app coming frontmost is
        // exactly the moment the coach wants fresh eyes (timer floor stays).
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleAppActivation(note)
        }
        NSLog("📡 CoachTelemetry started (sample \(Int(Self.sampleInterval))s, flush \(Int(Self.flushInterval))s, decision poll \(Int(Self.decisionPollInterval))s, app-switch describe gap \(Int(Self.appSwitchDescriptionMinGap))s)")
    }

    func stop() {
        sampleTimer?.invalidate(); sampleTimer = nil
        flushTimer?.invalidate(); flushTimer = nil
        decisionTimer?.invalidate(); decisionTimer = nil
        appSwitchSettleTimer?.invalidate(); appSwitchSettleTimer = nil
        if let obs = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appActivationObserver = nil
        }
    }

    /// App-switch description trigger (descriptions tier only, never
    /// in-session — maybeDescribeScreen re-checks both). Fires only when the
    /// activated bundle id differs from the last DESCRIBED one, after a 2s
    /// settle delay, with a 15s min-gap instead of the 60s timer floor.
    /// Single-flight + throttle live in maybeDescribeScreen, unchanged.
    private func handleAppActivation(_ note: Notification) {
        guard descriptionsEnabled else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier else { return }
        lock.lock()
        let last = lastDescribedBundleId
        lock.unlock()
        guard bundleId != last else { return }
        appSwitchSettleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.appSwitchSettleDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Re-read frontmost at fire time — the user may have moved on
            // during the settle window; describe what they landed on.
            let frontId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? bundleId
            self.lock.lock()
            let lastDescribed = self.lastDescribedBundleId
            self.lock.unlock()
            guard frontId != lastDescribed else { return }
            self.maybeDescribeScreen(app: frontId, host: nil, minGap: Self.appSwitchDescriptionMinGap)
        }
        appSwitchSettleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Focus Agent S3: fetch the pending coach decision and hand it to the
    /// presenter (AppDelegate → pill coach card). Single-flight; skips ids
    /// already presented this app run (see presentedDecisionIds note).
    private func pollPendingDecision() {
        guard enabled, onCoachDecision != nil else { return }
        lock.lock()
        if decisionPollInFlight { lock.unlock(); return }
        decisionPollInFlight = true
        lock.unlock()
        Task { [weak self] in
            defer {
                if let self {
                    self.lock.lock()
                    self.decisionPollInFlight = false
                    self.lock.unlock()
                }
            }
            guard let self, let client = self.backendClient else { return }
            guard let decision = await client.fetchPendingCoachDecision(),
                  let id = decision["id"] as? String else { return }
            self.lock.lock()
            let alreadyPresented = self.presentedDecisionIds.contains(id)
            self.lock.unlock()
            guard !alreadyPresented else { return }
            // Present on main; mark presented only when the card actually rendered.
            let presented = await MainActor.run { self.onCoachDecision?(decision) ?? false }
            if presented {
                self.lock.lock()
                self.presentedDecisionIds.insert(id)
                self.lock.unlock()
                NSLog("📡 CoachTelemetry: presented coach decision \(id.prefix(8))")
            }
        }
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
        payload["in_session"] = focusModeController?.isOn == true
        if let mins = AllowanceBalance.shared.availableMinutesAfterPending {
            payload["allowance_minutes_left"] = mins
        }
        // Window title via Accessibility — covers native apps (iTerm shows
        // cwd/command, Cursor shows the file, etc.). Content-derived: gated
        // by the privacy level ("titles" default; "names" strips it).
        if titlesEnabled, let winTitle = Self.frontmostWindowTitle() {
            payload["title"] = String(winTitle.prefix(100))
        }
        let ts = Date()
        // Browser tab host (+ title, replacing the window title — it's more
        // specific) read live on the AppleScript queue: FocusMonitor's cached
        // tab state is enforcement-gated and empty outside sessions, which
        // left the coach blind to sites (verified live 2026-06-12).
        let appId = payload["app"] as? String ?? "unknown"
        if let fm = focusMonitor {
            fm.fetchTabInfoForTelemetry { [weak self] host, tabTitle in
                guard let self else { return }
                var p = payload
                if let host { p["host"] = host }
                if self.titlesEnabled, let tabTitle { p["title"] = tabTitle }
                self.append(Event(ts: ts, kind: "sample", payload: p))
                self.maybeDescribeScreen(app: appId, host: host)
            }
        } else {
            append(Event(ts: ts, kind: "sample", payload: payload))
            maybeDescribeScreen(app: appId, host: nil)
        }
    }

    /// Fire-and-forget screen description: ONE on-device sentence about what
    /// the user is doing (ScreenCapture → vision model, OCR+text fallback —
    /// the payload's "engine" says which), appended as a separate
    /// "description" event so the regular sample is never delayed.
    /// Gates: privacy tier == "descriptions" (default) AND not in a focus
    /// session (in-session, the scorer already produces relevance data — and
    /// telemetry must never contend with it for the model). Throttled to one
    /// per `minGap` (60s timer floor; 15s for app-switch triggers) with a
    /// single-flight guard (skip, never queue).
    private func maybeDescribeScreen(app: String, host: String?,
                                     minGap: TimeInterval = CoachTelemetry.descriptionInterval) {
        guard descriptionsEnabled else { return }
        guard focusModeController?.isOn != true else { return }
        lock.lock()
        let throttled = lastDescriptionAt.map { Date().timeIntervalSince($0) < minGap } ?? false
        if descriptionInFlight || throttled {
            lock.unlock()
            return
        }
        descriptionInFlight = true
        lastDescriptionAt = Date()   // stamp at start — failures still throttle
        lock.unlock()

        Task { [weak self] in
            defer {
                if let self {
                    self.lock.lock()
                    self.descriptionInFlight = false
                    self.lock.unlock()
                }
            }
            guard let scorer = self?.relevanceScorer else { return }
            guard let result = await scorer.describeScreenForTelemetry() else { return }
            // Re-check session state: a session may have started mid-generation.
            guard let self, self.focusModeController?.isOn != true else { return }
            var p: [String: Any] = [
                "app": app,
                "description": result.description,
                "engine": result.engine,
            ]
            if let host { p["host"] = host }
            self.append(Event(ts: Date(), kind: "description", payload: p))
            self.lock.lock()
            self.lastDescribedBundleId = app
            self.lock.unlock()
        }
    }

    /// Privacy tiers: "descriptions" (default — names + titles + on-device
    /// screen descriptions), "titles" (names + window/tab titles), "names"
    /// (names only), "off".
    private var titlesEnabled: Bool { level != "names" }
    private var descriptionsEnabled: Bool { level == "descriptions" }

    static func frontmostWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win, CFGetTypeID(w as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        let s = title as? String
        return (s?.isEmpty == false) ? s : nil
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

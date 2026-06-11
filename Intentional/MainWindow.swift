//
//  MainWindow.swift
//  Intentional
//
//  Main application window using WKWebView for web-like UI.
//  Shows onboarding on first launch, then dashboard.
//

import Cocoa
import WebKit

class MainWindow: NSWindowController, WKScriptMessageHandler, WKUIDelegate {

    private var webView: WKWebView!
    weak var appDelegate: AppDelegate?

    #if DEBUG
    // UI Perf instrumentation — DEBUG only. Every 3s we dump counts of incoming messages
    // + outgoing callJS invocations. Tail: `tail -f $TMPDIR/intentional-debug.log | grep UIPERF`.
    // Release builds skip the per-message counter work entirely.
    private var uiPerfRxCounts: [String: Int] = [:]
    private var uiPerfCallJSCount: Int = 0
    private var uiPerfCallJSBytes: Int = 0
    private var uiPerfLastFlush: Date = Date()

    private func uiPerfMaybeFlush() {
        let now = Date()
        guard now.timeIntervalSince(uiPerfLastFlush) >= 3.0 else { return }
        let rx = uiPerfRxCounts
        let jsCount = uiPerfCallJSCount
        let jsBytes = uiPerfCallJSBytes
        uiPerfRxCounts.removeAll(keepingCapacity: true)
        uiPerfCallJSCount = 0
        uiPerfCallJSBytes = 0
        uiPerfLastFlush = now
        let rxStr = rx.sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        appDelegate?.postLog("[UIPERF] 3s: callJS=\(jsCount) (\(jsBytes) bytes)  rx={\(rxStr)}")
    }

    // MARK: - UI Test Hook (Settings Consolidation S1, 2026-06-10) — DEBUG only.
    //
    // Watches /tmp/intentional-uitest-cmd.json for {"id": N, "js": "..."}.
    // On a NEW id, evaluates the JS in the dashboard WKWebView and writes
    // {"id": N, "result": ...} or {"id": N, "error": "..."} to
    // /tmp/intentional-uitest-result.json. Enables instant selector-clicks and
    // DOM-state reads during verification instead of synthesized mouse events.
    //
    // Implementation note: a 500ms DispatchSourceTimer poll (not a vnode
    // watcher) — editors and `cat >` replace/truncate the file, which silently
    // kills vnode sources on the old inode. The id check makes the poll
    // idempotent (stale/already-processed ids are ignored), and 500ms is the
    // debounce.
    private var uiTestTimer: DispatchSourceTimer?
    private var uiTestLastId: Int = .min
    private static let uiTestCmdPath = "/tmp/intentional-uitest-cmd.json"
    private static let uiTestResultPath = "/tmp/intentional-uitest-result.json"

    private func startUITestHook() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self = self,
                  let data = FileManager.default.contents(atPath: MainWindow.uiTestCmdPath),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = json["id"] as? Int,
                  let js = json["js"] as? String,
                  id != self.uiTestLastId else { return }
            self.uiTestLastId = id
            DispatchQueue.main.async {
                self.webView.evaluateJavaScript(js) { value, error in
                    var out: [String: Any] = ["id": id]
                    if let error = error {
                        out["error"] = error.localizedDescription
                    } else if let value = value {
                        // evaluateJavaScript returns Foundation-bridged values;
                        // only embed directly if the wrapper is JSON-encodable.
                        out["result"] = JSONSerialization.isValidJSONObject(["v": value])
                            ? value : String(describing: value)
                    } else {
                        out["result"] = NSNull()
                    }
                    if let outData = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]) {
                        try? outData.write(to: URL(fileURLWithPath: MainWindow.uiTestResultPath), options: .atomic)
                    }
                }
            }
        }
        timer.resume()
        uiTestTimer = timer
        appDelegate?.postLog("🧪 UI test hook armed — watching \(MainWindow.uiTestCmdPath)")
    }
    #endif

    convenience init(appDelegate: AppDelegate) {
        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Initialize controller
        self.init(window: window)
        self.appDelegate = appDelegate

        // Configure WKWebView with message handler bridge
        let contentController = WKUserContentController()
        contentController.add(self, name: "intentional")

        // Inject theme at document-start to prevent flash of wrong theme
        let theme = MainWindow.readThemeFromSettings()
        let themeScript = WKUserScript(
            source: MainWindow.themeInjectionJS(theme: theme),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(themeScript)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        // Allow file:// access for local resources
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]

        // Dark background to match the web UI
        webView.setValue(false, forKey: "drawsBackground")
        webView.uiDelegate = self

        #if DEBUG
        // Safari Web Inspector — DEBUG only, never exposed in Release builds.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        window.contentView = webView
        window.title = "Intentional"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.backgroundColor = MainWindow.windowBackground(for: theme)

        // Force window visible
        print("🚨 ACTIVATE: MainWindow.init — makeKeyAndOrderFront + orderFrontRegardless")
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // Observe partner cross-device sync updates so the dashboard reflects
        // partner data set on a sibling device (e.g. iPhone) the moment
        // PartnerSyncService finishes its periodic /partner/status pull.
        observePartnerSyncUpdates()

        // Spec 1 — re-push intentions list to dashboard whenever IntentionStore
        // pulls fresh data (60s timer, didBecomeActive, or any push CRUD).
        NotificationCenter.default.addObserver(
            forName: .intentionsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleGetIntentions()
        }

        // May 2026 — re-push monthly goals list to dashboard whenever
        // MonthlyGoalStore pulls fresh data or any push CRUD lands.
        NotificationCenter.default.addObserver(
            forName: .monthlyGoalsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleGetMonthlyGoals()
        }

        // Load appropriate page
        loadCurrentPage()

        #if DEBUG
        // S1 (2026-06-10): file-driven JS evaluation for GUI verification.
        // Compiled out of Release builds entirely.
        startUITestHook()
        #endif
    }

    /// Listen for PartnerSyncService.pullAndApply() completions and forward
    /// the partnerEmail / partnerName / partnerConsentStatus into the
    /// dashboard via the `_partnerStatusResult` JS receiver. Also persists
    /// the values into the dashboard settings JSON so they survive page
    /// reloads.
    private func observePartnerSyncUpdates() {
        NotificationCenter.default.addObserver(
            forName: .partnerSyncDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let info = note.userInfo ?? [:]
            let email = (info["partnerEmail"] as? String) ?? ""
            let name = (info["partnerName"] as? String) ?? ""
            let consentStatus = (info["partnerConsentStatus"] as? String) ?? ""

            // Persist to settings JSON so the values survive a dashboard
            // reload (which re-hydrates `settings` from disk via
            // _settingsResult).
            self.updateSettingsFile { settings in
                settings["partnerEmail"] = email
                settings["partnerName"] = name
                if !consentStatus.isEmpty {
                    settings["consentStatus"] = consentStatus
                }
            }

            // Push to live dashboard. Use JSONSerialization to escape
            // partner names that contain apostrophes / quotes — building
            // the JS literal by string interpolation breaks on those.
            // We reuse the existing `_partnerStatusResult` receiver
            // instead of inventing a new symbol; it already handles the
            // same three fields and re-renders the lock-state UI.
            var payload: [String: Any] = [
                "success": true,
                "partnerEmail": email,
                "partnerName": name,
                "message": ""
            ]
            if !consentStatus.isEmpty {
                payload["consentStatus"] = consentStatus
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
               let json = String(data: data, encoding: .utf8) {
                self.callJS("window._partnerStatusResult && window._partnerStatusResult(\(json))")
            }
        }
    }

    // MARK: - Theme Helpers

    static func readThemeFromSettings() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let settingsURL = appSupport.appendingPathComponent("Intentional/onboarding_settings.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let theme = json["theme"] as? String else {
            return "iridescent"
        }
        return theme
    }

    static func themeInjectionJS(theme: String) -> String {
        let setAttr = theme == "iridescent" ? "" : "document.documentElement.setAttribute('data-theme','\(theme)');"
        let effectClass: String
        switch theme {
        case "iridescent": effectClass = "document.body.classList.add('theme-effects-iridescent');"
        case "warm": effectClass = "document.body.classList.add('theme-effects-warm');"
        default: effectClass = ""
        }
        // Run at document-start: set attribute immediately, add body class after DOM ready
        return """
        \(setAttr)
        document.addEventListener('DOMContentLoaded', function() {
            \(effectClass)
        });
        """
    }

    static func windowBackground(for theme: String) -> NSColor {
        switch theme {
        case "classic":   return NSColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1.0)
        case "emerald":   return NSColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1.0)
        case "warm":      return NSColor(red: 0.067, green: 0.067, blue: 0.063, alpha: 1.0)
        case "light":     return NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
        default:          return NSColor(red: 0.055, green: 0.055, blue: 0.07, alpha: 1.0) // iridescent
        }
    }

    // MARK: - Page Loading

    func loadCurrentPage() {
        // Login gate: if there's no JWT in Keychain, show login.html.
        // Once login completes, login.html posts AUTH_COMPLETE which calls
        // loadCurrentPage() again — at which point isLoggedIn is true and we
        // route to dashboard/onboarding as today.
        if appDelegate?.backendClient?.isLoggedIn == false {
            loadPage("login")
            return
        }
        let isComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
        if isComplete {
            loadPage("dashboard")
        } else {
            loadPage("onboarding")
        }
    }

    private func loadPage(_ name: String) {
        guard let htmlURL = Bundle.main.url(forResource: name, withExtension: "html") else {
            appDelegate?.postLog("ERROR: \(name).html not found in bundle")
            return
        }
        // allowingReadAccessTo the parent directory so HTML can load sibling resources
        webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        appDelegate?.postLog("🌐 Loaded \(name).html in WKWebView")
    }

    /// Push the current schedule state to the dashboard (refreshes calendar + focus page).
    func pushScheduleUpdate() {
        guard let manager = appDelegate?.scheduleManager else { return }
        var state = manager.getScheduleSyncPayload()
        state.removeValue(forKey: "type")
        // FIX-10: Surface the live intention id of the active session so the dashboard
        // can grey out strictness controls for that goal while it's running. The
        // session's period (set by every activation path) is canonical; fall back to
        // the current scheduled block's bound intentionId.
        if let sessionGoalId = appDelegate?.focusModeController?.currentPeriod?.intentionId {
            state["active_intention_id"] = sessionGoalId.uuidString
        } else if let blockIntentionId = manager.currentBlock?.intentionId {
            state["active_intention_id"] = blockIntentionId.uuidString
        } else {
            state["active_intention_id"] = NSNull()
        }
        if let data = try? JSONSerialization.data(withJSONObject: state),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._scheduleStateResult && window._scheduleStateResult(\(json))")
        }
    }

    /// Close-the-noise toast: dashboard renders 30s undo banner with
    /// [View stash] + [Restore everything] buttons. Fires from
    /// AppDelegate.runCloseTheNoiseSweep when the sweep finishes.
    func pushSweepToast(stashedTabs: Int, hiddenApps: Int, sessionId: String) {
        let safeSession = sessionId.replacingOccurrences(of: "'", with: "")
        callJS("window._sweepToast && window._sweepToast({" +
               "stashedTabs:\(stashedTabs), hiddenApps:\(hiddenApps), sessionId:'\(safeSession)'})")
    }

    /// Navigate the dashboard to a specific page (e.g., "today", "settings", "youtube").
    func navigateToPage(_ pageId: String) {
        webView.evaluateJavaScript("navigateTo('\(pageId)')") { _, error in
            if let error = error {
                self.appDelegate?.postLog("⚠️ navigateToPage('\(pageId)') error: \(error)")
            }
        }
    }

    /// Navigate to today page and open the block editor for a new block at the current time.
    func openScheduleWithNewBlock() {
        webView.evaluateJavaScript("navigateTo('today'); setTimeout(function(){ openNewBlockDraft(); }, 400);") { _, error in
            if let error = error {
                self.appDelegate?.postLog("⚠️ openScheduleWithNewBlock error: \(error)")
            }
        }
    }

    // MARK: - WKUIDelegate (JS alert/confirm dialogs)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else {
            appDelegate?.postLog("⚠️ WKWebView: Invalid message format")
            return
        }

        if type.contains("INTENTION") || type.contains("PROJECT") ||
           type.contains("MONTHLY_GOAL") || type == "UPDATE_INTENTION_STRICTNESS" ||
           type == "LINK_WEEKLY_TO_MONTHLY" || type == "START_GOAL_SESSION" ||
           type == "CREATE_SCHEDULED_SESSION" {
            appDelegate?.postLog("📥 BRIDGE rx: \(type)")
        }

        #if DEBUG
        if type != "DIAGNOSTIC_LOG" {
            uiPerfRxCounts[type, default: 0] += 1
            uiPerfMaybeFlush()
        }
        let rxStart = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - rxStart) * 1000
            if ms > 50 && type != "DIAGNOSTIC_LOG" {
                appDelegate?.postLog("[UIPERF] SLOW rx \(type) sync-phase \(Int(ms))ms")
            }
        }
        #endif

        switch type {
        case "DIAGNOSTIC_LOG":
            if let msg = body["msg"] as? String {
                appDelegate?.postLog(msg)
            }

        case "SAVE_ONBOARDING":
            handleSaveOnboarding(body)

        case "GET_DASHBOARD_DATA":
            handleGetDashboardData()

        case "GET_SETTINGS":
            handleGetSettings()

        case "GET_FOCUS_MODE":
            handleGetFocusMode()

        case "TEST_CONTENT_SAFETY":
            appDelegate?.contentSafetyMonitor?.triggerTestDetection()

        case "GET_NSFW_THRESHOLD":
            let t = ContentSafetyMonitor.currentNSFWThreshold()
            callJS("window._nsfwThresholdResult && window._nsfwThresholdResult({ threshold: \(t) })")

        case "SET_NSFW_THRESHOLD":
            if let body = message.body as? [String: Any],
               let t = body["threshold"] as? Double {
                ContentSafetyMonitor.setNSFWThreshold(Float(t))
                let stored = ContentSafetyMonitor.currentNSFWThreshold()
                callJS("window._nsfwThresholdResult && window._nsfwThresholdResult({ threshold: \(stored) })")
                appDelegate?.postLog("🛡️ NSFW threshold set to \(stored)")
            }

        case "LOG_GOAL_TIME":
            if let body = message.body as? [String: Any],
               let goalIdStr = body["intention_id"] as? String,
               let goalId = UUID(uuidString: goalIdStr),
               let minutes = body["minutes"] as? Int,
               minutes > 0 {
                Task {
                    guard let backend = self.appDelegate?.backendClient else { return }
                    let result = await backend.logIntentionTime(id: goalId, minutes: minutes)
                    await MainActor.run {
                        if let hours = result {
                            // Patch cache + refresh Plan
                            self.callJS("window._intentionHoursDoneResult && window._intentionHoursDoneResult({ id: '\(goalIdStr)', hours_done: \(hours) })")
                        }
                    }
                }
            }

        case "OPEN_CONTENT_SAFETY_SETTINGS":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }

        case "SAVE_LOCK_SETTINGS":
            handleSaveLockSettings(body)

        case "REQUEST_UNLOCK":
            handleRequestUnlock()

        case "VERIFY_UNLOCK":
            handleVerifyUnlock(body)

        case "GET_PARTNER_STATUS":
            handleGetPartnerStatus()

        case "GET_CONTENT_SAFETY_STATE":
            // FIX-15: status footer pull — emits _contentSafetyState
            handleGetContentSafetyState()

        case "GET_PUCK_STATUS":
            // FIX-15: status footer pull — Mac has no Puck pairing yet, so
            // this always emits connected:false. Stub for cross-device parity.
            handleGetPuckStatus()

        case "RELOCK_SETTINGS":
            handleRelockSettings()

        case "REMOVE_PARTNER":
            handleRemovePartner()

        case "RESEND_PARTNER_INVITE":
            handleResendPartnerInvite()

        case "SAVE_SETTINGS":
            handleSaveSettings(body)

        case "END_SESSION":
            handleEndSession(body)

        case "RESET_SETTINGS":
            handleResetSettings()

        case "UNINSTALL_APP":
            handleUninstall(requireCode: false)

        case "VERIFY_UNINSTALL":
            let code = body["code"] as? String ?? ""
            handleVerifyUninstall(code: code)

        case "NAVIGATE_TO_DASHBOARD":
            loadPage("dashboard")

        case "GET_AUTH_STATE":
            handleGetAuthState()

        case "AUTH_LOGIN":
            handleAuthLogin(body)

        case "AUTH_VERIFY":
            handleAuthVerify(body)

        case "AUTH_LOGOUT":
            handleAuthLogout()

        case "AUTH_DELETE":
            handleAuthDelete()

        case "AUTH_COMPLETE":
            appDelegate?.postLog("✅ AUTH_COMPLETE received — swapping page")
            DispatchQueue.main.async { [weak self] in
                self?.loadCurrentPage()
                // Sign-in just wrote fresh tokens to Keychain. The WebSocket
                // connect logic only fires at app launch — so a user who
                // launched with no tokens AND signed in mid-session would
                // never get a WS subscription. Trigger the connect here.
                self?.appDelegate?.connectFocusWebSocketIfNeeded()
            }

        case "GET_USAGE_HISTORY":
            handleGetUsageHistory()

        case "GET_JOURNAL":
            handleGetJournal()

        case "GET_SCHEDULE_STATE":
            handleGetScheduleState()

        case "SET_FOCUS_ENABLED":
            handleSetFocusEnabled(body)

        case "SET_PROFILE":
            handleSetProfileFromDashboard(body)

        case "SET_SCHEDULE":
            handleSetScheduleFromDashboard(body)

        case "GET_FOCUS_SCORE":
            handleGetFocusScore()

        case "GET_RELEVANCE_LOG":
            handleGetRelevanceLog()

        case "EXPORT_RELEVANCE_LOG":
            handleExportRelevanceLog()

        case "SET_FOCUS_ENFORCEMENT":
            handleSetFocusEnforcement(body)

        case "SET_AI_MODEL":
            handleSetAIModel(body)

        // LEGACY (Rules Consolidation R6, 2026-06-11): the Earned Browse
        // widget + Extra Time flow were deleted with EarnedBrowseManager —
        // the shared daily allowance (Rules page) replaced them. Kept as
        // no-op aliases for one release cycle (an old cached dashboard could
        // still post these). Remove after 2026-07.
        case "GET_EARNED_STATUS", "REQUEST_EXTRA_TIME", "VERIFY_EXTRA_TIME_CODE":
            appDelegate?.postLog("⚠️ \(type): legacy earned-browse message ignored (deleted in R6)")

        case "GET_BLOCK_ASSESSMENTS":
            handleGetBlockAssessments(body)

        case "SET_CALENDAR_ZOOM":
            if let zoom = body["zoom"] as? Int {
                appDelegate?.scheduleManager?.setCalendarZoom(zoom)
            }

        case "SET_ENFORCEMENT_SETTINGS":
            handleSetEnforcementSettings(body)

        case "SET_STRICTNESS_LEVEL":
            handleSetStrictnessLevel(body)

        case "GET_SCHEDULE_FOR_DATE":
            handleGetScheduleForDate(body)

        case "GET_INSTALLED_APPS":
            handleGetInstalledApps()

        case "PREVIEW_SOUND":
            if let sound = body["sound"] as? String {
                NSSound(named: sound)?.play()
            }

        case "SAVE_STRICT_MODE":
            handleSaveStrictMode(body)

        case "SAVE_STRICT_MODE_LOCKS":
            // Per-item lock map for Strict Mode. Stored in settings JSON so the
            // enforcement code (FocusMonitor, ContentSafetyMonitor, etc.) can
            // consult which protections to actually freeze when strict is on.
            // Gated: with Strict Mode on, disabling a currently-enabled lock
            // needs an active partner-unlock window (R4 follow-up).
            if let locks = body["locks"] as? [String: Any] {
                handleSaveStrictModeLocks(locks)
            }

        case "SAVE_IF_THEN_PLAN":
            if let planIndex = body["planIndex"] as? Int {
                UserDefaults.standard.set(planIndex, forKey: "defaultIfThenPlan")
            }

        case "SAVE_PLAN_FIRST_PROMPT":
            // Toggle the plan-first prompt feature (FocusMonitor.maybeShowNoPlanPill
            // reads this on every evaluateApp tick).
            if let enabled = body["enabled"] as? Bool {
                UserDefaults.standard.set(enabled, forKey: "planFirstPromptEnabled")
                appDelegate?.postLog("📋 SAVE_PLAN_FIRST_PROMPT: enabled=\(enabled)")
            }

        // LEGACY (R6, 2026-06-11): the Always Allowed Settings page is gone —
        // ✅ rules on the Rules page own this concept now (migrated by
        // RulesMigration). No-op aliases for one release cycle; the SAVE
        // no-op also closes the old "save from a never-fetched page wipes
        // the store" footgun (research §3.2). Remove after 2026-07.
        case "GET_ALWAYS_ALLOWED", "SAVE_ALWAYS_ALLOWED":
            appDelegate?.postLog("⚠️ \(type): legacy always-allowed message ignored (Rules page owns ✅ now)")

        case "OPEN_STASH_INSPECTOR":
            if let sid = body["sessionId"] as? String {
                appDelegate?.showStashInspector(sessionId: sid)
            }

        case "SAVE_INTENTIONAL_MODE":
            handleSaveIntentionalMode(body)

        case "GET_BEDTIME_SETTINGS":
            handleGetBedtimeSettings()

        case "SAVE_BEDTIME_SETTINGS":
            if let body = message.body as? [String: Any] {
                handleSaveBedtimeSettings(body)
            }

        case "GET_BLOCKING_PROFILES", "GET_BLOCK_RULES":
            handleGetBlockingProfiles()

        case "CREATE_BLOCKING_PROFILE", "CREATE_BLOCK_RULE":
            if let body = message.body as? [String: Any] {
                handleCreateBlockingProfile(body)
            }

        case "UPDATE_BLOCKING_PROFILE", "UPDATE_BLOCK_RULE":
            if let body = message.body as? [String: Any] {
                handleUpdateBlockingProfile(body)
            }

        case "DELETE_BLOCKING_PROFILE", "DELETE_BLOCK_RULE":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleDeleteBlockingProfile(id: id)
            }

        case "TOGGLE_BLOCK_RULE":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr),
               let enabled = body["enabled"] as? Bool {
                handleToggleBlockRule(id: id, enabled: enabled)
            }

        case "SNOOZE_BLOCK_RULE":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                BlockRuleEnforcer.shared.snoozeForRemainderOfWindow(profileId: id)
                handleGetBlockingProfiles()
            }

        case "UNSNOOZE_BLOCK_RULE":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                BlockRuleEnforcer.shared.clearSnooze(profileId: id)
                handleGetBlockingProfiles()
            }

        // LEGACY (projects kill B3, 2026-06-11): Project/ProjectStore is
        // deleted — Intentions (Weekly Goals) own these concepts. Dashboard
        // senders switched to the *_INTENTION_* / GET_GOAL_SESSIONS
        // equivalents in the same commit. No-op aliases for one release
        // cycle (same convention as the R6 taxonomy aliases). Remove after
        // 2026-07.
        case "START_PROJECT_SESSION", "GET_PROJECTS", "GET_PROJECT_DETAIL",
             "CREATE_PROJECT", "UPDATE_PROJECT", "DELETE_PROJECT":
            appDelegate?.postLog("⚠️ \(type): legacy Projects message ignored (Intentions own goals now)")

        case "PROMOTE_LEARNED_SITE":
            // Kept live (B3): promotes against LearnedSitesStore (keyed by
            // intentionId) + appends the host to the goal's allow_websites.
            if let body = message.body as? [String: Any] {
                handlePromoteLearnedSite(body)
            }

        // LEGACY (R6, 2026-06-11): the Distractions / Always Blocked Settings
        // pages and the orphaned Distraction Budget page are gone — 🚫 rules
        // + the shared allowance own these concepts (rows migrated by
        // RulesMigration; backend tables retire with their endpoints in a
        // later slice). No-op aliases for one release cycle. Remove after
        // 2026-07.
        case "GET_DISTRACTIONS", "ADD_DISTRACTION", "REMOVE_DISTRACTION",
             "GET_ALWAYS_BLOCKED", "ADD_ALWAYS_BLOCKED", "REMOVE_ALWAYS_BLOCKED",
             "GET_BUDGET_STATE", "SET_BUDGET_CONFIG":
            appDelegate?.postLog("⚠️ \(type): legacy taxonomy/budget message ignored (Rules page owns blocking now)")

        // Spec 1 — Intentions (new handlers; project handlers above kept as deprecated aliases)
        case "GET_INTENTIONS":
            handleGetIntentions()

        case "GET_INTENTIONS_FOR_WEEK":
            // FIX-7: On-demand fetch for past weeks selected from Plan history dropdown.
            if let body = message.body as? [String: Any],
               let week = body["week"] as? String {
                handleGetIntentionsForWeek(week: week)
            }

        case "GET_INTENTION":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleGetIntention(id: id)
            }

        case "CREATE_INTENTION":
            if let body = message.body as? [String: Any] {
                handleCreateIntention(body)
            }

        case "UPDATE_INTENTION":
            if let body = message.body as? [String: Any] {
                handleUpdateIntention(body)
            }

        case "DELETE_INTENTION":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleDeleteIntention(id: id)
            }

        case "START_INTENTION_SESSION":
            if let body = message.body as? [String: Any] {
                handleStartIntentionSession(body)
            }

        // Spec 3 (May 2026) — Strictness presets + deep-link
        case "UPDATE_INTENTION_STRICTNESS":
            if let body = message.body as? [String: Any] {
                handleUpdateIntentionStrictness(body)
            }

        case "CANCEL_PENDING_STRICTNESS_CHANGE":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleCancelPendingStrictnessChange(id: id)
            }

        case "OPEN_INTENTION_STRICTNESS_UNLOCK_SHEET":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String, let id = UUID(uuidString: idStr),
               let toStr = body["to_preset"] as? String,
               let to = StrictnessPreset(rawValue: toStr),
               let name = body["intention_name"] as? String {
                appDelegate?.openIntentionStrictnessUnlockSheet(
                    intentionId: id, toPreset: to, intentionName: name
                )
            }

        case "OPEN_PARTNER_UNLOCK_SHEET":
            // Generic partner-unlock sheet (BedtimeUnlockRequestView in .bedtime mode).
            // Used by Strict Mode disable flow. Reuses the bedtime unlock plumbing
            // since the underlying contract (request code → partner emails → user
            // enters code → verify) is identical.
            appDelegate?.openBedtimeUnlockRequestSheet()

        case "OPEN_INTENTION_EDITOR":
            // Deep-link from the block editor's "Coding · Standard" caption tap →
            // navigate the dashboard to the Intentions tab and open this intention.
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String {
                callJS("window._navigateToIntentionEditor && window._navigateToIntentionEditor('\(idStr)')")
            }

        // May 2026 — Monthly Goals
        case "GET_MONTHLY_GOALS":
            handleGetMonthlyGoals()

        case "GET_MONTHLY_GOAL":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) {
                handleGetMonthlyGoal(id: id)
            }

        case "CREATE_MONTHLY_GOAL":
            if let body = message.body as? [String: Any] {
                handleCreateMonthlyGoal(body)
            }

        case "UPDATE_MONTHLY_GOAL":
            if let body = message.body as? [String: Any] {
                handleUpdateMonthlyGoal(body)
            }

        case "DELETE_MONTHLY_GOAL":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) {
                handleDeleteMonthlyGoal(id: id)
            }

        case "LINK_WEEKLY_TO_MONTHLY":
            if let body = message.body as? [String: Any] {
                handleLinkWeeklyToMonthly(body)
            }

        case "START_GOAL_SESSION":
            // Legacy alias for START_INTENTION_SESSION; monthly_goal_id ignored for now (analytics only).
            // New drag-to-schedule flow uses CREATE_SCHEDULED_SESSION instead.
            if let body = message.body as? [String: Any] {
                handleStartIntentionSession(body)
            }

        case "GET_GOAL_SESSIONS":
            // B2 (projects kill, June 2026): recent session history for the goal
            // detail panel. Backend is the permanent record (focus_sessions incl.
            // focus_score); session_history.json is the instant/offline cache.
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleGetGoalSessions(id: id)
            }

        // June 2026 — Rules Consolidation R2 (unified blocked/limited/allowed
        // rules + shared allowance). Handlers only; Rules page UI is R3.
        // "Leisure pool" renamed "allowance" 2026-06-11; the old
        // *_LEISURE_POOL* message names stay as deprecated aliases for one
        // release cycle (same convention as the legacy *_PROJECT_* handlers).
        case "GET_RULES":
            handleGetRules()

        case "CREATE_RULE":
            if let body = message.body as? [String: Any] {
                handleCreateRule(body)
            }

        case "UPDATE_RULE":
            if let body = message.body as? [String: Any] {
                handleUpdateRule(body)
            }

        case "DELETE_RULE":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) {
                handleDeleteRule(id: id)
            }

        case "GET_ALLOWANCE",
             "GET_LEISURE_POOL":  // deprecated alias (pre-rename), one release cycle
            handleGetAllowance()

        case "UPDATE_ALLOWANCE_CONFIG",
             "UPDATE_LEISURE_POOL_CONFIG":  // deprecated alias (pre-rename), one release cycle
            // R3: Rules-page allowance editor (base 0-240, rate 1-20, cap 0-240).
            // Loosening changes are partner-gated in the dashboard JS before
            // this message is ever sent; Swift just persists + re-emits.
            if let body = message.body as? [String: Any] {
                handleUpdateAllowanceConfig(body)
            }

        case "CREATE_SCHEDULED_SESSION":
            // FIX-2: Drag a weekly-goal card onto the calendar — creates a real
            // local FocusBlock so the session shows up on Today + pushes to backend.
            if let body = message.body as? [String: Any] {
                handleCreateScheduledSession(body)
            }

        case "GET_SCREEN_PERMISSION":
            emitScreenPermissionStatus()

        case "REQUEST_SCREEN_PERMISSION":
            handleRequestScreenPermission()

        case "FOCUS_MODE_TOGGLE":
            handleFocusModeToggle(body: body)

        case "INTERVENTION_TOGGLE_SET":
            handleInterventionToggleSet(body: body)

        default:
            appDelegate?.postLog("⚠️ WKWebView: Unknown message type: \(type)")
        }
    }

    // MARK: - Save Onboarding

    private func handleSaveOnboarding(_ body: [String: Any]) {
        guard let settings = body["settings"] as? [String: Any] else {
            callJS("window._onboardingSaveResult({ success: false, error: 'Invalid settings' })")
            return
        }

        // Extract per-platform settings
        let platforms = settings["platforms"] as? [String: Any] ?? [:]
        let ytSettings = platforms["youtube"] as? [String: Any] ?? [:]
        let igSettings = platforms["instagram"] as? [String: Any] ?? [:]
        let fbSettings = platforms["facebook"] as? [String: Any] ?? [:]

        let partnerEmail = settings["partnerEmail"] as? String
        let partnerName = settings["partnerName"] as? String
        var lockMode = settings["lockMode"] as? String ?? "none"
        if lockMode == "self" { lockMode = "none" } // "self" lock mode removed
        let theme = settings["theme"] as? String

        appDelegate?.postLog("📋 Saving onboarding: lock=\(lockMode)")

        // 1. Save to UserDefaults
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        UserDefaults.standard.set(lockMode, forKey: "lockMode")

        // 2. Save structured data to JSON file
        saveOnboardingSettings(
            platforms: platforms,
            partnerEmail: partnerEmail,
            partnerName: partnerName,
            lockMode: lockMode,
            theme: theme
        )

        // 3. Make API calls, sync consent status, and broadcast to extensions
        Task {
            if let email = partnerEmail, !email.isEmpty {
                await appDelegate?.backendClient?.setPartner(email: email, name: partnerName)
            }
            if lockMode != "none" {
                _ = await appDelegate?.backendClient?.setLockMode(mode: lockMode)
            }

            // 5. Fetch consent status from backend and save to settings file
            //    so the dashboard can pick it up immediately via GET_SETTINGS
            var consentStatus = "none"
            if let email = partnerEmail, !email.isEmpty {
                if let partnerStatus = await appDelegate?.backendClient?.getPartnerStatus() {
                    consentStatus = partnerStatus.consentStatus
                    await MainActor.run {
                        self.updateSettingsFile { settings in
                            settings["consentStatus"] = consentStatus
                        }
                    }
                }
            }

            // 6. Respond to JS with success
            await MainActor.run {
                self.callJS("window._onboardingSaveResult && window._onboardingSaveResult({ success: true })")
            }
        }
    }

    // MARK: - Dashboard Data

    private func handleGetDashboardData() {
        guard let tracker = appDelegate?.timeTracker else { return }

        let ytMinutes = tracker.getMinutesUsed(for: "youtube")
        let igMinutes = tracker.getMinutesUsed(for: "instagram")
        let fbMinutes = tracker.getMinutesUsed(for: "facebook")

        // Build per-platform data including active session info
        func platformData(platform: String, minutes: Int) -> [String: Any] {
            let session = tracker.getPlatformSession(for: platform)
            var data: [String: Any] = [
                "minutesUsed": minutes
            ]
            if session.active {
                var sessionData: [String: Any] = [
                    "active": true,
                    "freeBrowse": session.freeBrowse
                ]
                if let intent = session.intent { sessionData["intent"] = intent }
                if let startedAt = session.startedAt { sessionData["startedAt"] = startedAt }
                if let endsAt = session.endsAt { sessionData["endsAt"] = endsAt }
                data["session"] = sessionData
            }
            return data
        }

        // Earned browse state: engine deleted in R6 — the key ships empty for
        // one release cycle so an old cached dashboard's reader doesn't choke.
        let earnedBrowse: [String: Any] = [:]

        let result: [String: Any] = [
            "youtube": platformData(platform: "youtube", minutes: ytMinutes),
            "instagram": platformData(platform: "instagram", minutes: igMinutes),
            "facebook": platformData(platform: "facebook", minutes: fbMinutes),
            "earnedBrowse": earnedBrowse
        ]

        if let data = try? JSONSerialization.data(withJSONObject: result),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._dashboardDataResult && window._dashboardDataResult(\(json))")
        }
    }

    // MARK: - Settings Persistence

    private func saveOnboardingSettings(
        platforms: [String: Any],
        partnerEmail: String?,
        partnerName: String?,
        lockMode: String,
        theme: String? = nil
    ) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let settingsURL = dir.appendingPathComponent("onboarding_settings.json")

        var settings: [String: Any] = [
            "platforms": platforms,
            "partnerEmail": partnerEmail ?? "",
            "partnerName": partnerName ?? "",
            "lockMode": lockMode,
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let th = theme { settings["theme"] = th }

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted) {
            try? data.write(to: settingsURL)
            appDelegate?.postLog("💾 Onboarding settings saved to \(settingsURL.lastPathComponent)")
        }
    }

    // MARK: - Settings File

    private var settingsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("onboarding_settings.json")
    }

    private func updateSettingsFile(_ block: (inout [String: Any]) -> Void) {
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsFileURL.path),
           let data = try? Data(contentsOf: settingsFileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }
        block(&settings)
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: .prettyPrinted) {
            try? data.write(to: settingsFileURL)
        }
    }

    // MARK: - Get Settings

    private func handleGetSettings() {
        appDelegate?.postLog("📋 GET_SETTINGS: Reading settings...")

        var savedSettings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsFileURL.path) {
            do {
                let data = try Data(contentsOf: settingsFileURL)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    savedSettings = json
                    appDelegate?.postLog("📋 GET_SETTINGS: Loaded file with keys: \(json.keys.sorted().joined(separator: ", "))")
                }
            } catch {
                appDelegate?.postLog("⚠️ GET_SETTINGS: Failed to read settings file: \(error)")
            }
        }

        let platforms = savedSettings["platforms"] as? [String: Any] ?? [:]
        let ytPlatform = platforms["youtube"] as? [String: Any] ?? [:]
        let igPlatform = platforms["instagram"] as? [String: Any] ?? [:]
        let fbPlatform = platforms["facebook"] as? [String: Any] ?? [:]

        var lockMode = (savedSettings["lockMode"] as? String)
            ?? UserDefaults.standard.string(forKey: "lockMode")
            ?? "none"
        // Migration: "self" lock mode removed — treat as unlocked
        if lockMode == "self" {
            lockMode = "none"
            UserDefaults.standard.set("none", forKey: "lockMode")
            updateSettingsFile { settings in
                settings["lockMode"] = "none"
                settings["selfUnlockAvailableAt"] = nil
            }
            appDelegate?.postLog("🔄 Migrated lockMode from 'self' to 'none'")
        }
        let partnerEmail = (savedSettings["partnerEmail"] as? String) ?? ""
        let partnerName = (savedSettings["partnerName"] as? String) ?? ""
        let deviceId = UserDefaults.standard.string(forKey: "deviceId") ?? ""

        let ytCategories = (ytPlatform["categories"] as? [String]) ?? [String]()

        let ytResult: [String: Any] = [
            "enabled": (ytPlatform["enabled"] as? Bool) ?? true,
            "threshold": (ytPlatform["threshold"] as? Int) ?? 35,
            "blockShorts": (ytPlatform["blockShorts"] as? Bool) ?? true,
            "hideSponsored": (ytPlatform["hideSponsored"] as? Bool) ?? true,
            "blockMode": (ytPlatform["blockMode"] as? String) ?? "hide",
            "zenDuration": (ytPlatform["zenDuration"] as? Int) ?? 10,
            "categories": ytCategories
        ]

        let igResult: [String: Any] = [
            "enabled": (igPlatform["enabled"] as? Bool) ?? true,
            "threshold": (igPlatform["threshold"] as? Int) ?? 35,
            "blockReels": (igPlatform["blockReels"] as? Bool) ?? true,
            "blockExplore": (igPlatform["blockExplore"] as? Bool) ?? true,
            "nsfwFilter": (igPlatform["nsfwFilter"] as? Bool) ?? true,
            "hideAds": (igPlatform["hideAds"] as? Bool) ?? true,
            "blockedCategories": (igPlatform["blockedCategories"] as? [String]) ?? [String](),
            "blockedAccounts": (igPlatform["blockedAccounts"] as? [String]) ?? [String]()
        ]

        let fbResult: [String: Any] = [
            "enabled": (fbPlatform["enabled"] as? Bool) ?? true,
            "blockWatch": (fbPlatform["blockWatch"] as? Bool) ?? true,
            "blockReels": (fbPlatform["blockReels"] as? Bool) ?? true,
            "blockMarketplace": (fbPlatform["blockMarketplace"] as? Bool) ?? false,
            "blockGaming": (fbPlatform["blockGaming"] as? Bool) ?? true,
            "blockStories": (fbPlatform["blockStories"] as? Bool) ?? false,
            "blockSponsored": (fbPlatform["blockSponsored"] as? Bool) ?? true,
            "blockSuggested": (fbPlatform["blockSuggested"] as? Bool) ?? true,
            "scrollLimit": (fbPlatform["scrollLimit"] as? Int) ?? 50,
            "friendsOnly": (fbPlatform["friendsOnly"] as? Bool) ?? false
        ]

        // Legacy: top-level blockedCategories (kept for backward compat, now also in youtube.categories)
        let blockedCategories = ytCategories
        let maxPerPeriod: [String: Any] = (ytPlatform["maxPerPeriod"] as? [String: Any]) ?? [
            "enabled": false,
            "minutes": 20,
            "periodHours": 1
        ]

        let consentStatus = (savedSettings["consentStatus"] as? String) ?? "none"
        let temporaryUnlockUntil = savedSettings["temporaryUnlockUntil"] as? String
        let unlockRequested = savedSettings["unlockRequested"] as? Bool ?? false
        let autoRelockEnabled = savedSettings["autoRelockEnabled"] as? Bool ?? true

        var result: [String: Any] = [
            "youtube": ytResult,
            "instagram": igResult,
            "facebook": fbResult,
            "blockedCategories": blockedCategories,
            "lockMode": lockMode,
            "partnerEmail": partnerEmail,
            "partnerName": partnerName,
            "consentStatus": consentStatus,
            "maxPerPeriod": maxPerPeriod,
            "deviceId": deviceId,
            "unlockRequested": unlockRequested,
            "autoRelockEnabled": autoRelockEnabled
        ]
        result["distractingSites"] = (savedSettings["distractingSites"] as? [String]) ?? [String]()
        result["disabledPlatforms"] = (savedSettings["disabledPlatforms"] as? [String]) ?? [String]()
        result["distractingApps"] = (savedSettings["distractingApps"] as? [[String: Any]]) ?? [[String: Any]]()
        result["alwaysRelevantSites"] = (savedSettings["alwaysRelevantSites"] as? [String]) ?? [String]()
        result["soundTone"] = (savedSettings["soundTone"] as? String) ?? "Glass"
        result["theme"] = (savedSettings["theme"] as? String) ?? "iridescent"
        result["strictModeEnabled"] = UserDefaults.standard.bool(forKey: "strictModeEnabled")
        result["planFirstPromptEnabled"] = UserDefaults.standard.bool(forKey: "planFirstPromptEnabled")
        // Calm-Down D2: global strictness dial. ScheduleManager reconciles this
        // on launch; "gentle" is the fresh-install default.
        result["strictnessLevel"] = UserDefaults.standard.string(forKey: "strictnessLevel") ?? "gentle"
        if let store = appDelegate?.alwaysAllowedStore {
            result["alwaysAllowed"] = [
                "bundleIds": Array(store.list.bundleIds).sorted(),
                "domains":   Array(store.list.domains).sorted()
            ]
        }
        // Per-item lock map. Defaults: every protection locked (true) when strict
        // mode is on. JS hydrates checkbox state from this. strict_mode_self is
        // always true (enforced JS-side; user can't uncheck the master lock).
        if let locks = savedSettings["strictModeLocks"] as? [String: Any] {
            result["strictModeLocks"] = locks
        }

        // Intentional Mode settings — read directly from UserDefaults (controller deleted in Task 9)
        let defaults = UserDefaults.standard
        result["intentionalModeEnabled"] = defaults.bool(forKey: "intentionalModeEnabled")
        result["intentionalModeSchedule"] = defaults.string(forKey: "intentionalModeSchedule") ?? "always"
        let rawGrace = defaults.integer(forKey: "intentionalModeGracePeriod")
        result["intentionalModeGracePeriod"] = rawGrace == 0 ? 3 : rawGrace
        if let csData = defaults.data(forKey: "intentionalModeCustomSchedule"),
           let csJson = try? JSONSerialization.jsonObject(with: csData) as? [String: Any] {
            result["intentionalModeCustomSchedule"] = csJson
        }

        result["userEmail"] = appDelegate?.backendClient?.storedEmail ?? ""
        result["overridePartnerRequired"] = (savedSettings["overridePartnerRequired"] as? Bool) ?? false
        // Content Safety settings
        let csSettings = savedSettings["contentSafety"] as? [String: Any]
        result["contentSafety"] = [
            "enabled": (csSettings?["enabled"] as? Bool) ?? false
        ]
        if let tuu = temporaryUnlockUntil { result["temporaryUnlockUntil"] = tuu }

        do {
            let data = try JSONSerialization.data(withJSONObject: result)
            if let json = String(data: data, encoding: .utf8) {
                appDelegate?.postLog("📋 GET_SETTINGS: Sending \(json.prefix(200))...")
                callJS("window._settingsResult && window._settingsResult(\(json))")
            } else {
                appDelegate?.postLog("⚠️ GET_SETTINGS: JSON string conversion returned nil")
            }
        } catch {
            appDelegate?.postLog("⚠️ GET_SETTINGS: JSON serialization failed: \(error)")
        }

        // Also push content safety monitor status so the toggle reflects actual state
        appDelegate?.contentSafetyMonitor?.pushPermissionStatus()
    }

    // MARK: - Save Settings

    private func handleSaveSettings(_ body: [String: Any]) {
        guard let settings = body["settings"] as? [String: Any] else { return }
        let ytSettings = settings["youtube"] as? [String: Any] ?? [:]
        let igSettings = settings["instagram"] as? [String: Any] ?? [:]
        let fbSettings = settings["facebook"] as? [String: Any] ?? [:]

        // Lock enforcement: reject weakening changes when locked
        let currentLockMode = UserDefaults.standard.string(forKey: "lockMode") ?? "none"
        if currentLockMode != "none" {
            var isUnlocked = false
            if let data = try? Data(contentsOf: settingsFileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let unlockUntil = json["temporaryUnlockUntil"] as? String {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: unlockUntil), date > Date() {
                    isUnlocked = true
                }
            }

            if !isUnlocked {
                if let data = try? Data(contentsOf: settingsFileURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let platforms = json["platforms"] as? [String: Any] ?? [:]
                    let curYT = platforms["youtube"] as? [String: Any] ?? [:]
                    let curIG = platforms["instagram"] as? [String: Any] ?? [:]
                    let curFB = platforms["facebook"] as? [String: Any] ?? [:]

                    var violation: String? = nil

                    // YouTube: can't disable, lower threshold, or disable shorts blocking
                    if (ytSettings["enabled"] as? Bool) == false && (curYT["enabled"] as? Bool) != false {
                        violation = "Cannot disable YouTube while settings are locked"
                    }
                    if violation == nil, let newT = ytSettings["threshold"] as? Int, let curT = curYT["threshold"] as? Int, newT < curT {
                        violation = "Cannot lower YouTube threshold while settings are locked"
                    }
                    if violation == nil, (ytSettings["blockShorts"] as? Bool) == false && (curYT["blockShorts"] as? Bool) != false {
                        violation = "Cannot disable Shorts blocking while settings are locked"
                    }

                    // Instagram: can't disable, lower threshold, or disable reels blocking
                    if violation == nil, (igSettings["enabled"] as? Bool) == false && (curIG["enabled"] as? Bool) != false {
                        violation = "Cannot disable Instagram while settings are locked"
                    }
                    if violation == nil, let newT = igSettings["threshold"] as? Int, let curT = curIG["threshold"] as? Int, newT < curT {
                        violation = "Cannot lower Instagram threshold while settings are locked"
                    }
                    if violation == nil, (igSettings["blockReels"] as? Bool) == false && (curIG["blockReels"] as? Bool) != false {
                        violation = "Cannot disable Reels blocking while settings are locked"
                    }

                    // Facebook: can't disable, or disable any blocking features
                    if violation == nil, (fbSettings["enabled"] as? Bool) == false && (curFB["enabled"] as? Bool) != false {
                        violation = "Cannot disable Facebook while settings are locked"
                    }
                    if violation == nil, (fbSettings["blockWatch"] as? Bool) == false && (curFB["blockWatch"] as? Bool) != false {
                        violation = "Cannot disable Watch blocking while settings are locked"
                    }
                    if violation == nil, (fbSettings["blockReels"] as? Bool) == false && (curFB["blockReels"] as? Bool) != false {
                        violation = "Cannot disable Facebook Reels blocking while settings are locked"
                    }
                    if violation == nil, (fbSettings["blockGaming"] as? Bool) == false && (curFB["blockGaming"] as? Bool) != false {
                        violation = "Cannot disable Gaming blocking while settings are locked"
                    }
                    if violation == nil, (fbSettings["blockSponsored"] as? Bool) == false && (curFB["blockSponsored"] as? Bool) != false {
                        violation = "Cannot disable Sponsored blocking while settings are locked"
                    }
                    if violation == nil, (fbSettings["blockSuggested"] as? Bool) == false && (curFB["blockSuggested"] as? Bool) != false {
                        violation = "Cannot disable Suggested content blocking while settings are locked"
                    }

                    // Content Safety: can't disable while locked
                    if violation == nil, let csNew = settings["contentSafety"] as? [String: Any] {
                        let curCS = json["contentSafety"] as? [String: Any] ?? [:]
                        if (csNew["enabled"] as? Bool) == false && (curCS["enabled"] as? Bool) == true {
                            violation = "Cannot disable Content Safety while settings are locked"
                        }
                    }

                    // Distracting sites: can't remove sites while locked (adding is OK)
                    if violation == nil, let newSites = settings["distractingSites"] as? [String] {
                        let currentSites = (json["distractingSites"] as? [String]) ?? []
                        let removedSites = currentSites.filter { !newSites.contains($0) }
                        if !removedSites.isEmpty {
                            violation = "Cannot remove distracting sites while settings are locked"
                        }
                    }

                    // Disabled platforms: can't disable platforms while locked (re-enabling is OK)
                    if violation == nil, let newDisabled = settings["disabledPlatforms"] as? [String] {
                        let currentDisabled = (json["disabledPlatforms"] as? [String]) ?? []
                        let newlyDisabled = newDisabled.filter { !currentDisabled.contains($0) }
                        if !newlyDisabled.isEmpty {
                            violation = "Cannot remove platforms from distracting sites while settings are locked"
                        }
                    }

                    // Distracting apps: can't remove apps while locked (adding is OK)
                    if violation == nil, let newApps = settings["distractingApps"] as? [[String: Any]] {
                        let currentApps = (json["distractingApps"] as? [[String: Any]]) ?? []
                        let currentBundleIds = Set(currentApps.compactMap { $0["bundleId"] as? String })
                        let newBundleIds = Set(newApps.compactMap { $0["bundleId"] as? String })
                        let removedApps = currentBundleIds.subtracting(newBundleIds)
                        if !removedApps.isEmpty {
                            violation = "Cannot remove distracting apps while settings are locked"
                        }
                    }

                    if let v = violation {
                        let escaped = v.replacingOccurrences(of: "'", with: "\\'")
                        callJS("window._saveSettingsResult && window._saveSettingsResult({ success: false, message: '\(escaped)' })")
                        appDelegate?.postLog("🔒 SAVE_SETTINGS: Rejected — \(v)")
                        return
                    }
                }
            }
        }

        let lockMode = settings["lockMode"] as? String ?? UserDefaults.standard.string(forKey: "lockMode") ?? "none"
        let partnerEmail = settings["partnerEmail"] as? String
        let partnerName = settings["partnerName"] as? String
        let distractingSites = settings["distractingSites"] as? [String]
        let disabledPlatforms = settings["disabledPlatforms"] as? [String]
        let distractingApps = settings["distractingApps"] as? [[String: Any]]
        let alwaysRelevantSites = settings["alwaysRelevantSites"] as? [String]
        let soundTone = settings["soundTone"] as? String
        let theme = settings["theme"] as? String
        let overridePartnerRequired = settings["overridePartnerRequired"] as? Bool
        let contentSafety = settings["contentSafety"] as? [String: Any]
        let platforms: [String: Any] = ["youtube": ytSettings, "instagram": igSettings, "facebook": fbSettings]

        saveSettingsToFile(
            platforms: platforms,
            blockedCategories: settings["blockedCategories"] as? [String],
            partnerEmail: partnerEmail,
            partnerName: partnerName,
            lockMode: lockMode,
            maxPerPeriod: settings["maxPerPeriod"] as? [String: Any],
            distractingSites: distractingSites,
            disabledPlatforms: disabledPlatforms,
            distractingApps: distractingApps,
            alwaysRelevantSites: alwaysRelevantSites,
            soundTone: soundTone,
            theme: theme,
            overridePartnerRequired: overridePartnerRequired,
            contentSafety: contentSafety
        )

        // Update FocusMonitor with override partner approval setting
        if let opr = overridePartnerRequired {
            appDelegate?.focusMonitor?.overridePartnerApprovalRequired = opr
        }

        // Update FocusMonitor with partner state
        let hasPartner = !(partnerEmail ?? "").isEmpty
        appDelegate?.focusMonitor?.hasConfiguredPartner = hasPartner

        // Persist sound tone to UserDefaults for DeepWorkTimerController
        if let tone = soundTone {
            UserDefaults.standard.set(tone, forKey: "soundTone")
        }

        // Update window background for theme change
        if let th = theme {
            self.window?.backgroundColor = MainWindow.windowBackground(for: th)
        }

        // Legacy: distractingSites/distractingApps are saved to onboarding_settings.json
        // for backward compat, but NO LONGER feed WebsiteBlocker or FocusMonitor directly.
        // Blocking is now profile-driven via BlockingProfileManager.
        // WebsiteBlocker is fed by applyAlwaysActiveProfiles() and applyFocusSession() only.

        // Update Content Safety Monitor
        if let cs = contentSafety {
            let csEnabled = cs["enabled"] as? Bool ?? false
            appDelegate?.contentSafetyMonitor?.onSettingsChanged(enabled: csEnabled)
            // FIX-15: keep the sidebar status footer in sync immediately.
            callJS("window._contentSafetyState && window._contentSafetyState({ enabled: \(csEnabled ? "true" : "false") })")
        }

        // Update FocusMonitor with always-relevant sites whitelist
        if let sites = alwaysRelevantSites {
            appDelegate?.focusMonitor?.alwaysRelevantHostnames = Set(sites.map { $0.lowercased() })
            appDelegate?.postLog("👁️ Updated always-relevant sites: \(sites)")
        }

        callJS("window._saveSettingsResult && window._saveSettingsResult({ success: true })")
        appDelegate?.postLog("💾 SAVE_SETTINGS: Settings saved")

        // Sync settings to backend (fire-and-forget, don't block UI)
        let syncPayload: [String: Any] = {
            var payload: [String: Any] = [:]
            payload["platforms"] = platforms
            if let ds = distractingSites { payload["distractingSites"] = ds }
            if let dp = disabledPlatforms { payload["disabledPlatforms"] = dp }
            if let da = distractingApps { payload["distractingApps"] = da }
            if let ars = alwaysRelevantSites { payload["alwaysRelevantSites"] = ars }
            if let cats = settings["blockedCategories"] as? [String] { payload["blockedCategories"] = cats }
            if let mpp = settings["maxPerPeriod"] as? [String: Any] { payload["maxPerPeriod"] = mpp }
            return payload
        }()
        Task {
            await appDelegate?.backendClient?.syncSettings(settings: syncPayload)
        }
    }

    // MARK: - End Session

    private func handleEndSession(_ body: [String: Any]) {
        guard let platform = body["platform"] as? String else { return }
        appDelegate?.timeTracker?.clearPlatformSession(for: platform)
        appDelegate?.postLog("⏹️ END_SESSION: \(platform)")
    }

    // MARK: - Save Settings to File

    private func saveSettingsToFile(
        platforms: [String: Any],
        blockedCategories: [String]?,
        partnerEmail: String?,
        partnerName: String?,
        lockMode: String,
        maxPerPeriod: [String: Any]?,
        distractingSites: [String]? = nil,
        disabledPlatforms: [String]? = nil,
        distractingApps: [[String: Any]]? = nil,
        alwaysRelevantSites: [String]? = nil,
        soundTone: String? = nil,
        theme: String? = nil,
        overridePartnerRequired: Bool? = nil,
        contentSafety: [String: Any]? = nil
    ) {
        updateSettingsFile { settings in
            var existingPlatforms = settings["platforms"] as? [String: Any] ?? [:]
            // Merge each platform rather than replace wholesale
            for (key, value) in platforms {
                if let newPlatform = value as? [String: Any] {
                    var existing = existingPlatforms[key] as? [String: Any] ?? [:]
                    existing.merge(newPlatform) { _, new in new }
                    existingPlatforms[key] = existing
                }
            }
            settings["platforms"] = existingPlatforms
            settings["lockMode"] = lockMode
            if let email = partnerEmail { settings["partnerEmail"] = email }
            if let name = partnerName { settings["partnerName"] = name }
            if let cats = blockedCategories { settings["blockedCategories"] = cats }
            if let mpp = maxPerPeriod { settings["maxPerPeriod"] = mpp }
            if let ds = distractingSites { settings["distractingSites"] = ds }
            if let dp = disabledPlatforms { settings["disabledPlatforms"] = dp }
            if let da = distractingApps { settings["distractingApps"] = da }
            if let ars = alwaysRelevantSites { settings["alwaysRelevantSites"] = ars }
            if let st = soundTone { settings["soundTone"] = st }
            if let th = theme { settings["theme"] = th }
            if let opr = overridePartnerRequired { settings["overridePartnerRequired"] = opr }
            if let cs = contentSafety { settings["contentSafety"] = cs }
            settings["lastModified"] = ISO8601DateFormatter().string(from: Date())
        }
    }

    // MARK: - Get Installed Apps

    private var installedAppsCache: [[String: Any]]?

    private func handleGetInstalledApps() {
        // Return cached result if available
        if let cached = installedAppsCache {
            sendInstalledAppsResult(cached)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var apps: [[String: Any]] = []
            let searchPaths = ["/Applications", NSHomeDirectory() + "/Applications"]

            // Bundle IDs to exclude (system utilities, Intentional itself, always-allowed productivity apps)
            let excludedPrefixes = ["com.apple."]
            let excludedBundleIds: Set<String> = [
                "com.arayan.intentional",
                Bundle.main.bundleIdentifier ?? ""
            ]

            for searchPath in searchPaths {
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: searchPath) else { continue }
                for item in contents {
                    guard item.hasSuffix(".app") else { continue }
                    let appPath = (searchPath as NSString).appendingPathComponent(item)
                    guard let bundle = Bundle(path: appPath),
                          let bundleId = bundle.bundleIdentifier else { continue }

                    // Skip excluded apps
                    if excludedBundleIds.contains(bundleId) { continue }
                    if excludedPrefixes.contains(where: { bundleId.hasPrefix($0) }) { continue }

                    let name = FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")

                    var appEntry: [String: Any] = [
                        "name": name,
                        "bundleId": bundleId
                    ]

                    // Get app icon as base64 PNG (32x32 thumbnail)
                    if let icon = NSWorkspace.shared.icon(forFile: appPath) as NSImage? {
                        let targetSize = NSSize(width: 32, height: 32)
                        let resized = NSImage(size: targetSize)
                        resized.lockFocus()
                        icon.draw(in: NSRect(origin: .zero, size: targetSize),
                                  from: NSRect(origin: .zero, size: icon.size),
                                  operation: .copy, fraction: 1.0)
                        resized.unlockFocus()

                        if let tiffData = resized.tiffRepresentation,
                           let bitmap = NSBitmapImageRep(data: tiffData),
                           let pngData = bitmap.representation(using: .png, properties: [:]) {
                            appEntry["icon"] = pngData.base64EncodedString()
                        }
                    }

                    apps.append(appEntry)
                }
            }

            // Sort alphabetically by name
            apps.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

            DispatchQueue.main.async {
                self?.installedAppsCache = apps
                self?.sendInstalledAppsResult(apps)
            }
        }
    }

    private func sendInstalledAppsResult(_ apps: [[String: Any]]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: apps)
            if let json = String(data: data, encoding: .utf8) {
                callJS("window._installedAppsResult && window._installedAppsResult(\(json))")
            }
        } catch {
            appDelegate?.postLog("⚠️ GET_INSTALLED_APPS: JSON serialization failed: \(error)")
        }
    }

    // MARK: - Sync State from Backend

    func syncStateFromBackend(_ status: BackendClient.StatusResult) {
        let effectiveLockMode = status.lockMode == "self" ? "none" : status.lockMode // "self" lock mode removed
        appDelegate?.postLog("🔄 Syncing state from backend: lockMode=\(effectiveLockMode), isLocked=\(status.isLocked), isTemporarilyUnlocked=\(status.isTemporarilyUnlocked)")

        // Update UserDefaults with authoritative backend state
        UserDefaults.standard.set(effectiveLockMode, forKey: "lockMode")

        // Update settings file with all backend state
        updateSettingsFile { settings in
            settings["lockMode"] = effectiveLockMode
            if let email = status.partnerEmail { settings["partnerEmail"] = email }
            if let consent = status.consentStatus { settings["consentStatus"] = consent }

            // Persist unlock state so it survives app restart
            if let tuu = status.temporaryUnlockUntil {
                settings["temporaryUnlockUntil"] = tuu
            } else if !status.isTemporarilyUnlocked {
                settings["temporaryUnlockUntil"] = nil
            }
            settings["autoRelockEnabled"] = status.autoRelock

            if status.hasPendingRequest {
                settings["unlockRequested"] = true
            } else {
                settings["unlockRequested"] = false
            }
        }

        // Push updated state to the dashboard JS
        let consent = status.consentStatus ?? "none"
        var jsFields = "lockMode: '\(effectiveLockMode)', consentStatus: '\(consent)'"
        // Only include partnerEmail if backend returned a non-empty value (avoid overwriting local data)
        if let pe = status.partnerEmail, !pe.isEmpty {
            let escaped = pe.replacingOccurrences(of: "'", with: "\\'")
            jsFields += ", partnerEmail: '\(escaped)'"
        }
        if let tuu = status.temporaryUnlockUntil {
            let escapedTuu = tuu.replacingOccurrences(of: "'", with: "\\'")
            jsFields += ", temporaryUnlockUntil: '\(escapedTuu)'"
        }
        if status.hasPendingRequest {
            jsFields += ", unlockRequested: true"
        } else {
            jsFields += ", unlockRequested: false"
        }
        jsFields += ", autoRelockEnabled: \(status.autoRelock ? "true" : "false")"
        callJS("if (window._lockStateResult) { window._lockStateResult({ \(jsFields) }); }")
    }

    // MARK: - Save Lock Settings (Pessimistic)

    private func handleSaveLockSettings(_ body: [String: Any]) {
        var lockMode = body["lockMode"] as? String ?? "none"
        if lockMode == "self" { lockMode = "none" } // "self" lock mode removed
        let partnerEmail = body["partnerEmail"] as? String ?? ""
        let partnerName = body["partnerName"] as? String ?? ""

        appDelegate?.postLog("🔒 SAVE_LOCK_SETTINGS: mode=\(lockMode), partner=\(partnerEmail)")

        Task {
            // 1. Set partner if provided
            if !partnerEmail.isEmpty {
                await appDelegate?.backendClient?.setPartner(
                    email: partnerEmail,
                    name: partnerName.isEmpty ? nil : partnerName
                )
            }

            // 2. Attempt to set lock mode
            var actualLockMode = lockMode
            var resultSuccess = true
            var resultMessage = "Lock settings saved"

            if lockMode != "none" {
                await appDelegate?.backendClient?.setLockMode(mode: lockMode)
                // Check if backend actually locked (consent may be pending)
                if let status = await appDelegate?.backendClient?.getPartnerStatus() {
                    if status.consentStatus == "pending" {
                        actualLockMode = "none"
                        resultSuccess = false
                        resultMessage = "Partner invitation sent. Lock will activate once accepted."
                    }
                }
            } else {
                await appDelegate?.backendClient?.setLockMode(mode: "none")
            }

            // 3. Get consent status from backend
            var consentStatus = "none"
            if let status = await appDelegate?.backendClient?.getPartnerStatus() {
                consentStatus = status.consentStatus
            }

            // 4. Commit the ACTUAL lock mode and consent status
            await MainActor.run {
                UserDefaults.standard.set(actualLockMode, forKey: "lockMode")
                self.updateSettingsFile { settings in
                    settings["lockMode"] = actualLockMode
                    settings["partnerEmail"] = partnerEmail
                    settings["partnerName"] = partnerName
                    settings["consentStatus"] = consentStatus
                }

                // 5. Report result + consent status to dashboard
                let escapedMessage = resultMessage.replacingOccurrences(of: "'", with: "\\'")
                let escapedEmail = partnerEmail.replacingOccurrences(of: "'", with: "\\'")
                let escapedName = partnerName.replacingOccurrences(of: "'", with: "\\'")
                self.callJS("window._lockSettingsResult && window._lockSettingsResult({ success: \(resultSuccess), lockMode: '\(actualLockMode)', message: '\(escapedMessage)', consentStatus: '\(consentStatus)', partnerEmail: '\(escapedEmail)', partnerName: '\(escapedName)' })")

                self.appDelegate?.postLog("🔒 SAVE_LOCK_SETTINGS: requested=\(lockMode), actual=\(actualLockMode), consent=\(consentStatus)")
            }
        }
    }

    // MARK: - Remove Partner

    private func handleRemovePartner() {
        appDelegate?.postLog("🔒 REMOVE_PARTNER: removing partner from backend")

        Task {
            // 1. Call DELETE /partner on backend
            let removed = await appDelegate?.backendClient?.removePartner() ?? false

            // 2. Reset lock mode to none on backend
            if removed {
                await appDelegate?.backendClient?.setLockMode(mode: "none")
            }

            await MainActor.run {
                // 3. Clear all partner/lock state from settings file + disable strict mode
                self.updateSettingsFile { settings in
                    settings["lockMode"] = "none"
                    settings["partnerEmail"] = ""
                    settings["partnerName"] = ""
                    settings["consentStatus"] = "none"
                    settings["temporaryUnlockUntil"] = nil
                    settings["unlockRequested"] = false
                    settings["settingsUnlocked"] = false
                    settings["strictModeEnabled"] = false
                }
                UserDefaults.standard.set("none", forKey: "lockMode")
                UserDefaults.standard.set(false, forKey: "strictModeEnabled")
                self.appDelegate?.updateStrictMode()

                // 4. Report result to dashboard
                let success = removed ? "true" : "false"
                self.callJS("window._removePartnerResult && window._removePartnerResult({ success: \(success) })")

                self.appDelegate?.postLog("🔒 REMOVE_PARTNER: done, removed=\(removed)")
            }
        }
    }

    // MARK: - R4(d): Strict Mode "Site & app blocks" lock (block_rules)
    //
    // The lock must gate the REAL stores server-side-of-the-bridge — research
    // (blocks-consolidation-research-2026-06-10.md §7.2/§8.5) showed the
    // advertised `block_rules` lock key was stored but never consulted by any
    // handler, so the Strict Mode promise "can't delete or disable a block"
    // was UI-only. Asymmetric per spec #5: tightening always passes;
    // loosening (delete/disable a blocking rule, demote 🚫 → ⏳/✅) requires
    // an active partner unlock window. "Snooze for today" stays allowed by
    // design (the lock row's own copy).

    /// True when loosening mutations of block rules must be refused:
    /// Strict Mode is ON (daemon-authoritative, UserDefaults fallback), the
    /// `block_rules` lock item is enabled (default ON when absent), and there
    /// is no active partner-unlock window (`temporaryUnlockUntil` in the
    /// settings file — same window SAVE_STRICT_MODE's disable path uses).
    func blockRulesLockEngaged() -> Bool {
        guard appDelegate?.daemonClient.isStrictModeEnabledSync() == true else { return false }
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsFileURL),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = j
        }
        if let locks = json["strictModeLocks"] as? [String: Any],
           let v = locks["block_rules"] as? Bool, v == false {
            return false   // user opted this item out of the lock set
        }
        if let unlockUntil = json["temporaryUnlockUntil"] as? String,
           let date = ISO8601DateFormatter().date(from: unlockUntil), date > Date() {
            return false   // active partner-unlock window — loosening allowed
        }
        return true
    }

    private func refuseLockedRuleMutation(_ what: String) {
        appDelegate?.postLog("🔒 \(what) refused — Strict Mode locks Site & app blocks (no active unlock window)")
        callJS("typeof showToast === 'function' && showToast('Strict Mode — loosening a block needs a partner code', 'error')")
    }

    /// Loosening test for the unified-rule store (mirrors dashboard.html's
    /// isLooseningAction): disabling a 🚫 rule, or demoting treatment
    /// (blocked → limited/allowed, limited → allowed).
    static func isLooseningRuleUpdate(current: Rule, payload: RuleUpdatePayload) -> Bool {
        if current.treatment == .blocked, payload.enabled == false { return true }
        if let to = payload.treatment {
            let rank: [RuleTreatment: Int] = [.blocked: 2, .limited: 1, .allowed: 0]
            if (rank[to] ?? 0) < (rank[current.treatment] ?? 0) { return true }
        }
        return false
    }

    // MARK: - Strict Mode Lock Map

    /// Default per-item lock map — must mirror `_defaultStrictLocks()` in
    /// dashboard.html. Used when no map was ever saved (a key absent from
    /// the stored map falls back to this; unknown keys default to enabled,
    /// matching the dashboard's `locks[key] !== false` render and
    /// `blockRulesLockEngaged`'s absent-means-engaged semantics).
    static let defaultStrictLocks: [String: Bool] = [
        "sensitive_content": true,
        "block_rules": true,
        "weekly_goals": false,
        "today_schedule": true,
        "strict_mode_self": true,
        "ai_scoring": true,
    ]

    /// R4 follow-up (2026-06-11): SAVE_STRICT_MODE_LOCKS was a one-step bypass
    /// of every R4 loosening gate — uncheck `block_rules` with no partner code,
    /// then delete/disable rules freely. The lock map itself is now
    /// lock-protected: with Strict Mode ON (daemon-authoritative), disabling
    /// any currently-enabled lock item (true→false) requires an active
    /// partner-unlock window (`temporaryUnlockUntil`). Enabling locks
    /// (false→true) always passes. With Strict Mode OFF everything passes —
    /// locks are config-in-waiting.
    private func handleSaveStrictModeLocks(_ locks: [String: Any]) {
        if appDelegate?.daemonClient.isStrictModeEnabledSync() == true {
            var json: [String: Any] = [:]
            if let data = try? Data(contentsOf: settingsFileURL),
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = j
            }
            let stored = json["strictModeLocks"] as? [String: Any]
            var unlocked = false
            if let unlockUntil = json["temporaryUnlockUntil"] as? String,
               let date = ISO8601DateFormatter().date(from: unlockUntil), date > Date() {
                unlocked = true   // active partner-unlock window — loosening allowed
            }
            if !unlocked {
                let disabling = locks.keys.sorted().filter { key in
                    guard (locks[key] as? Bool) == false else { return false }
                    let currentlyEnabled = (stored?[key] as? Bool)
                        ?? MainWindow.defaultStrictLocks[key] ?? true
                    return currentlyEnabled
                }
                if !disabling.isEmpty {
                    appDelegate?.postLog("🔒 SAVE_STRICT_MODE_LOCKS refused — disabling [\(disabling.joined(separator: ", "))] needs a partner unlock window (Strict Mode on)")
                    // Echo the authoritative map so the dashboard can revert
                    // its optimistic checkbox mutation.
                    let authoritative: [String: Any] = stored ?? MainWindow.defaultStrictLocks
                    let payload: [String: Any] = [
                        "success": false,
                        "reason": "strict_mode_locked",
                        "locks": authoritative,
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let js = String(data: data, encoding: .utf8) {
                        callJS("window._strictModeLocksResult && window._strictModeLocksResult(\(js))")
                    }
                    return
                }
            }
        }
        updateSettingsFile { settings in
            settings["strictModeLocks"] = locks
        }
        appDelegate?.postLog("🔒 SAVE_STRICT_MODE_LOCKS: \(locks)")
        callJS("window._strictModeLocksResult && window._strictModeLocksResult({ success: true })")
    }

    // MARK: - Strict Mode Toggle

    private func handleSaveStrictMode(_ body: [String: Any]) {
        let enabled = body["enabled"] as? Bool ?? false
        appDelegate?.postLog("🔒 SAVE_STRICT_MODE: enabled=\(enabled)")

        // Read current settings state
        var consentStatus = "none"
        var isUnlocked = false
        if let data = try? Data(contentsOf: settingsFileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            consentStatus = json["consentStatus"] as? String ?? "none"
            if let unlockUntil = json["temporaryUnlockUntil"] as? String {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: unlockUntil), date > Date() {
                    isUnlocked = true
                }
            }
        }

        if enabled {
            // Enabling: require confirmed accountability partner
            if consentStatus != "confirmed" {
                callJS("window._strictModeResult && window._strictModeResult({ success: false, message: 'You need a confirmed accountability partner to enable this.' })")
                appDelegate?.postLog("🔒 SAVE_STRICT_MODE: Rejected — no confirmed partner")
                return
            }
        } else {
            // Disabling: ALWAYS requires an active unlock window (code from partner)
            if !isUnlocked {
                callJS("window._strictModeResult && window._strictModeResult({ success: false, message: 'Request a code from your partner to disable this.' })")
                appDelegate?.postLog("🔒 SAVE_STRICT_MODE: Rejected — no unlock window")
                return
            }
        }

        // Save to UserDefaults (fallback) and settings file
        UserDefaults.standard.set(enabled, forKey: "strictModeEnabled")
        updateSettingsFile { settings in
            settings["strictModeEnabled"] = enabled
        }

        // Apply strict mode — syncs to daemon (if available) + fallback mechanisms
        appDelegate?.updateStrictMode()

        callJS("window._strictModeResult && window._strictModeResult({ success: true, enabled: \(enabled) })")
    }

    // MARK: - Intentional Mode

    private func handleSaveIntentionalMode(_ body: [String: Any]) {
        // IntentionalModeController deleted in Task 9 — persist directly to UserDefaults
        // so the dashboard settings round-trip continues to work.
        let enabled = body["enabled"] as? Bool ?? false
        let scheduleRaw = body["schedule"] as? String ?? "always"
        let grace = body["gracePeriodMinutes"] as? Int ?? 3

        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: "intentionalModeEnabled")
        defaults.set(scheduleRaw, forKey: "intentionalModeSchedule")
        defaults.set(grace, forKey: "intentionalModeGracePeriod")

        if let custom = body["customSchedule"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: custom) {
            defaults.set(data, forKey: "intentionalModeCustomSchedule")
        }

        appDelegate?.postLog("🔒 SAVE_INTENTIONAL_MODE: enabled=\(enabled), schedule=\(scheduleRaw), grace=\(grace)min")
    }

    // MARK: - Request Unlock

    private func handleRequestUnlock() {
        Task {
            guard let backendClient = appDelegate?.backendClient else {
                await MainActor.run {
                    self.callJS("window._unlockResult && window._unlockResult({ success: false, message: 'Backend not available' })")
                }
                return
            }

            let result = await backendClient.requestUnlock()

            await MainActor.run {
                self.appDelegate?.postLog("🔓 REQUEST_UNLOCK: success=\(result.success), mode=\(result.mode ?? "nil"), message=\(result.message)")

                if result.success {
                    // Persist unlock request state so it survives app restart
                    self.updateSettingsFile { settings in
                        settings["unlockRequested"] = true
                    }
                }

                // Build JS response
                let escaped = result.message.replacingOccurrences(of: "'", with: "\\'")
                var jsResponse = "success: \(result.success), message: '\(escaped)'"
                if let mode = result.mode {
                    jsResponse += ", mode: '\(mode)'"
                }
                self.callJS("window._unlockResult && window._unlockResult({ \(jsResponse) })")
            }
        }
    }

    // MARK: - Verify Unlock Code

    private func handleVerifyUnlock(_ body: [String: Any]) {
        let code = body["code"] as? String ?? ""
        let autoRelock = body["auto_relock"] as? Bool ?? false

        Task {
            guard let result = await appDelegate?.backendClient?.verifyUnlock(code: code, autoRelock: autoRelock) else {
                await MainActor.run {
                    self.callJS("window._verifyUnlockResult && window._verifyUnlockResult({ success: false, message: 'Could not reach server' })")
                }
                return
            }

            await MainActor.run {
                self.appDelegate?.postLog("🔑 VERIFY_UNLOCK: success=\(result.success), auto_relock=\(result.autoRelock), message=\(result.message)")

                if result.success {
                    // Persist unlock state to settings file so it survives app restart
                    self.updateSettingsFile { settings in
                        if let tuu = result.temporaryUnlockUntil {
                            settings["temporaryUnlockUntil"] = tuu
                        } else {
                            // Permanent unlock: use far-future sentinel
                            let farFuture = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 253402300800)) // year 9999
                            settings["temporaryUnlockUntil"] = farFuture
                        }
                        settings["autoRelockEnabled"] = result.autoRelock
                    }

                    // Build JS response
                    if result.autoRelock, let tuu = result.temporaryUnlockUntil {
                        self.callJS("window._verifyUnlockResult && window._verifyUnlockResult({ success: true, auto_relock: true, unlockUntil: '\(tuu)' })")
                    } else {
                        self.callJS("window._verifyUnlockResult && window._verifyUnlockResult({ success: true, auto_relock: false })")
                    }

                    // Notify EnforcementReconciler to refresh with the new unlock window
                    NotificationCenter.default.post(name: Notification.Name("enforcementShouldRefresh"), object: nil)
                } else {
                    let escaped = result.message.replacingOccurrences(of: "'", with: "\\'")
                    self.callJS("window._verifyUnlockResult && window._verifyUnlockResult({ success: false, message: '\(escaped)' })")
                }
            }
        }
    }

    // MARK: - Relock Settings

    private func handleRelockSettings() {
        Task {
            // Call backend to clear temporary unlock
            let result = await appDelegate?.backendClient?.relockSettings()
            await MainActor.run {
                // Clear all unlock state from settings file
                self.updateSettingsFile { settings in
                    settings["temporaryUnlockUntil"] = nil
                    settings["unlockRequested"] = false
                }
                self.appDelegate?.postLog("🔒 RELOCK_SETTINGS: backend=\(result?.success ?? false)")
            }
        }
    }

    // MARK: - Partner Status

    private func handleGetPartnerStatus() {
        Task {
            if let status = await appDelegate?.backendClient?.getPartnerStatus() {
                await MainActor.run {
                    // Persist consent status to settings file so it survives app restart
                    self.updateSettingsFile { settings in
                        let oldConsent = settings["consentStatus"] as? String ?? "none"
                        if oldConsent != status.consentStatus {
                            settings["consentStatus"] = status.consentStatus
                            self.appDelegate?.postLog("📋 Consent status updated: \(oldConsent) → \(status.consentStatus)")
                        }
                    }

                    let email = (status.partnerEmail ?? "").replacingOccurrences(of: "'", with: "\\'")
                    let name = (status.partnerName ?? "").replacingOccurrences(of: "'", with: "\\'")
                    let msg = status.message.replacingOccurrences(of: "'", with: "\\'")
                    self.callJS("window._partnerStatusResult && window._partnerStatusResult({ success: true, consentStatus: '\(status.consentStatus)', partnerEmail: '\(email)', partnerName: '\(name)', message: '\(msg)' })")
                }
            } else {
                await MainActor.run {
                    self.callJS("window._partnerStatusResult && window._partnerStatusResult({ success: false })")
                }
            }
        }
    }

    // MARK: - Status Footer (FIX-15)

    /// Emits the current ContentSafetyMonitor.isEnabled to the dashboard.
    /// Used by the sidebar status footer.
    private func handleGetContentSafetyState() {
        let enabled = appDelegate?.contentSafetyMonitor?.isEnabled ?? false
        callJS("window._contentSafetyState && window._contentSafetyState({ enabled: \(enabled ? "true" : "false") })")
    }

    /// Mac currently has no Puck pairing path (Puck pairs to the iPhone via
    /// the puck-ios app). Stub the bridge so the footer can render the
    /// "not paired" state without inventing a new symbol later.
    private func handleGetPuckStatus() {
        callJS("window._puckStatus && window._puckStatus({ connected: false })")
    }

    // MARK: - Resend Partner Invite

    private func handleResendPartnerInvite() {
        var partnerEmail = ""
        var partnerName = ""
        if FileManager.default.fileExists(atPath: settingsFileURL.path),
           let data = try? Data(contentsOf: settingsFileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            partnerEmail = (json["partnerEmail"] as? String) ?? ""
            partnerName = (json["partnerName"] as? String) ?? ""
        }

        guard !partnerEmail.isEmpty else {
            callJS("window._resendInviteResult && window._resendInviteResult({ success: false, message: 'No partner configured' })")
            return
        }

        Task {
            await appDelegate?.backendClient?.setPartner(
                email: partnerEmail,
                name: partnerName.isEmpty ? nil : partnerName
            )

            await MainActor.run {
                let escaped = partnerEmail.replacingOccurrences(of: "'", with: "\\'")
                self.callJS("window._resendInviteResult && window._resendInviteResult({ success: true, message: 'Invitation resent to \(escaped)' })")
                self.appDelegate?.postLog("📧 RESEND_PARTNER_INVITE: Resent to \(partnerEmail)")
            }
        }
    }

    // MARK: - Preview Block Ritual

    // MARK: - Reset Settings

    private func handleResetSettings() {
        appDelegate?.postLog("🗑️ Starting full reset...")

        // 1. Clear UserDefaults
        UserDefaults.standard.removeObject(forKey: "onboardingComplete")
        UserDefaults.standard.removeObject(forKey: "lockMode")

        // 2. Clear settings file
        try? FileManager.default.removeItem(at: settingsFileURL)

        // 3. Clear TimeTracker data files
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Intentional")
        for filename in ["daily_usage.json", "time_settings.json", "platform_sessions.json"] {
            let fileURL = dir.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: fileURL)
        }

        // 4. Call backend to clear lock mode + notify partner
        Task {
            await appDelegate?.backendClient?.setLockMode(mode: "none")
            appDelegate?.postLog("🗑️ Backend lock mode cleared")
        }

        appDelegate?.postLog("🗑️ Full reset complete")
        loadCurrentPage()
    }

    // MARK: - Uninstall

    /// Uninstall without code (no partner configured).
    private func handleUninstall(requireCode: Bool) {
        appDelegate?.postLog("🗑️ UNINSTALL requested (requireCode=\(requireCode))")
        performUninstall()
    }

    /// Verify code then uninstall.
    private func handleVerifyUninstall(code: String) {
        appDelegate?.postLog("🗑️ VERIFY_UNINSTALL: verifying code...")

        Task {
            guard let backendClient = appDelegate?.backendClient else {
                await MainActor.run {
                    callJS("window._uninstallResult && window._uninstallResult({ success: false, message: 'Backend not available' })")
                }
                return
            }

            let result = await backendClient.verifyUnlock(code: code, autoRelock: false)

            await MainActor.run {
                if result.success {
                    callJS("window._uninstallResult && window._uninstallResult({ success: true })")
                    appDelegate?.postLog("🗑️ Uninstall code verified — proceeding with uninstall")
                    // Short delay so user sees the success message
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.performUninstall()
                    }
                } else {
                    callJS("window._uninstallResult && window._uninstallResult({ success: false, message: 'Invalid code. Please check with your accountability partner.' })")
                    appDelegate?.postLog("🗑️ Uninstall code rejected")
                }
            }
        }
    }

    /// Runs the actual uninstall via privileged AppleScript (prompts for admin password).
    private func performUninstall() {
        // Notify backend before removing files so the server knows this device uninstalled
        Task {
            await appDelegate?.backendClient?.sendEvent(type: "app_uninstalled", details: [:])
        }
        // Give the network request a moment to fire before the AppleScript runs
        Thread.sleep(forTimeInterval: 1.0)

        let script = """
        do shell script "launchctl bootout system /Library/LaunchDaemons/com.intentional.daemon.plist 2>/dev/null; \
        killall syspolicyd_helper 2>/dev/null; \
        rm -f /usr/local/libexec/syspolicyd_helper; \
        rm -f /Library/LaunchDaemons/com.intentional.daemon.plist; \
        rm -f /Library/LaunchAgents/com.intentional.agent.plist; \
        rm -rf /private/var/intentional; \
        echo done" with administrator privileges
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                let result = appleScript.executeAndReturnError(&error)

                DispatchQueue.main.async {
                    if error != nil {
                        self?.appDelegate?.postLog("🗑️ Uninstall: admin auth cancelled or failed")
                        self?.callJS("window._uninstallResult && window._uninstallResult({ success: false, message: 'Admin password required to remove system files.' })")
                    } else {
                        self?.appDelegate?.postLog("🗑️ Uninstall: system files removed, quitting app")
                        // Remove the app itself and quit
                        try? FileManager.default.removeItem(atPath: Bundle.main.bundlePath)
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
    }

    // MARK: - Auth

    private func handleGetAuthState() {
        guard let backendClient = appDelegate?.backendClient else {
            callJS("window._authStateResult && window._authStateResult({ loggedIn: false })")
            return
        }

        if !backendClient.isLoggedIn {
            callJS("window._authStateResult && window._authStateResult({ loggedIn: false })")
            return
        }

        Task {
            let result = await backendClient.authMe()
            await MainActor.run {
                if result.success, let data = result.data {
                    let email = (data["email"] as? String ?? "").replacingOccurrences(of: "'", with: "\\'")
                    let accountId = data["account_id"] as? String ?? ""
                    let createdAt = data["created_at"] as? String ?? ""
                    let devices = data["devices"] as? [Any] ?? []
                    self.callJS("window._authStateResult && window._authStateResult({ loggedIn: true, email: '\(email)', accountId: '\(accountId)', createdAt: '\(createdAt)', deviceCount: \(devices.count) })")
                } else {
                    self.callJS("window._authStateResult && window._authStateResult({ loggedIn: false })")
                }
            }
        }
    }

    private func handleAuthLogin(_ body: [String: Any]) {
        guard let email = body["email"] as? String else {
            callJS("window._authLoginResult && window._authLoginResult({ success: false, message: 'Email required' })")
            return
        }

        Task {
            guard let result = await appDelegate?.backendClient?.authLogin(email: email) else {
                await MainActor.run {
                    self.callJS("window._authLoginResult && window._authLoginResult({ success: false, message: 'Backend not available' })")
                }
                return
            }
            await MainActor.run {
                let escaped = result.message.replacingOccurrences(of: "'", with: "\\'")
                self.callJS("window._authLoginResult && window._authLoginResult({ success: \(result.success), message: '\(escaped)' })")
            }
        }
    }

    private func handleAuthVerify(_ body: [String: Any]) {
        guard let email = body["email"] as? String,
              let code = body["code"] as? String else {
            callJS("window._authVerifyResult && window._authVerifyResult({ success: false, message: 'Email and code required' })")
            return
        }

        Task {
            guard let result = await appDelegate?.backendClient?.authVerify(email: email, code: code) else {
                await MainActor.run {
                    self.callJS("window._authVerifyResult && window._authVerifyResult({ success: false, message: 'Backend not available' })")
                }
                return
            }
            await MainActor.run {
                if result.success, let data = result.data {
                    let email = (data["email"] as? String ?? "").replacingOccurrences(of: "'", with: "\\'")
                    let accountId = data["account_id"] as? String ?? ""
                    let isNew = data["is_new_account"] as? Bool ?? false
                    self.callJS("window._authVerifyResult && window._authVerifyResult({ success: true, email: '\(email)', accountId: '\(accountId)', isNewAccount: \(isNew) })")
                } else {
                    let escaped = result.message.replacingOccurrences(of: "'", with: "\\'")
                    self.callJS("window._authVerifyResult && window._authVerifyResult({ success: false, message: '\(escaped)' })")
                }
            }
        }
    }

    private func handleAuthLogout() {
        Task {
            _ = await appDelegate?.backendClient?.authLogout()
            await MainActor.run {
                self.callJS("window._authLogoutResult && window._authLogoutResult({ success: true })")
                self.loadCurrentPage() // swap to login.html now that token is cleared
            }
        }
    }

    private func handleAuthDelete() {
        Task {
            guard let result = await appDelegate?.backendClient?.authDelete() else {
                await MainActor.run {
                    self.callJS("window._authDeleteResult && window._authDeleteResult({ success: false, message: 'Backend not available' })")
                }
                return
            }
            await MainActor.run {
                let escaped = result.message.replacingOccurrences(of: "'", with: "\\'")
                self.callJS("window._authDeleteResult && window._authDeleteResult({ success: \(result.success), message: '\(escaped)' })")
            }
        }
    }

    // MARK: - Usage History

    private func handleGetUsageHistory() {
        Task {
            guard let result = await appDelegate?.backendClient?.getUsageHistory(days: 7) else {
                await MainActor.run {
                    self.callJS("window._usageHistoryResult && window._usageHistoryResult({ success: false })")
                }
                return
            }
            await MainActor.run {
                if let data = try? JSONSerialization.data(withJSONObject: result),
                   let json = String(data: data, encoding: .utf8) {
                    self.callJS("window._usageHistoryResult && window._usageHistoryResult(\(json))")
                } else {
                    self.callJS("window._usageHistoryResult && window._usageHistoryResult({ success: false })")
                }
            }
        }
    }

    // MARK: - Session Journal

    private func handleGetJournal() {
        Task {
            guard let result = await appDelegate?.backendClient?.getJournal() else {
                await MainActor.run {
                    self.callJS("window._journalResult && window._journalResult({ success: false })")
                }
                return
            }
            await MainActor.run {
                if let data = try? JSONSerialization.data(withJSONObject: result),
                   let json = String(data: data, encoding: .utf8) {
                    self.callJS("window._journalResult && window._journalResult(\(json))")
                } else {
                    self.callJS("window._journalResult && window._journalResult({ success: false })")
                }
            }
        }
    }

    // MARK: - Focus Schedule (Dashboard Handlers)

    private func handleGetScheduleState() {
        guard let manager = appDelegate?.scheduleManager else {
            callJS("window._scheduleStateResult && window._scheduleStateResult({ enabled: false })")
            return
        }

        // Use getScheduleSyncPayload() to include the full blocks array for the calendar view
        var state = manager.getScheduleSyncPayload()
        state.removeValue(forKey: "type") // Don't send the "SCHEDULE_SYNC" type to dashboard
        // FIX-10: Surface the live intention id of the active session for strictness greying.
        // The session's period is canonical; fall back to the active block's intentionId.
        if let sessionGoalId = appDelegate?.focusModeController?.currentPeriod?.intentionId {
            state["active_intention_id"] = sessionGoalId.uuidString
        } else if let blockIntentionId = manager.currentBlock?.intentionId {
            state["active_intention_id"] = blockIntentionId.uuidString
        } else {
            state["active_intention_id"] = NSNull()
        }
        if let data = try? JSONSerialization.data(withJSONObject: state),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._scheduleStateResult && window._scheduleStateResult(\(json))")
        }
    }

    private func handleSetFocusEnabled(_ body: [String: Any]) {
        guard let enabled = body["enabled"] as? Bool else { return }
        appDelegate?.scheduleManager?.setEnabled(enabled)
        callJS("window._focusEnabledResult && window._focusEnabledResult({ success: true, enabled: \(enabled) })")
    }

    private func handleSetProfileFromDashboard(_ body: [String: Any]) {
        guard let text = body["profile"] as? String else { return }
        appDelegate?.scheduleManager?.setProfile(text)
        callJS("window._profileResult && window._profileResult({ success: true })")
    }

    private func handleSetScheduleFromDashboard(_ body: [String: Any]) {
        guard let blocksData = body["blocks"] as? [[String: Any]] else {
            callJS("window._scheduleResult && window._scheduleResult({ success: false })")
            return
        }

        let goals = body["goals"] as? [String] ?? []
        let dailyPlan = body["dailyPlan"] as? String ?? ""

        let blocks = blocksData.compactMap { dict -> ScheduleManager.FocusBlock? in
            guard let title = dict["title"] as? String,
                  let startHour = dict["startHour"] as? Int,
                  let startMinute = dict["startMinute"] as? Int,
                  let endHour = dict["endHour"] as? Int,
                  let endMinute = dict["endMinute"] as? Int else { return nil }
            let blockType: ScheduleManager.BlockType
            if let bt = dict["blockType"] as? String, let parsed = ScheduleManager.BlockType(rawValue: bt) {
                blockType = parsed
            } else {
                // Spec 2: legacy isFree=true → focusHours (free time = absence of block).
                blockType = .focusHours
            }
            let ignoreProfile = dict["ignoreProfile"] as? Bool ?? false
            // Spec 3 (May 2026): tolerate intentionId from the picker
            let intentionId: UUID? = (dict["intentionId"] as? String).flatMap { UUID(uuidString: $0) }
            return ScheduleManager.FocusBlock(
                id: dict["id"] as? String ?? UUID().uuidString,
                title: title,
                description: dict["description"] as? String ?? "",
                startHour: startHour,
                startMinute: startMinute,
                endHour: endHour,
                endMinute: endMinute,
                blockType: blockType,
                ignoreProfile: ignoreProfile,
                intentionId: intentionId
            )
        }

        appDelegate?.scheduleManager?.setTodaySchedule(goals: goals, dailyPlan: dailyPlan, blocks: blocks)
        callJS("window._scheduleResult && window._scheduleResult({ success: true })")
    }

    // MARK: - Schedule History

    private func handleGetScheduleForDate(_ body: [String: Any]) {
        guard let dateString = body["date"] as? String,
              let manager = appDelegate?.scheduleManager else {
            callJS("window._scheduleForDateResult && window._scheduleForDateResult({ blocks: [], goals: [], dailyPlan: '' })")
            return
        }

        if let schedule = manager.getScheduleForDate(dateString) {
            let blocks = schedule.blocks.map { block -> [String: Any] in
                return [
                    "id": block.id,
                    "title": block.title,
                    "description": block.description,
                    "startHour": block.startHour,
                    "startMinute": block.startMinute,
                    "endHour": block.endHour,
                    "endMinute": block.endMinute,
                    "blockType": block.blockType.rawValue,
                    "isFree": block.isFree
                ]
            }
            let result: [String: Any] = [
                "date": schedule.date,
                "blocks": blocks,
                // Wire format keeps legacy keys for dashboard.html compat (Spec 2 internal rename only).
                "goals": schedule.dayItems,
                "dailyPlan": schedule.dayNotes
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result),
               let json = String(data: data, encoding: .utf8) {
                callJS("window._scheduleForDateResult && window._scheduleForDateResult(\(json))")
            }
        } else {
            callJS("window._scheduleForDateResult && window._scheduleForDateResult({ date: '\(dateString)', blocks: [], goals: [], dailyPlan: '' })")
        }
    }

    // MARK: - Bedtime Settings

    private func handleGetBedtimeSettings() {
        guard let _ = appDelegate?.bedtimeEnforcer else {
            callJS("window.onBedtimeSettings && window.onBedtimeSettings(null)")
            return
        }

        let settingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional")
            .appendingPathComponent("bedtime_settings.json")

        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let jsonStr = String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8) ?? "{}"
            callJS("window.onBedtimeSettings && window.onBedtimeSettings(\(jsonStr))")
        } else {
            // Return defaults
            let defaults = """
            {"enabled":false,"bedtimeStart":{"hour":23,"minute":0},"wakeTime":{"hour":7,"minute":0},"activeDays":[0,1,2,3,4,5,6],"partnerLocked":false}
            """
            callJS("window.onBedtimeSettings && window.onBedtimeSettings(\(defaults))")
        }
    }

    private func handleSaveBedtimeSettings(_ body: [String: Any]) {
        guard let enabled = body["enabled"] as? Bool,
              let startObj = body["bedtimeStart"] as? [String: Int],
              let endObj = body["wakeTime"] as? [String: Int],
              let startHour = startObj["hour"],
              let startMin = startObj["minute"],
              let endHour = endObj["hour"],
              let endMin = endObj["minute"] else {
            appDelegate?.postLog("⚠️ Invalid bedtime settings payload")
            return
        }

        let activeDays = body["activeDays"] as? [Int] ?? [0, 1, 2, 3, 4, 5, 6]
        let partnerLocked = body["partnerLocked"] as? Bool ?? false

        let settings = BedtimeSettings(
            enabled: enabled,
            bedtimeStart: TimeOfDay(hour: startHour, minute: startMin),
            wakeTime: TimeOfDay(hour: endHour, minute: endMin),
            activeDays: activeDays,
            partnerLocked: partnerLocked
        )

        appDelegate?.bedtimeEnforcer?.saveSettings(settings)
        appDelegate?.postLog("🌙 Bedtime settings saved: \(enabled ? "ON" : "OFF") \(startHour):\(String(format: "%02d", startMin)) → \(endHour):\(String(format: "%02d", endMin))")

        // Push the change to the backend so the iPhone (and any future
        // Mac sibling) picks it up on its next poll. ISO weekdays
        // (1=Mon..7=Sun) on the wire vs Mac internal Sunday-based.
        if let backend = appDelegate?.backendClient {
            let dto = BackendClient.BedtimeConfigDTO(
                enabled: enabled,
                bedtime_start: .init(hour: startHour, minute: startMin),
                wake: .init(hour: endHour, minute: endMin),
                active_days: BedtimeConfigSync.sundayBasedToISO(activeDays),
                allowlist_bundle_ids: [],
                partner_locked: partnerLocked,
                updated_at: nil
            )
            Task {
                let ok = await backend.putBedtimeConfig(dto)
                await MainActor.run {
                    if ok {
                        appDelegate?.postLog("🌙 Bedtime config pushed to backend (cross-device)")
                    } else {
                        appDelegate?.postLog("⚠️ Bedtime config push to backend failed; local save still applied")
                    }
                }
            }
        }
    }

    // MARK: - Blocking Profile Handlers

    /// Snake-case dict representation of a profile/block-rule for the new
    /// Today→Blocks UI. Ships alongside the legacy struct-shaped payload so
    /// existing receivers (ProjectsController, profile detail view) keep working.
    @MainActor
    static func blockingProfileToDict(_ p: BlockingProfile) -> [String: Any] {
        let snoozed = BlockRuleEnforcer.shared.currentlySnoozedIds().contains(p.id)
        var d: [String: Any] = [
            "id": p.id.uuidString,
            "name": p.name,
            "websites": p.blockedDomains,
            "bundle_ids": p.blockedAppBundleIds,
            "is_default": p.isDefault,
            "always_active": p.alwaysActive,
            "enabled": p.enabled,
            "active_days": p.activeDays,
            // Effective active: in-window AND enabled AND NOT snoozed
            "is_currently_active": snoozed ? false : p.isCurrentlyActive,
            // Raw "in-window-and-enabled" so UI can tell snooze apart from out-of-window
            "is_in_window": p.isCurrentlyActive,
            "is_snoozed": snoozed
        ]
        if let sh = p.startHour { d["start_hour"] = sh }
        if let sm = p.startMinute { d["start_minute"] = sm }
        if let eh = p.endHour { d["end_hour"] = eh }
        if let em = p.endMinute { d["end_minute"] = em }
        if snoozed,
           let until = BlockRuleEnforcer.shared.snoozeReleaseDate(profileId: p.id) {
            let fmt = ISO8601DateFormatter()
            d["snoozed_until"] = fmt.string(from: until)
        }
        return d
    }

    private func handleGetBlockingProfiles() {
        let profiles = appDelegate?.blockingProfileManager?.profiles ?? []
        // Legacy receiver — keeps the existing profile-detail / ProjectsController flows alive.
        if let data = try? JSONEncoder().encode(profiles),
           let jsonStr = String(data: data, encoding: .utf8) {
            callJS("window.onBlockingProfiles && window.onBlockingProfiles(\(jsonStr))")
        }
        // New receiver — snake_case payload with schedule + enabled for Today→Blocks UI.
        let dicts = profiles.map { Self.blockingProfileToDict($0) }
        if let data = try? JSONSerialization.data(withJSONObject: dicts),
           let jsonStr = String(data: data, encoding: .utf8) {
            callJS("window._blockingProfilesList && window._blockingProfilesList(\(jsonStr))")
        }
    }

    /// Accepts both legacy keys (`domains`, `appBundleIds`) and new snake_case keys
    /// (`websites`, `bundle_ids`, `start_hour`, etc).
    private func handleCreateBlockingProfile(_ body: [String: Any]) {
        let name = body["name"] as? String ?? "New Profile"
        let domains = (body["websites"] as? [String]) ?? (body["domains"] as? [String]) ?? []
        let apps = (body["bundle_ids"] as? [String]) ?? (body["appBundleIds"] as? [String]) ?? []
        guard let manager = appDelegate?.blockingProfileManager else { return }
        let created = manager.createProfile(name: name, domains: domains, appBundleIds: apps)
        // Apply optional schedule + enabled in one update so we don't double-write the file.
        let enabled = body["enabled"] as? Bool
        let startHour = body["start_hour"] as? Int
        let startMinute = body["start_minute"] as? Int
        let endHour = body["end_hour"] as? Int
        let endMinute = body["end_minute"] as? Int
        let activeDays = body["active_days"] as? [Int]
        if enabled != nil || startHour != nil || startMinute != nil
            || endHour != nil || endMinute != nil || activeDays != nil {
            manager.updateProfile(
                id: created.id,
                enabled: enabled,
                startHour: .some(startHour),
                startMinute: .some(startMinute),
                endHour: .some(endHour),
                endMinute: .some(endMinute),
                activeDays: activeDays
            )
        }
        appDelegate?.applyAlwaysActiveProfiles()
        // Engage BlockRuleEnforcer immediately on the newly-created rule
        // (otherwise the user waits up to 30s for the next tick).
        BlockRuleEnforcer.shared.reevaluateNow()
        handleGetBlockingProfiles()
    }

    private func handleUpdateBlockingProfile(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) else { return }
        let domains = (body["websites"] as? [String]) ?? (body["domains"] as? [String])
        let apps = (body["bundle_ids"] as? [String]) ?? (body["appBundleIds"] as? [String])
        // R4 follow-up (2026-06-11): this legacy path skipped the R4 loosening
        // gate entirely. Post-R6 the profile store is empty (data migrated to
        // the unified rule store) and the editor UI is orphaned, but the bridge
        // alias is live for one release cycle — gate loosening edits (disable,
        // demote always-active, shrink blocklists) like the rule-store paths.
        if blockRulesLockEngaged(),
           let current = appDelegate?.blockingProfileManager?.profile(for: id) {
            let disabling = (body["enabled"] as? Bool) == false && current.enabled
            let demotingAlwaysActive =
                ((body["alwaysActive"] as? Bool ?? body["always_active"] as? Bool) == false)
                && current.alwaysActive
            let removesDomains = domains.map { !Set(current.blockedDomains).isSubset(of: Set($0)) } ?? false
            let removesApps = apps.map { !Set(current.blockedAppBundleIds).isSubset(of: Set($0)) } ?? false
            if disabling || demotingAlwaysActive || removesDomains || removesApps {
                refuseLockedRuleMutation("UPDATE_BLOCK_RULE(loosening) for \(id)")
                handleGetBlockingProfiles()   // re-render reverts any optimistic UI state
                return
            }
        }
        // For schedule fields, treat key-present-and-NSNull as "clear to nil",
        // key-present-and-Int as "set", key-absent as "leave alone".
        let scheduleArgs: (Int??, Int??, Int??, Int??) = (
            body.keys.contains("start_hour") ? .some(body["start_hour"] as? Int) : nil,
            body.keys.contains("start_minute") ? .some(body["start_minute"] as? Int) : nil,
            body.keys.contains("end_hour") ? .some(body["end_hour"] as? Int) : nil,
            body.keys.contains("end_minute") ? .some(body["end_minute"] as? Int) : nil
        )
        appDelegate?.blockingProfileManager?.updateProfile(
            id: id,
            name: body["name"] as? String,
            domains: domains,
            appBundleIds: apps,
            alwaysActive: body["alwaysActive"] as? Bool ?? body["always_active"] as? Bool,
            enabled: body["enabled"] as? Bool,
            startHour: scheduleArgs.0,
            startMinute: scheduleArgs.1,
            endHour: scheduleArgs.2,
            endMinute: scheduleArgs.3,
            activeDays: body["active_days"] as? [Int]
        )
        // Re-apply always-active enforcement after profile change
        appDelegate?.applyAlwaysActiveProfiles()
        // Engage BlockRuleEnforcer immediately on schedule/enabled/list edits.
        BlockRuleEnforcer.shared.reevaluateNow()
        handleGetBlockingProfiles()
    }

    private func handleToggleBlockRule(id: UUID, enabled: Bool) {
        // R4(d): disabling a block rule is loosening — partner-gated under
        // Strict Mode. Re-enabling (tightening) always passes.
        if !enabled && blockRulesLockEngaged() {
            refuseLockedRuleMutation("TOGGLE_BLOCK_RULE(off) for \(id)")
            handleGetBlockingProfiles()   // re-render reverts the optimistic UI toggle
            return
        }
        appDelegate?.blockingProfileManager?.setEnabled(id: id, enabled: enabled)
        appDelegate?.applyAlwaysActiveProfiles()
        // Toggle is the single most common user action on a rule — must engage
        // immediately, not on the next 30s tick.
        BlockRuleEnforcer.shared.reevaluateNow()
        handleGetBlockingProfiles()
    }

    private func handleDeleteBlockingProfile(id: UUID) {
        // R4(d): deleting a block rule is always loosening — partner-gated
        // under Strict Mode.
        if blockRulesLockEngaged() {
            refuseLockedRuleMutation("DELETE_BLOCK_RULE for \(id)")
            let payload = "{ id: '\(id.uuidString)', referencedBy: [], reason: 'strict_mode_locked' }"
            callJS("window.onBlockingProfileDeleteRefused && window.onBlockingProfileDeleteRefused(\(payload))")
            return
        }
        // B3 (projects kill): the projects-referencing-this-blocklist guard is
        // gone with ProjectStore — Intentions own their lists directly and
        // never reference profiles.
        _ = appDelegate?.blockingProfileManager?.deleteProfile(id: id)
        // Engage BlockRuleEnforcer immediately so the deleted rule's
        // blocklist is removed from the standalone enforcement layer.
        BlockRuleEnforcer.shared.reevaluateNow()
        handleGetBlockingProfiles()
    }

    // MARK: - Learned sites (B3 — Projects deleted; store keyed by intentionId)

    /// PROMOTE_LEARNED_SITE {id: <intention uuid>, host}: marks the host
    /// promoted in LearnedSitesStore AND appends it to the Intention's
    /// allow_websites (the old ProjectStore.promoteLearnedSite added the host
    /// to the project's allowed list — same contract, new owner). If the
    /// goal's session is live, enforcement re-applies immediately.
    /// Reply: window._learnedSitePromoted({id, host, success, added_to_allow}).
    private func handlePromoteLearnedSite(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String,
              let id = UUID(uuidString: idStr),
              let host = body["host"] as? String, !host.isEmpty else { return }

        Task {
            _ = await LearnedSitesStore.shared.promote(intentionId: id, host: host)

            var addedToAllow = false
            if let existing = await IntentionStore.shared.intention(id: id),
               existing.deletedAt == nil {
                if existing.allowWebsites.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) {
                    addedToAllow = true
                } else {
                    var payload = IntentionUpdatePayload(
                        name: existing.name,
                        description: existing.description,
                        colorHex: existing.colorHex,
                        icon: existing.icon,
                        macWebsites: existing.macWebsites,
                        macBundleIds: existing.macBundleIds,
                        iosAppTokensB64: existing.iosAppTokensB64,
                        iosCategoryTokensB64: existing.iosCategoryTokensB64,
                        version: existing.version
                    )
                    payload.outcome = existing.outcome
                    payload.status = existing.status
                    payload.weeklyTargetHours = existing.weeklyTargetHours
                    payload.intentText = existing.intentText
                    payload.aiScoringEnabled = existing.aiScoringEnabled
                    payload.allowWebsites = existing.allowWebsites + [host]
                    payload.allowBundleIds = existing.allowBundleIds
                    payload.monthlyGoalId = existing.monthlyGoalId
                    payload.weekOf = existing.weekOf
                    do {
                        _ = try await IntentionStore.shared.update(id: id, payload: payload)
                        addedToAllow = true
                    } catch {
                        await MainActor.run {
                            self.appDelegate?.postLog("⚠️ PROMOTE_LEARNED_SITE: allow-list update failed for \(host): \(error.localizedDescription)")
                        }
                    }
                }
            }

            await MainActor.run {
                // Live session of this goal? Apply the new allow right away.
                if self.appDelegate?.focusModeController?.currentPeriod?.intentionId == id {
                    Task { await self.appDelegate?.refreshIntentionEnforcement(for: id) }
                }
                let hostJS = host.replacingOccurrences(of: "'", with: "")
                self.callJS("window._learnedSitePromoted && window._learnedSitePromoted({ id: '\(id.uuidString.lowercased())', host: '\(hostJS)', success: true, added_to_allow: \(addedToAllow) })")
                self.appDelegate?.postLog("📚 Promoted learned site \(host) for goal \(id.uuidString.prefix(8)) (allow-list updated: \(addedToAllow))")
                // Refresh dashboard caches so allow counts re-render.
                self.handleGetIntentions()
            }
        }
    }

    private func emitSessionResult(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("window.onProjectSessionResult && window.onProjectSessionResult(\(json))")
    }

    // MARK: - Focus Score

    private func handleGetFocusScore() {
        guard let manager = appDelegate?.scheduleManager,
              let schedule = manager.todaySchedule else {
            callJS("window._focusScoreResult && window._focusScoreResult({ score: 0, blocks: [] })")
            return
        }

        let now = Date()
        let calendar = Calendar.current
        let currentMinute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        // R6: EarnedBrowse per-block stats deleted (they were empty at runtime
        // behind the feature flag) — the time-based fallback below is, and
        // was, the live scoring path.

        var totalWorkMinutes = 0
        var completedWorkMinutes = 0
        var breakMinutes = 0

        var blocksData: [[String: Any]] = []
        for block in schedule.blocks {
            let duration = block.endMinutes - block.startMinutes

            if block.isFree {
                if block.endMinutes <= currentMinute {
                    breakMinutes += duration
                } else if block.startMinutes < currentMinute {
                    breakMinutes += currentMinute - block.startMinutes
                }
            } else {
                totalWorkMinutes += duration
                if block.endMinutes <= currentMinute {
                    completedWorkMinutes += duration
                } else if block.startMinutes < currentMinute {
                    completedWorkMinutes += currentMinute - block.startMinutes
                }
            }

            let blockScore = 0  // per-block stats source deleted (R6)

            blocksData.append([
                "title": block.title,
                "startHour": block.startHour,
                "startMinute": block.startMinute,
                "endHour": block.endHour,
                "endMinute": block.endMinute,
                "blockType": block.blockType.rawValue,
                "isFree": block.isFree,
                "score": block.isFree ? 0 : blockScore
            ])
        }

        // Focus score: time-based (completed/total work minutes). This was
        // already the live path — per-block AI scores were zeros behind the
        // deleted engine's feature flag.
        let score = totalWorkMinutes > 0 ? min(100, (completedWorkMinutes * 100) / totalWorkMinutes) : 0

        // Off-task / focused tick aggregation retired with the engine (R6) —
        // the values had been zero at runtime, so the fallbacks below carry.
        let offTaskMinutes = 0
        let focusedMinutes = 0

        let result: [String: Any] = [
            "score": score,
            "focusedMinutes": focusedMinutes > 0 ? focusedMinutes : completedWorkMinutes,
            "offTaskMinutes": offTaskMinutes,
            "breakMinutes": breakMinutes,
            "blocks": blocksData
        ]

        if let data = try? JSONSerialization.data(withJSONObject: result),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._focusScoreResult && window._focusScoreResult(\(json))")
        }
    }

    // MARK: - Relevance Log

    private func handleGetRelevanceLog() {
        guard let monitor = appDelegate?.focusMonitor else {
            callJS("window._relevanceLogResult && window._relevanceLogResult([])")
            return
        }

        let entries: [[String: Any]] = monitor.relevanceLog.suffix(30).map { entry in
            var dict: [String: Any] = [
                "timestamp": entry.timestamp.timeIntervalSince1970 * 1000,
                "title": entry.title,
                "appName": entry.appName,
                "intention": entry.intention,
                "relevant": entry.relevant,
                "confidence": entry.confidence,
                "reason": entry.reason,
                "action": entry.action
            ]
            if entry.isEvent { dict["isEvent"] = true }
            if entry.userOverride { dict["userOverride"] = true }
            dict["path"] = entry.path.rawValue
            if let excerpt = entry.ocrExcerpt { dict["ocrExcerpt"] = excerpt }
            return dict
        }

        if let data = try? JSONSerialization.data(withJSONObject: entries),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._relevanceLogResult && window._relevanceLogResult(\(json))")
        }
    }

    private func handleExportRelevanceLog() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional")
        let file = dir.appendingPathComponent("relevance_log.jsonl")
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
        callJS("window._exportLogResult && window._exportLogResult({ success: true })")
    }

    private func handleGetBlockAssessments(_ body: [String: Any]) {
        let startMs = body["startTime"] as? Double ?? 0
        let endMs = body["endTime"] as? Double ?? 0
        let startDate = Date(timeIntervalSince1970: startMs / 1000)
        let endDate = Date(timeIntervalSince1970: endMs / 1000)

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional")
        let file = dir.appendingPathComponent("relevance_log.jsonl")

        var entries: [[String: Any]] = []
        let formatter = ISO8601DateFormatter()

        if let contents = try? String(contentsOf: file, encoding: .utf8) {
            for line in contents.components(separatedBy: "\n") where !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = formatter.date(from: tsStr) else { continue }
                if ts >= startDate && ts <= endDate {
                    var entry: [String: Any] = [
                        "timestamp": ts.timeIntervalSince1970 * 1000,
                        "title": obj["title"] ?? "",
                        "appName": obj["appName"] ?? obj["title"] ?? "",
                        "hostname": obj["hostname"] ?? "",
                        "intention": obj["intention"] ?? "",
                        "relevant": obj["relevant"] ?? false,
                        "confidence": obj["confidence"] ?? 0,
                        "reason": obj["reason"] ?? "",
                        "action": obj["action"] ?? "none"
                    ]
                    if let neutral = obj["neutral"] as? Bool, neutral {
                        entry["neutral"] = true
                    }
                    if let isEvent = obj["isEvent"] as? Bool, isEvent {
                        entry["isEvent"] = true
                    }
                    if let userOverride = obj["userOverride"] as? Bool, userOverride {
                        entry["userOverride"] = true
                    }
                    // Phase 2: scoring path (default to metadataRelevant for pre-Phase-2 log entries)
                    entry["path"] = (obj["path"] as? String) ?? "metadataRelevant"
                    if let excerpt = obj["ocrExcerpt"] as? String {
                        entry["ocrExcerpt"] = excerpt
                    }
                    entries.append(entry)
                }
            }
        }

        // Last-wins dedup by timestamp — handles userOverride correction rows appended by
        // markCurrentOverlayAsWrong() which share their original timestamp with the row they correct.
        var byTs: [Double: [String: Any]] = [:]
        var order: [Double] = []
        for e in entries {
            if let ts = e["timestamp"] as? Double {
                if byTs[ts] == nil { order.append(ts) }
                byTs[ts] = e
            }
        }
        entries = order.map { byTs[$0]! }

        if let data = try? JSONSerialization.data(withJSONObject: entries),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._blockAssessmentsResult && window._blockAssessmentsResult(\(json))")
        }
    }

    private func handleSetFocusEnforcement(_ body: [String: Any]) {
        guard let mode = body["mode"] as? String else { return }
        appDelegate?.scheduleManager?.setFocusEnforcement(mode)
        callJS("window._focusEnforcementResult && window._focusEnforcementResult({ success: true, mode: '\(mode)' })")
    }

    /// S2 (2026-06-10): legacy no-op — model is hardcoded to Qwen3-4B and the
    /// picker UI was removed. Kept for one release cycle so an old cached
    /// dashboard page can't crash the bridge. Remove after 2026-07.
    private func handleSetAIModel(_ body: [String: Any]) {
        appDelegate?.postLog("📋 SET_AI_MODEL ignored (deprecated — Qwen3-4B is hardcoded)")
        callJS("window._aiModelResult && window._aiModelResult({ success: true, model: 'qwen' })")
    }

    private func handleSetEnforcementSettings(_ body: [String: Any]) {
        guard let enfDict = body["settings"] as? [String: Any] else {
            callJS("window._enforcementSettingsResult && window._enforcementSettingsResult({ success: false, error: 'Invalid settings' })")
            return
        }

        // Lock check: reject if settings are locked
        let currentLockMode = UserDefaults.standard.string(forKey: "lockMode") ?? "none"
        if currentLockMode != "none" {
            var isUnlocked = false
            if let data = try? Data(contentsOf: settingsFileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let unlockUntil = json["temporaryUnlockUntil"] as? String {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: unlockUntil), date > Date() {
                    isUnlocked = true
                }
            }
            if !isUnlocked {
                callJS("window._enforcementSettingsResult && window._enforcementSettingsResult({ success: false, error: 'Settings are locked' })")
                return
            }
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: enfDict)
            let settings = try JSONDecoder().decode(ScheduleManager.EnforcementSettings.self, from: data)
            appDelegate?.scheduleManager?.setEnforcementSettings(settings)
            // Calm-Down D2: an individual checkbox edit flips the global dial to
            // "custom" — unless the result happens to exactly match a preset.
            let level = ScheduleManager.StrictnessLevel.matching(settings)?.rawValue ?? "custom"
            UserDefaults.standard.set(level, forKey: "strictnessLevel")
            callJS("window._enforcementSettingsResult && window._enforcementSettingsResult({ success: true, strictnessLevel: '\(level)' })")
        } catch {
            callJS("window._enforcementSettingsResult && window._enforcementSettingsResult({ success: false, error: 'Parse error' })")
        }
    }

    // Calm-Down Pass D2: one global strictness dial (gentle|standard|strict).
    // Rewrites BOTH per-block-type enforcement profiles per the spec mapping
    // and persists the level in UserDefaults. "custom" is never set via this
    // message — it's derived when an Advanced checkbox is edited
    // (SET_ENFORCEMENT_SETTINGS path above).
    private func handleSetStrictnessLevel(_ body: [String: Any]) {
        guard let raw = body["level"] as? String,
              let level = ScheduleManager.StrictnessLevel(rawValue: raw),
              let mapped = level.mappedSettings else {
            callJS("window._strictnessLevelResult && window._strictnessLevelResult({ success: false, error: 'Invalid level' })")
            return
        }

        // Same lock gate as SET_ENFORCEMENT_SETTINGS — the dial IS enforcement config.
        let currentLockMode = UserDefaults.standard.string(forKey: "lockMode") ?? "none"
        if currentLockMode != "none" {
            var isUnlocked = false
            if let data = try? Data(contentsOf: settingsFileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let unlockUntil = json["temporaryUnlockUntil"] as? String {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: unlockUntil), date > Date() {
                    isUnlocked = true
                }
            }
            if !isUnlocked {
                callJS("window._strictnessLevelResult && window._strictnessLevelResult({ success: false, error: 'Settings are locked' })")
                return
            }
        }

        appDelegate?.scheduleManager?.setEnforcementSettings(mapped)
        UserDefaults.standard.set(level.rawValue, forKey: "strictnessLevel")
        appDelegate?.postLog("📋 SET_STRICTNESS_LEVEL: \(level.rawValue)")

        let payload: [String: Any] = [
            "success": true,
            "level": level.rawValue,
            "enforcementSettings": mapped.toDict()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._strictnessLevelResult && window._strictnessLevelResult(\(json))")
        }
    }

    // Earned Browse status + Extra Time handlers deleted in R6 (2026-06-11)
    // with EarnedBrowseManager — the shared daily allowance (Rules page /
    // GET_ALLOWANCE) replaced the pool, and partner Extra Time went with the
    // hidden widget. Bridge messages are no-op aliases in didReceive.

    /// Push content safety status to dashboard (permission state, monitoring state).
    func pushContentSafetyStatus(_ status: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: status),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._contentSafetyStatus && window._contentSafetyStatus(\(json))")
        }
    }

    /// Push focus mode state to the dashboard toggle (called by AppDelegate onStateChanged).
    func pushFocusModeUpdate(state: FocusModeController.State) {
        let js = """
            if (typeof onFocusModeStateUpdate === 'function') {
                onFocusModeStateUpdate('\(state.rawValue)');
            }
        """
        callJS(js)
    }

    /// Handle GET_FOCUS_MODE — dashboard pulls current state on load. Pairs with
    /// pushFocusModeUpdate (which can race the page-load JS parse and silently
    /// drop). The pull guarantees the toggle reflects reality once JS is ready.
    private func handleGetFocusMode() {
        let stateRaw = appDelegate?.focusModeController?.state.rawValue ?? "off"
        pushFocusModeUpdate(state: FocusModeController.State(rawValue: stateRaw) ?? .off)
    }

    // MARK: - Focus Mode Toggle Bridge

    /// Body: { "on": Bool }
    /// Manual dashboard toggle of Focus Mode. Local activate/deactivate fires
    /// immediately for instant UI feedback. Same toggle is also propagated to
    /// the backend so other devices see it (and so the poller doesn't stomp on
    /// the local state by reconciling against a stale backend "no session").
    /// If the backend POST fails, local stays as-is; the next poller tick will
    /// reconcile if disk and backend disagree (backend wins on conflict).
    private func handleFocusModeToggle(body: [String: Any]) {
        guard let on = body["on"] as? Bool else { return }
        // Backend post is centralized in AppDelegate.focusModeController.onStateChanged
        // — calling it here too would double-post. Idempotent backend handles
        // dups but the duplicate is wasted network traffic.
        if on {
            appDelegate?.focusModeController?.activate(intention: nil, source: .manual)
        } else {
            appDelegate?.focusModeController?.deactivate(source: .manual)
        }
    }

    /// LEGACY (Settings Consolidation S4, 2026-06-10): the Interventions toggle
    /// UI was deleted with the Focus Mode settings page, so nothing sends this
    /// anymore. Kept as a persist-only no-op for one release cycle (an old
    /// cached dashboard could still post it). Remove after 2026-07.
    ///
    /// Body: { "key": String, "enabled": Bool }
    /// Persists the user's preference for an individual intervention. Honoring the
    /// preference (i.e., gating the actual intervention logic on this flag) is
    /// follow-up work — Task 10 only persists the UI state.
    /// key ∈ { "distractions_blocking", "switch_overlay", "ai_relevance",
    ///         "screen_red_shift", "off_task_nudge", "block_start_ritual",
    ///         "block_end_ritual", "pill_widget", "force_quit_apps",
    ///         "earned_browse_mode" }
    private func handleInterventionToggleSet(body: [String: Any]) {
        guard let key = body["key"] as? String,
              let enabled = body["enabled"] as? Bool else { return }
        let defaultsKey = "intervention.\(key)"
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
        NotificationCenter.default.post(
            name: .interventionToggleChanged,
            object: nil,
            userInfo: ["key": key, "enabled": enabled]
        )
        appDelegate?.postLog("🔧 INTERVENTION_TOGGLE_SET: \(key)=\(enabled)")
    }

    // MARK: - JS Helpers

    func callJS(_ script: String) {
        #if DEBUG
        let scriptSize = script.count
        let fnName: String = {
            if let r = script.range(of: #"window\.(_[A-Za-z0-9]+)"#, options: .regularExpression) {
                return String(script[r]).replacingOccurrences(of: "window.", with: "")
            }
            let head = script.prefix(40)
            return String(head).components(separatedBy: "(").first ?? String(head)
        }()
        #endif
        DispatchQueue.main.async {
            #if DEBUG
            // Counter mutations must run on main — uiPerfRxCounts / uiPerfCallJSCount
            // are also touched by didReceive (main thread). Background callers racing
            // on the dictionary corrupted heap and crashed in removeAll(keepingCapacity:).
            self.uiPerfCallJSCount += 1
            self.uiPerfCallJSBytes += scriptSize
            self.uiPerfMaybeFlush()
            let t0 = CFAbsoluteTimeGetCurrent()
            #endif
            self.webView.evaluateJavaScript(script) { _, error in
                #if DEBUG
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if ms > 50 {
                    self.appDelegate?.postLog("[UIPERF] SLOW callJS \(Int(ms))ms fn=\(fnName) size=\(scriptSize)")
                }
                #endif
                if let error = error {
                    self.appDelegate?.postLog("⚠️ JS eval error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Safely invoke a window callback with JSON-serialized data.
    /// Uses JSONSerialization to avoid string interpolation issues with special characters.
    private func callJSCallback(_ callbackName: String, data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            appDelegate?.postLog("⚠️ callJSCallback: Failed to serialize data for \(callbackName)")
            return
        }
        callJS("window.\(callbackName) && window.\(callbackName)(\(jsonStr))")
    }

    // App Taxonomy handlers (Slice 5 of 2026-05-05) deleted in R6 — the
    // Settings pages that drove them are gone; their bridge messages are
    // no-op aliases in didReceive. BackendClient's taxonomy getters survive
    // because RulesMigration reads the rows.

    // MARK: - Intentions (Spec 1)

    private func handleGetIntentions() {
        Task {
            let intentions = await IntentionStore.shared.active()
            // First emit the list immediately so cards render fast without waiting
            // for the per-goal hours_done aggregation.
            let baseItems = intentions.map { i -> [String: Any] in
                return Self.intentionToDict(i)
            }
            await MainActor.run {
                self.emitIntentionsList(baseItems)
            }

            // Then fan out a hours_done request per goal that has a week_of.
            // Fire-and-forget — each result patches the cache via _intentionUpdated.
            guard let backend = appDelegate?.backendClient else { return }
            await withTaskGroup(of: (UUID, Double?).self) { group in
                for i in intentions {
                    guard i.weekOf != nil else { continue }
                    group.addTask {
                        let h = await backend.getIntentionHoursDone(id: i.id, week: i.weekOf)
                        return (i.id, h)
                    }
                }
                for await (id, hours) in group {
                    guard let h = hours else { continue }
                    await MainActor.run {
                        // Surface the live total via a small JS patch so cards re-render.
                        self.callJS("window._intentionHoursDoneResult && window._intentionHoursDoneResult({ id: '\(id.uuidString)', hours_done: \(h) })")
                    }
                }
            }
        }
    }

    private func handleGetIntention(id: UUID) {
        Task {
            let intention = await IntentionStore.shared.intention(id: id)
            await MainActor.run {
                if let i = intention {
                    self.emitIntentionDetail(Self.intentionToDict(i))
                } else {
                    self.emitIntentionDetail(["error": "Focus mode not found"])
                }
            }
        }
    }

    /// FIX-7: Fetch goals for an arbitrary past week (ISO Monday date)
    /// and push them into the dashboard's cache via `window._intentionsForWeek`.
    /// The dashboard merges these into `_intentionsCache` so the Plan history view
    /// can render past weeks even after the active set has rotated.
    private func handleGetIntentionsForWeek(week: String) {
        guard let backend = appDelegate?.backendClient else { return }
        Task {
            guard let intentions = await backend.getIntentions(includeDeleted: false, week: week) else {
                await MainActor.run {
                    self.callJS("window._intentionsForWeek && window._intentionsForWeek([])")
                }
                return
            }
            let items = intentions.map { Self.intentionToDict($0) }
            await MainActor.run {
                let json = self.jsonString(items)
                self.callJS("window._intentionsForWeek && window._intentionsForWeek(\(json))")
            }
        }
    }

    /// Spec 3 (May 2026): single source of truth for shaping an Intention into the
    /// dashboard-facing dict. Includes strictness + pending change + budget-prep.
    static func intentionToDict(_ i: Intention) -> [String: Any] {
        var dict: [String: Any] = [
            "id": i.id.uuidString,
            "name": i.name,
            "description": i.description ?? "",
            "color_hex": i.colorHex ?? "",
            "icon": i.icon ?? "",
            "mac_websites": i.macWebsites,
            "mac_bundle_ids": i.macBundleIds,
            "version": i.version,
            "created_at": ISO8601DateFormatter().string(from: i.createdAt),
            "updated_at": ISO8601DateFormatter().string(from: i.updatedAt),
            // Spec 3:
            "strictness_preset": i.strictnessPreset.rawValue,
            "weekly_budget_hours": i.weeklyBudgetHours as Any? ?? NSNull(),
            "budget_enforcement": i.budgetEnforcement as Any? ?? NSNull(),
        ]
        if let pc = i.pendingStrictnessChange {
            dict["pending_strictness_change"] = [
                "to_preset": pc.toPreset.rawValue,
                "takes_effect_at": ISO8601DateFormatter().string(from: pc.takesEffectAt)
            ] as [String: Any]
        }
        // May 2026 prototype → production (weekly-goal vocab):
        dict["outcome"] = i.outcome ?? ""
        dict["status"] = i.status.rawValue
        dict["weekly_target_hours"] = i.weeklyTargetHours as Any? ?? NSNull()
        dict["intent_text"] = i.intentText ?? ""
        dict["ai_scoring_enabled"] = i.aiScoringEnabled
        dict["allow_websites"] = i.allowWebsites
        dict["allow_bundle_ids"] = i.allowBundleIds
        dict["monthly_goal_id"] = i.monthlyGoalId?.uuidString as Any? ?? NSNull()
        dict["week_of"] = i.weekOf as Any? ?? NSNull()
        return dict
    }

    /// May 2026 prototype → production: dashboard-facing dict for a MonthlyGoal.
    static func monthlyGoalToDict(_ g: MonthlyGoal) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = [
            "id": g.id.uuidString,
            "title": g.title,
            "outcome": g.outcome ?? "",
            "color_hex": g.colorHex ?? "",
            "month_of": g.monthOf,
            "status": g.status.rawValue,
            "version": g.version,
            "created_at": iso.string(from: g.createdAt),
            "updated_at": iso.string(from: g.updatedAt),
        ]
        if let d2 = g.deletedAt {
            d["deleted_at"] = iso.string(from: d2)
        }
        return d
    }

    private func handleCreateIntention(_ body: [String: Any]) {
        Task {
            let statusRaw = body["status"] as? String ?? "planned"
            let monthlyGoalId: UUID? = (body["monthly_goal_id"] as? String).flatMap(UUID.init)
            var payload = IntentionCreatePayload(
                name: body["name"] as? String ?? "Untitled",
                description: body["description"] as? String,
                colorHex: body["color_hex"] as? String,
                icon: body["icon"] as? String,
                macWebsites: body["mac_websites"] as? [String] ?? [],
                macBundleIds: body["mac_bundle_ids"] as? [String] ?? [],
                iosAppTokensB64: nil,
                iosCategoryTokensB64: nil
            )
            payload.outcome = body["outcome"] as? String
            payload.status = GoalStatus(rawValue: statusRaw) ?? .planned
            payload.weeklyTargetHours = body["weekly_target_hours"] as? Double
            payload.intentText = body["intent_text"] as? String
            if let ai = body["ai_scoring_enabled"] as? Bool { payload.aiScoringEnabled = ai }
            payload.allowWebsites = body["allow_websites"] as? [String] ?? []
            payload.allowBundleIds = body["allow_bundle_ids"] as? [String] ?? []
            payload.monthlyGoalId = monthlyGoalId
            payload.weekOf = body["week_of"] as? String
            do {
                let created = try await IntentionStore.shared.create(payload)
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "created", "id": created.id.uuidString
                    ])
                }
            } catch {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "error", "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    private func handleUpdateIntention(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) else { return }
        guard let version = body["version"] as? Int else {
            emitIntentionMutationResult(["status": "error", "error": "Missing version"])
            return
        }
        Task {
            // Fetch existing for fallthrough fields not in the patch.
            guard let existing = await IntentionStore.shared.intention(id: id) else {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "error", "error": "Focus mode not found"
                    ])
                }
                return
            }
            var payload = IntentionUpdatePayload(
                name: body["name"] as? String ?? existing.name,
                description: body["description"] as? String ?? existing.description,
                colorHex: body["color_hex"] as? String ?? existing.colorHex,
                icon: body["icon"] as? String ?? existing.icon,
                macWebsites: body["mac_websites"] as? [String] ?? existing.macWebsites,
                macBundleIds: body["mac_bundle_ids"] as? [String] ?? existing.macBundleIds,
                iosAppTokensB64: existing.iosAppTokensB64,
                iosCategoryTokensB64: existing.iosCategoryTokensB64,
                version: version
            )
            // Forward weekly-goal fields (May 2026 vocab). Treat missing keys as
            // "no change" (fall back to existing), explicit nulls as "clear".
            payload.outcome = body.keys.contains("outcome")
                ? body["outcome"] as? String
                : existing.outcome
            if let statusRaw = body["status"] as? String,
               let s = GoalStatus(rawValue: statusRaw) {
                payload.status = s
            } else {
                payload.status = existing.status
            }
            payload.weeklyTargetHours = body.keys.contains("weekly_target_hours")
                ? body["weekly_target_hours"] as? Double
                : existing.weeklyTargetHours
            payload.intentText = body.keys.contains("intent_text")
                ? body["intent_text"] as? String
                : existing.intentText
            if let ai = body["ai_scoring_enabled"] as? Bool {
                payload.aiScoringEnabled = ai
            } else {
                payload.aiScoringEnabled = existing.aiScoringEnabled
            }
            payload.allowWebsites = body["allow_websites"] as? [String]
                ?? existing.allowWebsites
            payload.allowBundleIds = body["allow_bundle_ids"] as? [String]
                ?? existing.allowBundleIds
            payload.monthlyGoalId = body.keys.contains("monthly_goal_id")
                ? (body["monthly_goal_id"] as? String).flatMap(UUID.init)
                : existing.monthlyGoalId
            payload.weekOf = body.keys.contains("week_of")
                ? body["week_of"] as? String
                : existing.weekOf
            do {
                var updated = try await IntentionStore.shared.update(id: id, payload: payload)

                // Slice 9 followup of 2026-05-05 redesign: strictness goes through
                // a dedicated endpoint (PUT /intentions/{id}/strictness). Detect a
                // change from the patch and call the dedicated endpoint after the
                // base update lands. Tightening applies instantly; softening queues
                // a pending change with 24h cool-down or partner unlock.
                if let newStrictnessRaw = body["strictness_preset"] as? String,
                   let newPreset = StrictnessPreset(rawValue: newStrictnessRaw),
                   newPreset != existing.strictnessPreset {
                    do {
                        updated = try await IntentionStore.shared.updateStrictness(
                            id: id, toPreset: newPreset
                        )
                    } catch {
                        // Don't fail the whole save if strictness change errors —
                        // user already saw "Saved". Log and surface a soft warning.
                        print("strictness update failed: \(error)")
                    }
                }

                await MainActor.run {
                    // B3: if a session of THIS goal is live, re-apply enforcement
                    // so edited block/allow lists take effect immediately (the
                    // old UPDATE_PROJECT path did this via
                    // refreshActiveProjectEnforcement).
                    if self.appDelegate?.focusModeController?.currentPeriod?.intentionId == id {
                        Task { await self.appDelegate?.refreshIntentionEnforcement(for: id) }
                    }
                    self.emitIntentionMutationResult([
                        "status": "updated", "id": updated.id.uuidString,
                        "version": updated.version
                    ])
                }
            } catch BackendClient.IntentionError.versionConflict(let serverV) {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "version_conflict",
                        "server_version": serverV ?? -1
                    ])
                }
            } catch {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "error", "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    private func handleDeleteIntention(id: UUID) {
        Task {
            let ok = await IntentionStore.shared.delete(id: id)
            await MainActor.run {
                self.emitIntentionMutationResult([
                    "status": ok ? "deleted" : "error",
                    "id": id.uuidString
                ])
            }
        }
    }

    private func handleStartIntentionSession(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) else {
            emitSessionResult(["status": "refused", "reason": "Missing weekly goal id"])
            return
        }
        Task {
            // Look up intention name for local enforcement
            guard let intention = await IntentionStore.shared.intention(id: id),
                  intention.deletedAt == nil else {
                await MainActor.run {
                    self.emitSessionResult(["status": "refused", "reason": "Focus mode not found"])
                }
                return
            }
            // Optimistic local activation. Per-goal enforcement engages via the
            // focusModeController.onStateChanged fanout (B3 — no separate mirror).
            await MainActor.run {
                self.appDelegate?.focusModeController?.activate(
                    intention: intention.name,
                    intentionId: id,
                    source: .manual
                )
            }
            // Backend POST (fire-and-forget; rollback on failure)
            let result = await self.appDelegate?.backendClient?.postFocusToggle(
                action: .start, intentionId: id, triggeredBy: "mac_manual"
            )
            if result == nil {
                // Roll back local activation on backend failure
                await MainActor.run {
                    self.appDelegate?.focusModeController?.deactivate(source: .manual)
                    self.emitSessionResult([
                        "status": "error",
                        "reason": "Backend unreachable — local enforcement reverted"
                    ])
                }
                return
            }
            await MainActor.run {
                self.emitSessionResult([
                    "status": "started", "intentionId": id.uuidString,
                    "sessionId": result?.sessionId ?? ""
                ])
            }
        }
    }

    // MARK: - Goal session history (B2, June 2026)

    /// Pull-on-open + cache-fallback: reply instantly from session_history.json
    /// when present, then fetch GET /intentions/{id}/sessions live; on success
    /// refresh the cache + re-push. Receiver: window._goalSessions.
    private func handleGetGoalSessions(id: UUID) {
        if let cached = GoalSessionHistoryCache.load(intentionId: id) {
            emitGoalSessions(id: id, sessions: cached, source: "cache")
        }
        Task {
            guard let live = await self.appDelegate?.backendClient?
                .getIntentionSessions(id: id, limit: 20) else {
                // Backend unreachable — the cache push above (if any) stands.
                self.appDelegate?.postLog("⚠️ GET_GOAL_SESSIONS: live fetch failed for \(id.uuidString.prefix(8)) — cache only")
                return
            }
            GoalSessionHistoryCache.save(intentionId: id, sessions: live)
            await MainActor.run {
                self.emitGoalSessions(id: id, sessions: live, source: "live")
            }
        }
    }

    private func emitGoalSessions(id: UUID, sessions: [GoalSession], source: String) {
        guard let data = try? GoalSessionHistoryCache.wireEncoder().encode(sessions),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("window._goalSessions && window._goalSessions({ id: '\(id.uuidString.lowercased())', source: '\(source)', sessions: \(json) })")
    }

    // FIX-2 (May 2026): Drag-to-schedule creates a real calendar block.
    // The dashboard fires this when the user drags a weekly-goal card onto an hour
    // in the Today / Plan timeline. We build a single-day FocusBlock bound to the
    // goal (Intention) and add it via ScheduleManager.addBlock — which handles
    // local persistence, backend push, and recalculateState in one call.
    private func handleCreateScheduledSession(_ body: [String: Any]) {
        // FIX-13: intention_id is now optional. When null, the session is
        // standalone (no weekly-goal binding) and uses title_override + outcome.
        // We also accept title_override, outcome, ai_scoring_enabled, and
        // auto_activate_block_rules from the New Session modal.
        let intentionIdStr = body["intention_id"] as? String
        let intentionIdOpt: UUID? = intentionIdStr.flatMap { UUID(uuidString: $0) }
        let titleOverride = (body["title_override"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = (body["outcome"] as? String) ?? ""
        // ai_scoring_enabled and auto_activate_block_rules are accepted but
        // not yet wired into FocusBlock — ScheduleManager.FocusBlock doesn't
        // model per-session AI override or auto-activate rule sets. Logged
        // so future plumbing can pick them up.
        let aiScoringEnabled = body["ai_scoring_enabled"] as? Bool
        let autoActivateRules = body["auto_activate_block_rules"] as? [String] ?? []

        let startHour = body["start_hour"] as? Int ?? 9
        let startMinute = body["start_minute"] as? Int ?? 0
        var endHour = body["end_hour"] as? Int ?? (startHour + 1)
        var endMinute = body["end_minute"] as? Int ?? startMinute
        // Guard: end must be after start. If caller didn't pass an end (or passed
        // a degenerate range), default to a 1-hour duration anchored at start.
        if (endHour * 60 + endMinute) <= (startHour * 60 + startMinute) {
            endHour = min(23, startHour + 1)
            endMinute = startMinute
        }
        // Clamp end-of-day so we don't spill past 23:59.
        if endHour > 23 { endHour = 23; endMinute = 59 }

        let isoDF = DateFormatter()
        isoDF.dateFormat = "yyyy-MM-dd"
        isoDF.timeZone = TimeZone.current
        let todayStr = isoDF.string(from: Date())
        let startDateStr = (body["start_date"] as? String) ?? todayStr

        Task { [weak self] in
            guard let self = self else { return }

            // Resolve intention (if any). For standalone sessions we need a title.
            var resolvedIntention: Intention? = nil
            if let iid = intentionIdOpt {
                guard let intention = await IntentionStore.shared.intention(id: iid),
                      intention.deletedAt == nil else {
                    await MainActor.run {
                        self.callJS("window._scheduledSessionCreated && window._scheduledSessionCreated({status:'error', reason:'Weekly goal not found'})")
                    }
                    return
                }
                resolvedIntention = intention
            } else if (titleOverride ?? "").isEmpty {
                // Standalone session without a title — reject.
                await MainActor.run {
                    self.callJS("window._scheduledSessionCreated && window._scheduledSessionCreated({status:'error', reason:'Title required for standalone session'})")
                }
                return
            }

            // Map intention strictness → block intensity.
            // Strict goal → deep_work (hard block). Standard/Soft → focus_hours.
            // Standalone session (no intention) defaults to focusHours.
            let blockType: ScheduleManager.BlockType =
                resolvedIntention?.strictnessPreset == .strict ? .deepWork : .focusHours

            // Choose final block title: explicit override wins, else fall back
            // to the intention name. For standalone we've already required a
            // title above.
            let finalTitle: String = {
                if let t = titleOverride, !t.isEmpty { return t }
                return resolvedIntention?.name ?? "Session"
            }()
            let finalDescription: String = {
                if !outcome.isEmpty { return outcome }
                return resolvedIntention?.description ?? ""
            }()

            await MainActor.run {
                guard let sm = self.appDelegate?.scheduleManager else {
                    self.callJS("window._scheduledSessionCreated && window._scheduledSessionCreated({status:'error', reason:'Schedule manager unavailable'})")
                    return
                }
                let newId = UUID().uuidString
                let newBlock = ScheduleManager.FocusBlock(
                    id: newId,
                    title: finalTitle,
                    description: finalDescription,
                    startHour: startHour,
                    startMinute: startMinute,
                    endHour: endHour,
                    endMinute: endMinute,
                    blockType: blockType,
                    ignoreProfile: false,
                    intentionId: intentionIdOpt,
                    intensity: blockType
                )
                sm.addBlock(newBlock)
                self.pushScheduleUpdate()
                let aiLog = aiScoringEnabled.map { $0 ? "ai=on" : "ai=off" } ?? "ai=default"
                let rulesLog = autoActivateRules.isEmpty ? "" : " rules=\(autoActivateRules.count)"
                self.appDelegate?.postLog("📋 CREATE_SCHEDULED_SESSION: \(finalTitle) \(startHour):\(String(format: "%02d", startMinute))–\(endHour):\(String(format: "%02d", endMinute)) date=\(startDateStr) goal=\(intentionIdOpt?.uuidString ?? "nil") \(aiLog)\(rulesLog)")
                var payload: [String: Any] = [
                    "status": "ok",
                    "block_id": newId
                ]
                if let iid = intentionIdOpt {
                    payload["intention_id"] = iid.uuidString
                }
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let json = String(data: data, encoding: .utf8) {
                    self.callJS("window._scheduledSessionCreated && window._scheduledSessionCreated(\(json))")
                }
            }
        }
    }

    // MARK: - Intentions (Spec 3 — strictness control)

    private func handleUpdateIntentionStrictness(_ body: [String: Any]) {
        appDelegate?.postLog("🎯 STRICTNESS handler: body=\(body)")
        guard let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) else {
            appDelegate?.postLog("🎯 STRICTNESS handler: missing/invalid id, bailing")
            emitIntentionMutationResult(["status": "error", "error": "Missing id"])
            return
        }
        guard let toStr = body["to_preset"] as? String,
              let to = StrictnessPreset(rawValue: toStr) else {
            emitIntentionMutationResult(["status": "error", "error": "Missing to_preset"])
            return
        }
        let partnerCode = body["partner_unlock_code"] as? String
        Task {
            do {
                let updated = try await IntentionStore.shared.updateStrictness(
                    id: id, toPreset: to, partnerUnlockCode: partnerCode
                )
                appDelegate?.postLog("🎯 STRICTNESS backend OK: id=\(updated.id) preset=\(updated.strictnessPreset.rawValue) pending=\(updated.pendingStrictnessChange?.toPreset.rawValue ?? "nil")")
                await MainActor.run {
                    var payload: [String: Any] = [
                        "status": "updated",
                        "id": updated.id.uuidString,
                        "strictness_preset": updated.strictnessPreset.rawValue,
                    ]
                    if let pc = updated.pendingStrictnessChange {
                        payload["pending"] = [
                            "to_preset": pc.toPreset.rawValue,
                            "takes_effect_at": ISO8601DateFormatter().string(from: pc.takesEffectAt)
                        ] as [String: Any]
                    } else {
                        payload["pending"] = NSNull()
                    }
                    self.emitIntentionMutationResult(payload)
                }
            } catch BackendClient.StrictnessUpdateError.requiresPartnerUnlock {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "requires_partner_unlock",
                        "id": id.uuidString,
                        "to_preset": to.rawValue
                    ])
                }
            } catch BackendClient.StrictnessUpdateError.sessionInProgress {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "session_in_progress",
                        "id": id.uuidString
                    ])
                }
            } catch BackendClient.StrictnessUpdateError.requires24hCooldown {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "queued_24h",
                        "id": id.uuidString,
                        "to_preset": to.rawValue
                    ])
                }
            } catch {
                await MainActor.run {
                    self.emitIntentionMutationResult([
                        "status": "error", "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    private func handleCancelPendingStrictnessChange(id: UUID) {
        Task {
            let ok = await IntentionStore.shared.cancelPendingStrictnessChange(id: id)
            await MainActor.run {
                self.emitIntentionMutationResult([
                    "status": ok ? "pending_cancelled" : "error",
                    "id": id.uuidString
                ])
            }
        }
    }

    // MARK: - Intention emit helpers

    private func emitIntentionsList(_ items: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("window._intentionsList && window._intentionsList(\(json))")
    }

    private func emitIntentionDetail(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("window._intentionDetail && window._intentionDetail(\(json))")
    }

    private func emitIntentionMutationResult(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        callJS("window._intentionMutationResult && window._intentionMutationResult(\(json))")
    }

    // MARK: - Monthly Goals (May 2026)

    private func handleGetMonthlyGoals() {
        guard let store = appDelegate?.monthlyGoalStore else {
            emitMonthlyGoalsList([])
            return
        }
        Task {
            let goals = await store.active()
            let items = goals.map { Self.monthlyGoalToDict($0) }
            await MainActor.run { self.emitMonthlyGoalsList(items) }
        }
    }

    private func handleGetMonthlyGoal(id: UUID) {
        guard let store = appDelegate?.monthlyGoalStore else { return }
        Task {
            if let g = await store.goal(id: id) {
                let dict = Self.monthlyGoalToDict(g)
                await MainActor.run { self.emitMonthlyGoalDetail(dict) }
            } else {
                await MainActor.run { self.emitMonthlyGoalDetail(["error": "Not found"]) }
            }
        }
    }

    private func handleCreateMonthlyGoal(_ body: [String: Any]) {
        guard let store = appDelegate?.monthlyGoalStore else { return }
        let title = (body["title"] as? String) ?? "Untitled"
        let monthOf = (body["month_of"] as? String) ?? ""
        let statusRaw = (body["status"] as? String) ?? "planned"
        let payload = MonthlyGoalCreatePayload(
            title: title,
            outcome: body["outcome"] as? String,
            colorHex: body["color_hex"] as? String,
            monthOf: monthOf,
            status: GoalStatus(rawValue: statusRaw) ?? .planned
        )
        Task {
            do {
                let created = try await store.create(payload)
                let dict = Self.monthlyGoalToDict(created)
                await MainActor.run { self.emitMonthlyGoalCreated(dict) }
            } catch {
                await MainActor.run {
                    self.emitMonthlyGoalCreated(["error": "\(error)"])
                }
            }
        }
    }

    private func handleUpdateMonthlyGoal(_ body: [String: Any]) {
        guard let store = appDelegate?.monthlyGoalStore,
              let idStr = body["id"] as? String,
              let id = UUID(uuidString: idStr),
              let version = body["version"] as? Int else { return }
        let payload = MonthlyGoalUpdatePayload(
            title: (body["title"] as? String) ?? "Untitled",
            outcome: body["outcome"] as? String,
            colorHex: body["color_hex"] as? String,
            monthOf: (body["month_of"] as? String) ?? "",
            status: GoalStatus(rawValue: (body["status"] as? String) ?? "planned") ?? .planned,
            version: version
        )
        Task {
            do {
                let updated = try await store.update(id: id, payload: payload)
                let dict = Self.monthlyGoalToDict(updated)
                await MainActor.run { self.emitMonthlyGoalUpdated(dict) }
            } catch {
                await MainActor.run { self.emitMonthlyGoalUpdated(["error": "\(error)"]) }
            }
        }
    }

    private func handleDeleteMonthlyGoal(id: UUID) {
        guard let store = appDelegate?.monthlyGoalStore else { return }
        Task {
            let ok = await store.delete(id: id)
            await MainActor.run {
                self.callJS("window._monthlyGoalDeleted && window._monthlyGoalDeleted({id: '\(id.uuidString)', ok: \(ok)})")
            }
        }
    }

    private func handleLinkWeeklyToMonthly(_ body: [String: Any]) {
        guard let store = appDelegate?.intentionStore,
              let intentionIdStr = body["intention_id"] as? String,
              let intentionId = UUID(uuidString: intentionIdStr) else { return }
        let monthlyGoalId: UUID? = (body["monthly_goal_id"] as? String).flatMap { UUID(uuidString: $0) }
        Task {
            guard let i = await store.intention(id: intentionId) else { return }
            // Round-trip all fields, just patch monthly_goal_id
            let payload = IntentionUpdatePayload(
                name: i.name,
                description: i.description,
                colorHex: i.colorHex,
                icon: i.icon,
                macWebsites: i.macWebsites,
                macBundleIds: i.macBundleIds,
                iosAppTokensB64: i.iosAppTokensB64,
                iosCategoryTokensB64: i.iosCategoryTokensB64,
                version: i.version,
                outcome: i.outcome,
                status: i.status,
                weeklyTargetHours: i.weeklyTargetHours,
                intentText: i.intentText,
                aiScoringEnabled: i.aiScoringEnabled,
                allowWebsites: i.allowWebsites,
                allowBundleIds: i.allowBundleIds,
                monthlyGoalId: monthlyGoalId,
                weekOf: i.weekOf
            )
            do {
                let updated = try await store.update(id: intentionId, payload: payload)
                let dict = Self.intentionToDict(updated)
                await MainActor.run {
                    let json = self.jsonString(dict)
                    self.callJS("window._intentionUpdated && window._intentionUpdated(\(json))")
                }
            } catch {
                await MainActor.run {
                    self.callJS("window._intentionUpdated && window._intentionUpdated({error: 'link failed'})")
                }
            }
        }
    }

    // MARK: - Monthly Goals emit helpers

    private func emitMonthlyGoalsList(_ items: [[String: Any]]) {
        let json = jsonString(items)
        callJS("window._monthlyGoalsList && window._monthlyGoalsList(\(json))")
    }

    private func emitMonthlyGoalDetail(_ dict: [String: Any]) {
        let json = jsonString(dict)
        callJS("window._monthlyGoalDetail && window._monthlyGoalDetail(\(json))")
    }

    private func emitMonthlyGoalCreated(_ dict: [String: Any]) {
        let json = jsonString(dict)
        callJS("window._monthlyGoalCreated && window._monthlyGoalCreated(\(json))")
    }

    private func emitMonthlyGoalUpdated(_ dict: [String: Any]) {
        let json = jsonString(dict)
        callJS("window._monthlyGoalUpdated && window._monthlyGoalUpdated(\(json))")
    }

    // MARK: - Rules + Allowance (Rules Consolidation R2 — June 2026; "leisure pool" renamed "allowance" 2026-06-11)

    /// Wire-format dict for one rule, mirroring the backend's _rule_to_dict
    /// (snake_case keys) so the dashboard JS sees the same shape either way.
    static func ruleToDict(_ r: Rule) -> [String: Any] {
        var d: [String: Any] = [
            "id": r.id.uuidString.lowercased(),
            "target_kind": r.targetKind.rawValue,
            "target": r.target,
            "treatment": r.treatment.rawValue,
            "enabled": r.enabled,
            "created_at": Rule.isoString(r.createdAt),
            "updated_at": Rule.isoString(r.updatedAt),
        ]
        if let schedule = r.schedule {
            d["schedule"] = schedule.mapValues { $0.value }
        } else {
            d["schedule"] = NSNull()
        }
        return d
    }

    static func allowanceToDict(_ p: Allowance) -> [String: Any] {
        var d: [String: Any] = [
            "pool_date": p.poolDate,
            "base_minutes": p.baseMinutes,
            "earned_minutes": p.earnedMinutes,
            "spent_minutes": p.spentMinutes,
            "bank_minutes": p.bankMinutes,
            "earn_rate": p.earnRate,
            "bank_cap": p.bankCap,
            "available_minutes": p.availableMinutes,
        ]
        if let c = p.creditedMinutes { d["credited_minutes"] = c }
        if let dd = p.deduped { d["deduped"] = dd }
        if let s = p.spentApplied { d["spent_applied"] = s }
        return d
    }

    private func handleGetRules() {
        guard let store = appDelegate?.ruleStore else {
            emitRulesList([])
            return
        }
        Task {
            // Serve the cache instantly (offline-friendly); a background pull
            // will re-emit via .rulesDidChange once the Rules page (R3) wires
            // a listener — for now the 60s sync rhythm keeps the cache fresh.
            let rules = await store.all()
            let items = rules.map { Self.ruleToDict($0) }
            await MainActor.run { self.emitRulesList(items) }
        }
    }

    private func handleCreateRule(_ body: [String: Any]) {
        guard let store = appDelegate?.ruleStore else {
            emitRuleCreated(["success": false, "reason": "store unavailable"])
            return
        }
        guard let kindRaw = body["target_kind"] as? String,
              let kind = RuleTargetKind(rawValue: kindRaw),
              let target = body["target"] as? String, !target.isEmpty,
              let treatmentRaw = body["treatment"] as? String,
              let treatment = RuleTreatment(rawValue: treatmentRaw) else {
            emitRuleCreated(["success": false, "reason": "invalid payload"])
            return
        }
        let schedule = (body["schedule"] as? [String: Any]).map { $0.mapValues { AnyCodable($0) } }
        let enabled = (body["enabled"] as? Bool) ?? true
        let payload = RuleCreatePayload(
            targetKind: kind, target: target, treatment: treatment,
            schedule: schedule, enabled: enabled
        )
        Task {
            do {
                let created = try await store.create(payload)
                var dict = Self.ruleToDict(created)
                dict["success"] = true
                await MainActor.run { self.emitRuleCreated(dict) }
            } catch BackendClient.RuleError.duplicate {
                await MainActor.run {
                    self.emitRuleCreated(["success": false, "reason": "duplicate"])
                }
            } catch {
                await MainActor.run {
                    self.emitRuleCreated(["success": false, "reason": "\(error.localizedDescription)"])
                }
            }
        }
    }

    // MARK: - Screen-permission bridge (onboarding just-in-time ask)

    private func emitScreenPermissionStatus() {
        let granted = CGPreflightScreenCaptureAccess()
        callJS("window._screenPermissionStatus && window._screenPermissionStatus({ granted: \(granted) })")
    }

    private func handleRequestScreenPermission() {
        if CGPreflightScreenCaptureAccess() {
            emitScreenPermissionStatus()
            return
        }
        // Triggers the one-time system prompt AND registers the app in the
        // Screen Recording list. Returns current grant state immediately.
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            // The system prompt only fires once per install; afterwards the user
            // must flip the toggle manually — take them straight to the pane.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        emitScreenPermissionStatus()
    }

    private func handleUpdateRule(_ body: [String: Any]) {
        guard let store = appDelegate?.ruleStore,
              let idStr = body["id"] as? String,
              let id = UUID(uuidString: idStr) else {
            emitRuleUpdated(["success": false, "reason": "invalid payload"])
            return
        }
        // Partial update: only keys present in the body are sent to the
        // backend. Send clear_schedule=true to null a schedule (a bare
        // schedule:null is treated as omitted, matching the backend contract).
        let payload = RuleUpdatePayload(
            targetKind: (body["target_kind"] as? String).flatMap { RuleTargetKind(rawValue: $0) },
            target: body["target"] as? String,
            treatment: (body["treatment"] as? String).flatMap { RuleTreatment(rawValue: $0) },
            schedule: (body["schedule"] as? [String: Any]).map { $0.mapValues { AnyCodable($0) } },
            clearSchedule: (body["clear_schedule"] as? Bool) == true ? true : nil,
            enabled: body["enabled"] as? Bool
        )
        Task {
            // R4(d): loosening a rule (disable a 🚫, demote treatment) is
            // partner-gated under Strict Mode. Tightening passes untouched.
            if let current = await store.rule(id: id),
               Self.isLooseningRuleUpdate(current: current, payload: payload),
               blockRulesLockEngaged() {
                refuseLockedRuleMutation("UPDATE_RULE(loosening) for \(idStr)")
                await MainActor.run {
                    self.emitRuleUpdated(["success": false, "reason": "strict_mode_locked", "id": idStr])
                }
                return
            }
            do {
                let updated = try await store.update(id: id, payload: payload)
                var dict = Self.ruleToDict(updated)
                dict["success"] = true
                await MainActor.run { self.emitRuleUpdated(dict) }
            } catch BackendClient.RuleError.duplicate {
                await MainActor.run {
                    self.emitRuleUpdated(["success": false, "reason": "duplicate", "id": idStr])
                }
            } catch BackendClient.RuleError.notFound {
                await MainActor.run {
                    self.emitRuleUpdated(["success": false, "reason": "not found", "id": idStr])
                }
            } catch {
                await MainActor.run {
                    self.emitRuleUpdated(["success": false, "reason": "\(error.localizedDescription)", "id": idStr])
                }
            }
        }
    }

    private func handleDeleteRule(id: UUID) {
        guard let store = appDelegate?.ruleStore else {
            emitRuleDeleted(["success": false, "reason": "store unavailable"])
            return
        }
        Task {
            // R4(d): deleting a 🚫 rule (even a disabled one — conservative,
            // matching the JS gate) is loosening — partner-gated under Strict
            // Mode. Deleting ⏳/✅ rules is tightening-or-neutral and passes.
            if let current = await store.rule(id: id),
               current.treatment == .blocked,
               blockRulesLockEngaged() {
                refuseLockedRuleMutation("DELETE_RULE(blocked) for \(id)")
                await MainActor.run {
                    self.emitRuleDeleted([
                        "success": false,
                        "reason": "strict_mode_locked",
                        "id": id.uuidString.lowercased(),
                    ])
                }
                return
            }
            let ok = await store.delete(id: id)
            await MainActor.run {
                self.emitRuleDeleted([
                    "success": ok,
                    "id": id.uuidString.lowercased(),
                ])
            }
        }
    }

    private func handleGetAllowance() {
        guard let store = appDelegate?.ruleStore else {
            emitAllowance(["error": "store unavailable"])
            return
        }
        Task {
            // refreshAllowance() returns the fresh server allowance, falling
            // back to the stale local cache when offline; nil = never synced.
            if let allowance = await store.refreshAllowance() {
                let dict = Self.allowanceToDict(allowance)
                await MainActor.run { self.emitAllowance(dict) }
            } else {
                await MainActor.run { self.emitAllowance(["error": "unavailable"]) }
            }
        }
    }

    private func handleUpdateAllowanceConfig(_ body: [String: Any]) {
        guard let store = appDelegate?.ruleStore else {
            emitAllowance(["error": "store unavailable"])
            return
        }
        let base = body["base_minutes"] as? Int
        let rate = body["earn_rate"] as? Int
        let cap = body["bank_cap"] as? Int
        Task {
            // updateAllowanceConfig returns nil on server rejection (422
            // outside ranges) or network failure — surface as an error so the
            // editor shows "couldn't save" instead of silently pretending.
            if let allowance = await store.updateAllowanceConfig(
                baseMinutes: base, earnRate: rate, bankCap: cap
            ) {
                var dict = Self.allowanceToDict(allowance)
                dict["config_saved"] = true
                await MainActor.run { self.emitAllowance(dict) }
            } else {
                await MainActor.run {
                    self.emitAllowance(["error": "config update failed"])
                }
            }
        }
    }

    // MARK: - Rules emit helpers

    private func emitRulesList(_ items: [[String: Any]]) {
        let json = jsonString(items)
        callJS("window._rulesList && window._rulesList(\(json))")
    }

    private func emitRuleCreated(_ dict: [String: Any]) {
        let json = jsonString(dict)
        callJS("window._ruleCreated && window._ruleCreated(\(json))")
    }

    private func emitRuleUpdated(_ dict: [String: Any]) {
        let json = jsonString(dict)
        callJS("window._ruleUpdated && window._ruleUpdated(\(json))")
    }

    private func emitRuleDeleted(_ dict: [String: Any]) {
        let json = jsonString(dict)
        callJS("window._ruleDeleted && window._ruleDeleted(\(json))")
    }

    private func emitAllowance(_ dict: [String: Any]) {
        let json = jsonString(dict)
        callJS("window._allowance && window._allowance(\(json))")
    }

    /// JSON-encode dict/array as String. Falls back to "null" on failure.
    private func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

}

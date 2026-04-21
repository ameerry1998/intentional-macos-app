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

    /// Debug monitor window (legacy SwiftUI views)
    private var debugMonitorWindow: LegacyMonitorWindow?

    /// Cache browser icons so we don't re-extract every poll cycle
    private var iconCache: [String: String] = [:]
    private let iconCacheLock = NSLock()

    /// Last JSON pushed for _extensionStatusResult. ~89 KB per push (icons as base64);
    /// the 5s poll re-sends it continuously. Skip when identical to save bridge cost
    /// (Swift→WebContent marshalling + JSC parse) that blocks scroll compositing.
    private var lastExtensionStatusJSON: String?

    /// Cheap fingerprint of the browser status payload (connectedCount + per-browser
    /// bundleId/isEnabled/hasExtension). Used to short-circuit the 89 KB JSON
    /// serialization when nothing material changed between 5s polls. Guarded by
    /// `extensionStatusLock` so the background serializer can read it without
    /// round-tripping to main.
    private var lastExtensionStatusSignature: String?
    private let extensionStatusLock = NSLock()

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

        // Load appropriate page
        loadCurrentPage()
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
        if let data = try? JSONSerialization.data(withJSONObject: state),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._scheduleStateResult && window._scheduleStateResult(\(json))")
        }
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

    // MARK: - Debug Monitor

    func showDebugMonitor() {
        print("🚨 ACTIVATE: MainWindow.showDebugMonitor")
        if debugMonitorWindow == nil {
            debugMonitorWindow = LegacyMonitorWindow()
        }
        debugMonitorWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        case "GET_EXTENSION_STATUS":
            handleGetExtensionStatus()

        case "GET_DASHBOARD_DATA":
            handleGetDashboardData()

        case "GET_SETTINGS":
            handleGetSettings()

        case "TEST_CONTENT_SAFETY":
            appDelegate?.contentSafetyMonitor?.triggerTestDetection()

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

        case "OPEN_EXTENSIONS_PAGE":
            if let urlStr = body["url"] as? String, let url = URL(string: urlStr) {
                if let bundleId = body["bundleId"] as? String,
                   let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    let config = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }

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

        case "GET_EARNED_STATUS":
            handleGetEarnedStatus()

        case "REQUEST_EXTRA_TIME":
            handleRequestExtraTime(body)

        case "VERIFY_EXTRA_TIME_CODE":
            handleVerifyExtraTimeCode(body)

        case "GET_BLOCK_ASSESSMENTS":
            handleGetBlockAssessments(body)

        case "SET_CALENDAR_ZOOM":
            if let zoom = body["zoom"] as? Int {
                appDelegate?.scheduleManager?.setCalendarZoom(zoom)
            }

        case "SET_ENFORCEMENT_SETTINGS":
            handleSetEnforcementSettings(body)

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

        case "SAVE_IF_THEN_PLAN":
            if let planIndex = body["planIndex"] as? Int {
                UserDefaults.standard.set(planIndex, forKey: "defaultIfThenPlan")
            }

        case "SAVE_INTENTIONAL_MODE":
            handleSaveIntentionalMode(body)

        case "GET_BEDTIME_SETTINGS":
            handleGetBedtimeSettings()

        case "SAVE_BEDTIME_SETTINGS":
            if let body = message.body as? [String: Any] {
                handleSaveBedtimeSettings(body)
            }

        case "GET_BLOCKING_PROFILES":
            handleGetBlockingProfiles()

        case "CREATE_BLOCKING_PROFILE":
            if let body = message.body as? [String: Any] {
                handleCreateBlockingProfile(body)
            }

        case "UPDATE_BLOCKING_PROFILE":
            if let body = message.body as? [String: Any] {
                handleUpdateBlockingProfile(body)
            }

        case "DELETE_BLOCKING_PROFILE":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleDeleteBlockingProfile(id: id)
            }

        // NOTE: START_PROJECT_SESSION is wired in a later task (#15).
        case "GET_PROJECTS":
            handleGetProjects()

        case "GET_PROJECT_DETAIL":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleGetProjectDetail(id: id)
            }

        case "CREATE_PROJECT":
            if let body = message.body as? [String: Any] {
                handleCreateProject(body)
            }

        case "UPDATE_PROJECT":
            if let body = message.body as? [String: Any] {
                handleUpdateProject(body)
            }

        case "DELETE_PROJECT":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String,
               let id = UUID(uuidString: idStr) {
                handleDeleteProject(id: id)
            }

        case "PROMOTE_LEARNED_SITE":
            if let body = message.body as? [String: Any] {
                handlePromoteLearnedSite(body)
            }

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

            // 6. Broadcast ONBOARDING_SYNC to all connected extensions
            await MainActor.run {
                self.broadcastOnboardingToExtensions(
                    platforms: platforms,
                    partnerEmail: partnerEmail,
                    partnerName: partnerName,
                    lockMode: lockMode
                )
            }

            // 7. Respond to JS with success
            await MainActor.run {
                self.callJS("window._onboardingSaveResult && window._onboardingSaveResult({ success: true })")
            }
        }
    }

    // MARK: - Extension Status

    private func handleGetExtensionStatus() {
        // Run heavy filesystem/icon work off the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let statuses = NativeMessagingSetup.shared.getBrowserStatus()
            let connectedCount = self.appDelegate?.socketRelayServer?.connectionCount ?? 0

            // Signature check: skip icon rasterization + 89 KB JSON serialization when
            // nothing material changed. Must match on every field the webview renders
            // differently on.
            let signature = "\(connectedCount)|" + statuses
                .map { "\($0.bundleId):\($0.isEnabled ? 1 : 0):\($0.hasExtension ? 1 : 0):\($0.extensionId ?? "")" }
                .joined(separator: "|")
            self.extensionStatusLock.lock()
            let signatureMatches = (self.lastExtensionStatusSignature == signature)
            self.extensionStatusLock.unlock()
            if signatureMatches { return }

            var browsersArray: [[String: Any]] = []
            for browser in statuses {
                var entry: [String: Any] = [
                    "name": browser.name,
                    "bundleId": browser.bundleId,
                    "hasExtension": browser.hasExtension,
                    "isEnabled": browser.isEnabled,
                    "extensionPageUrl": browser.extensionPageUrl
                ]
                if let extId = browser.extensionId {
                    entry["extensionId"] = extId
                }
                // Use cached icon or extract once
                self.iconCacheLock.lock()
                let cached = self.iconCache[browser.bundleId]
                self.iconCacheLock.unlock()
                if let cached = cached {
                    entry["iconDataUrl"] = cached
                } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleId) {
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    // Rasterize into a 64x64 (2x retina) bitmap. NSImage.size is just a hint —
                    // tiffRepresentation would otherwise serialize the 1024x1024 master rep,
                    // producing ~2MB base64 strings per icon and freezing the WebView.
                    if let bitmap = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: 64, pixelsHigh: 64,
                        bitsPerSample: 8, samplesPerPixel: 4,
                        hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 32
                    ) {
                        bitmap.size = NSSize(width: 32, height: 32)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                        icon.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32),
                                  from: .zero, operation: .copy, fraction: 1.0)
                        NSGraphicsContext.restoreGraphicsState()
                        if let pngData = bitmap.representation(using: .png, properties: [:]) {
                            let dataUrl = "data:image/png;base64,\(pngData.base64EncodedString())"
                            self.iconCacheLock.lock()
                            self.iconCache[browser.bundleId] = dataUrl
                            self.iconCacheLock.unlock()
                            entry["iconDataUrl"] = dataUrl
                        }
                    }
                }
                browsersArray.append(entry)
            }

            let result: [String: Any] = [
                "browsers": browsersArray,
                "connectedCount": connectedCount
            ]

            // .sortedKeys is required for dedup — Swift [String: Any] has non-deterministic
            // iteration order, so unsorted serialization produces different byte strings
            // for semantically-identical payloads and the dedup check never matches.
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                self.extensionStatusLock.lock()
                self.lastExtensionStatusSignature = signature
                self.extensionStatusLock.unlock()
                DispatchQueue.main.async {
                    if self.lastExtensionStatusJSON == json { return }
                    self.lastExtensionStatusJSON = json
                    self.callJS("window._extensionStatusResult && window._extensionStatusResult(\(json))")
                }
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

        // Earned browse state
        var earnedBrowse: [String: Any] = [:]
        if let mgr = appDelegate?.earnedBrowseManager {
            mgr.ensureToday()
            var savedSettings: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: settingsFileURL.path),
               let fileData = try? Data(contentsOf: settingsFileURL),
               let json = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] {
                savedSettings = json
            }
            let partnerEmail = (savedSettings["partnerEmail"] as? String) ?? ""
            let partnerName = (savedSettings["partnerName"] as? String) ?? ""
            earnedBrowse = [
                "earnedMinutes": mgr.earnedMinutes,
                "usedMinutes": mgr.usedMinutes,
                "availableMinutes": mgr.availableMinutes,
                "poolExhausted": mgr.isPoolExhausted,
                "hasPartner": !partnerEmail.isEmpty,
                "partnerName": partnerName.isEmpty ? "your partner" : partnerName
            ]
        }

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

    // MARK: - Extension Sync

    private func broadcastOnboardingToExtensions(
        platforms: [String: Any],
        partnerEmail: String?,
        partnerName: String?,
        lockMode: String
    ) {
        let ytSettings = platforms["youtube"] as? [String: Any] ?? [:]
        let igSettings = platforms["instagram"] as? [String: Any] ?? [:]
        let fbSettings = platforms["facebook"] as? [String: Any] ?? [:]

        // Build per-platform sub-dicts separately to help Swift type-checker
        let ytSync: [String: Any] = [
            "onboardingComplete": true,
            "enabled": ytSettings["enabled"] ?? true,
            "blockShorts": ytSettings["blockShorts"] ?? true,
            "blockMode": ytSettings["blockMode"] ?? "hide"
        ]
        let igSync: [String: Any] = [
            "onboardingComplete": true,
            "enabled": igSettings["enabled"] ?? true,
            "blockReels": igSettings["blockReels"] ?? true,
            "blockExplore": igSettings["blockExplore"] ?? true,
            "nsfwFilter": igSettings["nsfwFilter"] ?? true
        ]
        let fbSync: [String: Any] = [
            "onboardingComplete": true,
            "enabled": fbSettings["enabled"] ?? true,
            "blockWatch": fbSettings["blockWatch"] ?? true,
            "blockReels": fbSettings["blockReels"] ?? true,
            "blockMarketplace": fbSettings["blockMarketplace"] ?? false,
            "blockGaming": fbSettings["blockGaming"] ?? true,
            "blockStories": fbSettings["blockStories"] ?? false,
            "blockSponsored": fbSettings["blockSponsored"] ?? true,
            "blockSuggested": fbSettings["blockSuggested"] ?? true,
            "scrollLimit": fbSettings["scrollLimit"] ?? 50,
            "friendsOnly": fbSettings["friendsOnly"] ?? false
        ]
        let mpp: [String: Any] = (ytSettings["maxPerPeriod"] as? [String: Any]) ?? [
            "enabled": false, "minutes": 20, "periodHours": 1
        ]

        let message: [String: Any] = [
            "type": "ONBOARDING_SYNC",
            "platforms": platforms,
            "maxPerPeriod": mpp,
            "blockedCategories": (ytSettings["categories"] as? [String]) ?? [String](),
            "partnerEmail": partnerEmail ?? NSNull(),
            "partnerName": partnerName ?? NSNull(),
            "lockMode": lockMode,
            "settingsLocked": lockMode != "none",
            "youtube": ytSync,
            "instagram": igSync,
            "facebook": fbSync
        ]

        appDelegate?.socketRelayServer?.broadcastToAll(message)
        appDelegate?.postLog("🌐 ONBOARDING_SYNC broadcast to \(appDelegate?.socketRelayServer?.connectionCount ?? 0) extension(s)")
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

        // Intentional Mode settings
        let imController = appDelegate?.intentionalModeController
        result["intentionalModeEnabled"] = imController?.isEnabled ?? false
        result["intentionalModeSchedule"] = imController?.schedule.rawValue ?? "always"
        result["intentionalModeGracePeriod"] = imController?.gracePeriodMinutes ?? 3
        if let cs = imController?.customSchedule {
            result["intentionalModeCustomSchedule"] = [
                "weekdayStartHour": cs.weekdayStartHour,
                "weekdayStartMinute": cs.weekdayStartMinute,
                "weekdayEndHour": cs.weekdayEndHour,
                "weekdayEndMinute": cs.weekdayEndMinute,
                "weekendEnabled": cs.weekendEnabled,
                "weekendStartHour": cs.weekendStartHour,
                "weekendStartMinute": cs.weekendStartMinute,
                "weekendEndHour": cs.weekendEndHour,
                "weekendEndMinute": cs.weekendEndMinute
            ] as [String: Any]
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
        }

        // Update FocusMonitor with always-relevant sites whitelist
        if let sites = alwaysRelevantSites {
            appDelegate?.focusMonitor?.alwaysRelevantHostnames = Set(sites.map { $0.lowercased() })
            appDelegate?.postLog("👁️ Updated always-relevant sites: \(sites)")
        }

        broadcastSettingsToExtensions(settings)
        callJS("window._saveSettingsResult && window._saveSettingsResult({ success: true })")
        appDelegate?.postLog("💾 SAVE_SETTINGS: Settings saved and broadcast")

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

    // MARK: - Broadcast Settings to Extensions

    private func broadcastSettingsToExtensions(_ settings: [String: Any]) {
        var message: [String: Any] = ["type": "SETTINGS_SYNC"]
        // Forward all settings fields to extensions
        for (key, value) in settings {
            message[key] = value
        }
        appDelegate?.socketRelayServer?.broadcastToAll(message)
        appDelegate?.postLog("🌐 SETTINGS_SYNC broadcast to \(appDelegate?.socketRelayServer?.connectionCount ?? 0) extension(s)")
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

                // 6. Broadcast actual lock state to extensions
                let lockSync: [String: Any] = [
                    "type": "SETTINGS_SYNC",
                    "lockMode": actualLockMode,
                    "settingsLocked": actualLockMode != "none",
                    "partnerEmail": partnerEmail,
                    "partnerName": partnerName
                ]
                self.appDelegate?.socketRelayServer?.broadcastToAll(lockSync)
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

                // 5. Broadcast to extensions
                let lockSync: [String: Any] = [
                    "type": "SETTINGS_SYNC",
                    "lockMode": "none",
                    "settingsLocked": false,
                    "partnerEmail": "",
                    "partnerName": ""
                ]
                self.appDelegate?.socketRelayServer?.broadcastToAll(lockSync)
                self.appDelegate?.postLog("🔒 REMOVE_PARTNER: done, removed=\(removed)")
            }
        }
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
        guard let controller = appDelegate?.intentionalModeController else { return }

        let enabled = body["enabled"] as? Bool ?? false
        let scheduleRaw = body["schedule"] as? String ?? "always"
        let grace = body["gracePeriodMinutes"] as? Int ?? 3

        controller.isEnabled = enabled
        controller.schedule = IntentionalModeController.Schedule(rawValue: scheduleRaw) ?? .always
        controller.gracePeriodMinutes = grace

        if let custom = body["customSchedule"] as? [String: Any] {
            controller.customSchedule = IntentionalModeController.CustomSchedule(
                weekdayStartHour: custom["weekdayStartHour"] as? Int ?? 8,
                weekdayStartMinute: custom["weekdayStartMinute"] as? Int ?? 0,
                weekdayEndHour: custom["weekdayEndHour"] as? Int ?? 18,
                weekdayEndMinute: custom["weekdayEndMinute"] as? Int ?? 0,
                weekendEnabled: custom["weekendEnabled"] as? Bool ?? false,
                weekendStartHour: custom["weekendStartHour"] as? Int ?? 9,
                weekendStartMinute: custom["weekendStartMinute"] as? Int ?? 0,
                weekendEndHour: custom["weekendEndHour"] as? Int ?? 17,
                weekendEndMinute: custom["weekendEndMinute"] as? Int ?? 0
            )
        }

        controller.saveSettings()
        controller.recalculateState()
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

        // 5. Broadcast reset to connected extensions
        let resetMessage: [String: Any] = [
            "type": "SETTINGS_RESET",
            "lockMode": "none",
            "settingsLocked": false
        ]
        appDelegate?.socketRelayServer?.broadcastToAll(resetMessage)
        appDelegate?.postLog("🗑️ Reset broadcast to \(appDelegate?.socketRelayServer?.connectionCount ?? 0) extension(s)")

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
        if let data = try? JSONSerialization.data(withJSONObject: state),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._scheduleStateResult && window._scheduleStateResult(\(json))")
        }
    }

    private func handleSetFocusEnabled(_ body: [String: Any]) {
        guard let enabled = body["enabled"] as? Bool else { return }
        appDelegate?.scheduleManager?.setEnabled(enabled)
        appDelegate?.socketRelayServer?.broadcastScheduleSync()
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
            } else if dict["isFree"] as? Bool == true {
                blockType = .freeTime
            } else {
                blockType = .focusHours
            }
            let ignoreProfile = dict["ignoreProfile"] as? Bool ?? false
            return ScheduleManager.FocusBlock(
                id: dict["id"] as? String ?? UUID().uuidString,
                title: title,
                description: dict["description"] as? String ?? "",
                startHour: startHour,
                startMinute: startMinute,
                endHour: endHour,
                endMinute: endMinute,
                blockType: blockType,
                ignoreProfile: ignoreProfile
            )
        }

        appDelegate?.scheduleManager?.setTodaySchedule(goals: goals, dailyPlan: dailyPlan, blocks: blocks)
        appDelegate?.socketRelayServer?.broadcastScheduleSync()
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
                "goals": schedule.goals,
                "dailyPlan": schedule.dailyPlan
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
    }

    // MARK: - Blocking Profile Handlers

    private func handleGetBlockingProfiles() {
        let profiles = appDelegate?.blockingProfileManager?.profiles ?? []
        if let data = try? JSONEncoder().encode(profiles),
           let jsonStr = String(data: data, encoding: .utf8) {
            callJS("window.onBlockingProfiles && window.onBlockingProfiles(\(jsonStr))")
        }
    }

    private func handleCreateBlockingProfile(_ body: [String: Any]) {
        let name = body["name"] as? String ?? "New Profile"
        let domains = body["domains"] as? [String] ?? []
        let apps = body["appBundleIds"] as? [String] ?? []
        appDelegate?.blockingProfileManager?.createProfile(name: name, domains: domains, appBundleIds: apps)
        handleGetBlockingProfiles()
    }

    private func handleUpdateBlockingProfile(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) else { return }
        appDelegate?.blockingProfileManager?.updateProfile(
            id: id,
            name: body["name"] as? String,
            domains: body["domains"] as? [String],
            appBundleIds: body["appBundleIds"] as? [String],
            alwaysActive: body["alwaysActive"] as? Bool
        )
        // Re-apply always-active enforcement after profile change
        appDelegate?.applyAlwaysActiveProfiles()
        handleGetBlockingProfiles()
    }

    private func handleDeleteBlockingProfile(id: UUID) {
        Task {
            if let store = appDelegate?.projectStore {
                let referencing = await store.projectsReferencing(blocklistId: id)
                if !referencing.isEmpty {
                    let names = referencing.map { $0.name }
                    await MainActor.run {
                        let namesJSON = (try? String(data: JSONSerialization.data(withJSONObject: names), encoding: .utf8)) ?? "[]"
                        self.callJS("window.onBlockingProfileDeleteRefused && window.onBlockingProfileDeleteRefused({ id: '\(id.uuidString)', referencedBy: \(namesJSON) })")
                    }
                    return
                }
            }
            await MainActor.run {
                _ = self.appDelegate?.blockingProfileManager?.deleteProfile(id: id)
                self.handleGetBlockingProfiles()
            }
        }
    }

    // MARK: - Projects Handlers

    private func handleGetProjects() {
        Task {
            guard let store = appDelegate?.projectStore else {
                await MainActor.run {
                    self.callJS("window.onProjectsList && window.onProjectsList([])")
                }
                return
            }
            let summaries = await store.listSummary()
            await MainActor.run {
                if let data = try? Self.projectsJSONEncoder().encode(summaries),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    self.callJS("window.onProjectsList && window.onProjectsList(\(jsonStr))")
                }
            }
        }
    }

    private func handleGetProjectDetail(id: UUID) {
        Task {
            guard let store = appDelegate?.projectStore else { return }
            guard let project = await store.get(id: id) else {
                await MainActor.run {
                    self.callJS("window.onProjectDetail && window.onProjectDetail(null)")
                }
                return
            }
            await MainActor.run {
                self.emitProjectDetail(project)
            }
        }
    }

    private func handleCreateProject(_ body: [String: Any]) {
        let name = body["name"] as? String ?? "New Project"
        let intention = body["intention"] as? String ?? ""
        let allowSearchEngines = body["allowSearchEngines"] as? Bool ?? true
        let allowed = Self.decodeHostItems(body["allowed"] as? [[String: Any]] ?? [])
        let blocklistIds = (body["blocklistIds"] as? [String] ?? []).compactMap(UUID.init(uuidString:))

        Task {
            guard let store = appDelegate?.projectStore else { return }
            let project = await store.create(
                name: name,
                intention: intention,
                allowed: allowed,
                blocklistIds: blocklistIds,
                allowSearchEngines: allowSearchEngines
            )
            await MainActor.run {
                self.emitProjectDetail(project)
            }
        }
    }

    private func handleUpdateProject(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) else { return }
        let patchDict = body["patch"] as? [String: Any] ?? [:]

        var patch = ProjectPatch()
        patch.name = patchDict["name"] as? String
        patch.intention = patchDict["intention"] as? String
        patch.accent = patchDict["accent"] as? String
        patch.allowSearchEnginesForThisProject = patchDict["allowSearchEngines"] as? Bool
        if let allowedRaw = patchDict["allowed"] as? [[String: Any]] {
            patch.allowed = Self.decodeHostItems(allowedRaw)
        }
        if let idsRaw = patchDict["blocklistIds"] as? [String] {
            patch.blocklistIds = idsRaw.compactMap(UUID.init(uuidString:))
        }

        Task {
            guard let store = appDelegate?.projectStore else { return }
            guard let project = await store.update(id: id, patch: patch) else {
                await MainActor.run {
                    self.callJS("window.onProjectDetail && window.onProjectDetail(null)")
                }
                return
            }
            await MainActor.run {
                self.emitProjectDetail(project)
            }
        }
    }

    private func handleDeleteProject(id: UUID) {
        Task {
            guard let store = appDelegate?.projectStore else { return }
            _ = await store.delete(id: id)
            let summaries = await store.listSummary()
            await MainActor.run {
                if let data = try? Self.projectsJSONEncoder().encode(summaries),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    self.callJS("window.onProjectsList && window.onProjectsList(\(jsonStr))")
                }
            }
        }
    }

    private func handlePromoteLearnedSite(_ body: [String: Any]) {
        guard let idStr = body["id"] as? String,
              let id = UUID(uuidString: idStr),
              let host = body["host"] as? String else { return }

        Task {
            guard let store = appDelegate?.projectStore else { return }
            _ = await store.promoteLearnedSite(projectId: id, host: host)
            guard let project = await store.get(id: id) else { return }
            await MainActor.run {
                self.emitProjectDetail(project)
            }
        }
    }

    // MARK: - Projects helpers

    private static func projectsJSONEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private static func decodeHostItems(_ raw: [[String: Any]]) -> [HostItem] {
        raw.compactMap { dict -> HostItem? in
            guard let kindRaw = dict["kind"] as? String,
                  let kind = HostKind(rawValue: kindRaw),
                  let value = dict["value"] as? String else { return nil }
            let idStr = dict["id"] as? String
            let id = idStr.flatMap(UUID.init(uuidString:)) ?? UUID()
            return HostItem(id: id, kind: kind, value: value, note: dict["note"] as? String)
        }
    }

    private func emitProjectDetail(_ project: Project) {
        if let data = try? Self.projectsJSONEncoder().encode(project),
           let jsonStr = String(data: data, encoding: .utf8) {
            self.callJS("window.onProjectDetail && window.onProjectDetail(\(jsonStr))")
        }
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
        let focusStats = appDelegate?.earnedBrowseManager?.blockFocusStats ?? [:]

        var totalWorkMinutes = 0
        var completedWorkMinutes = 0
        var breakMinutes = 0
        var totalFocusScore = 0
        var scoredBlockCount = 0

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

            // Use real focus score from EarnedBrowseManager if available
            let blockScore: Int
            if let stats = focusStats[block.id], stats.totalTicks > 0 {
                blockScore = stats.focusScore
                totalFocusScore += blockScore
                scoredBlockCount += 1
            } else {
                blockScore = 0
            }

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

        // Focus score: average of per-block scores, or time-based fallback
        let score: Int
        if scoredBlockCount > 0 {
            score = totalFocusScore / scoredBlockCount
        } else {
            score = totalWorkMinutes > 0 ? min(100, (completedWorkMinutes * 100) / totalWorkMinutes) : 0
        }

        // Compute off-task minutes from focus stats (each tick ≈ 10s)
        var offTaskTicks = 0
        var focusedTicks = 0
        for (_, stats) in focusStats {
            offTaskTicks += stats.totalTicks - stats.relevantTicks
            focusedTicks += stats.relevantTicks
        }
        let offTaskMinutes = (offTaskTicks * 10) / 60
        let focusedMinutes = (focusedTicks * 10) / 60

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

    private func handleSetAIModel(_ body: [String: Any]) {
        if let model = body["model"] as? String, ["apple", "qwen"].contains(model) {
            appDelegate?.scheduleManager?.setAIModel(model)
            callJS("window._aiModelResult && window._aiModelResult({ success: true, model: '\(model)' })")
        }
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
            callJS("window._enforcementSettingsResult && window._enforcementSettingsResult({ success: true })")
        } catch {
            callJS("window._enforcementSettingsResult && window._enforcementSettingsResult({ success: false, error: 'Parse error' })")
        }
    }

    // MARK: - Earned Browse Status

    private func handleGetEarnedStatus() {
        guard let mgr = appDelegate?.earnedBrowseManager else { return }
        let blockType = appDelegate?.scheduleManager?.currentBlock?.blockType ?? .freeTime
        let costMultiplier: Double
        switch blockType {
        case .deepWork: costMultiplier = mgr.deepWorkCost
        case .focusHours: costMultiplier = mgr.focusHoursCost
        case .freeTime: costMultiplier = mgr.freeTimeCost
        }
        let effectiveBrowseTime = costMultiplier > 0 ? mgr.availableMinutes / costMultiplier : mgr.availableMinutes

        // Build per-block focus stats array
        var blockStats: [[String: Any]] = []
        for (_, stats) in mgr.blockFocusStats {
            blockStats.append([
                "blockId": stats.blockId,
                "blockTitle": stats.blockTitle,
                "focusScore": stats.focusScore,
                "earnedMinutes": stats.earnedMinutes,
                "relevantTicks": stats.relevantTicks,
                "totalTicks": stats.totalTicks,
                "nudgeCount": stats.nudgeCount
            ])
        }

        // Partner info for extra time flow (read from settings file, same as handleGetSettings)
        var savedSettings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settingsFileURL.path),
           let fileData = try? Data(contentsOf: settingsFileURL),
           let json = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] {
            savedSettings = json
        }
        let partnerEmail = (savedSettings["partnerEmail"] as? String) ?? ""
        let partnerName = (savedSettings["partnerName"] as? String) ?? ""
        let hasPartner = !partnerEmail.isEmpty

        let data: [String: Any] = [
            "earnedMinutes": mgr.earnedMinutes,
            "usedMinutes": mgr.usedMinutes,
            "availableMinutes": mgr.availableMinutes,
            "effectiveBrowseTime": effectiveBrowseTime,
            "blockType": blockType.rawValue,
            "isWorkBlock": blockType != .freeTime,
            "costMultiplier": costMultiplier,
            "poolExhausted": mgr.isPoolExhausted,
            "isDeepWork": blockType == .deepWork || mgr.isDeepWork,
            "blockFocusStats": blockStats,
            "hasPartner": hasPartner,
            "partnerName": partnerName.isEmpty ? "your partner" : partnerName
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data),
           let str = String(data: json, encoding: .utf8) {
            callJS("window._earnedStatusResult && window._earnedStatusResult(\(str))")
        }
    }

    // MARK: - Extra Time (Dashboard)

    private func handleRequestExtraTime(_ body: [String: Any]) {
        guard let mgr = appDelegate?.earnedBrowseManager else {
            callJSCallback("_extraTimeRequestResult", data: ["success": false, "message": "Earned browse manager not available"])
            return
        }
        let minutes = body["minutes"] as? Int ?? Int(mgr.partnerExtraTimeAmount)

        guard let backendClient = appDelegate?.backendClient else {
            callJSCallback("_extraTimeRequestResult", data: ["success": false, "message": "Backend client not available"])
            return
        }

        Task {
            let result = await backendClient.requestExtraTime(minutes: minutes)
            await MainActor.run {
                self.callJSCallback("_extraTimeRequestResult", data: [
                    "success": result.success,
                    "requestId": result.requestId ?? "",
                    "partnerName": result.partnerName ?? "",
                    "message": result.message,
                    "verifiedToday": result.verifiedToday,
                    "remainingToday": result.remainingToday
                ])
            }
            self.appDelegate?.postLog("💰 Dashboard extra time request: \(minutes) min → \(result.success ? "sent" : result.message)")
        }
    }

    private func handleVerifyExtraTimeCode(_ body: [String: Any]) {
        guard let code = body["code"] as? String,
              let requestId = body["requestId"] as? String ?? body["request_id"] as? String else {
            callJSCallback("_extraTimeVerifyResult", data: ["success": false, "message": "Missing code or requestId"])
            return
        }

        guard let mgr = appDelegate?.earnedBrowseManager else {
            callJSCallback("_extraTimeVerifyResult", data: ["success": false, "message": "Earned browse manager not available"])
            return
        }

        guard let backendClient = appDelegate?.backendClient else {
            callJSCallback("_extraTimeVerifyResult", data: ["success": false, "message": "Backend client not available"])
            return
        }

        Task {
            let result = await backendClient.verifyExtraTime(code: code, requestId: requestId)
            await MainActor.run {
                if result.success {
                    mgr.grantPartnerExtraTime(minutes: Double(result.addedMinutes))
                    self.callJSCallback("_extraTimeVerifyResult", data: [
                        "success": true,
                        "addedMinutes": result.addedMinutes,
                        "message": "Extra time added",
                        "verifiedToday": result.verifiedToday,
                        "remainingToday": result.remainingToday
                    ])
                    self.appDelegate?.socketRelayServer?.broadcastEarnedMinutesUpdate(mgr)
                } else {
                    self.callJSCallback("_extraTimeVerifyResult", data: [
                        "success": false,
                        "message": result.message,
                        "verifiedToday": result.verifiedToday,
                        "remainingToday": result.remainingToday
                    ])
                }
            }
            self.appDelegate?.postLog("💰 Dashboard extra time verify: code=\(code.prefix(2))*** → \(result.success ? "+\(result.addedMinutes) min" : result.message)")
        }
    }

    /// Push earned browse status to the dashboard (called by AppDelegate when pool changes).
    func pushEarnedUpdate() {
        handleGetEarnedStatus()
    }

    /// Push content safety status to dashboard (permission state, monitoring state).
    func pushContentSafetyStatus(_ status: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: status),
           let json = String(data: data, encoding: .utf8) {
            callJS("window._contentSafetyStatus && window._contentSafetyStatus(\(json))")
        }
    }

    // MARK: - JS Helpers

    private func callJS(_ script: String) {
        #if DEBUG
        uiPerfCallJSCount += 1
        uiPerfCallJSBytes += script.count
        let scriptSize = script.count
        let fnName: String = {
            if let r = script.range(of: #"window\.(_[A-Za-z0-9]+)"#, options: .regularExpression) {
                return String(script[r]).replacingOccurrences(of: "window.", with: "")
            }
            let head = script.prefix(40)
            return String(head).components(separatedBy: "(").first ?? String(head)
        }()
        uiPerfMaybeFlush()
        #endif
        DispatchQueue.main.async {
            #if DEBUG
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

}

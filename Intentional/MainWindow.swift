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

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        // Allow file:// access for local resources
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]

        // Dark background to match the web UI
        webView.setValue(false, forKey: "drawsBackground")
        webView.uiDelegate = self

        window.contentView = webView
        window.title = "Intentional"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.14, alpha: 1.0)

        // Force window visible
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // Load appropriate page
        loadCurrentPage()
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

    // MARK: - Debug Monitor

    func showDebugMonitor() {
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

        switch type {
        case "SAVE_ONBOARDING":
            handleSaveOnboarding(body)

        case "GET_EXTENSION_STATUS":
            handleGetExtensionStatus()

        case "GET_DASHBOARD_DATA":
            handleGetDashboardData()

        case "GET_SETTINGS":
            handleGetSettings()

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

        case "GET_BLOCK_ASSESSMENTS":
            handleGetBlockAssessments(body)

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
        let lockMode = settings["lockMode"] as? String ?? "none"

        appDelegate?.postLog("📋 Saving onboarding: lock=\(lockMode)")

        // 1. Save to UserDefaults
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        UserDefaults.standard.set(lockMode, forKey: "lockMode")

        // 2. Save structured data to JSON file
        saveOnboardingSettings(
            platforms: platforms,
            partnerEmail: partnerEmail,
            partnerName: partnerName,
            lockMode: lockMode
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
                    icon.size = NSSize(width: 32, height: 32)
                    if let tiffData = icon.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        let dataUrl = "data:image/png;base64,\(pngData.base64EncodedString())"
                        self.iconCacheLock.lock()
                        self.iconCache[browser.bundleId] = dataUrl
                        self.iconCacheLock.unlock()
                        entry["iconDataUrl"] = dataUrl
                    }
                }
                browsersArray.append(entry)
            }

            let result: [String: Any] = [
                "browsers": browsersArray,
                "connectedCount": connectedCount
            ]

            if let data = try? JSONSerialization.data(withJSONObject: result),
               let json = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
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
            earnedBrowse = [
                "earnedMinutes": mgr.earnedMinutes,
                "usedMinutes": mgr.usedMinutes,
                "availableMinutes": mgr.availableMinutes,
                "poolExhausted": mgr.isPoolExhausted
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
        lockMode: String
    ) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let settingsURL = dir.appendingPathComponent("onboarding_settings.json")

        let settings: [String: Any] = [
            "platforms": platforms,
            "partnerEmail": partnerEmail ?? "",
            "partnerName": partnerName ?? "",
            "lockMode": lockMode,
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ]

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

        let lockMode = (savedSettings["lockMode"] as? String)
            ?? UserDefaults.standard.string(forKey: "lockMode")
            ?? "none"
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
        let selfUnlockAvailableAt = savedSettings["selfUnlockAvailableAt"] as? String
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
        if let tuu = temporaryUnlockUntil { result["temporaryUnlockUntil"] = tuu }
        if let sua = selfUnlockAvailableAt { result["selfUnlockAvailableAt"] = sua }

        do {
            let data = try JSONSerialization.data(withJSONObject: result)
            if let json = String(data: data, encoding: .utf8) {
                callJS("window._settingsResult && window._settingsResult(\(json))")
            }
        } catch {
            appDelegate?.postLog("⚠️ GET_SETTINGS: JSON serialization failed: \(error)")
        }
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
        let platforms: [String: Any] = ["youtube": ytSettings, "instagram": igSettings, "facebook": fbSettings]

        saveSettingsToFile(
            platforms: platforms,
            blockedCategories: settings["blockedCategories"] as? [String],
            partnerEmail: partnerEmail,
            partnerName: partnerName,
            lockMode: lockMode,
            maxPerPeriod: settings["maxPerPeriod"] as? [String: Any]
        )

        broadcastSettingsToExtensions(settings)
        callJS("window._saveSettingsResult && window._saveSettingsResult({ success: true })")
        appDelegate?.postLog("💾 SAVE_SETTINGS: Settings saved and broadcast")
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
        maxPerPeriod: [String: Any]?
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

    // MARK: - Sync State from Backend

    func syncStateFromBackend(_ status: BackendClient.StatusResult) {
        appDelegate?.postLog("🔄 Syncing state from backend: lockMode=\(status.lockMode), isLocked=\(status.isLocked), isTemporarilyUnlocked=\(status.isTemporarilyUnlocked)")

        // Update UserDefaults with authoritative backend state
        UserDefaults.standard.set(status.lockMode, forKey: "lockMode")

        // Update settings file with all backend state
        updateSettingsFile { settings in
            settings["lockMode"] = status.lockMode
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
                if let sua = status.selfUnlockAvailableAt {
                    settings["selfUnlockAvailableAt"] = sua
                }
            } else {
                settings["unlockRequested"] = false
                settings["selfUnlockAvailableAt"] = nil
            }
        }

        // Push updated state to the dashboard JS
        let consent = status.consentStatus ?? "none"
        var jsFields = "lockMode: '\(status.lockMode)', consentStatus: '\(consent)'"
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
            if let sua = status.selfUnlockAvailableAt {
                jsFields += ", selfUnlockAvailableAt: '\(sua)'"
            }
        } else {
            jsFields += ", unlockRequested: false"
        }
        jsFields += ", autoRelockEnabled: \(status.autoRelock ? "true" : "false")"
        callJS("if (window._settingsResult) { window._settingsResult({ \(jsFields) }); }")
    }

    // MARK: - Save Lock Settings (Pessimistic)

    private func handleSaveLockSettings(_ body: [String: Any]) {
        let lockMode = body["lockMode"] as? String ?? "none"
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

                // 7. Update strict mode (login item, watchdog, flag file)
                self.appDelegate?.updateStrictMode(lockMode: actualLockMode)
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
                // 3. Clear all partner/lock state from settings file
                self.updateSettingsFile { settings in
                    settings["lockMode"] = "none"
                    settings["partnerEmail"] = ""
                    settings["partnerName"] = ""
                    settings["consentStatus"] = "none"
                    settings["temporaryUnlockUntil"] = nil
                    settings["selfUnlockAvailableAt"] = nil
                    settings["unlockRequested"] = false
                    settings["settingsUnlocked"] = false
                }
                UserDefaults.standard.set("none", forKey: "lockMode")

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

                // Disable strict mode (login item, watchdog, flag)
                self.appDelegate?.updateStrictMode(lockMode: "none")
            }
        }
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
                        if let sua = result.selfUnlockAvailableAt {
                            settings["selfUnlockAvailableAt"] = sua
                        }
                    }
                }

                // Build JS response
                let escaped = result.message.replacingOccurrences(of: "'", with: "\\'")
                var jsResponse = "success: \(result.success), message: '\(escaped)'"
                if let mode = result.mode {
                    jsResponse += ", mode: '\(mode)'"
                }
                if let sua = result.selfUnlockAvailableAt {
                    jsResponse += ", selfUnlockAvailableAt: '\(sua)'"
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
                        settings["selfUnlockAvailableAt"] = nil
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
                    settings["selfUnlockAvailableAt"] = nil
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
            return ScheduleManager.FocusBlock(
                id: dict["id"] as? String ?? UUID().uuidString,
                title: title,
                description: dict["description"] as? String ?? "",
                startHour: startHour,
                startMinute: startMinute,
                endHour: endHour,
                endMinute: endMinute,
                isFree: dict["isFree"] as? Bool ?? false
            )
        }

        appDelegate?.scheduleManager?.setTodaySchedule(goals: goals, dailyPlan: dailyPlan, blocks: blocks)
        appDelegate?.socketRelayServer?.broadcastScheduleSync()
        callJS("window._scheduleResult && window._scheduleResult({ success: true })")
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

            blocksData.append([
                "title": block.title,
                "startHour": block.startHour,
                "startMinute": block.startMinute,
                "endHour": block.endHour,
                "endMinute": block.endMinute,
                "isFree": block.isFree,
                "score": block.isFree ? 0 : (block.endMinutes <= currentMinute ? 85 : 0)
            ])
        }

        // V1 placeholder: score = completed work minutes / total work minutes
        let score = totalWorkMinutes > 0 ? min(100, (completedWorkMinutes * 100) / totalWorkMinutes) : 0

        let result: [String: Any] = [
            "score": score,
            "focusedMinutes": completedWorkMinutes,
            "offTaskMinutes": 0,
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
            [
                "timestamp": entry.timestamp.timeIntervalSince1970 * 1000,
                "title": entry.title,
                "intention": entry.intention,
                "relevant": entry.relevant,
                "confidence": entry.confidence,
                "reason": entry.reason,
                "action": entry.action
            ]
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
                    entries.append([
                        "timestamp": ts.timeIntervalSince1970 * 1000,
                        "title": obj["title"] ?? "",
                        "intention": obj["intention"] ?? "",
                        "relevant": obj["relevant"] ?? false,
                        "confidence": obj["confidence"] ?? 0,
                        "reason": obj["reason"] ?? "",
                        "action": obj["action"] ?? "none"
                    ])
                }
            }
        }

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

    // MARK: - Earned Browse Status

    private func handleGetEarnedStatus() {
        guard let mgr = appDelegate?.earnedBrowseManager else { return }
        let isWorkBlock = (appDelegate?.scheduleManager?.currentTimeState == .workBlock) == true
        let costMultiplier = isWorkBlock ? mgr.workBlockCost : mgr.freeBlockCost
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
                "totalTicks": stats.totalTicks
            ])
        }

        let data: [String: Any] = [
            "earnedMinutes": mgr.earnedMinutes,
            "usedMinutes": mgr.usedMinutes,
            "availableMinutes": mgr.availableMinutes,
            "effectiveBrowseTime": effectiveBrowseTime,
            "isWorkBlock": isWorkBlock,
            "costMultiplier": costMultiplier,
            "poolExhausted": mgr.isPoolExhausted,
            "isDeepWork": mgr.isDeepWork,
            "visitCount": mgr.visitCount,
            "currentDelay": mgr.currentDelay,
            "blockFocusStats": blockStats
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data),
           let str = String(data: json, encoding: .utf8) {
            callJS("window._earnedStatusResult && window._earnedStatusResult(\(str))")
        }
    }

    /// Push earned browse status to the dashboard (called by AppDelegate when pool changes).
    func pushEarnedUpdate() {
        handleGetEarnedStatus()
    }

    // MARK: - JS Helper

    private func callJS(_ script: String) {
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.appDelegate?.postLog("⚠️ JS eval error: \(error.localizedDescription)")
                }
            }
        }
    }
}

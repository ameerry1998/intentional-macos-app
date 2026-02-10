//
//  MainWindow.swift
//  Intentional
//
//  Main application window using WKWebView for web-like UI.
//  Shows onboarding on first launch, then dashboard.
//

import Cocoa
import WebKit

class MainWindow: NSWindowController, WKScriptMessageHandler {

    private var webView: WKWebView!
    weak var appDelegate: AppDelegate?

    /// Debug monitor window (legacy SwiftUI views)
    private var debugMonitorWindow: LegacyMonitorWindow?

    /// Cache browser icons so we don't re-extract every poll cycle
    private var iconCache: [String: String] = [:]

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

    // MARK: - Debug Monitor

    func showDebugMonitor() {
        if debugMonitorWindow == nil {
            debugMonitorWindow = LegacyMonitorWindow()
        }
        debugMonitorWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        let ytBudget = ytSettings["budget"] as? Int ?? 30
        let igBudget = igSettings["budget"] as? Int ?? 30
        let partnerEmail = settings["partnerEmail"] as? String
        let partnerName = settings["partnerName"] as? String
        let lockMode = settings["lockMode"] as? String ?? "none"

        appDelegate?.postLog("📋 Saving onboarding: YT=\(ytBudget)min, IG=\(igBudget)min, lock=\(lockMode)")

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

        // 3. Update TimeTracker budgets per platform
        appDelegate?.timeTracker?.setBudget(for: "youtube", minutes: ytBudget)
        appDelegate?.timeTracker?.setBudget(for: "instagram", minutes: igBudget)

        // 4. Make API calls and broadcast to extensions
        Task {
            if let email = partnerEmail, !email.isEmpty {
                await appDelegate?.backendClient?.setPartner(email: email, name: partnerName)
            }
            if lockMode != "none" {
                await appDelegate?.backendClient?.setLockMode(mode: lockMode)
            }

            // 5. Broadcast ONBOARDING_SYNC to all connected extensions
            await MainActor.run {
                self.broadcastOnboardingToExtensions(
                    platforms: platforms,
                    partnerEmail: partnerEmail,
                    partnerName: partnerName,
                    lockMode: lockMode
                )
            }

            // 6. Respond to JS with success
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
                if let cached = self.iconCache[browser.bundleId] {
                    entry["iconDataUrl"] = cached
                } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleId) {
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 32, height: 32)
                    if let tiffData = icon.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        let dataUrl = "data:image/png;base64,\(pngData.base64EncodedString())"
                        self.iconCache[browser.bundleId] = dataUrl
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
        let ytBudget = tracker.getBudget(for: "youtube")
        let igBudget = tracker.getBudget(for: "instagram")

        let result: [String: Any] = [
            "youtube": [
                "minutesUsed": ytMinutes,
                "budget": ytBudget
            ],
            "instagram": [
                "minutesUsed": igMinutes,
                "budget": igBudget
            ]
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

        let message: [String: Any] = [
            "type": "ONBOARDING_SYNC",
            "platforms": platforms,
            // Legacy flat fields for backward compatibility
            "dailyBudgetMinutes": ytSettings["budget"] as? Int ?? 30,
            "maxPerPeriod": ytSettings["maxPerPeriod"] ?? [
                "enabled": false,
                "minutes": 20,
                "periodHours": 1
            ],
            "blockedCategories": ytSettings["blockedCategories"] ?? [],
            "partnerEmail": partnerEmail ?? NSNull(),
            "partnerName": partnerName ?? NSNull(),
            "lockMode": lockMode,
            "settingsLocked": lockMode != "none",
            "youtube": [
                "onboardingComplete": true,
                "enabled": ytSettings["enabled"] ?? true,
                "blockShorts": ytSettings["blockShorts"] ?? true,
                "blockMode": ytSettings["blockMode"] ?? "hide"
            ],
            "instagram": [
                "onboardingComplete": true,
                "enabled": igSettings["enabled"] ?? true,
                "blockReels": igSettings["blockReels"] ?? true,
                "blockExplore": igSettings["blockExplore"] ?? true,
                "nsfwFilter": igSettings["nsfwFilter"] ?? true
            ]
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

        let ytBudget = appDelegate?.timeTracker?.getBudget(for: "youtube") ?? 30
        let igBudget = appDelegate?.timeTracker?.getBudget(for: "instagram") ?? 30

        let lockMode = (savedSettings["lockMode"] as? String)
            ?? UserDefaults.standard.string(forKey: "lockMode")
            ?? "none"
        let partnerEmail = (savedSettings["partnerEmail"] as? String) ?? ""
        let partnerName = (savedSettings["partnerName"] as? String) ?? ""
        let deviceId = UserDefaults.standard.string(forKey: "deviceId") ?? ""

        let ytResult: [String: Any] = [
            "enabled": (ytPlatform["enabled"] as? Bool) ?? true,
            "budget": ytBudget,
            "threshold": (ytPlatform["threshold"] as? Int) ?? 35,
            "blockShorts": (ytPlatform["blockShorts"] as? Bool) ?? true,
            "hideSponsored": (ytPlatform["hideSponsored"] as? Bool) ?? true,
            "blockMode": (ytPlatform["blockMode"] as? String) ?? "hide",
            "zenDuration": (ytPlatform["zenDuration"] as? Int) ?? 10
        ]

        let igResult: [String: Any] = [
            "enabled": (igPlatform["enabled"] as? Bool) ?? true,
            "budget": igBudget,
            "threshold": (igPlatform["threshold"] as? Int) ?? 35,
            "blockReels": (igPlatform["blockReels"] as? Bool) ?? true,
            "blockExplore": (igPlatform["blockExplore"] as? Bool) ?? true,
            "nsfwFilter": (igPlatform["nsfwFilter"] as? Bool) ?? true,
            "hideAds": (igPlatform["hideAds"] as? Bool) ?? true,
            "blockedCategories": (igPlatform["blockedCategories"] as? [String]) ?? [String](),
            "blockedAccounts": (igPlatform["blockedAccounts"] as? [String]) ?? [String]()
        ]

        let blockedCategories = (ytPlatform["blockedCategories"] as? [String]) ?? [String]()
        let maxPerPeriod: [String: Any] = (ytPlatform["maxPerPeriod"] as? [String: Any]) ?? [
            "enabled": false,
            "minutes": 20,
            "periodHours": 1
        ]

        let result: [String: Any] = [
            "youtube": ytResult,
            "instagram": igResult,
            "blockedCategories": blockedCategories,
            "lockMode": lockMode,
            "partnerEmail": partnerEmail,
            "partnerName": partnerName,
            "maxPerPeriod": maxPerPeriod,
            "deviceId": deviceId
        ]

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

        if let ytBudget = ytSettings["budget"] as? Int {
            appDelegate?.timeTracker?.setBudget(for: "youtube", minutes: ytBudget)
        }
        if let igBudget = igSettings["budget"] as? Int {
            appDelegate?.timeTracker?.setBudget(for: "instagram", minutes: igBudget)
        }

        let lockMode = settings["lockMode"] as? String ?? UserDefaults.standard.string(forKey: "lockMode") ?? "none"
        let partnerEmail = settings["partnerEmail"] as? String
        let partnerName = settings["partnerName"] as? String
        let platforms: [String: Any] = ["youtube": ytSettings, "instagram": igSettings]

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
        appDelegate?.postLog("🔄 Syncing state from backend: lockMode=\(status.lockMode), isLocked=\(status.isLocked)")

        // Update UserDefaults with authoritative backend state
        UserDefaults.standard.set(status.lockMode, forKey: "lockMode")

        // Update settings file
        updateSettingsFile { settings in
            settings["lockMode"] = status.lockMode
            if let email = status.partnerEmail { settings["partnerEmail"] = email }
            if let consent = status.consentStatus { settings["consentStatus"] = consent }
        }

        // Push updated state to the dashboard JS
        let consent = status.consentStatus ?? "none"
        let partner = (status.partnerEmail ?? "").replacingOccurrences(of: "'", with: "\\'")
        callJS("if (window._settingsResult) { window._settingsResult({ lockMode: '\(status.lockMode)', consentStatus: '\(consent)', partnerEmail: '\(partner)' }); }")
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

            // 4. Commit the ACTUAL lock mode
            await MainActor.run {
                UserDefaults.standard.set(actualLockMode, forKey: "lockMode")
                self.updateSettingsFile { settings in
                    settings["lockMode"] = actualLockMode
                    settings["partnerEmail"] = partnerEmail
                    settings["partnerName"] = partnerName
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
                let escaped = result.message.replacingOccurrences(of: "'", with: "\\'")
                self.callJS("window._unlockResult && window._unlockResult({ success: \(result.success), message: '\(escaped)' })")
                self.appDelegate?.postLog("🔓 REQUEST_UNLOCK: success=\(result.success), message=\(result.message)")
            }
        }
    }

    // MARK: - Verify Unlock Code

    private func handleVerifyUnlock(_ body: [String: Any]) {
        guard let code = body["code"] as? String else { return }

        Task {
            // TODO: Call backendClient.verifyUnlock(code:) when endpoint is available
            // For now, respond with the code submission acknowledgment
            await MainActor.run {
                let escaped = code.replacingOccurrences(of: "'", with: "\\'")
                self.appDelegate?.postLog("🔑 VERIFY_UNLOCK: code=\(escaped)")
                // The backend will verify and return success/failure
                // For now, pass through - the real verification will happen via backend
                self.callJS("window._verifyUnlockResult && window._verifyUnlockResult({ success: true, unlockUntil: '\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)))' })")
            }
        }
    }

    // MARK: - Partner Status

    private func handleGetPartnerStatus() {
        Task {
            if let status = await appDelegate?.backendClient?.getPartnerStatus() {
                await MainActor.run {
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
        UserDefaults.standard.removeObject(forKey: "onboardingComplete")
        UserDefaults.standard.removeObject(forKey: "lockMode")
        try? FileManager.default.removeItem(at: settingsFileURL)
        appDelegate?.postLog("🗑️ Settings reset")
        loadCurrentPage()
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

//
//  BrowserMonitor.swift
//  Intentional
//
//  Monitors ALL browsers dynamically discovered via Launch Services
//  Detects if user switches to unprotected browser
//

import Foundation
import Cocoa
import UserNotifications
import CoreServices

class BrowserMonitor: NSObject, UNUserNotificationCenterDelegate {

    private let backendClient: BackendClient
    private weak var appDelegate: AppDelegate?
    private var monitorTimer: Timer?

    // Reference to website blocker (set after initialization)
    weak var websiteBlocker: WebsiteBlocker?

    // Track last known state of each browser
    private var browserStates: [String: Bool] = [:]

    // Track last unprotected set for change-only logging
    private var lastUnprotectedBrowsers: Set<String> = []

    // Per-browser protection decision tracking (for change-only logging)
    private var lastProtectionDecisions: [String: String] = [:]

    // Track when we last notified user (avoid spam)
    private var lastNotificationTime: [String: Date] = [:]
    private let notificationCooldown: TimeInterval = 300 // 5 minutes

    // Safety: limit notifications per check to prevent notification bombs
    private let maxNotificationsPerCheck = 2
    // No grace period after socket disconnect. Socket = truth.
    // If the socket drops, the browser is immediately UNPROTECTED.

    // Known browser bundle IDs → (friendly name, AppleScript app name)
    // This helps us display friendly names and use correct AppleScript commands
    private let knownBrowserInfo: [String: (name: String, scriptName: String)] = [
        // Chrome variants
        "com.google.Chrome": ("Chrome", "Google Chrome"),
        "com.google.Chrome.beta": ("Chrome Beta", "Google Chrome Beta"),
        "com.google.Chrome.dev": ("Chrome Dev", "Google Chrome Dev"),
        "com.google.Chrome.canary": ("Chrome Canary", "Google Chrome Canary"),

        // Apple
        "com.apple.Safari": ("Safari", "Safari"),

        // Mozilla
        "org.mozilla.firefox": ("Firefox", "Firefox"),
        "org.mozilla.firefoxdeveloperedition": ("Firefox Developer", "Firefox Developer Edition"),
        "org.mozilla.nightly": ("Firefox Nightly", "Firefox Nightly"),

        // Microsoft
        "com.microsoft.edgemac": ("Edge", "Microsoft Edge"),
        "com.microsoft.edgemac.Beta": ("Edge Beta", "Microsoft Edge Beta"),
        "com.microsoft.edgemac.Dev": ("Edge Dev", "Microsoft Edge Dev"),
        "com.microsoft.edgemac.Canary": ("Edge Canary", "Microsoft Edge Canary"),

        // Other Chromium-based
        "com.brave.Browser": ("Brave", "Brave Browser"),
        "com.brave.Browser.beta": ("Brave Beta", "Brave Browser Beta"),
        "com.brave.Browser.nightly": ("Brave Nightly", "Brave Browser Nightly"),
        "company.thebrowser.Browser": ("Arc", "Arc"),
        "com.operasoftware.Opera": ("Opera", "Opera"),
        "com.operasoftware.OperaGX": ("Opera GX", "Opera GX"),
        "com.vivaldi.Vivaldi": ("Vivaldi", "Vivaldi"),
        "org.chromium.Chromium": ("Chromium", "Chromium"),

        // Privacy-focused
        "org.torproject.torbrowser": ("Tor Browser", "Tor Browser"),
        "com.duckduckgo.macos.browser": ("DuckDuckGo", "DuckDuckGo"),
        "io.gitlab.librewolf-community.librewolf": ("LibreWolf", "LibreWolf"),
        "net.nickvision.nickvision.waterfox": ("Waterfox", "Waterfox"),
        "net.nickvision.nickvision.mullvadbrowser": ("Mullvad Browser", "Mullvad Browser"),

        // Webkit-based
        "com.kagi.kagimacOS": ("Orion", "Orion"),

        // Productivity browsers
        "com.nickvision.sigmaos": ("SigmaOS", "SigmaOS"),
        "com.nickvision.nickvision.sidekick": ("Sidekick", "Sidekick"),
        "io.nickvision.nickvision.nickvision.desktop": ("Wavebox", "Wavebox"),

        // Developer browsers
        "nickvision.nickvision": ("Polypane", "Polypane"),
        "nickvision.nickvision.nickvision": ("Responsively", "Responsively App"),
        "nickvision.nickvision.nickvision.nickvision": ("Blisk", "Blisk"),

        // Minimal browsers
        "nickvision.nickvision.minbrowser": ("Min", "Min"),

        // Firefox forks
        "one.nickvision.floorp": ("Floorp", "Floorp"),
        "nickvision.nickvision.nickvision.zen-browser": ("Zen Browser", "Zen Browser"),
    ]

    // Apps that handle URLs but are NOT browsers
    private let excludedBundleIds: Set<String> = [
        // Apple apps
        "com.apple.mail",
        "com.apple.MobileSMS",
        "com.apple.Notes",
        "com.apple.Preview",
        "com.apple.finder",
        "com.apple.Terminal",
        "com.apple.iTunes",
        "com.apple.Music",
        "com.apple.podcasts",
        "com.apple.news",
        "com.apple.stocks",
        "com.apple.AppStore",

        // Communication apps
        "com.microsoft.Outlook",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.skype.skype",

        // Media apps
        "com.spotify.client",

        // Productivity apps
        "com.readdle.smartemail-Mac",
        "notion.id",
        "com.figma.Desktop",
        "com.linear",

        // Developer tools
        "com.electron.replit",
        "com.postmanlabs.mac",

        // Other non-browser apps that register URL handlers
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.lastpass.lastpass",

        // AI assistants / non-browser apps
        "ai.perplexity.comet",           // Perplexity Comet
        "com.openai.atlas",              // ChatGPT Atlas
        "com.openai.atlas.web",          // ChatGPT Atlas Web

        // Terminal apps
        "com.googlecode.iterm2",         // iTerm2
        "com.apple.Terminal",            // Terminal (already above but included for clarity)
    ]

    // Dynamically discovered browsers: bundleId → (name, scriptName)
    private var browsers: [String: (name: String, scriptName: String)] = [:]

    init(backendClient: BackendClient, appDelegate: AppDelegate) {
        self.backendClient = backendClient
        self.appDelegate = appDelegate
        super.init()

        // Discover installed browsers dynamically
        discoverInstalledBrowsers()

        // Request notification permissions
        requestNotificationPermissions()
    }

    // MARK: - Browser Discovery

    /// Discover all browsers by querying Launch Services for HTTPS URL handlers
    private func discoverInstalledBrowsers() {
        appDelegate?.postLog("🔍 Discovering installed browsers via Launch Services...")

        // Get all applications that can handle HTTPS URLs
        guard let handlers = LSCopyAllHandlersForURLScheme("https" as CFString)?.takeRetainedValue() as? [String] else {
            appDelegate?.postLog("⚠️ Could not query URL handlers, falling back to known browsers")
            discoverKnownBrowsersOnly()
            return
        }

        appDelegate?.postLog("📋 Found \(handlers.count) HTTPS handlers")

        for bundleId in handlers {
            // Skip excluded apps (not browsers)
            if excludedBundleIds.contains(bundleId) {
                continue
            }

            // Check if app is installed
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                continue
            }

            // Get browser info - either from known list or derive from app name
            let browserInfo: (name: String, scriptName: String)

            if let known = knownBrowserInfo[bundleId] {
                browserInfo = known
            } else {
                // Unknown browser - derive name from app bundle
                let appName = getAppName(from: appURL) ?? bundleId
                browserInfo = (name: appName, scriptName: appName)
                appDelegate?.postLog("🆕 Discovered unknown browser: \(appName) (\(bundleId))")
            }

            browsers[bundleId] = browserInfo
            appDelegate?.postLog("✅ Found browser: \(browserInfo.name)")
        }

        appDelegate?.postLog("📊 Monitoring \(browsers.count) installed browsers")
    }

    /// Fallback to checking only known browsers if Launch Services fails
    private func discoverKnownBrowsersOnly() {
        for (bundleId, browserInfo) in knownBrowserInfo {
            if isApplicationInstalled(bundleId: bundleId) {
                browsers[bundleId] = browserInfo
                appDelegate?.postLog("✅ Found browser (fallback): \(browserInfo.name)")
            }
        }
        appDelegate?.postLog("📊 Monitoring \(browsers.count) browsers (fallback mode)")
    }

    /// Get application display name from its bundle
    private func getAppName(from appURL: URL) -> String? {
        if let bundle = Bundle(url: appURL) {
            // Try display name first
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
                return displayName
            }
            // Then bundle name
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
                return name
            }
        }
        // Last resort: use the filename without extension
        return appURL.deletingPathExtension().lastPathComponent
    }

    private func isApplicationInstalled(bundleId: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return false
        }
        return FileManager.default.fileExists(atPath: appURL.path)
    }

    /// Get browser info for a bundle ID (used by WebsiteBlocker)
    func getBrowserInfo(bundleId: String) -> (name: String, scriptName: String)? {
        return browsers[bundleId]
    }

    /// Get all discovered browsers
    func getAllBrowsers() -> [String: (name: String, scriptName: String)] {
        return browsers
    }

    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ Notification permissions granted")
            } else if let error = error {
                print("❌ Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        // Check every 3 seconds for fast reaction after socket drops
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkAllBrowsers()
        }

        // Check immediately on start
        checkAllBrowsers()

        appDelegate?.postLog("✅ Multi-browser monitoring started")
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    /// Force recheck of all browser protection status
    /// Call this after extension discovery completes to update protection status
    func recheckBrowserProtection() {
        checkAllBrowsers()
    }

    // Post-scan grace period for socket connections to establish.
    // Native messaging relay processes take 1-3s to connect after app launch.
    // Only applies once (at startup); after any socket has connected, blocking proceeds normally.
    private let socketEstablishmentGrace: TimeInterval = 1.5
    private var hasReceivedFirstSocket = false
    private var scheduledPostGraceRecheck = false

    private func checkAllBrowsers() {
        // Phase 1: Wait for NativeMessagingSetup to complete its first extension scan.
        // Without scan data, every browser would be falsely marked as unprotected.
        if !NativeMessagingSetup.shared.hasCompletedInitialScan {
            let runningApps = NSWorkspace.shared.runningApplications
            var currentStates: [String: Bool] = [:]
            for (bundleId, _) in browsers {
                let isRunning = runningApps.contains { app in
                    app.bundleIdentifier == bundleId
                }
                currentStates[bundleId] = isRunning
            }
            browserStates = currentStates
            return
        }

        // Phase 2: Brief post-scan grace for socket connections to establish.
        // For unpacked extensions that file scan can't detect, the socket connection
        // is the only signal. Skip this grace once any socket has connected (meaning
        // the relay infrastructure is working) or once the grace period expires.
        if !hasReceivedFirstSocket {
            let connectedBundleIds = appDelegate?.socketRelayServer?.getConnectedBrowserBundleIds() ?? []
            if !connectedBundleIds.isEmpty {
                hasReceivedFirstSocket = true
            } else if let scanTime = NativeMessagingSetup.shared.initialScanCompletedAt,
                      Date().timeIntervalSince(scanTime) < socketEstablishmentGrace {
                // Still within grace period and no socket yet — populate states but skip decisions
                let runningApps = NSWorkspace.shared.runningApplications
                var currentStates: [String: Bool] = [:]
                for (bundleId, _) in browsers {
                    let isRunning = runningApps.contains { app in
                        app.bundleIdentifier == bundleId
                    }
                    currentStates[bundleId] = isRunning
                }
                browserStates = currentStates
                // Schedule a recheck right when the grace expires so we don't wait
                // for the next 10-second timer tick
                if !scheduledPostGraceRecheck {
                    scheduledPostGraceRecheck = true
                    let remaining = socketEstablishmentGrace - Date().timeIntervalSince(scanTime)
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.1) { [weak self] in
                        self?.checkAllBrowsers()
                    }
                }
                return
            }
            // Grace expired with no socket — proceed (extension probably isn't installed)
        }

        let runningApps = NSWorkspace.shared.runningApplications
        var currentStates: [String: Bool] = [:]
        var runningBrowsers: [String] = []

        // Check which browsers are running
        for (bundleId, browserInfo) in browsers {
            let isRunning = runningApps.contains { app in
                app.bundleIdentifier == bundleId
            }
            currentStates[bundleId] = isRunning

            if isRunning {
                runningBrowsers.append(browserInfo.name)
            }

            // Detect state changes
            if let previousState = browserStates[bundleId], previousState != isRunning {
                handleBrowserStateChange(bundleId: bundleId, browserName: browserInfo.name, isRunning: isRunning)
            }
        }

        browserStates = currentStates

        // Alert if unprotected browsers running
        checkForUnprotectedBrowsers(runningBrowsers: runningBrowsers)
    }

    private func handleBrowserStateChange(bundleId: String, browserName: String, isRunning: Bool) {
        if isRunning {
            appDelegate?.postLog("🌐 \(browserName) started")

            Task {
                await backendClient.sendEvent(type: "browser_started", details: [
                    "browser": browserName,
                    "bundle_id": bundleId,
                    "has_extension": hasExtension(bundleId: bundleId)
                ])
            }
        } else {
            appDelegate?.postLog("🚫 \(browserName) closed")

            Task {
                await backendClient.sendEvent(type: "browser_closed", details: [
                    "browser": browserName,
                    "bundle_id": bundleId
                ])
            }
        }
    }

    // MARK: - Protection State Machine

    /// Protection status for a single browser
    private enum ProtectionStatus {
        case protected(reason: String)
        case unprotected(reason: String)
    }

    /// Determine if a browser has the Intentional extension installed.
    /// Uses same priority as protectionDecision but returns a simple boolean.
    private func hasExtension(bundleId: String) -> Bool {
        // Active socket = definitive proof
        let connectedBundleIds = appDelegate?.socketRelayServer?.getConnectedBrowserBundleIds() ?? []
        if connectedBundleIds.contains(bundleId) {
            return true
        }

        // No socket → fall back to file scan
        let browserStatuses = NativeMessagingSetup.shared.getBrowserStatus()
        if let status = browserStatuses.first(where: { $0.bundleId == bundleId }) {
            return status.hasExtension && status.isEnabled
        }

        return false
    }

    /// Determine protection status for a single browser.
    /// Simple rule: Socket connected = PROTECTED. Otherwise consult file scan.
    /// No grace periods — socket is truth.
    ///
    /// 1. Socket CONNECTED → PROTECTED (definitive proof extension is running)
    /// 2. Socket NOT connected → consult file scan
    /// 3. No signal at all → UNPROTECTED
    private func protectionDecision(
        bundleId: String,
        connectedBundleIds: Set<String>,
        browserStatuses: [BrowserExtensionStatus]
    ) -> ProtectionStatus {

        // Priority 1: Active socket connection is definitive
        if connectedBundleIds.contains(bundleId) {
            return .protected(reason: "active socket connection")
        }

        // Priority 2: No socket — consult file scan
        if let status = browserStatuses.first(where: { $0.bundleId == bundleId }) {
            if status.hasExtension && status.isEnabled {
                return .protected(reason: "file scan says enabled")
            } else if status.hasExtension && !status.isEnabled {
                return .unprotected(reason: "file scan says DISABLED")
            } else {
                return .unprotected(reason: "no extension found by file scan")
            }
        }

        // Priority 3: No signal at all
        return .unprotected(reason: "no extension data, no socket history")
    }

    private func checkForUnprotectedBrowsers(runningBrowsers: [String]) {
        let connectedBundleIds = appDelegate?.socketRelayServer?.getConnectedBrowserBundleIds() ?? []
        let browserStatuses = NativeMessagingSetup.shared.getBrowserStatus()

        var unprotectedBrowserNames: [String] = []

        for (bundleId, browserInfo) in browsers {
            // Only evaluate running browsers
            guard browserStates[bundleId] == true else { continue }

            let status = protectionDecision(
                bundleId: bundleId,
                connectedBundleIds: connectedBundleIds,
                browserStatuses: browserStatuses
            )

            // Build decision key for change detection
            let decisionKey: String
            switch status {
            case .protected(let reason):
                decisionKey = "protected:\(reason)"
            case .unprotected(let reason):
                decisionKey = "unprotected:\(reason)"
                unprotectedBrowserNames.append(browserInfo.name)
            }

            // Log on every check (verbose, but needed for debugging timing)
            switch status {
            case .protected(let reason):
                appDelegate?.postLog("🛡️ \(browserInfo.name): PROTECTED — \(reason)")
            case .unprotected(let reason):
                appDelegate?.postLog("⚠️ \(browserInfo.name): UNPROTECTED — \(reason)")
            }
            lastProtectionDecisions[bundleId] = decisionKey
        }

        // Clean up decisions for browsers no longer running
        for bundleId in lastProtectionDecisions.keys {
            if browserStates[bundleId] != true {
                lastProtectionDecisions.removeValue(forKey: bundleId)
            }
        }

        // Log aggregate change
        let currentUnprotected = Set(unprotectedBrowserNames)
        if currentUnprotected != lastUnprotectedBrowsers {
            if currentUnprotected.isEmpty && !lastUnprotectedBrowsers.isEmpty {
                appDelegate?.postLog("✅ All running browsers now protected")
            }
            lastUnprotectedBrowsers = currentUnprotected
        }

        // Update WebsiteBlocker
        if !unprotectedBrowserNames.isEmpty {
            websiteBlocker?.updateBlockedBrowsers(browsers: unprotectedBrowserNames)

            Task {
                await backendClient.sendEvent(type: "unprotected_browsing", details: [
                    "browsers": unprotectedBrowserNames,
                    "count": unprotectedBrowserNames.count
                ])
            }
        } else {
            websiteBlocker?.updateBlockedBrowsers(browsers: [])
        }
    }

    // REMOVED: showExtensionMissingNotification
    // No longer showing notifications for missing extensions
    // Users can check extension status in Settings, and the blocking page
    // will show install prompts when they visit blocked sites

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // User tapped notification - could open extension installation URL
        if let browserName = response.notification.request.content.userInfo["browser"] as? String {
            appDelegate?.postLog("📬 User tapped notification for \(browserName)")
            // TODO: Open extension store URL for the browser
        }
        completionHandler()
    }

    deinit {
        stopMonitoring()
    }
}

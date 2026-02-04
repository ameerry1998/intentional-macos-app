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

    // Track when we last notified user (avoid spam)
    private var lastNotificationTime: [String: Date] = [:]
    private let notificationCooldown: TimeInterval = 300 // 5 minutes

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
        // Check every 10 seconds
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
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

    private func checkAllBrowsers() {
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

    /// Determine which browsers have the Intentional extension installed
    /// Currently only Chrome has extension support
    private func hasExtension(bundleId: String) -> Bool {
        // Chrome-based browsers can have our extension
        return bundleId.contains("Chrome") || bundleId.contains("google.Chrome")
    }

    private func checkForUnprotectedBrowsers(runningBrowsers: [String]) {
        let unprotectedBrowsers = runningBrowsers.filter { browserName in
            // Only Chrome currently has extension
            !browserName.contains("Chrome")
        }

        if !unprotectedBrowsers.isEmpty {
            appDelegate?.postLog("⚠️ Unprotected browsers running: \(unprotectedBrowsers.joined(separator: ", "))")

            // Show notification for each unprotected browser (with cooldown)
            for browser in unprotectedBrowsers {
                showExtensionMissingNotification(browserName: browser)
            }

            // Notify website blocker to block YouTube/Instagram
            websiteBlocker?.updateBlockedBrowsers(browsers: unprotectedBrowsers)

            // Alert backend about unprotected browsing
            Task {
                await backendClient.sendEvent(type: "unprotected_browsing", details: [
                    "browsers": unprotectedBrowsers,
                    "count": unprotectedBrowsers.count
                ])
            }
        } else {
            // All browsers protected, notify blocker to disable
            websiteBlocker?.updateBlockedBrowsers(browsers: [])
        }
    }

    private func showExtensionMissingNotification(browserName: String) {
        // Check cooldown to avoid spam
        let now = Date()
        if let lastNotified = lastNotificationTime[browserName],
           now.timeIntervalSince(lastNotified) < notificationCooldown {
            return // Too soon, skip notification
        }

        lastNotificationTime[browserName] = now

        let content = UNMutableNotificationContent()
        content.title = "Intentional Protection Missing"
        content.body = "\(browserName) is open without the Intentional extension. Install the extension to enable accountability on all browsers."
        content.sound = .default
        content.categoryIdentifier = "EXTENSION_MISSING"
        content.userInfo = ["browser": browserName]

        // Deliver notification immediately
        let request = UNNotificationRequest(
            identifier: "missing-extension-\(browserName)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to show notification: \(error.localizedDescription)")
            } else {
                print("📬 Notification shown: \(browserName) missing extension")
            }
        }
    }

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

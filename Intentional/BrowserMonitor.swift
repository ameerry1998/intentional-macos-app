//
//  BrowserMonitor.swift
//  Intentional
//
//  Monitors ALL browsers dynamically discovered via Launch Services.
//
//  Post-extension-removal scope (May 2026): this file no longer tracks
//  per-browser "protection" status — there is no extension to be present or
//  absent. Browsers are simply discovered, their lifecycle is tracked, and the
//  full list is dispatched to `WebsiteBlocker` so AppleScript tab inspection
//  can run against every running browser.
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

    // Track which set of browsers was last dispatched to WebsiteBlocker so we
    // only log on change.
    private var lastDispatchedBrowsers: Set<String> = []

    // Track when we last notified user (avoid spam)
    private var lastNotificationTime: [String: Date] = [:]
    private let notificationCooldown: TimeInterval = 300 // 5 minutes

    // Safety: limit notifications per check to prevent notification bombs
    private let maxNotificationsPerCheck = 2

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
        "com.kagi.kagimacOS.RC": ("Orion RC", "Orion RC"),

        // Productivity browsers (real bundle IDs verified — earlier
        // `nickvision.*` placeholders were removed because they never matched
        // real installs; unknown browsers auto-register from the app filename
        // via the Launch Services fallback in discoverInstalledBrowsers).
        "com.sigmaos.sigmaos.macos.SigmaOS": ("SigmaOS", "SigmaOS"),
        "app.wavebox": ("Wavebox", "Wavebox"),
        "com.pushplaylabs.sidekick": ("Sidekick", "Sidekick"),

        // The Browser Company family
        "company.thebrowser.dia": ("Dia", "Dia"),

        // AI-powered Chromium browsers — full browsers despite the "AI assistant"
        // marketing. They render arbitrary websites (incl. YouTube/Instagram) and
        // expose Chrome's AppleScript API for `URL of active tab of front window`.
        // If we don't register them here they get excluded → no tab inspection →
        // YouTube loads freely during a Focus session.
        "ai.perplexity.comet": ("Comet", "Comet"),
        "com.openai.atlas": ("ChatGPT Atlas", "ChatGPT Atlas"),
        "com.openai.atlas.web": ("ChatGPT Atlas Web", "ChatGPT Atlas Web"),
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

        // (Comet / ChatGPT Atlas removed from excluded list — they are full
        // Chromium-based browsers and need tab-level enforcement. Registered in
        // `knownBrowserInfo` above.)

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
        // Check every 3 seconds to keep browser lifecycle reasonably fresh.
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

    /// Force recheck of all browsers. Retained as a no-cost passthrough so the
    /// existing AppDelegate callsites (which will be cleaned up in the next
    /// dispatch) keep compiling.
    func recheckBrowserProtection() {
        checkAllBrowsers()
    }

    private func checkAllBrowsers() {
        let runningApps = NSWorkspace.shared.runningApplications
        var currentStates: [String: Bool] = [:]
        var runningBrowserNames: [String] = []

        // Check which browsers are running
        for (bundleId, browserInfo) in browsers {
            let isRunning = runningApps.contains { app in
                app.bundleIdentifier == bundleId
            }
            currentStates[bundleId] = isRunning

            if isRunning {
                runningBrowserNames.append(browserInfo.name)
            }

            // Detect state changes
            if let previousState = browserStates[bundleId], previousState != isRunning {
                handleBrowserStateChange(bundleId: bundleId, browserName: browserInfo.name, isRunning: isRunning)
            }
        }

        browserStates = currentStates

        // WebsiteBlocker handles every running browser — there's no extension
        // sensing layer to exempt anything.
        dispatchRunningBrowsers(runningBrowserNames: runningBrowserNames)
    }

    private func handleBrowserStateChange(bundleId: String, browserName: String, isRunning: Bool) {
        if isRunning {
            appDelegate?.postLog("🌐 \(browserName) started")

            Task {
                await backendClient.sendEvent(type: "browser_started", details: [
                    "browser": browserName,
                    "bundle_id": bundleId
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

    /// Hand the full set of currently-running browsers to WebsiteBlocker so it
    /// can apply AppleScript-based tab enforcement against every one of them.
    /// Logs only on change to keep the log readable.
    private func dispatchRunningBrowsers(runningBrowserNames: [String]) {
        let current = Set(runningBrowserNames)
        if current != lastDispatchedBrowsers {
            if current.isEmpty {
                appDelegate?.postLog("ℹ️ No browsers running")
            } else {
                appDelegate?.postLog("🛡️ Tracking running browsers: \(runningBrowserNames.joined(separator: ", "))")
            }
            lastDispatchedBrowsers = current
        }

        websiteBlocker?.updateBlockedBrowsers(browsers: runningBrowserNames)

        if !runningBrowserNames.isEmpty {
            Task {
                await backendClient.sendEvent(type: "browsers_running", details: [
                    "browsers": runningBrowserNames,
                    "count": runningBrowserNames.count
                ])
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
        if let browserName = response.notification.request.content.userInfo["browser"] as? String {
            appDelegate?.postLog("📬 User tapped notification for \(browserName)")
        }
        completionHandler()
    }

    deinit {
        stopMonitoring()
    }
}

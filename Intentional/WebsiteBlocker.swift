//
//  WebsiteBlocker.swift
//  Intentional
//
//  Blocks YouTube/Instagram tabs on browsers without extension
//  Uses AppleScript to monitor and replace blocked URLs
//

import Foundation
import Cocoa
import UserNotifications

class WebsiteBlocker: NSObject, UNUserNotificationCenterDelegate {

    private weak var appDelegate: AppDelegate?
    private let backendClient: BackendClient

    // AppleScript tab monitoring (Opal-style)
    private var monitorTimer: Timer?
    private let checkInterval: TimeInterval = 0.5  // Check every 0.5 seconds for faster blocking

    // Blocked domains
    private let blockedDomains = [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "instagram.com",
        "www.instagram.com",
        "m.instagram.com",
        "facebook.com",
        "www.facebook.com",
        "m.facebook.com"
    ]

    // Custom blocking page URL (will be in app bundle)
    private var blockPageURL: String {
        if let bundlePath = Bundle.main.resourcePath {
            return "file://\(bundlePath)/blocked.html"
        }
        return "about:blank"
    }

    // Track if blocking is currently active
    private var isBlocking = false

    // Cache of recently blocked DOMAINS to avoid repeated attempts
    // Using domains instead of full URLs to handle redirects (e.g., m.youtube.com → youtube.com)
    private var recentlyBlockedDomains: Set<String> = []
    private var lastCacheClear = Date()
    private let cacheDuration: TimeInterval = 1.0  // Clear cache every 1 second

    // Domains currently being blocked (AppleScript in-flight on the serial queue).
    // Prevents queueing duplicate blocking scripts while one is already pending.
    private var inFlightDomains: Set<String> = []

    // Browsers that currently have a check script queued/running on the serial queue.
    // Prevents flooding the queue when scripts take longer than the 0.5s timer interval.
    private var checkInFlight: Set<String> = []

    // Serial queue for AppleScript execution - prevents concurrent scripts to same browser
    private let appleScriptQueue = DispatchQueue(label: "com.intentional.applescript", qos: .userInitiated)

    // MARK: - Bypass Detection
    // Track time spent on blocked sites (for detecting if someone bypasses the blocking page)
    private var bypassTimeTracking: [String: (startTime: Date, totalSeconds: TimeInterval, lastSeen: Date)] = [:]
    private let bypassAlertThreshold: TimeInterval = 300.0  // 5 minutes
    private var bypassAlertsSent: Set<String> = []  // Don't spam alerts

    // Track last notification time to avoid spam
    private var lastNotificationTime: Date?
    private let notificationCooldown: TimeInterval = 60.0  // 1 minute between notifications

    // Track last tab count log time per browser to avoid spam
    private var lastTabLogTime: [String: Date] = [:]
    private let tabLogCooldown: TimeInterval = 60.0  // Log tab counts once per minute

    init(backendClient: BackendClient, appDelegate: AppDelegate) {
        self.backendClient = backendClient
        self.appDelegate = appDelegate
        super.init()
        setupNotifications()
    }

    // MARK: - Notifications Setup

    private func setupNotifications() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                self.appDelegate?.postLog("🔔 Notification permission granted")
            } else if let error = error {
                self.appDelegate?.postLog("⚠️ Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    // Show native macOS notification when a blocked site is detected
    private func showBlockedSiteNotification(site: String, browser: String) {
        // Cooldown to prevent notification spam
        if let lastTime = lastNotificationTime,
           Date().timeIntervalSince(lastTime) < notificationCooldown {
            return
        }
        lastNotificationTime = Date()

        let content = UNMutableNotificationContent()
        content.title = "Site Blocked"
        content.body = "\(browser) tried to access \(site). Install the Intentional extension for full protection."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                self.appDelegate?.postLog("⚠️ Failed to show notification: \(error.localizedDescription)")
            } else {
                self.appDelegate?.postLog("🔔 Notification shown for \(site) in \(browser)")
            }
        }
    }

    // UNUserNotificationCenterDelegate - handle notification when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show notification even when app is in foreground
        completionHandler([.banner, .sound])
    }

    // MARK: - Bypass Detection

    // Track time spent on a blocked domain (not on blocking page = bypass attempt)
    private func trackBypassTime(domain: String, browser: String, isOnBlockingPage: Bool) {
        let baseDomain = domain.replacingOccurrences(of: "www.", with: "")
                               .replacingOccurrences(of: "m.", with: "")

        if isOnBlockingPage {
            // They're on the blocking page, not bypassing - reset tracking
            bypassTimeTracking.removeValue(forKey: baseDomain)
            return
        }

        // They're on the actual site (bypassing) - track time
        let now = Date()

        if var tracking = bypassTimeTracking[baseDomain] {
            // Continue tracking - add time since last seen
            let elapsed = now.timeIntervalSince(tracking.lastSeen)
            // Only add time if they were seen recently (within 2 seconds = continuous bypass)
            if elapsed < 2.0 {
                tracking.totalSeconds += elapsed
            }
            tracking.lastSeen = now
            bypassTimeTracking[baseDomain] = tracking

            // Check if threshold exceeded
            if tracking.totalSeconds >= bypassAlertThreshold && !bypassAlertsSent.contains(baseDomain) {
                sendBypassAlert(domain: baseDomain, browser: browser, totalMinutes: tracking.totalSeconds / 60.0)
                bypassAlertsSent.insert(baseDomain)
            }
        } else {
            // Start tracking
            bypassTimeTracking[baseDomain] = (startTime: now, totalSeconds: 0, lastSeen: now)
            appDelegate?.postLog("⏱️ Started bypass tracking for \(baseDomain)")
        }
    }

    // Send alert to backend when bypass threshold exceeded
    private func sendBypassAlert(domain: String, browser: String, totalMinutes: Double) {
        appDelegate?.postLog("🚨 BYPASS ALERT: User spent \(String(format: "%.1f", totalMinutes)) minutes on \(domain) in \(browser)")

        Task {
            await backendClient.sendEvent(type: "bypass_detected", details: [
                "domain": domain,
                "browser": browser,
                "minutes_on_site": String(format: "%.1f", totalMinutes),
                "alert_type": "unprotected_browser_bypass"
            ])
        }
    }

    // Reset bypass alerts daily
    func resetDailyBypassAlerts() {
        bypassAlertsSent.removeAll()
        bypassTimeTracking.removeAll()
        appDelegate?.postLog("🔄 Reset daily bypass tracking")
    }

    // MARK: - Public Interface

    func startBlocking() {
        appDelegate?.postLog("🛡️ Starting website blocking via AppleScript...")

        // Start tab monitoring
        monitorTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkAllBrowserTabs()
        }

        isBlocking = true
        appDelegate?.postLog("👁️ Tab monitoring started (checking every \(checkInterval)s)")

        // Check tabs immediately — don't wait for the first timer tick
        checkAllBrowserTabs()

        // Send event to backend
        Task {
            await backendClient.sendEvent(type: "blocking_method_changed", details: [
                "method": "applescript_tab_blocking",
                "domains": blockedDomains
            ])
        }
    }

    func stopBlocking() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        isBlocking = false
        inFlightDomains.removeAll()
        checkInFlight.removeAll()
        appDelegate?.postLog("🛑 Tab monitoring stopped")
    }

    // Track which browsers are currently running and unprotected
    private var activeBrowsers: Set<String> = []

    func updateBlockedBrowsers(browsers: [String]) {
        // Called by BrowserMonitor when unprotected browsers detected
        appDelegate?.postLog("📣 updateBlockedBrowsers called with: \(browsers)")

        activeBrowsers = Set(browsers)

        if !browsers.isEmpty && !isBlocking {
            appDelegate?.postLog("▶️ Starting blocking for browsers: \(browsers)")
            startBlocking()
        } else if browsers.isEmpty && isBlocking {
            stopBlocking()
        } else if !browsers.isEmpty && isBlocking {
            appDelegate?.postLog("🔄 Blocking already active, updated browsers to: \(browsers)")
        }
    }

    // MARK: - Tab Monitoring

    // Extract base domain for caching (e.g., "youtube.com" from "m.youtube.com" or "www.youtube.com")
    private func getBaseDomain(from url: String) -> String? {
        guard let urlObj = URL(string: url),
              let host = urlObj.host?.lowercased() else {
            return nil
        }

        // For our blocked domains, find which one this host matches
        for domain in blockedDomains {
            if host == domain || host.hasSuffix("." + domain) {
                // Return the base domain (e.g., "youtube.com" not "m.youtube.com")
                // This ensures m.youtube.com and www.youtube.com share the same cache entry
                return domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
            }
        }
        return host
    }

    // Check if a domain was recently blocked
    private func wasRecentlyBlocked(url: String) -> Bool {
        guard let baseDomain = getBaseDomain(from: url) else { return false }
        return recentlyBlockedDomains.contains(baseDomain)
    }

    // Mark a domain as recently blocked
    private func markAsBlocked(url: String) {
        guard let baseDomain = getBaseDomain(from: url) else { return }
        recentlyBlockedDomains.insert(baseDomain)
        appDelegate?.postLog("📝 Cached domain: \(baseDomain)")
    }

    // Check if URL is on blocking page (not the actual blocked site)
    private func isOnBlockingPage(url: String) -> Bool {
        let lowercased = url.lowercased()
        return lowercased.contains("blocked.html") ||
               lowercased.contains("blocked=") ||
               lowercased.hasPrefix("file://")
    }

    // Check if URL matches any blocked domain (regardless of cache)
    private func matchesBlockedDomain(url: String) -> Bool {
        guard let urlObj = URL(string: url),
              let host = urlObj.host?.lowercased() else {
            return false
        }

        return blockedDomains.contains { domain in
            host == domain || host.hasSuffix("." + domain)
        }
    }

    // Process URLs from a browser - handle blocking and bypass detection
    // Deduplicates by domain to avoid running multiple blocking scripts for the same domain
    private func processURLs(_ urls: [String], browserName: String, blockAction: (String) -> Void) {
        // Bail out if this browser was removed from the active set while the
        // AppleScript check was running on the background queue. Without this,
        // already-queued scripts keep blocking tabs long after the browser was
        // marked as protected.
        guard activeBrowsers.contains(browserName) else { return }

        // Track which domains we've already queued for blocking in this batch
        var domainsToBlock: [String: String] = [:]  // domain -> first URL with that domain

        for url in urls {
            // Check if this URL matches a blocked domain
            if matchesBlockedDomain(url: url) {
                let isOnBlockPage = isOnBlockingPage(url: url)

                // Track bypass time (are they on actual site vs blocking page?)
                if let domain = getBaseDomain(from: url) {
                    trackBypassTime(domain: domain, browser: browserName, isOnBlockingPage: isOnBlockPage)

                    // Queue for blocking if not on blocking page, not recently blocked, and not already in-flight
                    if !isOnBlockPage && shouldBlock(url: url) && !wasRecentlyBlocked(url: url) && !inFlightDomains.contains(domain) {
                        if domainsToBlock[domain] == nil {
                            domainsToBlock[domain] = url
                            appDelegate?.postLog("🎯 \(browserName): Will block \(domain) (not on block page, should block, not cached, not in-flight)")
                        }
                    }
                }
            }
        }

        // Now execute blocking for each unique domain
        for (domain, url) in domainsToBlock {
            markAsBlocked(url: url)
            inFlightDomains.insert(domain)
            let protectedList = getProtectedBrowsersList()
            appDelegate?.postLog("🚫 BLOCKING \(browserName): domain=\(domain), protectedBrowsers=[\(protectedList)]")
            blockAction(url)
        }
    }

    // Map browser friendly names to their AppleScript application names
    private let browserAppleScriptNames: [String: String] = [
        // Apple
        "Safari": "Safari",

        // Chrome variants
        "Chrome": "Google Chrome",
        "Chrome Beta": "Google Chrome Beta",
        "Chrome Dev": "Google Chrome Dev",
        "Chrome Canary": "Google Chrome Canary",

        // Chromium-based (use same API as Chrome)
        "Brave": "Brave Browser",
        "Brave Beta": "Brave Browser Beta",
        "Brave Nightly": "Brave Browser Nightly",
        "Edge": "Microsoft Edge",
        "Edge Beta": "Microsoft Edge Beta",
        "Edge Dev": "Microsoft Edge Dev",
        "Edge Canary": "Microsoft Edge Canary",
        "Arc": "Arc",
        "Vivaldi": "Vivaldi",
        "Opera": "Opera",
        "Opera GX": "Opera GX",
        "Chromium": "Chromium",

        // Privacy browsers (Chromium-based)
        "DuckDuckGo": "DuckDuckGo",
        "Orion": "Orion",

        // Firefox (limited AppleScript support)
        "Firefox": "Firefox",
        "Firefox Developer": "Firefox Developer Edition",
        "Firefox Nightly": "Firefox Nightly",
        "LibreWolf": "LibreWolf",
        "Waterfox": "Waterfox",
        "Floorp": "Floorp",
        "Zen Browser": "Zen Browser",

        // Other
        "Tor Browser": "Tor Browser",
    ]

    private func checkAllBrowserTabs() {
        // Clear cache periodically
        if Date().timeIntervalSince(lastCacheClear) > cacheDuration {
            recentlyBlockedDomains.removeAll()
            lastCacheClear = Date()
        }

        // Only check browsers that are currently running and unprotected
        guard !activeBrowsers.isEmpty else {
            return
        }

        for browser in activeBrowsers {
            // Get the AppleScript app name, or use the browser name as fallback
            let scriptName = browserAppleScriptNames[browser] ?? browser

            // Use browser-specific methods where they exist (they may have special handling)
            // Otherwise fall back to generic Chromium method
            switch browser {
            case "Safari":
                checkSafariTabs()
            case "Chrome", "Chrome Beta", "Chrome Dev", "Chrome Canary":
                checkChromeTabs()
            case "Brave", "Brave Beta", "Brave Nightly":
                checkBraveTabs()
            case "Edge", "Edge Beta", "Edge Dev", "Edge Canary":
                checkEdgeTabs()
            case "Arc":
                checkArcTabs()
            case _ where isFirefoxBased(browser):
                checkFirefoxTabs(browserName: browser, scriptName: scriptName)
            default:
                // Generic Chromium-based method for unknown browsers
                checkChromiumTabs(browserName: browser, scriptName: scriptName)
            }
        }
    }

    /// Check if browser is Firefox-based (limited AppleScript support)
    private func isFirefoxBased(_ browser: String) -> Bool {
        let firefoxBrowsers = ["Firefox", "Firefox Developer", "Firefox Nightly",
                               "LibreWolf", "Waterfox", "Floorp", "Zen Browser",
                               "Tor Browser", "Pale Moon", "Basilisk"]
        return firefoxBrowsers.contains(browser)
    }

    // MARK: - Safari Blocking

    private func checkSafariTabs() {
        let script = """
        tell application "Safari"
            if it is running then
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set tabURL to URL of t
                            return tabURL
                        end try
                    end repeat
                end repeat
            end if
        end tell
        return ""
        """

        executeScript(script, browserName: "Safari") { [weak self] urls in
            guard let self = self else { return }
            self.processURLs(urls, browserName: "Safari") { url in
                self.blockSafariTab(url: url)
            }
        }
    }

    private func blockSafariTab(url: String) {
        let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBrowser = "Safari".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Safari"
        let protectedBrowsers = getProtectedBrowsersList()
        let blockURL = "\(blockPageURL)?blocked=\(encodedURL)&browser=\(encodedBrowser)&protected=\(protectedBrowsers)"

        let blockScript = """
        tell application "Safari"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set tabURL to URL of t
                        if tabURL contains "\(getSafeDomain(from: url))" and tabURL does not contain "blocked.html" then
                            set URL of t to "\(blockURL)"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """

        executeBlockingScript(blockScript, browserName: "Safari", blockedURL: url)
    }

    // MARK: - Chrome Blocking

    /// Two-tier Chrome blocking:
    /// - Fast path: checks only the active tab of the front window (1 Apple Event, <1s)
    /// - Slow path: scans ALL tabs across all windows (many Apple Events, can take 10+ seconds)
    /// The fast path runs on every timer tick; the slow path only when not already in-flight.
    private func checkChromeTabs() {
        checkChromeActiveTab()
        checkChromeAllTabs()
    }

    /// Fast path: check just the active tab of the front window
    private func checkChromeActiveTab() {
        let protectedBrowsers = getProtectedBrowsersList()
        let encodedBrowser = "Chrome".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Chrome"

        // Build domain checks for the active tab
        var domainChecks = ""
        for domain in blockedDomains {
            let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain
            let blockURL = "\(blockPageURL)?blocked=\(encodedDomain)&browser=\(encodedBrowser)&protected=\(protectedBrowsers)"
            domainChecks += """
                        if tabURL contains "\(domain)" and tabURL does not contain "blocked.html" then
                            set URL of active tab of front window to "\(blockURL)"
                            return "BLOCKED:" & tabURL
                        end if

            """
        }

        let script = """
        tell application "Google Chrome"
            if it is running then
                try
                    set tabURL to URL of active tab of front window
        \(domainChecks)
                    return tabURL
                end try
            end if
        end tell
        return ""
        """

        // Use a separate in-flight key so this doesn't conflict with full scan
        executeScript(script, browserName: "Chrome-active") { [weak self] results in
            guard let self = self else { return }
            let result = results.joined()
            if result.hasPrefix("BLOCKED:") {
                let blockedURL = String(result.dropFirst("BLOCKED:".count))
                let domain = self.getSafeDomain(from: blockedURL)
                self.appDelegate?.postLog("🚫 Blocked (active tab): \(blockedURL) in Chrome")
                self.showBlockedSiteNotification(site: domain, browser: "Chrome")
                Task {
                    await self.backendClient.sendEvent(type: "site_blocked", details: [
                        "url": blockedURL, "browser": "Chrome", "method": "applescript_active_tab"
                    ])
                }
            }
        }
    }

    /// Slow path: scan ALL tabs across all windows (catches background tabs)
    private func checkChromeAllTabs() {
        let protectedBrowsers = getProtectedBrowsersList()
        let encodedBrowser = "Chrome".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Chrome"

        var domainChecks = ""
        for domain in blockedDomains {
            let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain
            let blockURL = "\(blockPageURL)?blocked=\(encodedDomain)&browser=\(encodedBrowser)&protected=\(protectedBrowsers)"
            domainChecks += """
                            if tabURL contains "\(domain)" and tabURL does not contain "blocked.html" then
                                set URL of t to "\(blockURL)"
                                set end of blockedList to tabURL
                            end if

            """
        }

        let script = """
        tell application "Google Chrome"
            if it is running then
                set blockedList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set tabURL to URL of t
        \(domainChecks)                    end try
                    end repeat
                end repeat
                set AppleScript's text item delimiters to linefeed
                set resultText to (blockedList as text)
                set AppleScript's text item delimiters to ""
                return resultText
            end if
        end tell
        return ""
        """

        // This uses "Chrome" as the in-flight key — will be skipped if a full scan is already running
        executeScript(script, browserName: "Chrome") { [weak self] results in
            guard let self = self else { return }
            let blocked = results.filter { !$0.isEmpty }

            for url in blocked {
                let domain = self.getSafeDomain(from: url)
                self.appDelegate?.postLog("🚫 Blocked (all tabs): \(url) in Chrome")
                self.showBlockedSiteNotification(site: domain, browser: "Chrome")
                Task {
                    await self.backendClient.sendEvent(type: "site_blocked", details: [
                        "url": url, "browser": "Chrome", "method": "applescript"
                    ])
                }
            }
        }
    }

    // MARK: - Brave Blocking

    private func checkBraveTabs() {
        let script = """
        tell application "Brave Browser"
            if it is running then
                set urlList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set end of urlList to URL of t
                        end try
                    end repeat
                end repeat
                set AppleScript's text item delimiters to linefeed
                set urlText to urlList as text
                set AppleScript's text item delimiters to ""
                return urlText
            end if
        end tell
        return ""
        """

        executeScript(script, browserName: "Brave") { [weak self] urls in
            guard let self = self else { return }
            self.processURLs(urls, browserName: "Brave") { url in
                self.blockBraveTab(url: url)
            }
        }
    }

    private func blockBraveTab(url: String) {
        let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBrowser = "Brave".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Brave"
        let protectedBrowsers = getProtectedBrowsersList()
        let blockURL = "\(blockPageURL)?blocked=\(encodedURL)&browser=\(encodedBrowser)&protected=\(protectedBrowsers)"

        let blockScript = """
        tell application "Brave Browser"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set tabURL to URL of t
                        if tabURL contains "\(getSafeDomain(from: url))" and tabURL does not contain "blocked.html" then
                            set URL of t to "\(blockURL)"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """

        executeBlockingScript(blockScript, browserName: "Brave", blockedURL: url)
    }

    // MARK: - Edge Blocking

    private func checkEdgeTabs() {
        let script = """
        tell application "Microsoft Edge"
            if it is running then
                set urlList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set end of urlList to URL of t
                        end try
                    end repeat
                end repeat
                set AppleScript's text item delimiters to linefeed
                set urlText to urlList as text
                set AppleScript's text item delimiters to ""
                return urlText
            end if
        end tell
        return ""
        """

        executeScript(script, browserName: "Edge") { [weak self] urls in
            guard let self = self else { return }
            self.processURLs(urls, browserName: "Edge") { url in
                self.blockEdgeTab(url: url)
            }
        }
    }

    private func blockEdgeTab(url: String) {
        let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBrowser = "Edge".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Edge"
        let protectedBrowsers = getProtectedBrowsersList()
        let blockURL = "\(blockPageURL)?blocked=\(encodedURL)&browser=\(encodedBrowser)&protected=\(protectedBrowsers)"

        let blockScript = """
        tell application "Microsoft Edge"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set tabURL to URL of t
                        if tabURL contains "\(getSafeDomain(from: url))" and tabURL does not contain "blocked.html" then
                            set URL of t to "\(blockURL)"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """

        executeBlockingScript(blockScript, browserName: "Edge", blockedURL: url)
    }

    // MARK: - Arc Blocking

    private func checkArcTabs() {
        // Arc sometimes has AppleScript connection issues
        // Try a simpler script first to check if Arc is responding
        let script = """
        tell application "Arc"
            if it is running then
                set urlList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set end of urlList to URL of t
                        end try
                    end repeat
                end repeat
                set AppleScript's text item delimiters to linefeed
                set urlText to urlList as text
                set AppleScript's text item delimiters to ""
                return urlText
            end if
        end tell
        return ""
        """

        executeScript(script, browserName: "Arc") { [weak self] urls in
            guard let self = self else { return }
            // Log found URLs for debugging (throttled to once per minute)
            if !urls.isEmpty {
                let browserName = "Arc"
                let shouldLog = self.lastTabLogTime[browserName].map { Date().timeIntervalSince($0) >= self.tabLogCooldown } ?? true
                if shouldLog {
                    self.lastTabLogTime[browserName] = Date()
                    self.appDelegate?.postLog("🔍 Arc: Found \(urls.count) tabs")
                }
                // Domain match detection handled by processURLs
            }
            self.processURLs(urls, browserName: "Arc") { url in
                self.blockArcTab(url: url)
            }
        }
    }

    private func blockArcTab(url: String) {
        let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBrowser = "Arc".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Arc"
        let protectedBrowsers = getProtectedBrowsersList()
        let blockURL = "\(blockPageURL)?blocked=\(encodedURL)&browser=\(encodedBrowser)&protected=\(protectedBrowsers)"

        appDelegate?.postLog("🔧 Arc: Attempting to block URL: \(url)")
        appDelegate?.postLog("🔧 Arc: Redirect target: \(blockURL)")
        appDelegate?.postLog("🔧 Arc: Safe domain for matching: \(getSafeDomain(from: url))")

        // Try multiple methods to set Arc tab URLs
        // Arc's AppleScript dictionary is unusual - need to try different approaches
        let blockScript = """
        tell application "Arc"
            set matchCount to 0
            set blockedCount to 0
            set errorLog to ""

            -- Method 1: Standard windows/tabs approach
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set tabURL to URL of t
                        if tabURL contains "\(getSafeDomain(from: url))" then
                            set matchCount to matchCount + 1
                            if tabURL does not contain "blocked.html" then
                                try
                                    set URL of t to "\(blockURL)"
                                    set blockedCount to blockedCount + 1
                                on error errMsg
                                    set errorLog to errorLog & "setURL error: " & errMsg & "; "
                                end try
                            end if
                        end if
                    on error errMsg
                        set errorLog to errorLog & "getURL error: " & errMsg & "; "
                    end try
                end repeat
            end repeat

            -- If standard method didn't work, try active tab approach
            if blockedCount = 0 and matchCount > 0 then
                try
                    tell front window
                        set activeTabURL to URL of active tab
                        if activeTabURL contains "\(getSafeDomain(from: url))" and activeTabURL does not contain "blocked.html" then
                            set URL of active tab to "\(blockURL)"
                            set blockedCount to blockedCount + 1
                        end if
                    end tell
                on error errMsg
                    set errorLog to errorLog & "activeTab error: " & errMsg & "; "
                end try
            end if

            return "matched:" & matchCount & ",blocked:" & blockedCount & ",errors:" & errorLog
        end tell
        """

        executeBlockingScriptWithResult(blockScript, browserName: "Arc", blockedURL: url)
    }

    // MARK: - Generic Chromium-based Browser Blocking

    /// Check tabs for any Chromium-based browser (Chrome, Brave, Edge, Vivaldi, Opera, etc.)
    /// Most Chromium browsers share the same AppleScript API
    private func checkChromiumTabs(browserName: String, scriptName: String) {
        let script = """
        tell application "\(scriptName)"
            if it is running then
                set urlList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set end of urlList to URL of t
                        end try
                    end repeat
                end repeat
                set AppleScript's text item delimiters to linefeed
                set urlText to urlList as text
                set AppleScript's text item delimiters to ""
                return urlText
            end if
        end tell
        return ""
        """

        executeScript(script, browserName: browserName) { [weak self] urls in
            guard let self = self else { return }
            // Log found URLs for debugging (throttled to once per minute)
            if !urls.isEmpty {
                let shouldLog = self.lastTabLogTime[browserName].map { Date().timeIntervalSince($0) >= self.tabLogCooldown } ?? true
                if shouldLog {
                    self.lastTabLogTime[browserName] = Date()
                    self.appDelegate?.postLog("🔍 \(browserName): Found \(urls.count) tabs")
                }
                // Domain match detection handled by processURLs
            }
            self.processURLs(urls, browserName: browserName) { url in
                self.blockChromiumTab(url: url, browserName: browserName, scriptName: scriptName)
            }
        }
    }

    /// Block a tab in any Chromium-based browser
    private func blockChromiumTab(url: String, browserName: String, scriptName: String) {
        let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBrowser = browserName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? browserName
        let protectedBrowsers = getProtectedBrowsersList()
        let blockURL = "\(blockPageURL)?blocked=\(encodedURL)&browser=\(encodedBrowser)&protected=\(protectedBrowsers)"

        let blockScript = """
        tell application "\(scriptName)"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set tabURL to URL of t
                        if tabURL contains "\(getSafeDomain(from: url))" and tabURL does not contain "blocked.html" then
                            set URL of t to "\(blockURL)"
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """

        executeBlockingScript(blockScript, browserName: browserName, blockedURL: url)
    }

    // MARK: - Firefox-based Browser Blocking

    /// Check tabs for Firefox-based browsers (limited AppleScript support)
    private func checkFirefoxTabs(browserName: String, scriptName: String) {
        // Firefox has limited AppleScript support - it can get window info but not tab URLs
        // We log that the browser is running and show a notification
        appDelegate?.postLog("📌 \(browserName) detected - limited blocking support (no tab URL access)")

        // Still try to run AppleScript - some Firefox forks may support it
        let script = """
        tell application "\(scriptName)"
            if it is running then
                try
                    -- Try to get URLs (may not work on all Firefox-based browsers)
                    set urlList to {}
                    repeat with w in windows
                        try
                            set end of urlList to URL of current tab of w
                        end try
                    end repeat
                    set AppleScript's text item delimiters to linefeed
                    set urlText to urlList as text
                    set AppleScript's text item delimiters to ""
                    return urlText
                on error
                    return ""
                end try
            end if
        end tell
        return ""
        """

        executeScript(script, browserName: browserName) { [weak self] urls in
            guard let self = self, !urls.isEmpty else { return }
            // If we got URLs (some Firefox variants might support it), process them
            self.processURLs(urls, browserName: browserName) { url in
                self.blockFirefoxTab(url: url, browserName: browserName, scriptName: scriptName)
            }
        }
    }

    /// Attempt to block a tab in Firefox-based browsers
    private func blockFirefoxTab(url: String, browserName: String, scriptName: String) {
        let encodedURL = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBrowser = browserName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? browserName
        let protectedBrowsers = getProtectedBrowsersList()
        let blockURL = "\(blockPageURL)?blocked=\(encodedURL)&browser=\(encodedBrowser)&protected=\(protectedBrowsers)"

        // Firefox blocking is attempted but may not work on all variants
        let blockScript = """
        tell application "\(scriptName)"
            try
                repeat with w in windows
                    try
                        if URL of current tab of w contains "\(getSafeDomain(from: url))" then
                            set URL of current tab of w to "\(blockURL)"
                        end if
                    end try
                end repeat
            on error
                -- Firefox doesn't support tab URL manipulation via AppleScript
            end try
        end tell
        """

        executeBlockingScript(blockScript, browserName: browserName, blockedURL: url)
    }

    // MARK: - Helper Methods

    private func getProtectedBrowsersList() -> String {
        let setup = NativeMessagingSetup.shared
        let extensionIds = setup.getAllExtensionIds()
        guard !extensionIds.isEmpty else { return "" }

        let statuses = setup.getBrowserStatus()
        let protectedBrowsers = statuses.filter { $0.isEnabled }.map { $0.name }
        return protectedBrowsers.joined(separator: ",")
    }

    private func shouldBlock(url: String) -> Bool {
        // Don't block our own blocking page (prevents infinite recursion)
        // Check for file:// scheme, blocked.html, blocked= query param, or /Contents/Resources/ path
        let lowercasedURL = url.lowercased()
        if lowercasedURL.hasPrefix("file://") ||
           lowercasedURL.contains("blocked.html") ||
           lowercasedURL.contains("blocked=") ||
           lowercasedURL.contains("/contents/resources/") {
            return false
        }

        // Parse URL to extract just the host (not query params)
        // This prevents matching "youtube.com" in query strings
        guard let urlObj = URL(string: url),
              let host = urlObj.host?.lowercased() else {
            // Fallback: if URL parsing fails, do simple check but exclude query strings
            let urlWithoutQuery = url.components(separatedBy: "?").first ?? url
            return blockedDomains.contains { domain in
                urlWithoutQuery.lowercased().contains(domain)
            }
        }

        // Check if the host matches any blocked domain
        return blockedDomains.contains { domain in
            host == domain || host.hasSuffix("." + domain)
        }
    }

    private func getSafeDomain(from url: String) -> String {
        // Extract main domain for matching (e.g., "youtube.com" from full URL)
        let lowercasedURL = url.lowercased()
        for domain in blockedDomains {
            if lowercasedURL.contains(domain) {
                return domain
            }
        }
        return url
    }

    private func executeScript(_ script: String, browserName: String, completion: @escaping ([String]) -> Void) {
        // Prevent queue flooding: skip if a check script is already queued/running for this key
        guard !checkInFlight.contains(browserName) else { return }
        checkInFlight.insert(browserName)

        // Extract actual browser name for activeBrowsers check
        // (e.g., "Chrome-active" → "Chrome")
        let actualBrowser = browserName.components(separatedBy: "-").first ?? browserName

        // IMPORTANT: NSAppleScript is NOT thread-safe. Use serial queue to prevent crashes.
        appleScriptQueue.async { [weak self] in
            guard let self = self else { return }

            defer {
                DispatchQueue.main.async { self.checkInFlight.remove(browserName) }
            }

            // Bail if browser was removed from active set while queued
            guard self.activeBrowsers.contains(actualBrowser) else { return }

            guard let appleScript = NSAppleScript(source: script) else {
                DispatchQueue.main.async {
                    self.appDelegate?.postLog("❌ Failed to create AppleScript for \(browserName)")
                }
                return
            }

            let startTime = CFAbsoluteTimeGetCurrent()
            var error: NSDictionary?
            let output = appleScript.executeAndReturnError(&error)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            if let errorDict = error {
                let errorMsg = errorDict["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                let errorNum = errorDict["NSAppleScriptErrorNumber"] as? Int ?? 0
                DispatchQueue.main.async {
                    self.appDelegate?.postLog("❌ \(browserName) AppleScript error (\(String(format: "%.1f", elapsed))s): \(errorMsg) (code: \(errorNum))")
                }
                return
            }

            DispatchQueue.main.async {
                self.appDelegate?.postLog("⏱️ \(browserName) script took \(String(format: "%.1f", elapsed))s")
            }

            if let urlString = output.stringValue, !urlString.isEmpty {
                // Split by newline since all scripts now use linefeed as delimiter
                let urls = urlString.components(separatedBy: "\n").filter { !$0.isEmpty }
                DispatchQueue.main.async {
                    completion(urls)
                }
            }
        }
    }

    private func executeBlockingScript(_ script: String, browserName: String, blockedURL: String) {
        // Use serial queue to prevent concurrent AppleScript execution
        appleScriptQueue.async { [weak self] in
            guard let self = self else { return }

            // Clear in-flight tracking when done (on main queue where it's accessed)
            defer {
                let domain = self.getBaseDomain(from: blockedURL)
                DispatchQueue.main.async {
                    if let domain = domain {
                        self.inFlightDomains.remove(domain)
                    }
                }
            }

            // Bail if browser was removed from active set while queued
            guard self.activeBrowsers.contains(browserName) else { return }

            guard let appleScript = NSAppleScript(source: script) else {
                DispatchQueue.main.async {
                    self.appDelegate?.postLog("❌ Failed to create blocking script for \(browserName)")
                }
                return
            }

            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)

            if let errorDict = error {
                let errorMsg = errorDict["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                DispatchQueue.main.async {
                    self.appDelegate?.postLog("❌ Block failed for \(browserName): \(errorMsg)")
                }
            } else {
                DispatchQueue.main.async {
                    self.appDelegate?.postLog("🚫 Blocked: \(blockedURL) in \(browserName)")

                    // Show native notification
                    let domain = self.getSafeDomain(from: blockedURL)
                    self.showBlockedSiteNotification(site: domain, browser: browserName)

                    // Log to backend
                    Task {
                        await self.backendClient.sendEvent(type: "site_blocked", details: [
                            "url": blockedURL,
                            "browser": browserName,
                            "method": "applescript"
                        ])
                    }
                }
            }
        }
    }

    /// Execute blocking script and capture the result (for debugging)
    /// Uses a serial queue to prevent concurrent AppleScript execution which can cause hangs
    private func executeBlockingScriptWithResult(_ script: String, browserName: String, blockedURL: String) {
        // Use serial queue to prevent concurrent AppleScript execution
        appleScriptQueue.async { [weak self] in
            guard let self = self else { return }

            // Clear in-flight tracking when done
            defer {
                let domain = self.getBaseDomain(from: blockedURL)
                DispatchQueue.main.async {
                    if let domain = domain {
                        self.inFlightDomains.remove(domain)
                    }
                }
            }

            // Bail if browser was removed from active set while queued
            guard self.activeBrowsers.contains(browserName) else { return }

            DispatchQueue.main.async {
                self.appDelegate?.postLog("⏳ \(browserName): Starting AppleScript execution...")
            }

            guard let appleScript = NSAppleScript(source: script) else {
                DispatchQueue.main.async {
                    self.appDelegate?.postLog("❌ Failed to create blocking script for \(browserName)")
                }
                return
            }

            var error: NSDictionary?
            let result = appleScript.executeAndReturnError(&error)

            if let errorDict = error {
                let errorMsg = errorDict["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                let errorNum = errorDict["NSAppleScriptErrorNumber"] as? Int ?? 0
                DispatchQueue.main.async {
                    self.appDelegate?.postLog("❌ Block failed for \(browserName): \(errorMsg) (code: \(errorNum))")
                }
            } else {
                let resultString = result.stringValue ?? "no result"
                DispatchQueue.main.async {
                    self.appDelegate?.postLog("🔧 \(browserName) block script result: \(resultString)")

                    // Check if we actually blocked anything
                    if resultString.contains("blocked:0") {
                        self.appDelegate?.postLog("⚠️ \(browserName): Script ran but no tabs were blocked - URL may have already changed or AppleScript can't set URL")
                    } else if resultString.contains("blocked:") {
                        self.appDelegate?.postLog("🚫 Blocked: \(blockedURL) in \(browserName)")

                        // Show native notification
                        let domain = self.getSafeDomain(from: blockedURL)
                        self.showBlockedSiteNotification(site: domain, browser: browserName)

                        // Log to backend
                        Task {
                            await self.backendClient.sendEvent(type: "site_blocked", details: [
                                "url": blockedURL,
                                "browser": browserName,
                                "method": "applescript"
                            ])
                        }
                    }
                }
            }
        }
    }

    deinit {
        stopBlocking()
    }
}

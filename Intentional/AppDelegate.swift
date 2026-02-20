//
//  AppDelegate.swift
//  Intentional
//
//  Main application delegate - entry point for the app
//

import Cocoa
import Foundation
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {

    // Menu bar icon
    var statusBarItem: NSStatusItem?

    // Main window
    var mainWindowController: MainWindow?

    // Monitoring components
    var sleepWakeMonitor: SleepWakeMonitor?
    var browserMonitor: BrowserMonitor?
    var websiteBlocker: WebsiteBlocker?
    var backendClient: BackendClient?
    var permissionManager: PermissionManager?

    // Cross-browser time tracking (Phase 3)
    var nativeMessagingHost: NativeMessagingHost?
    var timeTracker: TimeTracker?

    // Native app heartbeat timer (Phase 2: Tamper Detection)
    var heartbeatTimer: Timer?

    // Socket relay server for Native Messaging
    var socketRelayServer: SocketRelayServer?

    // Extension re-scan timer
    var extensionRescanTimer: Timer?
    private let heartbeatInterval: TimeInterval = 120.0  // 2 minutes
    private let appStartTime = Date()

    // MARK: - Strict Mode (Tamper-Resistant Persistence)

    /// Path to the strict mode flag file.
    /// Watchdog checks this to decide whether to relaunch.
    func strictModeFlagPath() -> String {
        let appSupport = NSHomeDirectory() + "/Library/Application Support/Intentional"
        try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        return appSupport + "/strict-mode"
    }

    /// Block Cmd+Q when accountability lock is active.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let lockMode = UserDefaults.standard.string(forKey: "lockMode") ?? "none"

        if lockMode == "none" {
            return .terminateNow
        }

        // Locked — show dialog, block quit
        postLog("🔒 Quit blocked — lock mode is '\(lockMode)'")
        let alert = NSAlert()
        alert.messageText = "Intentional is Locked"
        alert.informativeText = "This app is in accountability mode. To quit, unlock it first through your accountability partner."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Running")
        alert.runModal()

        return .terminateCancel
    }

    /// Enable/disable strict mode based on lock mode.
    /// Called on launch and whenever lock mode changes.
    func updateStrictMode(lockMode: String) {
        let strictEnabled = (lockMode == "partner" || lockMode == "self")
        postLog("🔒 updateStrictMode: lockMode=\(lockMode), strict=\(strictEnabled)")

        // 1. Login item: auto-start on login
        if #available(macOS 13.0, *) {
            if strictEnabled {
                do {
                    try SMAppService.mainApp.register()
                    postLog("✅ Login item registered (auto-start on login)")
                } catch {
                    postLog("⚠️ Failed to register login item: \(error)")
                }
            } else {
                do {
                    try SMAppService.mainApp.unregister()
                    postLog("✅ Login item unregistered")
                } catch {
                    // Not registered — that's fine
                }
            }
        }

        // 2. Strict mode flag file (for watchdog + SIGTERM handler)
        let flagPath = strictModeFlagPath()
        if strictEnabled {
            FileManager.default.createFile(atPath: flagPath, contents: "1".data(using: .utf8))
            postLog("✅ Strict mode flag written: \(flagPath)")
        } else {
            try? FileManager.default.removeItem(atPath: flagPath)
            postLog("✅ Strict mode flag removed")
        }

        // 3. Watchdog LaunchAgent
        updateWatchdog(enabled: strictEnabled)
    }

    /// Register/unregister the watchdog LaunchAgent that relaunches the app if force-quit.
    private func updateWatchdog(enabled: Bool) {
        if #available(macOS 13.0, *) {
            let agent = SMAppService.agent(plistName: "com.intentional.watchdog.plist")
            if enabled {
                do {
                    try agent.register()
                    postLog("✅ Watchdog agent registered")
                } catch {
                    postLog("⚠️ Failed to register watchdog: \(error)")
                }
            } else {
                agent.unregister { [weak self] error in
                    if let error = error {
                        self?.postLog("⚠️ Failed to unregister watchdog: \(error)")
                    } else {
                        self?.postLog("✅ Watchdog agent unregistered")
                    }
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // DIAGNOSTIC: Log every launch attempt to persistent file
        let diagnosticLogPath = NSTemporaryDirectory() + "intentional-launches.log"
        let launchTime = Date()
        let launchLog = """
        ===== LAUNCH ATTEMPT =====
        Time: \(launchTime)
        PID: \(ProcessInfo.processInfo.processIdentifier)
        Args: \(CommandLine.arguments.joined(separator: " "))
        isatty(STDIN): \(isatty(STDIN_FILENO))
        isatty(STDOUT): \(isatty(STDOUT_FILENO))
        ========================

        """
        if let existingLog = try? String(contentsOfFile: diagnosticLogPath, encoding: .utf8) {
            try? (existingLog + launchLog).write(toFile: diagnosticLogPath, atomically: true, encoding: .utf8)
        } else {
            try? launchLog.write(toFile: diagnosticLogPath, atomically: true, encoding: .utf8)
        }

        // Multiple logging methods to ensure we see SOMETHING
        print("=== applicationDidFinishLaunching CALLED ===")
        NSLog("=== applicationDidFinishLaunching CALLED (NSLog) ===")

        let logPath = NSTemporaryDirectory() + "intentional-debug.log"
        "applicationDidFinishLaunching called at \(Date())\n".appendLine(to: logPath)

        postLog("✅ Intentional app launched")

        // Re-enable auto-launch from extensions (user manually started the app)
        // This allows extension relays to launch the app via NSWorkspace
        UserDefaults.standard.set(true, forKey: "allowAutoLaunchFromExtension")
        postLog("✅ Auto-launch from extensions enabled (app manually started)")

        // Initialize backend client
        backendClient = BackendClient(baseURL: "https://api.intentional.social")
        postLog("🔗 Backend URL: https://api.intentional.social")

        // Create main window (WKWebView-based: shows onboarding or dashboard)
        mainWindowController = MainWindow(appDelegate: self)
        postLog("🪟 Main window created")

        // Bring window to front
        NSApp.activate(ignoringOtherApps: true)

        // Create menu bar icon
        setupMenuBar()
        postLog("🔝 Menu bar icon added")

        // Start permission monitoring
        permissionManager = PermissionManager(appDelegate: self)
        permissionManager?.startMonitoring()
        postLog("✅ Permission monitoring started")

        // Start sleep/wake monitoring
        sleepWakeMonitor = SleepWakeMonitor(backendClient: backendClient!, appDelegate: self)
        postLog("✅ Sleep/wake monitoring registered")

        // Start website blocker (ScreenTime + AppleEvents fallback)
        websiteBlocker = WebsiteBlocker(backendClient: backendClient!, appDelegate: self)
        websiteBlocker?.startBlocking()
        postLog("✅ Website blocking initialized")

        // Start browser monitoring (all browsers)
        browserMonitor = BrowserMonitor(backendClient: backendClient!, appDelegate: self)
        browserMonitor?.websiteBlocker = websiteBlocker  // Connect them
        browserMonitor?.startMonitoring()
        postLog("✅ Multi-browser monitoring started")

        // Register device, sync state, and send startup event (in sequence)
        Task {
            await backendClient?.registerDevice()

            // Sync lock/partner state from backend (fixes stale local state)
            if let status = await backendClient?.getUnlockStatus() {
                await MainActor.run {
                    mainWindowController?.syncStateFromBackend(status)
                }
            }

            await backendClient?.sendEvent(type: "app_started", details: [:])
        }

        // Initialize strict mode based on current lock setting
        let currentLockMode = UserDefaults.standard.string(forKey: "lockMode") ?? "none"
        updateStrictMode(lockMode: currentLockMode)

        // Notify UI
        postEventNotification(type: "app_started")

        // Start native app heartbeat (Phase 2: Tamper Detection)
        // Backend uses this to detect if native app is quit while computer is awake
        startHeartbeat()

        // Initialize cross-browser time tracking (Phase 3)
        // TimeTracker aggregates time from ALL browsers into single budget
        timeTracker = TimeTracker(appDelegate: self)
        timeTracker?.backendClient = backendClient
        postLog("⏱️ TimeTracker initialized")

        // Wire up cross-browser session sync: when a session changes in TimeTracker,
        // broadcast SESSION_SYNC to all connected browsers via the socket relay server
        timeTracker?.onSessionChanged = { [weak self] platform in
            self?.postLog("🌐 Session changed for \(platform) — broadcasting to all browsers")
            self?.socketRelayServer?.broadcastSessionSync()
        }

        // All extension connections come through the socket relay server.
        // Chrome-launched processes are thin relays (in main.swift) that forward
        // stdin/stdout ↔ socket. The primary app never reads from stdin.
        // nativeMessagingHost is kept as a template for SocketRelayServer's per-connection handlers.
        nativeMessagingHost = NativeMessagingHost(appDelegate: self)
        nativeMessagingHost?.timeTracker = timeTracker
        postLog("🔌 Primary app — all extension connections via socket relay")

        // Start socket relay server for Native Messaging
        socketRelayServer = SocketRelayServer(appDelegate: self)
        if socketRelayServer?.start() == true {
            postLog("🔌 Socket relay server started - extensions will relay through socket")
        } else {
            postLog("⚠️ Socket relay server failed to start")
        }

        // Auto-discover extensions and install manifests
        let discovered = NativeMessagingSetup.shared.autoDiscoverExtensions()
        if discovered > 0 {
            postLog("🔍 Auto-discovered \(discovered) Intentional extension(s)")
        }

        NativeMessagingSetup.shared.installManifestsIfNeeded()

        let totalIds = NativeMessagingSetup.shared.getAllExtensionIds()
        if !totalIds.isEmpty {
            postLog("📋 Native Messaging manifests installed for \(totalIds.count) extension(s)")
        } else {
            postLog("⚠️ No extensions found - install the Intentional extension in Chrome")
        }

        // CRITICAL: Re-check browser protection status after extension discovery
        browserMonitor?.recheckBrowserProtection()

        // Start periodic extension re-scanning (detects enable/disable changes)
        extensionRescanTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            NativeMessagingSetup.shared.autoDiscoverExtensions()
            self.browserMonitor?.recheckBrowserProtection()
        }
        postLog("🔄 Extension re-scan timer started (every 60s)")

        postLog("✅ All monitors initialized")
    }

    // MARK: - Native App Heartbeat (Tamper Detection)

    private func startHeartbeat() {
        // Send first heartbeat immediately
        sendHeartbeat()

        // Schedule recurring heartbeats every 2 minutes
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            self?.sendHeartbeat()
        }
        postLog("💓 Heartbeat timer started (every \(Int(heartbeatInterval))s)")
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        postLog("💔 Heartbeat timer stopped")
    }

    private func sendHeartbeat() {
        let uptime = Date().timeIntervalSince(appStartTime)

        // Collect running browsers for additional context
        var runningBrowsers: [String] = []
        if let browsers = browserMonitor?.getAllBrowsers() {
            let runningApps = NSWorkspace.shared.runningApplications
            for (bundleId, info) in browsers {
                if runningApps.contains(where: { $0.bundleIdentifier == bundleId }) {
                    runningBrowsers.append(info.name)
                }
            }
        }

        Task {
            await backendClient?.sendEvent(type: "native_app_heartbeat", details: [
                "version": "1.0",
                "uptime_seconds": Int(uptime),
                "running_browsers": runningBrowsers,
                "browser_count": runningBrowsers.count
            ])
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        postLog("⚠️ App terminating")

        // User quit the primary app — disable auto-launch from extensions.
        // With the relay architecture, the primary is always manually launched,
        // so this always runs when the user quits.
        UserDefaults.standard.set(false, forKey: "allowAutoLaunchFromExtension")
        postLog("🚫 Auto-launch from extensions disabled (app was quit by user)")

        // Stop timers
        stopHeartbeat()
        extensionRescanTimer?.invalidate()
        extensionRescanTimer = nil

        // Stop socket relay server and Native Messaging host
        socketRelayServer?.stop()
        nativeMessagingHost?.stop()

        // Force sync time tracking data
        timeTracker?.forceSync()

        // Send shutdown event before quitting (synchronously to ensure it's sent)
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await backendClient?.sendEvent(type: "app_quit", details: [
                "uptime_seconds": Int(Date().timeIntervalSince(appStartTime)),
                "quit_type": "normal"  // Distinguishes from crash/force-quit
            ])
            semaphore.signal()
        }
        // Wait up to 2 seconds for the event to send
        _ = semaphore.wait(timeout: .now() + 2.0)
    }

    // MARK: - Menu Bar Setup

    func setupMenuBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusBarItem?.button {
            // Use SF Symbol
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "eye.circle.fill", accessibilityDescription: "Intentional")
            } else {
                button.title = "👁️"
            }
        }

        // Create menu
        let menu = NSMenu()

        // Status item
        let statusItem = NSMenuItem(title: "Status: Active ✓", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Show window
        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showMainWindow), keyEquivalent: "w"))

        // Debug Monitor
        menu.addItem(NSMenuItem(title: "Debug Monitor", action: #selector(showDebugMonitor), keyEquivalent: "m"))

        // Dashboard
        menu.addItem(NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d"))

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit Intentional", action: #selector(quitApp), keyEquivalent: "q"))

        statusBarItem?.menu = menu
    }

    @objc func showMainWindow() {
        mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - URL Scheme Handler (intentional://)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "intentional" else { continue }
            let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            postLog("🔗 URL scheme opened: \(url.absoluteString) (action: \(action))")

            switch action {
            case "open", "dashboard", "":
                showMainWindow()
            default:
                postLog("🔗 Unknown URL action: \(action), showing main window")
                showMainWindow()
            }
        }
    }

    @objc func showDebugMonitor() {
        mainWindowController?.showDebugMonitor()
    }

    @objc func openDashboard() {
        // Open web dashboard
        if let url = URL(string: "https://intentional.social/dashboard") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }

    // MARK: - Event Notifications

    func postEventNotification(type: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("SystemEventOccurred"),
            object: nil,
            userInfo: ["type": type]
        )
    }

    func postLog(_ message: String) {
        print(message)

        // Also write to log file for debugging
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logPath = NSTemporaryDirectory() + "intentional-debug.log"

        // Log rotation: if file exceeds 50MB, rotate
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? Int,
           size > 50_000_000 {
            let oldPath = logPath + ".old"
            try? FileManager.default.removeItem(atPath: oldPath)
            try? FileManager.default.moveItem(atPath: logPath, toPath: oldPath)
        }

        "[\(timestamp)] \(message)\n".appendLine(to: logPath)

        NotificationCenter.default.post(
            name: NSNotification.Name("AppLogMessage"),
            object: nil,
            userInfo: ["message": message]
        )
    }
}

// Helper extension for file logging
extension String {
    func appendLine(to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            if let data = self.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            // File doesn't exist, create it
            try? self.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

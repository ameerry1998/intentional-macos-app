//
//  AppDelegate.swift
//  Intentional
//
//  Main application delegate - entry point for the app
//

import Cocoa
import Foundation

// @main removed - using explicit main.swift instead
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
    private let heartbeatInterval: TimeInterval = 120.0  // 2 minutes
    private let appStartTime = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Multiple logging methods to ensure we see SOMETHING
        print("=== applicationDidFinishLaunching CALLED ===")
        NSLog("=== applicationDidFinishLaunching CALLED (NSLog) ===")

        let logPath = NSTemporaryDirectory() + "intentional-debug.log"
        "applicationDidFinishLaunching called at \(Date())\n".appendLine(to: logPath)

        postLog("✅ Intentional app launched")

        // Initialize backend client
        // TODO: Change to https://api.intentional.social when deployed
        backendClient = BackendClient(baseURL: "http://localhost:8000")
        postLog("🔗 Backend URL: http://localhost:8000")

        // Create main window
        mainWindowController = MainWindow()
        mainWindowController?.showWindow(nil)
        postLog("🪟 Main window created")

        // Bring window to front - force it
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        mainWindowController?.window?.orderFrontRegardless()

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

        // Register device and send startup event (in sequence)
        Task {
            // Register first (idempotent - safe to call every time)
            await backendClient?.registerDevice()

            // Then send startup event
            await backendClient?.sendEvent(type: "app_started", details: [:])
        }

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

        // Native Messaging host for extension communication
        // Note: Only starts if launched via Native Messaging (stdin available)
        if isLaunchedViaNativeMessaging() {
            nativeMessagingHost = NativeMessagingHost(appDelegate: self)
            nativeMessagingHost?.timeTracker = timeTracker
            nativeMessagingHost?.start()
            postLog("🔌 Native Messaging mode - connected to extension")
        }

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

        // Stop heartbeat timer
        stopHeartbeat()

        // Stop Native Messaging host
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

    /// Check if app was launched via Native Messaging (stdin is a pipe, not a terminal)
    private func isLaunchedViaNativeMessaging() -> Bool {
        // When launched by Chrome via Native Messaging, stdin is a pipe
        // When launched normally, stdin is /dev/ttys00X or similar
        return isatty(STDIN_FILENO) == 0
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

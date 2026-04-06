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

    // Daily Focus Plan (V2)
    var scheduleManager: ScheduleManager?
    var relevanceScorer: RelevanceScorer?
    var focusMonitor: FocusMonitor?
    var nudgeController: NudgeWindowController?

    // Earn Your Browse budget system
    var earnedBrowseManager: EarnedBrowseManager?

    // Intentional Mode — screen lock until you plan
    var intentionalModeController: IntentionalModeController?

    // Content Safety — on-device screen monitoring for explicit content
    var contentSafetyMonitor: ContentSafetyMonitor?

    // Root daemon XPC client (tamper-resistant strict mode)
    let daemonClient = DaemonXPCClient()

    // Native app heartbeat timer (Phase 2: Tamper Detection)
    var heartbeatTimer: Timer?

    // Socket relay server for Native Messaging
    var socketRelayServer: SocketRelayServer?

    // Extension re-scan timer
    var extensionRescanTimer: Timer?
    private let heartbeatInterval: TimeInterval = 120.0  // 2 minutes
    private let appStartTime = Date()

    // MARK: - Strict Mode (Tamper-Resistant Persistence)
    //
    // Two paths:
    // 1. Daemon installed (PKG): XPC to syspolicyd_helper — config in /private/var/, tamper-resistant
    // 2. No daemon (dev/DMG): fallback to UserDefaults + flag file — bypassable but functional

    /// Path to the strict mode flag file (fallback when daemon is not running).
    func strictModeFlagPath() -> String {
        let appSupport = NSHomeDirectory() + "/Library/Application Support/Intentional"
        try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        return appSupport + "/strict-mode"
    }

    /// Block Cmd+Q when strict mode is enabled.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Ask daemon first, fall back to UserDefaults
        let strictEnabled = daemonClient.isStrictModeEnabledSync()

        if !strictEnabled {
            return .terminateNow
        }

        // Strict mode is ON — block quit (requires partner code to disable via dashboard)
        postLog("🔒 Quit blocked — strict mode ON (requires partner code to disable)")
        let alert = NSAlert()
        alert.messageText = "App Persistence is On"
        alert.informativeText = "Intentional is set to keep running. To disable this, open settings and request a code from your accountability partner."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Running")
        alert.runModal()
        return .terminateCancel
    }

    /// Enable/disable strict mode.
    /// If daemon is running, it is the AUTHORITY — UserDefaults cannot override it.
    /// This prevents the `defaults write strictModeEnabled false` bypass.
    func updateStrictMode() {
        var strictEnabled = UserDefaults.standard.bool(forKey: "strictModeEnabled")

        // If daemon is available, check its state FIRST.
        // If daemon says strict=true but UserDefaults says false, someone tampered
        // with UserDefaults. Trust the daemon and restore UserDefaults.
        if daemonClient.isDaemonAvailable {
            let daemonState = daemonClient.isStrictModeEnabledSync()
            if daemonState && !strictEnabled {
                postLog("🔒 TAMPER DETECTED: UserDefaults says strict=false but daemon says true. Restoring.")
                UserDefaults.standard.set(true, forKey: "strictModeEnabled")
                strictEnabled = true
            }
        }

        postLog("🔒 updateStrictMode: strict=\(strictEnabled)")

        // Sync to daemon (if running)
        daemonClient.setStrictMode(enabled: strictEnabled) { [weak self] success, error in
            if success {
                self?.postLog("🔒 Daemon: strict mode synced")
            } else if let error = error {
                self?.postLog("🔒 Daemon: strict mode rejected — \(error)")
            }
        }

        // Also sync partner state to daemon
        var lockMode = UserDefaults.standard.string(forKey: "lockMode") ?? "none"
        if lockMode == "self" { // "self" lock mode removed — migrate on startup
            lockMode = "none"
            UserDefaults.standard.set("none", forKey: "lockMode")
        }
        let isLocked = lockMode != "none"
        let deviceId = UserDefaults.standard.string(forKey: "deviceId")
        // Read partner email from settings file
        let settingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional/onboarding_settings.json")
        var partnerEmail: String?
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            partnerEmail = json["partnerEmail"] as? String
        }
        daemonClient.updatePartnerLockState(isLocked: isLocked, partnerEmail: partnerEmail, deviceId: deviceId)

        // Fallback: login item (only when daemon is NOT available)
        if !daemonClient.isDaemonAvailable {
            if #available(macOS 13.0, *) {
                if strictEnabled {
                    do {
                        try SMAppService.mainApp.register()
                        postLog("✅ Login item registered (fallback — no daemon)")
                    } catch {
                        postLog("⚠️ Failed to register login item: \(error)")
                    }
                } else {
                    do {
                        try SMAppService.mainApp.unregister()
                        postLog("✅ Login item unregistered")
                    } catch {}
                }
            }
        }

        // Fallback: flag file (only when daemon is NOT available)
        if !daemonClient.isDaemonAvailable {
            let flagPath = strictModeFlagPath()
            if strictEnabled {
                FileManager.default.createFile(atPath: flagPath, contents: "1".data(using: .utf8))
                postLog("✅ Strict mode flag written (fallback)")
            } else {
                try? FileManager.default.removeItem(atPath: flagPath)
                postLog("✅ Strict mode flag removed (fallback)")
            }
            updateWatchdog(enabled: strictEnabled)
        } else {
            postLog("🔒 Daemon available — skipping fallback flag file + watchdog")
        }
    }

    /// Register/unregister the watchdog LaunchAgent (fallback when daemon is not running).
    private func updateWatchdog(enabled: Bool) {
        if #available(macOS 13.0, *) {
            let agent = SMAppService.agent(plistName: "com.intentional.watchdog.plist")
            if enabled {
                do {
                    try agent.register()
                    postLog("✅ Watchdog agent registered (fallback)")
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

        // Safety net: restore color in case previous instance was killed with grayscale active
        GrayscaleOverlayController.forceRestoreSaturation()

        // Re-enable auto-launch from extensions (user manually started the app)
        // This allows extension relays to launch the app via NSWorkspace
        UserDefaults.standard.set(true, forKey: "allowAutoLaunchFromExtension")
        postLog("✅ Auto-launch from extensions enabled (app manually started)")

        // Connect to root daemon (if installed via PKG)
        daemonClient.connect()
        if daemonClient.isDaemonAvailable {
            postLog("🔒 Daemon connected — tamper-resistant mode")
        } else {
            postLog("🔒 Daemon not available — using UserDefaults fallback")
        }

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
        setupMainMenu()
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
        // Load custom distracting sites from settings
        if let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let settingsURL = supportDir.appendingPathComponent("Intentional/onboarding_settings.json")
            postLog("🌐🔍 Loading distracting sites from: \(settingsURL.path)")
            if let data = try? Data(contentsOf: settingsURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let sites = json["distractingSites"] as? [String] ?? []
                postLog("🌐🔍 Found distractingSites in settings: \(sites)")
                if !sites.isEmpty {
                    websiteBlocker?.updateDistractingSites(sites)
                } else {
                    postLog("🌐🔍 distractingSites is EMPTY — nothing will be blocked by WebsiteBlocker")
                }
            } else {
                postLog("🌐🔍 Could not read settings file or parse JSON")
            }
        } else {
            postLog("🌐🔍 Could not find Application Support directory")
        }
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

            // Restore settings from backend on fresh install (no local settings file)
            await self.restoreSettingsFromBackendIfNeeded()

            await backendClient?.sendEvent(type: "app_started", details: [:])
        }

        // Initialize strict mode based on user preference
        updateStrictMode()

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

        // Initialize Earn Your Browse budget system
        earnedBrowseManager = EarnedBrowseManager(appDelegate: self)
        earnedBrowseManager?.load()
        postLog("💰 EarnedBrowseManager initialized")

        // Wire TimeTracker callback: deduct social media time from earned pool
        timeTracker?.onSocialMediaTimeRecorded = { [weak self] platform, minutes, isFreeBrowse in
            guard let mgr = self?.earnedBrowseManager else { return }
            let blockType = self?.scheduleManager?.currentBlock?.blockType ?? .freeTime
            let remaining = mgr.recordSocialMediaTime(
                minutes: minutes, blockType: blockType, isFreeBrowse: isFreeBrowse
            )
            self?.socketRelayServer?.broadcastEarnedMinutesUpdate(mgr)
            self?.mainWindowController?.pushEarnedUpdate()
            self?.postLog("💰 Social media time: -\(String(format: "%.1f", minutes))m, remaining: \(String(format: "%.1f", remaining))m")
        }

        // Initialize Daily Focus Plan (V2: schedule engine + relevance scoring)
        scheduleManager = ScheduleManager(appDelegate: self)
        relevanceScorer = RelevanceScorer(appDelegate: self)

        // Initialize focus monitor and nudge window (V2: desktop app monitoring)
        nudgeController = NudgeWindowController(appDelegate: self)
        let focusOverlayController = FocusOverlayWindowController(appDelegate: self)
        focusMonitor = FocusMonitor(appDelegate: self)
        focusMonitor?.scheduleManager = scheduleManager
        focusMonitor?.relevanceScorer = relevanceScorer
        focusMonitor?.nudgeController = nudgeController
        focusMonitor?.overlayController = focusOverlayController
        let interventionController = InterventionOverlayController(appDelegate: self)
        focusMonitor?.interventionController = interventionController
        // focusMonitor?.ritualController = BlockRitualController()  // Now pill-centric
        focusMonitor?.endRitualController = BlockEndRitualController()
        // Load user-configured distracting apps from saved settings
        let settingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional").appendingPathComponent("onboarding_settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let apps = json["distractingApps"] as? [[String: Any]] {
                focusMonitor?.distractingAppBundleIds = Set(apps.compactMap { $0["bundleId"] as? String })
            }
            if let sites = json["alwaysRelevantSites"] as? [String] {
                focusMonitor?.alwaysRelevantHostnames = Set(sites.map { $0.lowercased() })
                postLog("👁️ Loaded \(sites.count) always-relevant site(s): \(sites)")
            }
            // Load AI override settings
            focusMonitor?.overridePartnerApprovalRequired = json["overridePartnerRequired"] as? Bool ?? false
            let partnerEmail = json["partnerEmail"] as? String ?? ""
            focusMonitor?.hasConfiguredPartner = !partnerEmail.isEmpty
        }
        focusMonitor?.start()
        postLog("👁️ FocusMonitor + NudgeWindowController + FocusOverlayWindow + InterventionOverlay initialized")

        // Initialize Intentional Mode (screen lock until you plan)
        intentionalModeController = IntentionalModeController(appDelegate: self)
        intentionalModeController?.scheduleManager = scheduleManager
        intentionalModeController?.loadSettings()
        intentionalModeController?.recalculateState()
        intentionalModeController?.start()
        postLog("🔒 IntentionalModeController initialized (enabled=\(intentionalModeController?.isEnabled ?? false))")

        // Wire schedule block changes: when the active block changes,
        // clear the relevance cache, reset focus monitor, and broadcast SCHEDULE_SYNC
        scheduleManager?.onBlockChanged = { [weak self] block, state in
            guard let self = self else { return }
            self.postLog("📋 Block changed → \(state.rawValue)" + (block != nil ? " (\(block!.title))" : ""))

            // Capture previous block data BEFORE resetting activeBlockId
            let prevBlockId = self.earnedBrowseManager?.activeBlockId
            let prevStats = prevBlockId.flatMap { self.earnedBrowseManager?.blockFocusStats[$0] }
            let prevBlock = prevBlockId.flatMap { id in
                self.scheduleManager?.todaySchedule?.blocks.first(where: { $0.id == id })
            }

            self.relevanceScorer?.clearCache()
            // Set activeBlockId BEFORE focusMonitor re-evaluates (which may call recordWorkTick)
            self.earnedBrowseManager?.onBlockChanged(blockId: block?.id, blockTitle: block?.title)
            self.focusMonitor?.onBlockChanged()
            self.intentionalModeController?.onBlockChanged(block: block, timeState: state)
            self.socketRelayServer?.broadcastScheduleSync()
            self.mainWindowController?.pushScheduleUpdate()

            // Show celebration in the pill for the block that just ended
            if let prevBlock = prevBlock, let prevStats = prevStats,
               prevBlock.id != block?.id,      // Not the same block (edited)
               prevStats.totalTicks > 0 {      // User was actually present

                let nextBlock = self.scheduleManager?.nextUpcomingBlock()

                self.focusMonitor?.showCelebration(
                    block: prevBlock,
                    stats: prevStats,
                    nextBlock: nextBlock,
                    onDone: {}
                )
            }

            // If celebration was skipped but pill was in blockComplete, resume deferred start
            self.focusMonitor?.resumeIfPendingBlockStart()
        }

        // ScheduleManager.init() already called recalculateState(), but the callback
        // wasn't wired yet, so activeBlockId was never set. Sync it now in case the
        // app started during a work block.
        if let block = scheduleManager?.currentBlock {
            earnedBrowseManager?.onBlockChanged(blockId: block.id, blockTitle: block.title)
            // Also sync focusMonitor so the floating timer shows immediately on startup mid-block
            focusMonitor?.onBlockChanged()
        }

        // Content Safety Monitor — on-device screen monitoring for explicit content
        contentSafetyMonitor = ContentSafetyMonitor(appDelegate: self)
        // Load enabled state from persisted settings
        let csSettingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional/onboarding_settings.json")
        if let csData = try? Data(contentsOf: csSettingsURL),
           let csJSON = try? JSONSerialization.jsonObject(with: csData) as? [String: Any],
           let csSettings = csJSON["contentSafety"] as? [String: Any],
           let csEnabled = csSettings["enabled"] as? Bool, csEnabled {
            contentSafetyMonitor?.onSettingsChanged(enabled: true)
        }
        postLog("🛡️ ContentSafetyMonitor initialized")

        // All extension connections come through the socket relay server.
        // Chrome-launched processes are thin relays (in main.swift) that forward
        // stdin/stdout ↔ socket. The primary app never reads from stdin.
        // nativeMessagingHost is kept as a template for SocketRelayServer's per-connection handlers.
        nativeMessagingHost = NativeMessagingHost(appDelegate: self)
        nativeMessagingHost?.timeTracker = timeTracker
        nativeMessagingHost?.scheduleManager = scheduleManager
        nativeMessagingHost?.relevanceScorer = relevanceScorer
        nativeMessagingHost?.earnedBrowseManager = earnedBrowseManager
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
        // Also ping the daemon so it knows the app is alive
        daemonClient.sendHeartbeat()

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

        // Stop content safety monitor
        contentSafetyMonitor?.stop()

        // Stop focus monitor
        focusMonitor?.stop()

        // Stop socket relay server and Native Messaging host
        socketRelayServer?.stop()
        nativeMessagingHost?.stop()

        // Force sync time tracking data
        timeTracker?.forceSync()

        // Save earned browse state
        earnedBrowseManager?.save()

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

    /// Set up the main menu bar with an Edit menu so Cmd+C/V/X work in WKWebView text fields.
    func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (required as first item)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Intentional", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — enables Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z in WKWebView
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func showMainWindow() {
        mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show main window and navigate to a specific dashboard page (e.g., "focus").
    func showDashboardPage(_ pageId: String) {
        showMainWindow()
        // Small delay to ensure the webview is ready after showing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.mainWindowController?.navigateToPage(pageId)
        }
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

    // MARK: - Settings Restore from Backend

    /// On fresh install (no local settings file), pull settings from backend and restore them.
    /// Local settings always win if they exist — backend is only the fallback.
    private func restoreSettingsFromBackendIfNeeded() async {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Intentional")
        let settingsURL = dir.appendingPathComponent("onboarding_settings.json")

        // Only restore if local settings file doesn't exist (fresh install)
        guard !FileManager.default.fileExists(atPath: settingsURL.path) else {
            postLog("☁️ Settings restore: local file exists, skipping backend pull")
            return
        }

        guard let backendSettings = await backendClient?.getSettings() else {
            postLog("☁️ Settings restore: no backend settings available")
            return
        }

        postLog("☁️ Settings restore: fresh install detected, restoring from backend")

        // Write backend settings to disk
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: backendSettings, options: .prettyPrinted) {
            try? data.write(to: settingsURL)
            postLog("☁️ Settings restore: wrote settings to \(settingsURL.lastPathComponent)")
        }

        // Update in-memory components on the main thread
        await MainActor.run {
            // Restore distracting sites into WebsiteBlocker
            if let sites = backendSettings["distractingSites"] as? [String], !sites.isEmpty {
                websiteBlocker?.updateDistractingSites(sites)
                postLog("☁️ Settings restore: updated WebsiteBlocker with \(sites.count) distracting site(s)")
            }

            // Restore distracting apps into FocusMonitor
            if let apps = backendSettings["distractingApps"] as? [[String: Any]] {
                let bundleIds = Set(apps.compactMap { $0["bundleId"] as? String })
                focusMonitor?.distractingAppBundleIds = bundleIds
                postLog("☁️ Settings restore: updated FocusMonitor with \(bundleIds.count) distracting app(s)")
            }

            // Restore always-relevant sites into FocusMonitor
            if let sites = backendSettings["alwaysRelevantSites"] as? [String] {
                focusMonitor?.alwaysRelevantHostnames = Set(sites.map { $0.lowercased() })
                postLog("☁️ Settings restore: updated FocusMonitor with \(sites.count) always-relevant site(s)")
            }

            // Broadcast restored settings to connected browser extensions
            socketRelayServer?.broadcastToAll(
                ["type": "SETTINGS_SYNC"].merging(backendSettings) { _, new in new }
            )
            postLog("☁️ Settings restore: broadcast to extensions complete")
        }
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

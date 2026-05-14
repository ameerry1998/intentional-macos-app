//
//  AppDelegate.swift
//  Intentional
//
//  Main application delegate - entry point for the app
//

import Cocoa
import Foundation
import ServiceManagement
import SwiftUI

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
    var focusModeController: FocusModeController?
    var nudgeController: NudgeWindowController?

    // Earn Your Browse budget system
    var earnedBrowseManager: EarnedBrowseManager?

    // Content Safety — on-device screen monitoring for explicit content
    var contentSafetyMonitor: ContentSafetyMonitor?

    // Enforcement (Content Safety Lockdown) — verifies partner-locked settings
    var enforcementReconciler: EnforcementReconciler?
    var tamperOverlayController: TamperOverlayController?

    // Context-switching overlay v1 — intervenes on switches from work to non-work
    var switchCoordinator: SwitchInterventionCoordinator?
    var switchOverlayController: SwitchOverlayController?

    // Bedtime Enforcer — locks screen during bedtime hours
    var bedtimeEnforcer: BedtimeEnforcer?
    /// Cross-device sync for bedtime config (start/end/enabled/active days).
    /// Pulls from `/bedtime/config` on launch + active + every 60s and feeds
    /// the result into BedtimeEnforcer via applyRemoteSettings. Closes the
    /// gap where Mac and iPhone bedtime configs would diverge (each device
    /// previously read only its local file).
    var bedtimeConfigSync: BedtimeConfigSync?
    /// Floating window hosting BedtimeUnlockRequestView. Singleton so
    /// repeat taps from the pill's "Ask partner" button don't open a
    /// window stack.
    var bedtimeUnlockWindow: NSWindow?

    // Partner cross-device sync — pulls /partner/status on launch + active +
    // every 60s and pushes the result into the dashboard so a partner set
    // on a sibling device (e.g. iPhone) appears here automatically.
    var partnerSyncService: PartnerSyncService?

    // Blocking Profiles & Focus Sessions (Puck integration)
    var blockingProfileManager: BlockingProfileManager?

    var projectStore: ProjectStore?

    // Spec 1: cross-device account-scoped focus presets (replaces local-only Project)
    var intentionStore: IntentionStore?

    // May 2026 prototype → production: cross-device monthly goals
    var monthlyGoalStore: MonthlyGoalStore?

    // Slice 1 (Subscription Entitlements): polls /me/entitlements on launch +
    // foreground + every 60s. Caches to entitlement_cache.json for offline
    // resilience. Drives subscription gating across the app (lapsed banner,
    // feature locks). Backend is canonical; local cache is best-effort.
    private(set) var entitlementClient: EntitlementClient!

    // Bridges entitlement state changes to the dashboard's lapsed-subscriber
    // banner via window._entitlementState. Wired after mainWindowController exists.
    private var lapsedBanner: LapsedSubscriberBanner?

    // Transient: which project's session is currently active (replaces
    // FocusBlock.projectId; cleared on block end in onBlockChanged).
    private(set) var activeProjectSession: (projectId: UUID, blockId: String)?

    func setActiveProjectSession(projectId: UUID, blockId: String) {
        self.activeProjectSession = (projectId, blockId)
        Task { await self.refreshProjectEnforcement(for: projectId) }
    }

    func clearActiveProjectSession() {
        self.activeProjectSession = nil
        self.focusMonitor?.projectEnforcement = nil
    }

    /// Call after an in-session project edit so the new allow/block lists take effect.
    func refreshActiveProjectEnforcement() {
        guard let pid = activeProjectSession?.projectId else { return }
        Task { await self.refreshProjectEnforcement(for: pid) }
    }

    /// Sync `activeProjectSession` to the current schedule block. Called on app startup
    /// and whenever the active block changes — the in-memory session isn't otherwise
    /// restored after a restart and queued sessions don't auto-activate when their
    /// block becomes current.
    func ensureProjectSessionMatchesCurrentBlock() {
        guard let block = scheduleManager?.currentBlock else { return }
        if activeProjectSession?.blockId == block.id { return }
        guard let store = projectStore else { return }
        Task {
            let all = await store.list()
            let match = all.first { p in
                p.sessions.contains { $0.blockId?.uuidString == block.id }
            }
            guard let project = match else { return }
            await MainActor.run {
                guard self.scheduleManager?.currentBlock?.id == block.id else { return }
                self.setActiveProjectSession(projectId: project.id, blockId: block.id)
            }
        }
    }

    private func refreshProjectEnforcement(for projectId: UUID) async {
        guard let store = projectStore,
              let project = await store.get(id: projectId) else {
            await MainActor.run { self.focusMonitor?.projectEnforcement = nil }
            return
        }
        let merged = blockingProfileManager?.mergedBlockList(profileIds: project.blocklistIds)
        var allowedBundleIds = Set<String>()
        var allowedDomains = Set<String>()
        for item in project.allowed {
            switch item.kind {
            case .appBundleId: allowedBundleIds.insert(item.value)
            case .domain: allowedDomains.insert(item.value.lowercased())
            }
        }
        var blockedBundleIds = Set<String>()
        var blockedDomains = Set<String>()
        for item in project.blocked {
            switch item.kind {
            case .appBundleId: blockedBundleIds.insert(item.value)
            case .domain: blockedDomains.insert(item.value.lowercased())
            }
        }
        if let merged = merged {
            for app in merged.appBundleIds { blockedBundleIds.insert(app) }
            for d in merged.domains { blockedDomains.insert(d.lowercased()) }
        }
        let enforcement = FocusMonitor.ProjectEnforcement(
            projectId: projectId,
            allowedBundleIds: allowedBundleIds,
            allowedDomains: allowedDomains,
            blockedBundleIds: blockedBundleIds,
            blockedDomains: blockedDomains
        )
        await MainActor.run {
            guard self.activeProjectSession?.projectId == projectId else { return }
            self.focusMonitor?.projectEnforcement = enforcement
        }
    }

    var activeProjectId: UUID? { activeProjectSession?.projectId }

    var focusWebSocketClient: FocusWebSocketClient?
    var focusStatePoller: FocusStatePoller?
    private var focusStartOverlayWindows: [NSWindow] = []
    private var focusStartOverlayViewModel: FocusStartOverlayViewModel?
    private var puckHotkeyMonitor: Any?

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

    /// Block Cmd+Q when strict mode is enabled — unless the daemon is running
    /// (in which case, let the quit happen and the daemon will relaunch us).
    /// This is critical for macOS permission changes (e.g. Screen Recording)
    /// which require a full process restart to take effect.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let strictEnabled = daemonClient.isStrictModeEnabledSync()
        let decision = QuitPolicy.decide(
            strictModeEnabled: strictEnabled,
            daemonAvailable: daemonClient.isDaemonAvailable
        )

        switch decision {
        case .allowQuit:
            if strictEnabled {
                postLog("🔒 Quit allowed — daemon will relaunch in seconds")
            }
            return .terminateNow
        case .blockQuit:
            postLog("🔒 Quit blocked — strict mode ON, no daemon to relaunch")
            let alert = NSAlert()
            alert.messageText = "App Persistence is On"
            alert.informativeText = "Intentional is set to keep running. To disable this, open settings and request a code from your accountability partner."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Keep Running")
            alert.runModal()
            return .terminateCancel
        }
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
            // Daemon is available, but main.swift still reads the flag file during SIGTERM
            // to decide whether to write a no-relaunch marker. Keep it in sync.
            let flagPath = strictModeFlagPath()
            if strictEnabled {
                FileManager.default.createFile(atPath: flagPath, contents: "1".data(using: .utf8))
            } else {
                try? FileManager.default.removeItem(atPath: flagPath)
            }
            postLog("🔒 Daemon available — flag file synced, skipping fallback watchdog")
        }
    }

    /// One-time migration: clear local Intentional Mode state on first launch
    /// of the new build (the focus consolidation drops the IntentionalModeController
    /// + FocusSessionManager — these stale settings would persist otherwise).
    /// Wiped: 4 IntentionalMode UserDefaults keys + focus_session.json on disk.
    /// Preserved: account auth, schedule, distractions list, partner config,
    /// strict mode, content safety, intervention preferences.
    private func runFocusModeMigrationIfNeeded() {
        let migrationKey = "focus_mode_v1_migration_complete"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        postLog("🔄 Running Focus Mode v1 migration — wiping local focus state")

        // 1. Clear UserDefaults keys related to old controllers.
        // Settings written by the now-deleted IntentionalModeController. The
        // dashboard still reads/writes these keys via handleSaveIntentionalMode
        // (Task 10 left that handler as documented dead code) — wiping them
        // gives the user a fresh start.
        let keysToWipe = [
            "intentionalModeEnabled",
            "intentionalModeSchedule",
            "intentionalModeGracePeriod",
            "intentionalModeCustomSchedule"
        ]
        for k in keysToWipe { defaults.removeObject(forKey: k) }

        // 2. Clear on-disk state files that the old controllers wrote.
        // FocusSessionManager wrote `focus_session.json`. IntentionalModeController
        // didn't persist to disk (UserDefaults only) — the speculative
        // `intentional_mode_state.json` is kept as a defensive guard against any
        // future build that may have written it.
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let intentionalDir = appSupport.appendingPathComponent("Intentional", isDirectory: true)
            for filename in ["focus_session.json", "intentional_mode_state.json"] {
                let url = intentionalDir.appendingPathComponent(filename)
                guard fm.fileExists(atPath: url.path) else { continue }
                do {
                    try fm.removeItem(at: url)
                    postLog("🗑️ Focus migration: removed \(filename)")
                } catch {
                    postLog("⚠️ Focus migration: failed to remove \(filename): \(error.localizedDescription)")
                }
            }
        }

        defaults.set(true, forKey: migrationKey)
        postLog("✅ Focus Mode v1 migration complete")
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

        // One-time migration: clear legacy focus state from old controllers
        runFocusModeMigrationIfNeeded()

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

        // Init step 1.5: EntitlementClient (drives subscription gating across the app).
        // Polls /me/entitlements on launch + foreground + every 60s. Cache survives
        // offline / launch-before-network-ready.
        entitlementClient = EntitlementClient(backendClient: backendClient!)
        entitlementClient.start()
        postLog("✅ EntitlementClient started")

        // Create main window (WKWebView-based: shows onboarding or dashboard)
        mainWindowController = MainWindow(appDelegate: self)
        postLog("🪟 Main window created")

        // Wire entitlement state to dashboard banner (T12).
        // Must be after mainWindowController exists so the bridge has somewhere
        // to send JS calls.
        if let mw = mainWindowController {
            lapsedBanner = LapsedSubscriberBanner(mainWindow: mw, entitlementClient: entitlementClient)
            postLog("✅ LapsedSubscriberBanner wired")
        }

        // Bring window to front
        postLog("🚨 ACTIVATE: AppDelegate.applicationDidFinishLaunching — initial launch")
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
        // Legacy distractingSites loading removed — blocking is now driven by
        // BlockingProfileManager (always-active profiles + focus session profiles).
        // WebsiteBlocker starts empty; applyAlwaysActiveProfiles() populates it below.
        websiteBlocker?.startBlocking()
        postLog("✅ Website blocking initialized (profile-driven)")

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

        // Partner cross-device sync — fetches /partner/status on launch +
        // didBecomeActive + every 60s. Posts .partnerSyncDidUpdate which
        // MainWindow forwards to the dashboard via WKWebView. Closes the
        // sibling-sync gap where a Mac that never set the partner locally
        // didn't learn about a partner set on the user's iPhone.
        partnerSyncService = PartnerSyncService.shared
        partnerSyncService?.configure(appDelegate: self, backendClient: backendClient!)
        partnerSyncService?.start()
        postLog("👥 PartnerSyncService started")

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

        // Initialize Projects store
        projectStore = ProjectStore()
        postLog("📁 ProjectStore initialized")

        // Spec 1: IntentionStore (cross-device focus presets via backend) + one-time migration
        intentionStore = IntentionStore.shared
        Task { @MainActor in
            await intentionStore?.wire(backend: backendClient!, appDelegate: self)
            await intentionStore?.pull()

            // Run one-time migration of local projects.json → backend Intentions.
            // Idempotent + resumable; receipt at ~/Library/Application Support/Intentional/migration_intentions_v1.json
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = support.appendingPathComponent("Intentional", isDirectory: true)
            let migration = IntentionMigration(
                projectStore: self.projectStore,
                blockingProfileManager: self.blockingProfileManager,
                intentionStore: self.intentionStore!,
                backend: self.backendClient!,
                settingsDir: dir
            )
            await migration.run(log: { msg in
                Task { @MainActor in self.postLog(msg) }
            })
        }
        intentionStore?.startSyncTimer()
        postLog("🎯 IntentionStore wired and pulling")

        // May 2026 prototype → production — MonthlyGoalStore (cross-device monthly goals)
        monthlyGoalStore = MonthlyGoalStore()
        Task {
            await monthlyGoalStore?.wire(backend: backendClient!, appDelegate: self)
            await monthlyGoalStore?.pull()
        }
        monthlyGoalStore?.startSyncTimer()
        postLog("📅 MonthlyGoalStore wired and pulling")

        // Wire TimeTracker callback: deduct social media time from earned pool
        timeTracker?.onSocialMediaTimeRecorded = { [weak self] platform, minutes, isFreeBrowse in
            guard let mgr = self?.earnedBrowseManager else { return }
            // Spec 2: nil block = free time (absence of block).
            let blockType = self?.scheduleManager?.currentBlock?.blockType
            let remaining = mgr.recordSocialMediaTime(
                minutes: minutes, blockType: blockType, isFreeBrowse: isFreeBrowse
            )
            self?.socketRelayServer?.broadcastEarnedMinutesUpdate(mgr)
            self?.mainWindowController?.pushEarnedUpdate()
            self?.postLog("💰 Social media time: -\(String(format: "%.1f", minutes))m, remaining: \(String(format: "%.1f", remaining))m")
        }

        // Initialize Daily Focus Plan (V2: schedule engine + relevance scoring)
        scheduleManager = ScheduleManager(appDelegate: self)
        if let backend = backendClient {
            scheduleManager?.wire(backend: backend)  // Spec 2: backend pull on init + 60s + foreground
            postLog("📅 ScheduleManager wired to backend (pull on init + 60s)")
        }
        relevanceScorer = RelevanceScorer(appDelegate: self)
        relevanceScorer?.loadLearnedOverrides()

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
        // Legacy distractingApps loading removed — app blocking is now driven by
        // BlockingProfileManager (always-active profiles + focus session profiles).
        // FocusMonitor.distractingAppBundleIds is populated by applyAlwaysActiveProfiles() below.
        let settingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional").appendingPathComponent("onboarding_settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let sites = json["alwaysRelevantSites"] as? [String] {
                focusMonitor?.alwaysRelevantHostnames = Set(sites.map { $0.lowercased() })
                postLog("👁️ Loaded \(sites.count) always-relevant site(s): \(sites)")
            }
            // Load AI override settings
            focusMonitor?.overridePartnerApprovalRequired = json["overridePartnerRequired"] as? Bool ?? false
            let partnerEmail = json["partnerEmail"] as? String ?? ""
            focusMonitor?.hasConfiguredPartner = !partnerEmail.isEmpty
        }
        // Step 15d: Switch intervention coordinator (context-switching overlay v1).
        let switchCoordinator = SwitchInterventionCoordinator(
            exemptBundleIds: Set(["com.arayan.intentional"])
        )
        let switchOverlayController = SwitchOverlayController()
        focusMonitor?.switchCoordinator = switchCoordinator
        focusMonitor?.switchOverlayController = switchOverlayController
        self.switchCoordinator = switchCoordinator
        self.switchOverlayController = switchOverlayController

        // Seed session state from current schedule, in case the app starts mid-block.
        if let block = scheduleManager?.currentBlock,
           block.blockType == .deepWork || block.blockType == .focusHours {
            switchCoordinator.sessionStarted(at: Date())
        }
        postLog("👁️ SwitchInterventionCoordinator + SwitchOverlayController wired to FocusMonitor")

        // Phase B: async backend fetch. Don't block startup.
        Task { [weak self] in
            await self?.enforcementReconciler?.runPhaseB()
        }

        focusMonitor?.start()
        postLog("👁️ FocusMonitor + NudgeWindowController + FocusOverlayWindow + InterventionOverlay initialized")

        // Step 15.5: FocusModeController — single source of truth for "is the app enforcing"
        // (replaces IntentionalModeController + FocusSessionManager — see plan
        // docs/superpowers/plans/2026-04-27-focus-mode-consolidation.md)
        focusModeController = FocusModeController()
        let restoredState = focusModeController?.state ?? .off
        postLog("✅ FocusModeController initialized (state=\(restoredState.rawValue))")
        focusMonitor?.focusModeController = focusModeController
        self.switchCoordinator?.focusModeController = focusModeController

        focusModeController?.onStateChanged = { [weak self] old, new, period in
            guard let self = self else { return }
            let intentionStr = period?.intention.map { " (\"\($0)\")" } ?? ""
            self.postLog("🎯 Focus Mode: \(old.rawValue) → \(new.rawValue)\(intentionStr)")

            // Backend sync — single source of truth. Previously the post was
            // wired only in handleFocusModeToggle + scheduleManager.onBlockChanged,
            // so other activation paths (startFocusSession via Cmd+Shift+P, the
            // focus picker overlay, endFocusSession) updated local state without
            // posting. The next FocusStatePoller tick (2s) would then see no
            // active session on backend and force-deactivate locally — the
            // "focus mode turns off on its own" symptom. Centralizing here
            // covers every activation path.
            //
            // Filter by originator: only post when this Mac IS the originator
            // (.manual, .schedule). Cross-device receivers (.puck, .crossDevice)
            // mean the originating device already posted; re-posting is wasted
            // network traffic. Backend stop is idempotent so .off fall-through
            // is safe even when source isn't carried (period nil on deactivate).
            if old != new {
                let isLocallyOriginated: Bool = {
                    if let src = period?.source {
                        switch src {
                        case .manual, .schedule: return true
                        case .puck, .crossDevice, .bedtimeSchedule: return false
                        }
                    }
                    return true  // .off transition (period nil) — idempotent backend
                }()
                if isLocallyOriginated {
                    if new == .focus {
                        self.postFocusToggleToBackend(action: "start")
                    } else if new == .off && old == .focus {
                        self.postFocusToggleToBackend(action: "stop")
                    }
                }
            }

            self.relevanceScorer?.clearCache()

            // earnedBrowseManager.onBlockChanged MUST run before focusMonitor.onBlockChanged
            // — recordWorkTick reads activeBlockId. (CLAUDE.md Known Bug Fixes #2.)
            // Read currentBlock from the schedule because Period doesn't carry blockId.
            let block = self.scheduleManager?.currentBlock
            self.earnedBrowseManager?.onBlockChanged(blockId: block?.id, blockTitle: block?.title)

            self.focusMonitor?.onBlockChanged()
            self.socketRelayServer?.broadcastScheduleSync()
            self.mainWindowController?.pushScheduleUpdate()

            if new == .focus && old != .focus {
                // Cross-device, schedule, and dashboard-toggle paths activate
                // FocusModeController without going through startFocusSession's
                // profile picker — so the blocklist is never propagated to
                // WebsiteBlocker. Apply the user's default profile here so
                // those paths actually block. The picker path runs AFTER this
                // and overrides with its explicit profileIds.
                self.applyDefaultBlockingProfile()
            }
            if new == .off {
                self.switchCoordinator?.reset()
                self.applyAlwaysActiveProfiles()
            }
            self.mainWindowController?.pushFocusModeUpdate(state: new)
        }

        // Bedtime Enforcer
        bedtimeEnforcer = BedtimeEnforcer(appDelegate: self)
        sleepWakeMonitor?.onWake = { [weak self] in
            self?.bedtimeEnforcer?.onMacWoke()
        }
        // Drive the pill widget from bedtime state transitions.
        // - .windDown(phase) → bedtimeWindDown pill (allowMinimize only at T-30)
        // - .locked          → bedtimeLocked pill with Ask Partner button
        // - .inactive / .released → dismiss bedtime pill (other pill modes
        //   such as deep-work timer are owned by FocusMonitor and unaffected)
        bedtimeEnforcer?.onStateChanged = { [weak self] oldState, newState in
            self?.handleBedtimeStateChange(from: oldState, to: newState)
        }
        bedtimeEnforcer?.start()
        // BedtimeLockLoop reads state from the enforcer on every tick to
        // self-cancel when bedtime ends (R10 mitigation). Bind once here
        // so the loop knows which enforcer to consult.
        if let enforcer = bedtimeEnforcer {
            DispatchQueue.main.async {
                BedtimeLockLoop.shared.bind(to: enforcer)
            }
        }
        postLog("🌙 BedtimeEnforcer initialized and started")

        // Cross-device bedtime config sync. Pulls /bedtime/config on launch +
        // didBecomeActive + every 60s. Pushes user edits to backend (via
        // MainWindow's saveSettings handler) so a change on Mac is mirrored
        // on iPhone within ~60s, and vice versa. Migrates the legacy local
        // bedtime_settings.json to the backend on first run.
        if let enforcer = bedtimeEnforcer, let backend = backendClient {
            bedtimeConfigSync = BedtimeConfigSync(
                appDelegate: self, enforcer: enforcer, backendClient: backend
            )
            bedtimeConfigSync?.start()
            postLog("🌙 BedtimeConfigSync started")
        }

        // Blocking Profiles & Focus Sessions
        blockingProfileManager = BlockingProfileManager()

        // Apply always-active profiles on startup
        applyAlwaysActiveProfiles()

        // If FocusModeController restored .focus from disk (Mac was killed
        // mid-session — force quit, crash, OS restart), re-engage enforcement
        // now that BlockingProfileManager + FocusMonitor are ready. Without
        // this, the controller's in-memory state is correct but no blocklist
        // is applied until the next state transition. Poller will reconcile
        // within 2s if disk and backend disagree (backend wins).
        if focusModeController?.state == .focus {
            postLog("🎯 Restored .focus from disk — re-engaging enforcement")
            applyDefaultBlockingProfile()
            focusMonitor?.onBlockChanged()
        }

        // Mock Puck trigger: Cmd+Shift+P global hotkey
        puckHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 35 {
                DispatchQueue.main.async { self?.togglePuckFocus() }
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 35 {
                DispatchQueue.main.async { self?.togglePuckFocus() }
                return nil
            }
            return event
        }
        postLog("🎯 BlockingProfileManager initialized")

        // WebSocket focus signal client (receives start/stop from Puck via backend)
        focusWebSocketClient = FocusWebSocketClient()
        focusWebSocketClient?.onFocusSignal = { [weak self] action, sessionId, triggeredBy in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if action == "start" {
                    self.postLog("🔌 Focus signal: START (session: \(sessionId), triggeredBy: \(triggeredBy))")
                    self.focusWebSocketClient?.startHeartbeat(sessionId: sessionId)
                    // Cross-device start: the user is on the originating device
                    // (iPhone, Puck), not at the Mac. Auto-engage so enforcement
                    // fires immediately — don't wait for a click on the local
                    // intention picker. If a stale picker is already on screen
                    // from a prior signal or local Cmd+Shift+P, dismiss it first
                    // so it doesn't compete with the auto-started session.
                    self.dismissFocusStartOverlay()

                    let intention = triggeredBy == "puck"
                        ? "Focus session (started on phone)"
                        : "Focus session"
                    let source: FocusModeController.ActivationSource = triggeredBy == "puck" ? .puck : .crossDevice
                    self.focusModeController?.activate(intention: intention, source: source)
                } else if action == "stop" {
                    self.postLog("🔌 Focus signal: STOP (session: \(sessionId))")
                    self.focusWebSocketClient?.stopHeartbeat()
                    self.focusModeController?.deactivate(source: .crossDevice)
                }
            }
        }
        focusWebSocketClient?.onConnectionStateChanged = { [weak self] connected in
            self?.postLog("🔌 WebSocket \(connected ? "connected" : "disconnected")")
            if connected {
                self?.checkForActiveFocusSession()
            }
        }
        // When backend rejects WS auth (expired JWT), refresh the token and
        // reconnect. Without this, the WS retries forever with the same
        // expired token and cross-device focus signals stop arriving until
        // the user manually re-signs in.
        focusWebSocketClient?.onAuthExpired = { [weak self] in
            guard let self = self else { return }
            self.postLog("🔌 WebSocket auth expired — refreshing token")
            Task { [weak self] in
                guard let self = self else { return }
                let refreshed = await self.backendClient?.authRefresh() ?? false
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if refreshed, let newToken = self.backendClient?.getAccessToken() {
                        self.postLog("🔌 Token refreshed — reconnecting WebSocket")
                        self.focusWebSocketClient?.reconnect(token: newToken)
                        IntentionalDeviceRegistration.shared.registerIfNeeded(token: newToken, log: { msg in self.postLog(msg) })
                    } else {
                        self.postLog("🔌 Token refresh failed — user must sign in again")
                    }
                }
            }
        }

        // Connect WebSocket + register device. Extracted so MainWindow's
        // AUTH_COMPLETE handler can call it after a mid-session sign-in
        // (cold launches with no token would otherwise leave the WS
        // permanently disconnected even after the user signs in via login.html).
        connectFocusWebSocketIfNeeded()

        // Start the focus-state debug dump timer. Writes JSON every 5s to
        // /tmp/.../intentional-focus-state.json so scripts/focus-debug.py
        // can show GROUND-TRUTH Mac state instead of log-scraped guesses.
        startFocusDebugStateTimer()

        // Polling fallback for cross-device focus signal. Runs in parallel with
        // the WebSocket — whichever path detects the transition first wins.
        // activate / deactivate on FocusModeController are idempotent. Polling
        // is more robust against the WS reconnect-after-offline failure mode.
        if let controller = focusModeController {
            focusStatePoller = FocusStatePoller(
                appDelegate: self,
                focusModeController: controller
            )
            focusStatePoller?.start()

            // Wire poller's known-active state into the controller's deactivation
            // gate. ScheduleManager.onBlockChanged fires .schedule-sourced
            // deactivations on every 60s pull, but Spec 1 sessions don't live
            // in /time_blocks — only in /focus/active. So a 0-blocks pull
            // shouldn't kill an active session. The closure stays loosely
            // coupled (no direct ref) so either side can be replaced.
            controller.isBackendSessionActive = { [weak self] in
                self?.focusStatePoller?.lastKnownActive ?? false
            }
        }

        // Wire schedule block changes: the schedule is a trigger source for
        // FocusModeController. All enforcement fanout (cache clear, focusMonitor
        // re-eval, broadcasts, dashboard push) lives in focusModeController.onStateChanged.
        // This closure only:
        //   (a) routes the new TimeState into FocusModeController, and
        //   (b) handles domain logic (project sessions, celebration) that is NOT fanout.
        scheduleManager?.onBlockChanged = { [weak self] block, state in
            guard let self = self else { return }
            self.postLog("📋 Block changed → \(state.rawValue)" + (block != nil ? " (\(block!.title))" : ""))

            // Capture previous block data BEFORE transitioning state (used for
            // celebration and project-session bookkeeping below).
            let prevBlockId = self.earnedBrowseManager?.activeBlockId
            let prevStats = prevBlockId.flatMap { self.earnedBrowseManager?.blockFocusStats[$0] }
            let prevBlock = prevBlockId.flatMap { id in
                self.scheduleManager?.todaySchedule?.blocks.first(where: { $0.id == id })
            }

            // Route into FocusModeController. Fanout (clearCache, earnedBrowse, focusMonitor,
            // broadcasts) runs via focusModeController.onStateChanged.
            switch state {
            case .focus:
                self.focusModeController?.activate(intention: block?.title, source: .schedule)
            case .bedtime:
                self.focusModeController?.activateBedtime(source: .bedtimeSchedule)
                // Bedtime is phone-and-Mac local for now — separate backend
                // surface will be added by the bedtime cross-device feature
                // (docs/superpowers/plans/2026-04-27-bedtime-cross-device.md).
                // Don't reuse /focus/toggle for bedtime; semantically different.
            case .off:
                self.focusModeController?.deactivate(source: .schedule)
            }
            // Backend post happens inside focusModeController.onStateChanged
            // — keyed off the period's source so .schedule transitions sync
            // and .crossDevice receivers don't echo-post.

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

            if let tracked = self.activeProjectSession?.blockId, block?.id != tracked {
                // Finalize the session BEFORE clearing so we can look up the session id
                // and snapshot the focus score for the just-ended block.
                if let projectId = self.activeProjectSession?.projectId,
                   let blockUUID = UUID(uuidString: tracked),
                   let store = self.projectStore {
                    let scorePct = self.earnedBrowseManager?.blockFocusStats[tracked]?.focusScore
                    let scoreFraction: Double? = scorePct.map { Double($0) / 100.0 }
                    Task {
                        if let sid = await store.findActiveSession(projectId: projectId, blockId: blockUUID) {
                            _ = await store.recordSessionEnd(
                                projectId: projectId,
                                sessionId: sid,
                                focusScore: scoreFraction
                            )
                        }
                    }
                }
                self.clearActiveProjectSession()
            }
            self.ensureProjectSessionMatchesCurrentBlock()
        }

        // ScheduleManager.init() already called recalculateState(), but the callback
        // wasn't wired yet, so activeBlockId was never set. Sync it now in case the
        // app started during a work block.
        if let block = scheduleManager?.currentBlock {
            earnedBrowseManager?.onBlockChanged(blockId: block.id, blockTitle: block.title)
            // Also sync focusMonitor so the floating timer shows immediately on startup mid-block
            focusMonitor?.onBlockChanged()
            ensureProjectSessionMatchesCurrentBlock()
        }

        // Spec 3 (May 2026): rebind any block.profileIds → block.intentionId.
        // Idempotent + resumable; receipt at migration_profiles_to_intentions_v1.json.
        // Runs after scheduleManager + intentionStore + blockingProfileManager + backendClient
        // are all wired. Fire-and-forget on a Task so app launch isn't blocked.
        Task { [weak self] in
            guard let self = self,
                  let scheduleManager = self.scheduleManager,
                  let bpm = self.blockingProfileManager,
                  let store = self.intentionStore,
                  let backend = self.backendClient else { return }
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = support.appendingPathComponent("Intentional", isDirectory: true)
            let mig = await BlockingProfilesToIntentionsMigration(
                scheduleManager: scheduleManager,
                blockingProfileManager: bpm,
                intentionStore: store,
                backend: backend,
                settingsDir: dir
            )
            await mig.run(log: { msg in
                Task { @MainActor in self.postLog(msg) }
            })
        }

        // Initial sync: if a block is already active when the app starts, activate
        // Focus Mode immediately. (Catches app-started-during-block.) FocusModeController
        // fanout will then trigger downstream re-eval.
        if let currentBlock = scheduleManager?.currentBlock {
            let timeState = scheduleManager?.currentTimeState ?? .off
            switch timeState {
            case .focus:
                focusModeController?.activate(intention: currentBlock.title, source: .schedule)
            case .bedtime:
                focusModeController?.activateBedtime(source: .bedtimeSchedule)
            case .off:
                break  // already off
            }
        }

        // Step 15b: Enforcement Reconciler — runs BEFORE ContentSafetyMonitor
        // so CS reads a verified state.
        tamperOverlayController = TamperOverlayController()
        let enforcementDaemonClient = EnforcementDaemonClient(daemonClient: daemonClient)
        enforcementReconciler = EnforcementReconciler(
            appDelegate: self,
            backendClient: backendClient!,
            daemonClient: enforcementDaemonClient
        )

        // Phase A is async but fast (local XPC). Block startup briefly with a hard cap.
        let enforcementSema = DispatchSemaphore(value: 0)
        Task {
            await enforcementReconciler?.runBlockingPhaseA()
            enforcementSema.signal()
        }
        _ = enforcementSema.wait(timeout: .now() + 1.0)  // hard cap at 1s; if daemon hangs, proceed
        postLog("🛡️ Enforcement: Phase A complete")

        // Push daemon-available flag to dashboard for the degraded-mode banner.
        let daemonAvailable = enforcementDaemonClient.daemonAvailable
        DispatchQueue.main.async { [weak self] in
            let js = "window._daemonAvailable && window._daemonAvailable(\(daemonAvailable ? "true" : "false"))"
            self?.mainWindowController?.callJS(js)
        }

        // Observe post-unlock refresh notifications from MainWindow
        NotificationCenter.default.addObserver(
            forName: Notification.Name("enforcementShouldRefresh"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.enforcementReconciler?.refresh() }
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
            Task { [weak self] in
                await self?.enforcementReconciler?.refreshIfDue()
            }
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

        // Disconnect WebSocket
        focusWebSocketClient?.disconnect()
        focusStatePoller?.stop()

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

        // Focus Session Toggle
        menu.addItem(NSMenuItem(title: "Toggle Focus (\u{2318}\u{21E7}P)", action: #selector(menuToggleFocus), keyEquivalent: ""))

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
        postLog("🚨 ACTIVATE: AppDelegate.showMainWindow — caller: \(Thread.callStackSymbols.prefix(5).joined(separator: "\n"))")
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
            // Legacy distractingSites/distractingApps restore removed — blocking is now
            // profile-driven via BlockingProfileManager. Backend settings may still contain
            // these fields for backward compat but they no longer feed WebsiteBlocker/FocusMonitor.
            // Re-apply always-active profiles after settings restore.
            applyAlwaysActiveProfiles()

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

    // MARK: - Focus Session Control

    @objc func menuToggleFocus() {
        togglePuckFocus()
    }

    func togglePuckFocus() {
        if focusModeController?.isOn == true {
            endFocusSession()
        } else {
            showFocusStartOverlay(isPuckTriggered: true)
        }
    }

    func showFocusStartOverlay(isPuckTriggered: Bool) {
        guard focusStartOverlayWindows.isEmpty else { return }

        // Ensure profiles are loaded before showing the overlay
        if blockingProfileManager == nil {
            blockingProfileManager = BlockingProfileManager()
        }

        let vm = FocusStartOverlayViewModel()
        vm.availableProfiles = blockingProfileManager?.profiles ?? []
        vm.isPuckTriggered = isPuckTriggered
        vm.aiScoringEnabled = UserDefaults.standard.bool(forKey: "aiScoringEnabled")

        if isPuckTriggered, let defaultProfile = blockingProfileManager?.profiles.first(where: { $0.isDefault }) {
            vm.selectedProfileIds = [defaultProfile.id]
        }

        vm.onStartFocus = { [weak self] profileIds, intention, aiEnabled in
            self?.startFocusSession(profileIds: profileIds, intention: intention, aiEnabled: aiEnabled, triggeredByPuck: isPuckTriggered)
            self?.dismissFocusStartOverlay()
        }
        vm.onCancel = { [weak self] in
            self?.dismissFocusStartOverlay()
        }
        self.focusStartOverlayViewModel = vm

        for screen in NSScreen.screens {
            let view = FocusStartOverlayView(viewModel: vm)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = screen.frame

            let window = KeyableWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            focusStartOverlayWindows.append(window)
        }
        postLog("🎯 Focus start overlay shown (puck=\(isPuckTriggered))")
    }

    func dismissFocusStartOverlay() {
        for window in focusStartOverlayWindows { window.close() }
        focusStartOverlayWindows.removeAll()
        focusStartOverlayViewModel = nil
    }

    /// Dump live focus / WS / auth state to a JSON file for the debug page.
    /// The file is the source of truth for `scripts/focus-debug.py` so its
    /// dashboard reflects ACTUAL Mac state, not log-scraped approximations.
    /// Called every 5s by `focusDebugStateTimer`.
    func writeFocusDebugState() {
        let now = ISO8601DateFormatter().string(from: Date())
        let block = scheduleManager?.currentBlock
        let modeState = focusModeController?.state.rawValue ?? "off"
        let period = focusModeController?.currentPeriod

        var blockJSON: [String: Any] = ["present": false]
        if let block = block {
            blockJSON = [
                "present": true,
                "id": block.id,
                "title": block.title,
                "type": block.blockType.rawValue,
                "startHour": block.startHour,
                "startMinute": block.startMinute,
                "endHour": block.endHour,
                "endMinute": block.endMinute,
            ]
        }

        var sessionJSON: [String: Any] = ["active": false, "mode": modeState]
        if let period = period {
            sessionJSON = [
                "active": focusModeController?.isOn == true,
                "mode": modeState,
                "intention": period.intention as Any,
                "intentionId": period.intentionId?.uuidString as Any,
                "source": period.source.rawValue,
                "startedAt": ISO8601DateFormatter().string(from: period.startedAt),
            ]
        }

        let payload: [String: Any] = [
            "generated_at": now,
            "process_pid": ProcessInfo.processInfo.processIdentifier,
            "websocket": [
                "is_connected": focusWebSocketClient?.isConnected ?? false,
            ],
            "auth": [
                "is_logged_in": backendClient?.isLoggedIn ?? false,
                "has_access_token": backendClient?.getAccessToken() != nil,
            ],
            "focus_session": sessionJSON,
            "current_block": blockJSON,
            "enforcement": [
                "is_session_active_locally": focusModeController?.isOn == true,
                "distracting_app_bundle_ids_count": focusMonitor?.distractingAppBundleIds.count ?? 0,
            ],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else { return }
        let path = NSTemporaryDirectory() + "intentional-focus-state.json"
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private var focusDebugStateTimer: Timer?

    func startFocusDebugStateTimer() {
        focusDebugStateTimer?.invalidate()
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.writeFocusDebugState()
        }
        RunLoop.main.add(timer, forMode: .common)
        focusDebugStateTimer = timer
        // Fire once immediately so the file exists right after launch.
        writeFocusDebugState()
    }

    /// Connect the focus WebSocket and register this device with the backend,
    /// using whatever access token is currently in Keychain. Idempotent: safe
    /// to call multiple times — the WS bails out internally if it's already
    /// connected, and device-register is upsert-by-(account, type, name).
    ///
    /// Call this on every transition that *could* introduce a fresh token:
    /// app launch, mid-session sign-in (AUTH_COMPLETE bridge message), and
    /// after a successful authRefresh. Without this, a user who signs in via
    /// the in-app login screen has a valid token but a disconnected WebSocket,
    /// because the original connect logic only ran once at app boot.
    func connectFocusWebSocketIfNeeded() {
        guard let token = backendClient?.getAccessToken() else {
            postLog("🔌 connectFocusWebSocketIfNeeded: no access token, skipping")
            return
        }
        focusWebSocketClient?.connect(token: token)
        postLog("🔌 WebSocket connecting with stored token")

        IntentionalDeviceRegistration.shared.registerIfNeeded(
            token: token,
            log: { [weak self] msg in self?.postLog(msg) },
            onAuthExpired: { [weak self] in
                guard let self = self else { return }
                Task { [weak self] in
                    guard let self = self else { return }
                    let refreshed = await self.backendClient?.authRefresh() ?? false
                    await MainActor.run { [weak self] in
                        guard let self = self,
                              refreshed,
                              let newToken = self.backendClient?.getAccessToken() else { return }
                        self.postLog("🔌 DeviceRegister retry with refreshed token")
                        IntentionalDeviceRegistration.shared.registerIfNeeded(
                            token: newToken,
                            log: { msg in self.postLog(msg) }
                        )
                    }
                }
            }
        )
    }

    func startFocusSession(profileIds: [UUID], intention: String?, aiEnabled: Bool, triggeredByPuck: Bool) {
        // Pre-flight: don't engage if there's nothing to enforce. Without this
        // guard a no-profiles + no-intention call would still flip
        // focusModeController to .focus while applyFocusSession() bails on its
        // own guard, leaving the controller "on" with no actual enforcement.
        let hasIntention = intention != nil && !(intention!.isEmpty)
        if profileIds.isEmpty && !hasIntention {
            postLog("🎯 startFocusSession: no profiles + no intention — ignoring (would have been a phantom session)")
            return
        }
        let source: FocusModeController.ActivationSource = triggeredByPuck ? .puck : .manual
        focusModeController?.activate(intention: intention, source: source)
        applyFocusSession(profileIds: profileIds, intention: intention)
        postLog("🎯 Focus session started (profiles=\(profileIds.count), intention=\(intention ?? "none"), puck=\(triggeredByPuck))")
    }

    func applyFocusSession(profileIds: [UUID], intention: String?) {
        let merged = blockingProfileManager?.mergedBlockList(profileIds: profileIds)
        let domains = merged?.domains ?? []
        let appBundleIds = merged?.appBundleIds ?? []
        let hasProfiles = !profileIds.isEmpty && !domains.isEmpty
        let hasIntention = intention != nil && !intention!.isEmpty

        // Only enforce if there's something to enforce
        guard hasProfiles || hasIntention else {
            postLog("🎯 Focus session has no profiles and no intention — skipping enforcement")
            return
        }

        websiteBlocker?.updateDistractingSites(domains)
        focusMonitor?.distractingAppBundleIds = Set(appBundleIds)

        if hasIntention {
            let now = Date()
            let cal = Calendar.current
            let block = ScheduleManager.FocusBlock(
                id: UUID().uuidString,
                title: intention!,
                description: "",
                startHour: cal.component(.hour, from: now),
                startMinute: cal.component(.minute, from: now),
                endHour: 23,
                endMinute: 59,
                blockType: hasProfiles ? .deepWork : .focusHours
            )
            scheduleManager?.injectFocusSessionBlock(block)
        }
        focusMonitor?.onBlockChanged()
    }

    func endFocusSession() {
        focusModeController?.deactivate(source: .manual)

        // Fall back to always-active profiles (or empty if none)
        applyAlwaysActiveProfiles()

        scheduleManager?.clearInjectedFocusSessionBlock()
        focusMonitor?.stop()
        focusMonitor?.start()
        postLog("🎯 Focus session ended")
    }

    /// Enforce always-active profiles. Called on startup, after profile edits, and when focus sessions end.
    func applyAlwaysActiveProfiles() {
        let alwaysActive = blockingProfileManager?.alwaysActiveBlockList()
        let domains = alwaysActive?.domains ?? []
        let appBundleIds = alwaysActive?.appBundleIds ?? []
        websiteBlocker?.updateDistractingSites(domains)
        focusMonitor?.distractingAppBundleIds = Set(appBundleIds)
        postLog("🎯 Always-active enforcement: \(domains.count) domains, \(appBundleIds.count) apps")
    }

    /// POST /focus/toggle to the backend with X-Device-ID auth. Used by:
    /// - Mac dashboard toggle (manual)
    /// - Mac scheduler (when a focus block starts/ends)
    /// Local FocusModeController.activate/deactivate runs FIRST for instant
    /// feedback; this fires async to mirror the change to backend so other
    /// devices (iPhone, future) and the Mac's own poller see it. On failure
    /// the next poller tick reconciles (backend wins).
    func postFocusToggleToBackend(action: String) {
        guard let deviceId = backendClient?.getDeviceId(),
              let url = URL(string: "https://api.intentional.social/focus/toggle") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["action": action])
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let error = error {
                self?.postLog("⚠️ /focus/toggle \(action) failed: \(error.localizedDescription)")
            } else if status >= 400 {
                self?.postLog("⚠️ /focus/toggle \(action) HTTP \(status)")
            } else {
                self?.postLog("🎯 /focus/toggle \(action) → backend OK")
            }
        }.resume()
    }

    /// Apply the user's default blocking profile (the one with `isDefault: true`).
    /// Used by FocusModeController.onStateChanged when entering .focus from any path
    /// that doesn't explicitly select profiles (cross-device puck, schedule, manual
    /// dashboard toggle). Falls back to always-active if no default profile exists.
    func applyDefaultBlockingProfile() {
        guard let manager = blockingProfileManager,
              let defaultProfile = manager.profiles.first(where: { $0.isDefault }) else {
            postLog("🎯 No default blocking profile — falling back to always-active")
            applyAlwaysActiveProfiles()
            return
        }
        let merged = manager.mergedBlockList(profileIds: [defaultProfile.id])
        websiteBlocker?.updateDistractingSites(merged.domains)
        focusMonitor?.distractingAppBundleIds = Set(merged.appBundleIds)
        postLog("🎯 Default profile '\(defaultProfile.name)' applied: \(merged.domains.count) domains, \(merged.appBundleIds.count) apps")
    }

    func checkForActiveFocusSession() {
        guard let token = backendClient?.getAccessToken() else { return }
        guard focusModeController?.isOn != true else { return } // Already in a session

        #if DEBUG
        let urlString = "http://localhost:8000/focus/active"
        #else
        let urlString = "https://api.intentional.social/focus/active"
        #endif
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let active = json["active"] as? Bool, active else { return }
            let triggeredBy = (json["triggered_by"] as? String) ?? "puck"
            let sessionId = (json["session_id"] as? String) ?? ""

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.postLog("🔌 Found active Puck focus session on reconnect — engaging enforcement (session=\(sessionId), triggeredBy=\(triggeredBy))")

                // Auto-engage with default profile + placeholder intention,
                // matching the WS-signal handler. Don't show the interactive
                // picker — the user expressed intent on the originating device
                // (their phone) and isn't here to click anything.
                self.dismissFocusStartOverlay()
                let defaultProfileIds = self.blockingProfileManager?.profiles
                    .filter { $0.isDefault }
                    .map { $0.id } ?? []
                let intention = triggeredBy == "puck"
                    ? "Focus session (recovered from phone)"
                    : "Focus session (recovered)"
                self.startFocusSession(
                    profileIds: defaultProfileIds,
                    intention: intention,
                    aiEnabled: false,
                    triggeredByPuck: triggeredBy == "puck"
                )
                if !sessionId.isEmpty {
                    self.focusWebSocketClient?.startHeartbeat(sessionId: sessionId)
                }
            }
        }.resume()
    }

    // MARK: - Bedtime → Pill bridge

    /// Drive the pill widget from BedtimeEnforcer state transitions.
    /// Wired in `applicationDidFinishLaunching` after the enforcer is
    /// created. Runs on the main queue (state transitions originate from
    /// the recalc tickTimer, which is a main-queue Timer).
    func handleBedtimeStateChange(from old: BedtimeState, to new: BedtimeState) {
        guard let pill = focusMonitor?.deepWorkTimerController else { return }

        switch new {
        case .inactive, .released:
            // Bedtime pill should go away. We only dismiss when the pill
            // is currently in a bedtime mode — otherwise we'd kill an
            // active deep-work / focus-hours timer that's unrelated.
            if let mode = pill.viewModel?.mode, mode == .bedtimeWindDown || mode == .bedtimeLocked {
                pill.dismiss()
            }

        case .windDown(let phase):
            guard let settings = bedtimeEnforcer?.currentSettings else { return }
            let cal = Calendar.current
            let now = Date()
            // Same logic as scheduleWindDownForTonight — the next bedtime
            // boundary on the user's wall clock.
            guard let candidate = cal.date(
                bySettingHour: settings.bedtimeStart.hour,
                minute: settings.bedtimeStart.minute,
                second: 0,
                of: now
            ) else { return }
            let nextBedtime = candidate > now
                ? candidate
                : (cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate)
            let minutesUntil = max(1, Int((nextBedtime.timeIntervalSince(now) / 60).rounded()))

            // T-30 phase only allows minimize / push-10. Beyond that, the
            // user has to wait or ask partner — no escape.
            let allowMinimize = (phase == .t30)
            let push10Handler: (() -> Void)? = allowMinimize ? { [weak self] in
                self?.focusMonitor?.deepWorkTimerController?.minimize()
            } : nil

            pill.showBedtimeWindDown(
                minutesUntilBedtime: minutesUntil,
                bedtime: nextBedtime,
                allowMinimize: allowMinimize,
                onPush10: push10Handler,
                onAskPartner: nil
            )

        case .locked:
            guard let settings = bedtimeEnforcer?.currentSettings else { return }
            let cal = Calendar.current
            let now = Date()
            // Wake time on tomorrow's clock if bedtime crosses midnight,
            // else today.
            guard let candidate = cal.date(
                bySettingHour: settings.wakeTime.hour,
                minute: settings.wakeTime.minute,
                second: 0,
                of: now
            ) else { return }
            let wakeTime = candidate > now
                ? candidate
                : (cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate)

            pill.showBedtimeLocked(wakeTime: wakeTime) { [weak self] in
                self?.openBedtimeUnlockRequestSheet()
            }
        }
    }

    /// Open the bedtime unlock-request sheet in a floating window.
    /// Hosts BedtimeUnlockRequestView in a SwiftUI NSHostingController.
    /// The window is reused across taps so multiple openings don't pile
    /// up (single source of truth — the underlying request flow is
    /// already idempotent, but window proliferation is a UX papercut).
    func openBedtimeUnlockRequestSheet() {
        if let existing = bedtimeUnlockWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: BedtimeUnlockRequestView())
        let window = NSWindow(contentViewController: host)
        window.title = "Ask Partner to Unlock"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.center()
        window.isReleasedWhenClosed = false
        // Track close so the next tap re-creates the window with fresh
        // state (slider snaps back to default 30 min, etc.).
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.bedtimeUnlockWindow = nil
        }
        bedtimeUnlockWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Spec 3 (May 2026): Hosts BedtimeUnlockRequestView in `.intentionStrictness`
    /// mode. Singleton window so the user can't open multiple. Closes when the
    /// request is verified or cancelled.
    var intentionStrictnessUnlockWindow: NSWindow?

    func openIntentionStrictnessUnlockSheet(
        intentionId: UUID,
        toPreset: StrictnessPreset,
        intentionName: String
    ) {
        if let existing = intentionStrictnessUnlockWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let kind: UnlockRequestKind = .intentionStrictness(
            intentionId: intentionId, toPreset: toPreset, intentionName: intentionName
        )
        let host = NSHostingController(rootView: BedtimeUnlockRequestView(kind: kind))
        let win = NSWindow(contentViewController: host)
        win.title = "Soften \(intentionName)"
        win.styleMask = [.titled, .closable]
        win.level = .floating
        win.setContentSize(NSSize(width: 460, height: 520))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        intentionStrictnessUnlockWindow = win
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            self?.intentionStrictnessUnlockWindow = nil
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

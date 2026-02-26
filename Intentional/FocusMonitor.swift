import Cocoa
import Foundation

/// Monitors the frontmost application and manages focus enforcement.
///
/// All enforcement is driven by a single `cumulativeDistractionSeconds` counter.
/// On each 10s poll, the counter increments if content is irrelevant; on relevant content,
/// it decays by 5s per poll. All actions are threshold-driven — no separate timers.
///
/// **Deep Work** — strict enforcement:
///   - 10s cumulative: nudge + timer dot red
///   - 20s cumulative: auto-redirect to last relevant URL + grayscale
///   - 20s+ (revisit): instant redirect if site already redirected this block
///   - 300s cumulative: intervention overlay (60s/90s/120s escalating)
///
/// **Focus Hours** — gentle reminders:
///   - 10s: level 1 nudge (auto-dismiss 8s)
///   - 30s: grayscale starts (30s fade)
///   - 70s/130s/190s: level 1 nudge repeats (+60s interval)
///   - 240s: red warning nudge ("intervention in 60s")
///   - 300s: intervention overlay (60s, escalating every +300s)
///   - Between interventions: level 2 persistent nudges on each poll
///
/// **Free Time** — no enforcement (handled before this class is invoked)
///
/// Two input paths:
/// 1. **Non-browser apps**: Detected via NSWorkspace.didActivateApplicationNotification,
///    scored by RelevanceScorer using the app name.
/// 2. **Browser tabs**: Read directly via AppleScript (tab title + URL), scored by RelevanceScorer.
///    Polls every 10s while a browser is frontmost to catch tab switches.
class FocusMonitor {

    weak var appDelegate: AppDelegate?
    weak var scheduleManager: ScheduleManager?
    weak var relevanceScorer: RelevanceScorer?
    var nudgeController: NudgeWindowController?
    var overlayController: FocusOverlayWindowController?
    var interventionController: InterventionOverlayController?
    var grayscaleController: GrayscaleOverlayController?
    var deepWorkTimerController: DeepWorkTimerController?

    /// User-configured distracting apps: always treated as irrelevant during work blocks
    var distractingAppBundleIds: Set<String> = []

    // MARK: - Social Media Hostnames (extension handles enforcement)

    /// Social media hostnames where the Chrome extension handles enforcement
    private static let socialMediaHostnames: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com",
        "instagram.com", "www.instagram.com",
        "facebook.com", "www.facebook.com", "m.facebook.com"
    ]

    /// Check if a hostname is a social media site handled by the extension
    private func isSocialMedia(_ hostname: String) -> Bool {
        Self.socialMediaHostnames.contains(hostname.lowercased())
    }

    // MARK: - Known Browser Bundle IDs + AppleScript Names

    /// Browsers we can read tab titles from via AppleScript.
    private static let browserBundleIds: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    /// Maps bundle ID → AppleScript application name for tab access.
    private static let browserAppNames: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.apple.Safari": "Safari",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
        "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox",
        "com.operasoftware.Opera": "Opera",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    // MARK: - Always-Allowed Apps

    /// Apps that are never blocked during any work block. These are system utilities,
    /// developer tools, and infrastructure apps that are relevant to virtually any task.
    private static let alwaysAllowedBundleIds: Set<String> = [
        // ── Terminals ──
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "io.alacritty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "com.panic.Prompt",                     // SSH client
        "se.king.Prompt3",

        // ── IDEs & Code Editors ──
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.vscodium",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.CLion",
        "com.jetbrains.goland",
        "com.jetbrains.rider",
        "com.jetbrains.rubymine",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.fleet",
        "com.todesktop.230313mzl4w4u92",       // Cursor
        "dev.zed.Zed",
        "com.panic.Nova",
        "com.barebones.bbedit",
        "co.noteplan.NotePlan3",
        "md.obsidian",
        "com.github.atom",

        // ── Password Managers ──
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",

        // ── Spotlight & Launchers ──
        "com.apple.Spotlight",
        "com.runningwithcrayons.Alfred",
        "com.raycast.macos",

        // ── Notification Center / System Processes ──
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",

        // ── VPN & Network Security ──
        "com.wireguard.macos",
        "net.tunnelblick.tunnelblick",
        "com.tailscale.ipn.macos",

        // ── Clipboard Managers ──
        "com.sindresorhus.Paste",
        "com.p5sys.jump-desktop-connect",

        // ── Window Management ──
        "com.knollsoft.Rectangle",
        "com.hegenberg.BetterTouchTool",
        "com.manytricks.Moom",
        "com.crowdcafe.windowmagnet",

        // ── Screenshot & Recording ──
        "com.apple.Screenshot",
        "cc.ffitch.shottr",
        "com.cleanshot.CleanShot-X",
        "com.getdropzone.Dropzone5",

        // ── Virtualization & Containers ──
        "com.docker.docker",
        "com.docker.Docker",
        "com.utmapp.UTM",
        "com.parallels.desktop.console",
        "com.vmware.fusion",

        // ── Database Tools ──
        "com.tinyapp.TablePlus",
        "eu.sequel-ace.sequel-ace",
        "com.apple.dt.Instruments",

        // ── API & Dev Tools ──
        "com.postmanlabs.mac",
        "com.insomnia.app",
        "com.charlesproxy.Charles",
        "com.proxyman.NSProxy",

        // ── Git GUI ──
        "com.git-tower.Tower3",
        "com.sublimemerge",
        "com.github.GitHubClient",              // GitHub Desktop
        "com.RowDaBoat.GitX",
        "abz.SourceTree",

        // ── Calendar, Contacts, Reminders (planning/scheduling tools) ──
        "com.apple.iCal",
        "com.apple.AddressBook",
        "com.apple.reminders",
        "com.apple.Notes",

        // ── File Management & Archiving ──
        "com.apple.archiveutility",
        "com.apple.dt.FileMerge",
    ]

    /// Apple entertainment apps that SHOULD be scored by the LLM (excluded from com.apple.* auto-allow).
    private static let appleEntertainmentBundleIds: Set<String> = [
        "com.apple.Music",
        "com.apple.TV",
        "com.apple.podcasts",
        "com.apple.news",
        "com.apple.Chess",
        "com.apple.Photos",
        "com.apple.iBooks",
        "com.apple.AppStore",
    ]

    /// Neutral apps: neither earn browse time nor count as distracting.
    /// These represent system states where the user isn't actively working or browsing.
    private static let neutralBundleIds: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.systempreferences",           // System Preferences (pre-Ventura)
        "com.apple.systemsettings",              // System Settings (Ventura+)
        "com.apple.KeyboardSetupAssistant",
        "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.installer",
        "com.apple.SoftwareUpdate",
        "com.apple.ActivityMonitor",
        "com.apple.DiskUtility",
        "com.apple.MigrationUtility",
        "com.apple.SetupAssistant",
    ]

    /// Check if a bundle ID is a neutral activity (no earning, no penalty).
    private func isNeutralApp(_ bundleId: String) -> Bool {
        Self.neutralBundleIds.contains(bundleId)
    }

    // MARK: - Constants

    /// How often to re-check the active browser tab (seconds)
    static let browserPollInterval: TimeInterval = 10.0
    /// Decay ratio: for every second of relevant work, reduce distraction counter by this fraction
    static let distractionDecayRatio: TimeInterval = 0.5
    /// Suppression duration after user justifies content (seconds)
    static let suppressionSeconds: TimeInterval = 300.0
    /// Linger duration for fallback unplanned/noPlan blocking (seconds)
    static let lingerDurationSeconds: TimeInterval = 30.0
    /// Maximum relevance log entries to keep in memory
    static let maxLogEntries = 50

    // MARK: - Threshold Tables (unified distraction counter)

    // ── Focus Hours thresholds ──
    /// First nudge threshold (seconds of cumulative distraction)
    static let focusNudgeThreshold: TimeInterval = 10.0
    /// Grayscale start threshold
    static let focusGrayscaleThreshold: TimeInterval = 30.0
    /// Interval between repeating level 1 nudges (after first nudge)
    static let focusNudgeRepeatInterval: TimeInterval = 60.0
    /// Warning nudge threshold — red warning before intervention
    static let focusWarningThreshold: TimeInterval = 240.0
    /// Intervention threshold (and re-intervention interval)
    static let focusInterventionThreshold: TimeInterval = 300.0

    // ── Deep Work thresholds ──
    /// First nudge + timer dot red
    static let deepWorkNudgeThreshold: TimeInterval = 10.0
    /// Auto-redirect to last relevant URL + grayscale starts
    static let deepWorkRedirectThreshold: TimeInterval = 20.0
    /// Intervention overlay threshold
    static let deepWorkInterventionThreshold: TimeInterval = 300.0

    // MARK: - Relevance Log

    struct RelevanceEntry {
        let timestamp: Date
        let title: String        // page title or app name
        let appName: String      // always the app name (e.g. "Google Chrome")
        let hostname: String     // domain for browser tabs (e.g. "github.com"), empty for non-browser apps
        let intention: String    // current block intention
        let relevant: Bool
        let confidence: Int
        let reason: String
        let action: String       // "none", "nudge", "blocked"
        let neutral: Bool        // true for neutral apps (loginwindow, etc.)
        let isEvent: Bool        // true for enforcement events (nudge/block) — not time ticks
    }

    private(set) var relevanceLog: [RelevanceEntry] = []

    private func logAssessment(title: String, appName: String = "", hostname: String = "", intention: String, relevant: Bool, confidence: Int, reason: String, action: String, neutral: Bool = false, isEvent: Bool = false) {
        let entry = RelevanceEntry(
            timestamp: Date(), title: title, appName: appName.isEmpty ? title : appName, hostname: hostname, intention: intention,
            relevant: relevant, confidence: confidence, reason: reason, action: action, neutral: neutral, isEvent: isEvent
        )
        relevanceLog.append(entry)
        if relevanceLog.count > Self.maxLogEntries {
            relevanceLog.removeFirst(relevanceLog.count - Self.maxLogEntries)
        }
        persistAssessment(entry)
    }

    private func persistAssessment(_ entry: RelevanceEntry) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("relevance_log.jsonl")

        let aiModel = appDelegate?.scheduleManager?.aiModel ?? "apple"
        var dict: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
            "title": entry.title,
            "appName": entry.appName,
            "hostname": entry.hostname,
            "intention": entry.intention,
            "relevant": entry.relevant,
            "confidence": entry.confidence,
            "reason": entry.reason,
            "action": entry.action,
            "model": aiModel
        ]
        if entry.neutral { dict["neutral"] = true }
        if entry.isEvent { dict["isEvent"] = true }

        if let data = try? JSONSerialization.data(withJSONObject: dict),
           var line = String(data: data, encoding: .utf8) {
            line += "\n"
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - State

    /// Current frontmost application
    private(set) var currentApp: NSRunningApplication?
    private var currentAppBundleId: String?

    // Linger tracking
    private var lingerTimer: Timer?
    private var lingerStart: Date?
    private var currentTarget: String = ""      // Display name (app name or page title)
    private var currentTargetKey: String = ""    // Key for counting (bundle ID or hostname)
    private var isCurrentlyIrrelevant = false
    private var currentOverlayIsNoPlan = false   // Whether the current overlay is for noPlan/unplanned

    // Tiered enforcement: targets already warned once in this block
    private var warnedTargets: Set<String> = []
    private var suppressedUntil: [String: Date] = [:]

    // Grace period: delay before showing overlay on new irrelevant content
    private var graceTimer: Timer?
    private var pendingOverlay: PendingOverlayInfo?

    // Per-tab blocking: tracks when a browser tab has been redirected to focus-blocked.html
    private var tabIsOnBlockingPage = false
    private var blockedOriginalURL: String?

    // Cumulative distraction counter (seconds). Increases when on irrelevant content,
    // decays when user returns to relevant content. Resets on block change.
    private var cumulativeDistractionSeconds: TimeInterval = 0
    /// Whether the last browser tab score was irrelevant (for sampling unchanged tabs)
    private var lastScoreWasIrrelevant = false

    // Nudge escalation state (all threshold-driven off cumulativeDistractionSeconds)
    /// Whether a nudge has been shown for the current irrelevant content
    private var nudgeShownForCurrentContent = false
    /// Cumulative distraction seconds at which the last nudge was shown (for repeat interval)
    private var lastNudgeShownAtDistraction: TimeInterval = 0
    /// Content approved by user justification during this block (targetKey set)
    private var sessionOverrides: Set<String> = []
    /// How many interventions have been triggered during this distraction run (for escalating duration)
    private var interventionCount: Int = 0
    /// Cumulative distraction seconds at which the last intervention was triggered
    private var lastInterventionAtDistraction: TimeInterval = 0
    /// Whether the Deep Work auto-redirect has fired for the current distraction run
    private var deepWorkRedirectFired = false
    /// Whether grayscale has been triggered at least once this block (instant re-trigger on revisit)
    private var grayscaleTriggeredThisBlock = false

    // Deep Work aggressive enforcement
    /// Sites that have been auto-redirected during this Deep Work block (instant redirect on revisit)
    private var deepWorkRedirectedSites: Set<String> = []
    /// Deep Work native app grace: shorter than normal (5s instead of 30s)
    static let deepWorkNativeGraceSeconds: TimeInterval = 5.0
    /// Deep Work justification suppression: shorter (3 min instead of 5 min)
    static let deepWorkSuppressionSeconds: TimeInterval = 180.0

    // Global noPlan snooze: suppresses ALL noPlan/unplanned overlays (not per-target)
    private var noPlanSnoozeUntil: Date?

    /// Grace duration for first encounter during a work block
    static let graceDurationSeconds: TimeInterval = 30.0
    /// Shorter grace for revisits (already warned once this block)
    static let revisitGraceDurationSeconds: TimeInterval = 15.0
    /// Grace duration for unplanned/noPlan time (short — prompt to plan quickly)
    static let unplannedGraceDurationSeconds: TimeInterval = 5.0

    /// Captures all overlay details so the grace timer can show it later.
    private struct PendingOverlayInfo {
        let targetKey: String
        let displayName: String
        let intention: String
        let reason: String
        let isRevisit: Bool
        let focusDurationMinutes: Int
        let isNoPlan: Bool
        let confidence: Int
    }

    /// The display name of the current frontmost app (resolves browser bundle IDs to names like "Google Chrome").
    private var currentAppName: String {
        if let bundleId = currentAppBundleId, Self.browserBundleIds.contains(bundleId) {
            return Self.browserAppNames[bundleId] ?? currentApp?.localizedName ?? "Browser"
        }
        return currentApp?.localizedName ?? "unknown"
    }

    // Browser tab polling
    private var browserPollTimer: Timer?
    // Work tick timer for always-allowed non-browser apps (Xcode, Terminal, etc.)
    private var workTickTimer: Timer?
    // Neutral tick timer for screen lock, Intentional app, etc. (logs grey entries)
    private var neutralTickTimer: Timer?
    private var lastScoredTitle: String?
    private var lastScoredURL: String?

    /// Last relevant browser tab URL for smart "Back to work" navigation
    private var lastRelevantTabURL: String?

    // Serial queue for AppleScript execution (not thread-safe)
    private let appleScriptQueue = DispatchQueue(label: "com.intentional.focusmonitor.applescript", qos: .userInitiated)

    // MARK: - Logging

    /// Debug logging — only printed when verbose mode is on (default: off).
    /// Use for app-switch routing, exit reasons, score details, timer ticks.
    private static var verboseLogging = false

    private func debugLog(_ message: String) {
        guard Self.verboseLogging else { return }
        appDelegate?.postLog(message)
    }

    // MARK: - Init

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    /// Start monitoring frontmost application changes.
    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        grayscaleController = GrayscaleOverlayController()
        deepWorkTimerController = DeepWorkTimerController()

        appDelegate?.postLog("👁️ FocusMonitor started — watching frontmost app")
    }

    /// Stop monitoring and dismiss any active nudge/overlay.
    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        cancelGracePeriod()
        stopLingerTimer()
        stopBrowserPolling()
        stopWorkTickTimer()
        stopNeutralTickTimer()
        nudgeController?.dismiss()
        overlayController?.dismiss()
        grayscaleController?.dismiss()
        deepWorkTimerController?.dismiss()
        appDelegate?.socketRelayServer?.broadcastHideFocusOverlay()
        appDelegate?.postLog("👁️ FocusMonitor stopped")
    }

    // MARK: - Block Change

    /// Called when the active focus block changes.
    /// Resets all warning state, timers, and suppression.
    func onBlockChanged() {
        appDelegate?.postLog("👁️ onBlockChanged() — resetting all state, will re-evaluate current app")
        warnedTargets.removeAll()
        suppressedUntil.removeAll()
        noPlanSnoozeUntil = nil
        cancelGracePeriod()
        stopLingerTimer()
        stopBrowserPolling()
        stopWorkTickTimer()
        stopNeutralTickTimer()
        nudgeController?.dismiss()
        overlayController?.dismiss()
        appDelegate?.socketRelayServer?.broadcastHideFocusOverlay()
        isCurrentlyIrrelevant = false
        currentTarget = ""
        currentTargetKey = ""
        lastScoredTitle = nil
        lastScoredURL = nil
        lastRelevantTabURL = nil
        tabIsOnBlockingPage = false
        blockedOriginalURL = nil
        cumulativeDistractionSeconds = 0
        lastScoreWasIrrelevant = false
        nudgeShownForCurrentContent = false
        lastNudgeShownAtDistraction = 0
        sessionOverrides.removeAll()
        interventionCount = 0
        lastInterventionAtDistraction = 0
        deepWorkRedirectFired = false
        grayscaleTriggeredThisBlock = false
        interventionController?.dismiss()
        deepWorkRedirectedSites.removeAll()

        // Grayscale: reconcile — after resetting flags above, reconciler will restore color
        reconcileGrayscale()

        // Floating timer: show for all focus schedule blocks (Deep Work, Focus Hours, Free Time)
        if let block = scheduleManager?.currentBlock {
            let calendar = Calendar.current
            let now = Date()
            let endOfBlock = calendar.date(bySettingHour: block.endHour, minute: block.endMinute, second: 0, of: now) ?? now
            deepWorkTimerController?.show(intention: block.title, endsAt: endOfBlock)
            deepWorkTimerController?.update(isDistracted: false)
            pushFocusStatsToTimer()
        } else {
            deepWorkTimerController?.dismiss()
        }

        // Re-evaluate current frontmost app against the new block
        if let app = currentApp {
            evaluateApp(app)
        }
    }

    // MARK: - Browser Tab Scoring (called by NativeMessagingHost)

    /// Called by NativeMessagingHost after scoring a browser tab via SCORE_RELEVANCE.
    /// Acts as a supplementary signal — AppleScript polling is the primary path.
    func reportBrowserTabScored(
        relevant: Bool,
        confidence: Int,
        pageTitle: String,
        hostname: String?
    ) {
        // Only process if a browser is currently frontmost
        guard let bundleId = currentAppBundleId,
              Self.browserBundleIds.contains(bundleId) else {
            return
        }

        let targetKey = hostname ?? bundleId
        let displayName = pageTitle.isEmpty ? (currentApp?.localizedName ?? "Browser") : pageTitle

        if relevant {
            handleRelevantContent()
        } else {
            handleIrrelevantContent(targetKey: targetKey, displayName: displayName)
        }
    }

    // MARK: - App Switch Handling

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

        currentApp = app
        currentAppBundleId = app.bundleIdentifier

        evaluateApp(app)
    }

    private func evaluateApp(_ app: NSRunningApplication) {
        let appName = app.localizedName ?? app.bundleIdentifier ?? "unknown"
        let bundleId = app.bundleIdentifier ?? "no-bundle-id"
        let currentState = scheduleManager?.currentTimeState.rawValue ?? "nil"
        let currentBlock = scheduleManager?.currentBlock?.title ?? "none"

        // Stop tick timers from previous app (will restart if new app needs them)
        stopWorkTickTimer()
        stopNeutralTickTimer()

        debugLog("👁️ evaluateApp: \(appName) (\(bundleId)), state=\(currentState), block=\(currentBlock)")

        // Skip reconciliation for browsers — handled below with proper state
        // (prevents grayscale turning OFF briefly before async scoring re-enables it)
        if !Self.browserBundleIds.contains(bundleId) {
            reconcileGrayscale()
        }

        guard let manager = scheduleManager else {
            debugLog("👁️ EXIT: no scheduleManager — treating as relevant")
            handleRelevantContent()
            stopBrowserPolling()
            return
        }

        let state = manager.currentTimeState
        debugLog("👁️ State check: enabled=\(manager.isEnabled), state=\(state.rawValue), hasPlan=\(manager.todaySchedule != nil), blocks=\(manager.todaySchedule?.blocks.count ?? 0)")

        // States where browsing is allowed freely
        // disabled = feature off, freeTime = scheduled break, snoozed = user chose to delay
        if state == .disabled || state == .freeTime || state == .snoozed {
            debugLog("👁️ EXIT: state=\(state.rawValue) — browsing allowed freely")
            handleRelevantContent()
            stopBrowserPolling()
            return
        }

        guard let bid = app.bundleIdentifier else {
            handleRelevantContent()
            stopBrowserPolling()
            return
        }

        // Neutral apps: log as neutral (gray in popover) but don't earn or penalize
        // Keep enforcement state frozen — neutral apps shouldn't clear grayscale/overlays
        // (otherwise opening System Settings becomes an escape hatch)
        if isNeutralApp(bid) {
            debugLog("👁️ EXIT: neutral app \(appName) — no earning, no penalty")
            stopBrowserPolling()
            stopWorkTickTimer()
            logAssessment(
                title: appName,
                intention: scheduleManager?.currentBlock?.title ?? "",
                relevant: true, confidence: 0, reason: "Neutral app", action: "none", neutral: true
            )
            startNeutralTickTimer(appName: appName)
            return
        }

        // Our own app — two cases:
        // 1. Overlay is showing → user clicked the overlay (which activates our app).
        //    Do NOT dismiss it — let the buttons inside the overlay handle the interaction.
        // 2. Overlay is NOT showing → user switched to the Intentional dashboard.
        //    Allow freely, but preserve grace timer.
        if bid == "com.intentional.app" || bid == Bundle.main.bundleIdentifier {
            if overlayController?.isShowing == true || interventionController?.isShowing == true {
                debugLog("👁️ EXIT: own app activated by overlay click — keeping overlay")
                return
            }
            debugLog("👁️ EXIT: own app — allowing (grace timer preserved)")
            stopLingerTimer()
            isCurrentlyIrrelevant = false
            nudgeController?.dismiss()
            appDelegate?.socketRelayServer?.broadcastHideFocusOverlay()
            stopBrowserPolling()
            stopWorkTickTimer()
            startNeutralTickTimer(appName: "Intentional")
            return
        }

        // UNPLANNED or NO_PLAN: use grace period before showing overlay
        if state == .unplanned || state == .noPlan {
            // Check global noPlan snooze (applies to ALL apps, not per-target)
            if let until = noPlanSnoozeUntil, Date() < until {
                debugLog("👁️ EXIT: \(state.rawValue) — globally snoozed until \(until)")
                reconcileGrayscale()
                stopBrowserPolling()
                return
            }
            // Check per-target suppression (from "5 more min")
            if let until = suppressedUntil[bid], Date() < until {
                debugLog("👁️ EXIT: \(state.rawValue) but suppressed until \(until)")
                reconcileGrayscale()
                stopBrowserPolling()
                return
            }
            // If already showing overlay for this target, skip
            if isCurrentlyIrrelevant && currentTargetKey == bid {
                debugLog("👁️ EXIT: \(state.rawValue) — overlay already showing for \(bid)")
                reconcileGrayscale()
                stopBrowserPolling()
                return
            }

            let intention = state == .noPlan ? "Plan your day" : "Unscheduled time"
            let reason = state == .noPlan
                ? "Set up your daily plan to start browsing."
                : "This time isn't scheduled — add a block or take a break."

            let pending = PendingOverlayInfo(
                targetKey: bid,
                displayName: appName,
                intention: intention,
                reason: reason,
                isRevisit: warnedTargets.contains(bid),
                focusDurationMinutes: 0,
                isNoPlan: true,
                confidence: 0
            )

            debugLog("👁️ \(state.rawValue) — starting grace period on \(appName)")
            startGracePeriod(pending: pending)
            stopBrowserPolling()
            return
        }

        // WORK STATE (deep work or focus hours): score content for relevance
        guard state.isWork else {
            handleRelevantContent()
            stopBrowserPolling()
            return
        }

        // User-configured distracting apps: always treat as irrelevant during work blocks
        // Checked BEFORE always-allowed — user intent overrides defaults
        // Skip grace period — user explicitly configured this app as distracting
        if distractingAppBundleIds.contains(bid) {
            debugLog("👁️ \(appName) is user-configured distracting app — direct enforcement (no grace)")
            stopBrowserPolling()
            logAssessment(
                title: appName,
                intention: scheduleManager?.currentBlock?.title ?? "",
                relevant: false,
                confidence: 100,
                reason: "User-configured distracting app",
                action: "none"
            )
            if scheduleManager?.currentTimeState.isWork == true {
                appDelegate?.earnedBrowseManager?.recordAssessment(relevant: false)
            }
            // Increment distraction counter
            cumulativeDistractionSeconds += Self.browserPollInterval
            // Set state directly — no grace period limbo
            cancelGracePeriod()
            warnedTargets.insert(bid)
            currentTarget = appName
            currentTargetKey = bid
            isCurrentlyIrrelevant = true
            // Start gradual grayscale (same slow shift as distracting websites)
            let blockType = scheduleManager?.currentBlock?.blockType ?? .focusHours
            if !(grayscaleController?.isActive ?? false) && isEnforcementEnabled(.screenRedShift) {
                grayscaleController?.startDesaturation()
                grayscaleTriggeredThisBlock = true
            }
            deepWorkTimerController?.update(isDistracted: true)
            // Show overlay (deep work) or nudge (focus hours)
            let intention = scheduleManager?.currentBlock?.title ?? ""
            let focusDuration = computeFocusDurationMinutes()
            if blockType == .deepWork && isEnforcementEnabled(.blockingOverlay) {
                showOverlay(intention: intention, reason: "User-configured distracting app",
                           focusDurationMinutes: focusDuration, isNoPlan: false, displayName: appName)
            } else if isEnforcementEnabled(.nudge) {
                showNudgeForContent(intention: intention, displayName: appName, escalated: false)
            }
            return
        }

        // Apple system apps: auto-allow com.apple.* unless it's an entertainment app
        if bid.hasPrefix("com.apple.") && !Self.appleEntertainmentBundleIds.contains(bid) {
            debugLog("👁️ EXIT: Apple system app \(appName) — always allowed")
            handleRelevantContent()
            stopBrowserPolling()
            logAssessment(
                title: appName,
                intention: scheduleManager?.currentBlock?.title ?? "",
                relevant: true,
                confidence: 100,
                reason: "Always-allowed app",
                action: "none"
            )
            appDelegate?.earnedBrowseManager?.updateLastActiveApp(name: appName, timestamp: Date())
            startWorkTickTimer(appName: appName)
            return
        }

        // Always-allowed apps: never block system utilities, terminals, password managers, etc.
        if Self.alwaysAllowedBundleIds.contains(bid) {
            debugLog("👁️ EXIT: \(appName) is always-allowed")
            handleRelevantContent()
            stopBrowserPolling()
            logAssessment(
                title: appName,
                intention: scheduleManager?.currentBlock?.title ?? "",
                relevant: true,
                confidence: 100,
                reason: "Always-allowed app",
                action: "none"
            )
            appDelegate?.earnedBrowseManager?.updateLastActiveApp(name: appName, timestamp: Date())
            startWorkTickTimer(appName: appName)
            return
        }

        // If it's a browser, read tab title via AppleScript and start polling
        if Self.browserBundleIds.contains(bid) {
            debugLog("👁️ Browser detected (\(bid)) — reading tab via AppleScript")

            // If grayscale was triggered this block, maintain it when returning to browser.
            // Assume content is irrelevant until AI scoring proves otherwise (prevents flicker).
            if grayscaleTriggeredThisBlock && scheduleManager?.currentTimeState.isWork == true && isEnforcementEnabled(.screenRedShift) {
                isCurrentlyIrrelevant = true
                if !(grayscaleController?.isActive ?? false) {
                    grayscaleController?.startDesaturation()
                    appDelegate?.postLog("🌫️ Browser activated: grayscale maintained (pending AI score)")
                    logAssessment(title: "Grayscale", appName: appName, intention: scheduleManager?.currentBlock?.title ?? "",
                                 relevant: false, confidence: 0, reason: "Browser activated — maintaining grayscale pending AI score",
                                 action: "grayscale_on", isEvent: true)
                }
            }

            lastScoredTitle = nil
            lastScoredURL = nil
            lastScoreWasIrrelevant = false
            readAndScoreActiveTab(bundleId: bid)
            startBrowserPolling(bundleId: bid)
            return
        }

        // Non-browser app: stop browser polling and score the app name
        stopBrowserPolling()
        debugLog("👁️ App switched to: \(appName) (\(bid))")

        // Score app name asynchronously
        Task {
            guard let scorer = self.relevanceScorer,
                  let block = manager.currentBlock else { return }

            let result = await scorer.scoreRelevance(
                pageTitle: appName,
                intention: block.title,
                intentionDescription: block.description,
                profile: manager.profile,
                dailyPlan: manager.todaySchedule?.dailyPlan ?? "",
                contentType: .application
            )

            await MainActor.run {
                // Stale check: app may no longer be frontmost (scoring is async)
                guard self.currentAppBundleId == bid else {
                    self.appDelegate?.postLog("👁️ Scoring completed but \(appName) no longer frontmost — ignoring")
                    return
                }

                self.logAssessment(
                    title: appName, intention: block.title,
                    relevant: result.relevant, confidence: result.confidence,
                    reason: result.reason, action: "none"
                )
                if result.relevant {
                    self.debugLog("👁️ App is relevant: \(appName)")
                    self.handleRelevantContent()
                    // Let the work tick timer handle earning (no initial tick to avoid double-counting)
                    if self.scheduleManager?.currentTimeState.isWork == true {
                        self.appDelegate?.earnedBrowseManager?.updateLastActiveApp(
                            name: appName, timestamp: Date()
                        )
                        // Start continuous work tick timer so earning + decay continues
                        self.startWorkTickTimer(appName: appName)
                    }
                } else {
                    self.appDelegate?.postLog("👁️ App is NOT relevant: \(appName) — \(result.reason)")
                    // Record irrelevant assessment for deep work tracking
                    if self.scheduleManager?.currentTimeState.isWork == true {
                        self.appDelegate?.earnedBrowseManager?.recordAssessment(relevant: false)
                    }
                    self.handleIrrelevantContent(targetKey: bid, displayName: appName)
                }
            }
        }
    }

    // MARK: - AppleScript Tab Reading

    /// Read the active tab title and URL via AppleScript, then score for relevance.
    private func readAndScoreActiveTab(bundleId: String) {
        guard let manager = scheduleManager,
              manager.currentTimeState.isWork,
              let block = manager.currentBlock,
              let scorer = relevanceScorer else { return }

        let tabInfo = readActiveTabInfo(for: bundleId)

        guard let info = tabInfo else {
            debugLog("👁️ Could not read tab info for \(bundleId)")
            // Still log assessment so browser time is tracked even when AppleScript fails
            let browserName = Self.browserAppNames[bundleId] ?? "Browser"
            logAssessment(
                title: browserName, appName: browserName,
                intention: scheduleManager?.currentBlock?.title ?? "",
                relevant: true, confidence: 0, reason: "Unable to read tab", action: "none",
                neutral: true
            )
            return
        }

        // Detect transition FROM blocking page (user justified or left)
        if tabIsOnBlockingPage {
            if !info.url.contains("focus-blocked.html") {
                tabIsOnBlockingPage = false
                blockedOriginalURL = nil
                cumulativeDistractionSeconds = 0
                if info.hostname == currentTargetKey {
                    // Justified return → 5-min suppression + whitelist in scorer
                    suppressedUntil[currentTargetKey] = Date().addingTimeInterval(Self.suppressionSeconds)
                    if let title = lastScoredTitle, let block = scheduleManager?.currentBlock {
                        relevanceScorer?.approvePageTitle(title, for: block.title)
                    }
                    isCurrentlyIrrelevant = false
                    lastScoredTitle = nil
                    lastScoredURL = nil
                    debugLog("👁️ Justified return to \(currentTargetKey) — whitelisted + 5-min suppression set")
                } else {
                    // Left to different site or about:blank → clear state
                    isCurrentlyIrrelevant = false
                    lastScoredTitle = nil
                    lastScoredURL = nil
                    debugLog("👁️ Left blocking page to \(info.hostname) — state cleared")
                }
                return
            } else {
                // Still on blocking page — skip scoring, preserve state
                return
            }
        }

        // Skip re-scoring if tab hasn't changed since last score.
        // Still record work ticks (relevant) or cumulative samples (irrelevant).
        if info.title == lastScoredTitle && info.url == lastScoredURL {
            if lastScoreWasIrrelevant {
                // Log assessment so the popover time tracking is accurate for irrelevant tabs too
                let browserName = Self.browserAppNames[bundleId] ?? "Browser"
                logAssessment(
                    title: info.title, appName: browserName, hostname: info.hostname, intention: scheduleManager?.currentBlock?.title ?? "",
                    relevant: false, confidence: 0, reason: "unchanged tab (irrelevant)", action: "none"
                )
                if scheduleManager?.currentTimeState.isWork == true {
                    appDelegate?.earnedBrowseManager?.recordAssessment(relevant: false)
                }
                handleIrrelevantContent(targetKey: info.hostname, displayName: info.title)
            } else if scheduleManager?.currentTimeState.isWork == true {
                // Tab is still relevant — record ongoing work tick + assessment
                appDelegate?.earnedBrowseManager?.recordWorkTick(seconds: Self.browserPollInterval)
                appDelegate?.earnedBrowseManager?.recordAssessment(relevant: true)
                pushFocusStatsToTimer()
                // Log assessment so the popover time tracking is accurate
                let browserName = Self.browserAppNames[bundleId] ?? "Browser"
                logAssessment(
                    title: info.title, appName: browserName, hostname: info.hostname, intention: scheduleManager?.currentBlock?.title ?? "",
                    relevant: true, confidence: 100, reason: "unchanged tab", action: "none"
                )
            }
            return
        }
        lastScoredTitle = info.title
        lastScoredURL = info.url

        // Don't score our own focus-blocked page
        if info.url.contains("focus-blocked.html") || info.url.contains("blocked.html") {
            lastScoreWasIrrelevant = false
            return
        }

        debugLog("👁️ Scoring tab: \"\(info.title)\" (\(info.hostname))")

        // Score asynchronously
        Task {
            let result = await scorer.scoreRelevance(
                pageTitle: info.title,
                intention: block.title,
                intentionDescription: block.description,
                profile: manager.profile,
                dailyPlan: manager.todaySchedule?.dailyPlan ?? ""
            )

            await MainActor.run {
                // Stale check: browser may no longer be frontmost (scoring is async)
                guard self.currentAppBundleId == bundleId else {
                    self.appDelegate?.postLog("👁️ Scoring completed but \(bundleId) no longer frontmost — ignoring")
                    return
                }

                if result.relevant {
                    self.lastScoreWasIrrelevant = false
                    let browserName = Self.browserAppNames[bundleId] ?? "Browser"
                    self.logAssessment(
                        title: info.title, appName: browserName, hostname: info.hostname, intention: block.title,
                        relevant: true, confidence: result.confidence,
                        reason: result.reason, action: "none"
                    )
                    self.debugLog("👁️ Tab is relevant: \"\(info.title)\"")
                    self.handleRelevantContent()
                    // No initial tick here — browser poll timer handles ongoing earning
                } else {
                    self.lastScoreWasIrrelevant = true
                    let browserName = Self.browserAppNames[bundleId] ?? "Browser"
                    self.logAssessment(
                        title: info.title, appName: browserName, hostname: info.hostname, intention: block.title,
                        relevant: false, confidence: result.confidence,
                        reason: result.reason, action: "none"
                    )
                    // Record irrelevant assessment for earned browse tracking
                    if self.scheduleManager?.currentTimeState.isWork == true {
                        self.appDelegate?.earnedBrowseManager?.recordAssessment(relevant: false)
                    }
                    self.appDelegate?.postLog("👁️ Tab is NOT relevant: \"\(info.title)\" — \(result.reason)")
                    self.handleIrrelevantContent(targetKey: info.hostname, displayName: info.title, confidence: result.confidence, reason: result.reason)
                }
            }
        }
    }

    /// Read the active tab's title and URL using AppleScript.
    /// Returns nil if the browser isn't responding or has no windows.
    private func readActiveTabInfo(for bundleId: String) -> (title: String, url: String, hostname: String)? {
        guard let appName = Self.browserAppNames[bundleId] else { return nil }

        let script: String
        if bundleId == "com.apple.Safari" {
            script = """
            tell application "Safari"
                if it is running and (count of windows) > 0 then
                    set t to name of current tab of front window
                    set u to URL of current tab of front window
                    return t & "|||" & u
                end if
            end tell
            return ""
            """
        } else {
            script = """
            tell application "\(appName)"
                if it is running and (count of windows) > 0 then
                    set t to title of active tab of front window
                    set u to URL of active tab of front window
                    return t & "|||" & u
                end if
            end tell
            return ""
            """
        }

        guard let appleScript = NSAppleScript(source: script) else { return nil }

        var error: NSDictionary?
        let output = appleScript.executeAndReturnError(&error)

        if error != nil { return nil }

        guard let result = output.stringValue, !result.isEmpty else { return nil }

        let parts = result.components(separatedBy: "|||")
        guard parts.count >= 2 else { return nil }

        let title = parts[0]
        let url = parts[1]

        var hostname = bundleId
        if let urlObj = URL(string: url), let host = urlObj.host {
            hostname = host
        }

        return (title: title, url: url, hostname: hostname)
    }

    // MARK: - Browser Polling

    private func startBrowserPolling(bundleId: String) {
        stopBrowserPolling()
        browserPollTimer = Timer.scheduledTimer(withTimeInterval: Self.browserPollInterval, repeats: true) { [weak self] _ in
            self?.pollActiveTab(bundleId: bundleId)
        }
    }

    private func stopBrowserPolling() {
        browserPollTimer?.invalidate()
        browserPollTimer = nil
    }

    /// Start a repeating timer that records work ticks for always-allowed non-browser apps.
    private func startWorkTickTimer(appName: String) {
        stopWorkTickTimer()
        workTickTimer = Timer.scheduledTimer(withTimeInterval: Self.browserPollInterval, repeats: true) { [weak self] _ in
            guard let self = self,
                  self.scheduleManager?.currentTimeState.isWork == true else {
                self?.stopWorkTickTimer()
                return
            }
            // Log assessment on each tick so always-allowed apps accumulate time in the assessment popover
            self.logAssessment(
                title: appName,
                intention: self.scheduleManager?.currentBlock?.title ?? "",
                relevant: true,
                confidence: 100,
                reason: "Always-allowed app",
                action: "none"
            )
            self.appDelegate?.earnedBrowseManager?.recordWorkTick(seconds: Self.browserPollInterval)
            self.appDelegate?.earnedBrowseManager?.recordAssessment(relevant: true)
            self.pushFocusStatsToTimer()
            self.appDelegate?.earnedBrowseManager?.updateLastActiveApp(name: appName, timestamp: Date())
            // Decay distraction counter while on relevant/always-allowed app
            if self.cumulativeDistractionSeconds > 0 {
                let decay = Self.browserPollInterval * Self.distractionDecayRatio
                self.cumulativeDistractionSeconds = max(0, self.cumulativeDistractionSeconds - decay)
            }
        }
    }

    private func stopWorkTickTimer() {
        workTickTimer?.invalidate()
        workTickTimer = nil
    }

    /// Start a repeating timer that logs neutral ticks (grey in popover) for screen lock, Intentional app, etc.
    /// Neutral time: no earning, no penalty, no distraction decay — cumulative distraction stays frozen.
    private func startNeutralTickTimer(appName: String) {
        stopNeutralTickTimer()
        neutralTickTimer = Timer.scheduledTimer(withTimeInterval: Self.browserPollInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.logAssessment(
                title: appName,
                intention: self.scheduleManager?.currentBlock?.title ?? "",
                relevant: true, confidence: 0, reason: "Neutral app", action: "none", neutral: true
            )
        }
    }

    private func stopNeutralTickTimer() {
        neutralTickTimer?.invalidate()
        neutralTickTimer = nil
    }

    private func pollActiveTab(bundleId: String) {
        guard currentAppBundleId == bundleId,
              let manager = scheduleManager,
              manager.currentTimeState.isWork else {
            stopBrowserPolling()
            return
        }

        reconcileGrayscale()
        readAndScoreActiveTab(bundleId: bundleId)
    }

    // MARK: - Tab Redirect Blocking

    private func blockActiveTab(intention: String, pageTitle: String, hostname: String, originalURL: String? = nil) {
        guard let bundleId = currentAppBundleId,
              let appName = Self.browserAppNames[bundleId] else { return }

        guard let resourcePath = Bundle.main.resourcePath else { return }
        let blockPageBase = "file://\(resourcePath)/focus-blocked.html"

        // Use a strict character set for query values — urlQueryAllowed doesn't escape &=?#
        // which breaks parameter parsing when values (like URLs) contain those characters
        var queryValueAllowed = CharacterSet.urlQueryAllowed
        queryValueAllowed.remove(charactersIn: "&=+?#")

        let encodedIntention = intention.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? intention
        let encodedPage = pageTitle.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? pageTitle
        let encodedHost = hostname.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? hostname
        var fullURL = "\(blockPageBase)?intention=\(encodedIntention)&page=\(encodedPage)&hostname=\(encodedHost)"
        if let original = originalURL,
           let encodedOriginal = original.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) {
            fullURL += "&url=\(encodedOriginal)"
        }
        // Pass focus duration for the badge
        let focusDuration = computeFocusDurationMinutes()
        fullURL += "&focusDuration=\(focusDuration)"
        // Pass last relevant URL for "Back to work" navigation
        if let backURL = lastRelevantTabURL,
           let encodedBack = backURL.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) {
            fullURL += "&backURL=\(encodedBack)"
        }

        // Log enforcement event for popover visibility
        logAssessment(
            title: pageTitle, appName: appName, hostname: hostname,
            intention: intention, relevant: false, confidence: 0,
            reason: "Tab redirected to block page",
            action: "blocked", isEvent: true
        )

        // First check if already on the blocked page
        if let info = readActiveTabInfo(for: bundleId), info.url.contains("focus-blocked.html") {
            debugLog("👁️ Already on focus-blocked page, skipping redirect")
            return
        }

        let script: String
        if bundleId == "com.apple.Safari" {
            script = """
            tell application "Safari"
                set URL of current tab of front window to "\(fullURL)"
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
                set URL of active tab of front window to "\(fullURL)"
            end tell
            """
        }

        appleScriptQueue.async { [weak self] in
            guard let appleScript = NSAppleScript(source: script) else { return }
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)

            DispatchQueue.main.async {
                if let errorDict = error {
                    let msg = errorDict["NSAppleScriptErrorMessage"] as? String ?? "Unknown"
                    self?.debugLog("👁️ Failed to redirect tab: \(msg)")
                } else {
                    self?.tabIsOnBlockingPage = true
                    self?.blockedOriginalURL = originalURL
                    self?.debugLog("👁️ Redirected tab to focus-blocked page")
                }
            }
        }
    }

    // MARK: - Grayscale Reconciliation

    /// Reconciliation check: ensure grayscale matches current state.
    /// Called on every poll tick and on app-switch evaluation.
    /// Grayscale should be ON only when ALL of these are true:
    ///   1. We're in a work block (deep work or focus hours)
    ///   2. grayscaleTriggeredThisBlock is true (we already decided to trigger it)
    ///   3. The user is currently on irrelevant content (isCurrentlyIrrelevant)
    /// If any condition is false and grayscale is active, restore color.
    private func reconcileGrayscale() {
        guard grayscaleController?.isActive == true else { return }

        let inWorkBlock = scheduleManager?.currentTimeState.isWork == true
        let shouldBeGray = inWorkBlock && grayscaleTriggeredThisBlock && isCurrentlyIrrelevant

        if !shouldBeGray {
            grayscaleController?.restoreSaturation()
            appDelegate?.postLog("🌫️ Reconciler: grayscale OFF (work=\(inWorkBlock), triggered=\(grayscaleTriggeredThisBlock), irrelevant=\(isCurrentlyIrrelevant))")
            logAssessment(title: currentTarget.isEmpty ? currentAppName : currentTarget, appName: currentAppName,
                         intention: scheduleManager?.currentBlock?.title ?? "",
                         relevant: true, confidence: 0, reason: "Content now relevant — grayscale removed",
                         action: "grayscale_off", isEvent: true)
        }
    }

    // MARK: - Floating Timer Stats

    /// Push latest focus percentage and earned minutes to the floating timer widget.
    private func pushFocusStatsToTimer() {
        guard let ebm = appDelegate?.earnedBrowseManager else { return }
        let focusPercent: Int
        let blockEarned: Double
        if let blockId = ebm.activeBlockId, let stats = ebm.blockFocusStats[blockId] {
            focusPercent = stats.focusScore
            blockEarned = stats.earnedMinutes
        } else {
            focusPercent = 0
            blockEarned = 0
        }
        deepWorkTimerController?.update(focusPercent: focusPercent, earnedMinutes: blockEarned)
    }

    // MARK: - Relevance Handling

    private func handleRelevantContent() {
        debugLog("👁️ handleRelevantContent — dismissing overlays")
        cancelGracePeriod()
        stopLingerTimer()
        isCurrentlyIrrelevant = false
        tabIsOnBlockingPage = false
        blockedOriginalURL = nil
        nudgeController?.dismiss()
        overlayController?.dismiss()
        appDelegate?.socketRelayServer?.broadcastHideFocusOverlay()

        // Restore grayscale whenever user is on relevant content (any app, any tab)
        reconcileGrayscale()
        deepWorkTimerController?.update(isDistracted: false)
        pushFocusStatsToTimer()

        // Decay cumulative distraction counter when back on relevant content
        // (counter persists — thresholds already crossed stay crossed)
        if cumulativeDistractionSeconds > 0 {
            let decay = Self.browserPollInterval * Self.distractionDecayRatio
            cumulativeDistractionSeconds = max(0, cumulativeDistractionSeconds - decay)
            appDelegate?.postLog("👁️ Distraction decay: now \(Int(cumulativeDistractionSeconds))s")

            // Reset one-shot flags when counter decays below their thresholds
            if cumulativeDistractionSeconds < Self.deepWorkRedirectThreshold {
                deepWorkRedirectFired = false
            }
        }

        // Reset per-content nudge tracking (but NOT interventionCount or lastInterventionAtDistraction —
        // those are cumulative and persist until block change or counter reaches 0)
        nudgeShownForCurrentContent = false

        // Dismiss active intervention if showing
        interventionController?.dismiss()

        // Track last relevant browser tab for smart "Back to work"
        if let bundleId = currentAppBundleId,
           Self.browserBundleIds.contains(bundleId),
           let info = readActiveTabInfo(for: bundleId),
           !info.url.contains("focus-blocked.html") {
            lastRelevantTabURL = info.url
        }
    }

    /// Block-type-aware enforcement for irrelevant content.
    ///
    /// **Deep Work** (browsers): nudge → 30s → overlay → 5 min cumulative → tab redirect
    /// **Deep Work** (native apps): grace period → overlay
    /// **Focus Hours** (browsers): level 1 nudge (auto-dismiss 8s) → 5 min → level 2 nudge (persistent, reappears 90s)
    /// **Focus Hours** (native apps): grace period → nudge (not overlay)
    private func handleIrrelevantContent(targetKey: String, displayName: String, confidence: Int = 0, reason: String = "") {
        // Check suppression
        if let until = suppressedUntil[targetKey], Date() < until { return }

        // Content approved via justification — skip enforcement
        if sessionOverrides.contains(targetKey) { return }

        let isBrowser = currentAppBundleId.map { Self.browserBundleIds.contains($0) } ?? false
        guard let timeState = scheduleManager?.currentTimeState, timeState.isWork else { return }
        let blockType = scheduleManager?.currentBlock?.blockType ?? .focusHours

        // Increment cumulative distraction counter (always — even for extension-handled sites)
        cumulativeDistractionSeconds += Self.browserPollInterval

        // Check if extension handles nudge/redirect enforcement for this site
        let extensionHandled: Bool = {
            guard isBrowser, isSocialMedia(targetKey), let bundleId = currentAppBundleId else { return false }
            let connectedBrowsers = appDelegate?.socketRelayServer?.getConnectedBrowserBundleIds() ?? []
            return connectedBrowsers.contains(bundleId)
        }()

        appDelegate?.postLog("👁️ Distraction: \(Int(cumulativeDistractionSeconds))s [\(blockType.rawValue)]\(extensionHandled ? " (ext handles nudges)" : "")")

        // Grayscale + deep work timer apply regardless of who handles nudges
        if isBrowser && extensionHandled {
            // Grayscale: instant if already triggered this block, otherwise at threshold
            let shouldGrayscale = grayscaleTriggeredThisBlock
                || cumulativeDistractionSeconds >= Self.focusGrayscaleThreshold
            if shouldGrayscale && !(grayscaleController?.isActive ?? false) && isEnforcementEnabled(.screenRedShift) {
                grayscaleController?.startDesaturation()
                grayscaleTriggeredThisBlock = true
                appDelegate?.postLog("🌫️ Grayscale started at \(Int(cumulativeDistractionSeconds))s distraction (extension-handled site)")
                logAssessment(title: currentTarget, appName: currentAppName, intention: scheduleManager?.currentBlock?.title ?? "",
                             relevant: false, confidence: 0, reason: "Grayscale at \(Int(cumulativeDistractionSeconds))s distraction (extension-handled)",
                             action: "grayscale_on", isEvent: true)
            }
            // Deep Work: timer dot red
            if blockType == .deepWork {
                deepWorkTimerController?.update(isDistracted: true)
                pushFocusStatsToTimer()
            }
            return // Extension handles nudges/redirects for social media
        }

        let intention = scheduleManager?.currentBlock?.title ?? ""

        if isBrowser {
            // ── Browser enforcement (differentiated by block type) ──
            switch blockType {
            case .deepWork:
                handleDeepWorkBrowserIrrelevance(targetKey: targetKey, displayName: displayName,
                                                  intention: intention, confidence: confidence, reason: reason)
            case .focusHours:
                handleFocusHoursBrowserIrrelevance(targetKey: targetKey, displayName: displayName,
                                                    intention: intention, confidence: confidence, reason: reason)
            case .freeTime:
                break // Should never reach here — freeTime is filtered out earlier
            }
        } else {
            // ── Native app enforcement ──
            // If already showing overlay/nudge for this same target, don't re-trigger
            if isCurrentlyIrrelevant && currentTargetKey == targetKey { return }

            let alreadyWarned = warnedTargets.contains(targetKey)
            let focusDuration = computeFocusDurationMinutes()

            let pending = PendingOverlayInfo(
                targetKey: targetKey,
                displayName: displayName,
                intention: intention,
                reason: reason,
                isRevisit: alreadyWarned,
                focusDurationMinutes: focusDuration,
                isNoPlan: false,
                confidence: confidence
            )

            startGracePeriod(pending: pending)
        }
    }

    // MARK: - Deep Work Browser Enforcement

    /// Deep Work aggressive browser enforcement (all threshold-driven):
    /// - 10s cumulative: nudge + timer dot red
    /// - 20s cumulative: auto-redirect to last relevant URL + grayscale starts
    /// - 20s+ (revisit): instant redirect if site already redirected this block
    /// - 300s cumulative: intervention overlay (escalating 60s/90s/120s)
    private func handleDeepWorkBrowserIrrelevance(targetKey: String, displayName: String,
                                                   intention: String, confidence: Int, reason: String) {
        // Timer dot → red immediately
        deepWorkTimerController?.update(isDistracted: true)
        pushFocusStatsToTimer()

        // Site was already redirected during this block → instant redirect
        if deepWorkRedirectedSites.contains(targetKey) && isEnforcementEnabled(.autoRedirect) {
            appDelegate?.postLog("👁️ Deep Work: instant redirect (revisit) for \(targetKey)")
            navigateToRelevant()
            return
        }

        // Track current target
        if currentTargetKey != targetKey {
            nudgeShownForCurrentContent = false
            currentTarget = displayName
            currentTargetKey = targetKey
        }

        // Check thresholds in descending order (highest priority first)

        // 300s+: Intervention overlay (and re-trigger every 300s)
        if cumulativeDistractionSeconds >= Self.deepWorkInterventionThreshold
            && (cumulativeDistractionSeconds - lastInterventionAtDistraction >= Self.deepWorkInterventionThreshold)
            && interventionEnabled && isEnforcementEnabled(.interventionExercises) {
            lastInterventionAtDistraction = cumulativeDistractionSeconds
            interventionCount += 1
            nudgeController?.dismiss()
            let duration = min(60 + ((interventionCount - 1) * 30), 120)
            showInterventionOverlay(intention: intention, displayName: displayName, duration: duration)
            return
        }

        // 20s: Auto-redirect + grayscale
        if cumulativeDistractionSeconds >= Self.deepWorkRedirectThreshold && !deepWorkRedirectFired {
            deepWorkRedirectFired = true
            if isEnforcementEnabled(.autoRedirect) {
                deepWorkAutoRedirect()
                return
            }
        }

        // 10s: First nudge
        if cumulativeDistractionSeconds >= Self.deepWorkNudgeThreshold && !nudgeShownForCurrentContent {
            nudgeShownForCurrentContent = true
            if isEnforcementEnabled(.nudge) {
                showNudgeForContent(intention: intention, displayName: displayName, escalated: false)
            }
        }
    }

    /// Deep Work: cumulative threshold reached → auto-redirect tab to last relevant URL + start grayscale.
    private func deepWorkAutoRedirect() {
        guard scheduleManager?.currentBlock?.blockType == .deepWork else { return }

        nudgeController?.dismiss()

        let intention = scheduleManager?.currentBlock?.title ?? ""
        let targetKey = currentTargetKey

        // Add to redirected set for instant redirect on revisit
        deepWorkRedirectedSites.insert(targetKey)

        // Start grayscale at the second notification (the redirect)
        if !(grayscaleController?.isActive ?? false) && isEnforcementEnabled(.screenRedShift) {
            grayscaleController?.startDesaturation()
            grayscaleTriggeredThisBlock = true
            appDelegate?.postLog("🌫️ Deep Work: grayscale started on redirect")
            logAssessment(title: currentTarget, appName: currentAppName, intention: scheduleManager?.currentBlock?.title ?? "",
                         relevant: false, confidence: 0, reason: "Deep Work auto-redirect grayscale",
                         action: "grayscale_on", isEvent: true)
        }

        appDelegate?.postLog("👁️ Deep Work: auto-redirect at \(Int(cumulativeDistractionSeconds))s cumulative — \(currentTarget)")

        // Navigate to last relevant URL
        navigateToRelevant()

        // Show brief auto-dismissing nudge confirming the redirect
        setupNudgeCallbacks()
        nudgeController?.showNudge(
            intention: intention,
            appOrPage: "Not related to \"\(intention)\"",
            escalated: false
        )
        // Auto-dismiss the nudge after 5s (shorter than normal 8s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.nudgeController?.dismiss()
        }

        // Log enforcement event
        let browserName = currentAppBundleId.flatMap { Self.browserAppNames[$0] } ?? ""
        logAssessment(
            title: currentTarget, appName: browserName.isEmpty ? currentTarget : browserName,
            intention: intention, relevant: false, confidence: 0,
            reason: "Deep Work auto-redirect",
            action: "blocked", isEvent: true
        )
    }

    /// Navigate the active browser tab to the last relevant URL (or google.com as fallback).
    private func navigateToRelevant() {
        guard let bundleId = currentAppBundleId, Self.browserBundleIds.contains(bundleId) else { return }
        let url = lastRelevantTabURL ?? "https://www.google.com"
        navigateActiveTab(to: url, bundleId: bundleId)
        tabIsOnBlockingPage = false
        isCurrentlyIrrelevant = false
    }

    /// Redirect browser tab to focus-blocked.html (Deep Work only, after sustained distraction)
    private func redirectBrowserTab(targetKey: String, displayName: String, intention: String) {
        var originalURL: String? = nil
        if let bundleId = currentAppBundleId, let info = readActiveTabInfo(for: bundleId) {
            originalURL = info.url
            if info.url.contains("focus-blocked.html") { return }
        }

        blockActiveTab(intention: intention, pageTitle: displayName,
                      hostname: targetKey, originalURL: originalURL)

        cumulativeDistractionSeconds = 0  // Reset after redirect
        appDelegate?.postLog("👁️ Deep work: redirected tab to focus-blocked page")
    }

    // MARK: - Focus Hours Browser Enforcement

    /// Focus Hours browser enforcement — all threshold-driven off cumulativeDistractionSeconds:
    /// 10s: Level 1 nudge #1 (auto-dismiss 8s)
    /// 30s: Grayscale starts (30s fade to dark)
    /// 70s: Level 1 nudge #2 (+60s from first)
    /// 130s: Level 1 nudge #3
    /// 190s: Level 1 nudge #4
    /// 240s: Warning nudge (red, "intervention in 60s")
    /// 300s: Intervention overlay (60s mandatory, escalating)
    /// 600s: Re-intervention (90s mandatory)
    /// 900s: Re-intervention (120s mandatory, capped)
    /// Between interventions: Level 2 persistent nudges (re-show on each poll if dismissed)
    private func handleFocusHoursBrowserIrrelevance(targetKey: String, displayName: String,
                                                     intention: String, confidence: Int, reason: String) {
        // Track current target
        currentTarget = displayName
        currentTargetKey = targetKey

        // Update floating timer distraction dot (red) for focus hours too
        deepWorkTimerController?.update(isDistracted: true)
        pushFocusStatsToTimer()

        // ── Grayscale: instant if already triggered this block, otherwise at 30s ──
        let shouldGrayscale = grayscaleTriggeredThisBlock
            || cumulativeDistractionSeconds >= Self.focusGrayscaleThreshold
        if shouldGrayscale && !(grayscaleController?.isActive ?? false) && isEnforcementEnabled(.screenRedShift) {
            grayscaleController?.startDesaturation()
            grayscaleTriggeredThisBlock = true
            appDelegate?.postLog("🌫️ Focus Hours: grayscale at \(Int(cumulativeDistractionSeconds))s\(grayscaleTriggeredThisBlock ? " (re-trigger)" : "")")
            logAssessment(title: displayName, appName: currentAppName, intention: intention,
                         relevant: false, confidence: 0, reason: "Focus Hours grayscale at \(Int(cumulativeDistractionSeconds))s",
                         action: "grayscale_on", isEvent: true)
        }

        // ── Check thresholds in descending order ──

        // 300s+: Intervention overlay (re-trigger every 300s)
        if cumulativeDistractionSeconds >= Self.focusInterventionThreshold
            && (cumulativeDistractionSeconds - lastInterventionAtDistraction >= Self.focusInterventionThreshold)
            && interventionEnabled && isEnforcementEnabled(.interventionExercises) {
            lastInterventionAtDistraction = cumulativeDistractionSeconds
            interventionCount += 1
            nudgeController?.dismiss()
            let duration = min(60 + ((interventionCount - 1) * 30), 120)
            showInterventionOverlay(intention: intention, displayName: displayName, duration: duration)
            return
        }

        // Past intervention threshold but between re-triggers: Level 2 persistent nudges
        if cumulativeDistractionSeconds >= Self.focusInterventionThreshold {
            // Show level 2 nudge if not already showing one (and intervention isn't showing)
            if !(nudgeController?.isShowing ?? false) && !(interventionController?.isShowing ?? false)
                && isEnforcementEnabled(.nudge) {
                let distractionMinutes = Int(cumulativeDistractionSeconds / 60)
                showNudgeForContent(intention: intention, displayName: displayName,
                                   escalated: true, distractionMinutes: distractionMinutes)
            }
            return
        }

        // 240s: Warning nudge (red, "intervention in 60s")
        if cumulativeDistractionSeconds >= Self.focusWarningThreshold
            && interventionEnabled && isEnforcementEnabled(.interventionExercises)
            && lastNudgeShownAtDistraction < Self.focusWarningThreshold {
            lastNudgeShownAtDistraction = cumulativeDistractionSeconds
            if isEnforcementEnabled(.nudge) {
                showNudgeForContent(intention: intention, displayName: displayName,
                                   escalated: true, distractionMinutes: Int(cumulativeDistractionSeconds / 60),
                                   warning: true)
            }
            return
        }

        // 10s+: Level 1 nudges — first at 10s, then every +60s (70, 130, 190)
        if cumulativeDistractionSeconds >= Self.focusNudgeThreshold
            && cumulativeDistractionSeconds < Self.focusWarningThreshold {
            let shouldShow = !nudgeShownForCurrentContent ||
                (cumulativeDistractionSeconds - lastNudgeShownAtDistraction >= Self.focusNudgeRepeatInterval)
            if shouldShow {
                nudgeShownForCurrentContent = true
                lastNudgeShownAtDistraction = cumulativeDistractionSeconds
                if isEnforcementEnabled(.nudge) {
                    showNudgeForContent(intention: intention, displayName: displayName, escalated: false)
                }
            }
        }
    }

    // MARK: - Intervention Overlay

    /// Whether focus interventions are enabled (default: true).
    private var interventionEnabled: Bool {
        return UserDefaults.standard.object(forKey: "focusInterventionEnabled") as? Bool ?? true
    }

    /// Check if a specific enforcement mechanism is enabled for the current block type.
    private func isEnforcementEnabled(_ mechanism: ScheduleManager.EnforcementMechanism) -> Bool {
        return scheduleManager?.isEnforcementEnabled(mechanism) ?? true
    }

    /// Show the full-screen intervention overlay with a random game.
    /// Duration escalates: 60s (1st), 90s (2nd), 120s (3rd+).
    private func showInterventionOverlay(intention: String, displayName: String, duration: Int = 60) {
        let distractionMinutes = Int(cumulativeDistractionSeconds / 60)
        // Compute focus score from current block stats
        let focusScore: Int = {
            guard let blockId = appDelegate?.earnedBrowseManager?.activeBlockId,
                  let stats = appDelegate?.earnedBrowseManager?.blockFocusStats[blockId] else { return 0 }
            return stats.focusScore
        }()
        interventionController?.onComplete = { [weak self] in
            self?.appDelegate?.postLog("🧩 Intervention completed (count: \(self?.interventionCount ?? 0))")
            // Level 2 nudges will resume on next poll via threshold check
        }
        interventionController?.showIntervention(
            intention: intention, displayName: displayName,
            distractionMinutes: distractionMinutes,
            duration: duration, focusScore: focusScore
        )
        // Log enforcement event
        let browserName = currentAppBundleId.flatMap { Self.browserAppNames[$0] } ?? ""
        logAssessment(
            title: displayName, appName: browserName.isEmpty ? displayName : browserName,
            intention: intention, relevant: false, confidence: 0,
            reason: "Focus intervention (\(distractionMinutes) min off-task)",
            action: "intervention", isEvent: true
        )
    }

    // MARK: - Nudge Display Helper

    /// Show a nudge card with the appropriate callbacks wired up.
    private func showNudgeForContent(intention: String, displayName: String,
                                     escalated: Bool = false, distractionMinutes: Int = 0,
                                     warning: Bool = false) {
        setupNudgeCallbacks()
        nudgeController?.showNudge(
            intention: intention,
            appOrPage: displayName,
            escalated: escalated,
            distractionMinutes: distractionMinutes,
            warning: warning
        )
        appDelegate?.earnedBrowseManager?.recordNudge()
        // Log enforcement event for popover visibility
        let browserName = currentAppBundleId.flatMap { Self.browserAppNames[$0] } ?? ""
        let reason: String
        if warning {
            reason = "Warning nudge (intervention in 60s)"
        } else if escalated {
            reason = "Level 2 nudge (persistent)"
        } else {
            reason = "Level 1 nudge"
        }
        logAssessment(
            title: displayName, appName: browserName.isEmpty ? displayName : browserName,
            intention: intention, relevant: false, confidence: 0,
            reason: reason,
            action: "nudge", isEvent: true
        )
    }

    /// Wire up nudge button callbacks (idempotent — safe to call multiple times).
    private func setupNudgeCallbacks() {
        nudgeController?.onGotIt = { [weak self] in
            self?.appDelegate?.postLog("💬 Nudge: 'Got it'")
            // Don't clear isCurrentlyIrrelevant — user acknowledged but content is still irrelevant
        }
        nudgeController?.onThisIsRelevant = { [weak self] justification in
            self?.handleJustification(text: justification)
        }
    }

    // MARK: - Justification Re-evaluation

    /// Handle "This is relevant" justification from nudge.
    /// Re-runs AI relevance check with the user's explanation as additional context.
    /// If accepted: marks content as relevant for this session.
    /// If rejected: escalates enforcement (Deep Work → overlay, Focus Hours → persistent nudge).
    private func handleJustification(text: String) {
        guard let scorer = relevanceScorer,
              let block = scheduleManager?.currentBlock,
              let manager = scheduleManager else {
            appDelegate?.postLog("💬 Justification: no scorer/block — rejecting")
            escalateAfterRejectedJustification()
            return
        }

        let targetKey = currentTargetKey
        let displayName = currentTarget
        let blockType = block.blockType

        appDelegate?.postLog("💬 Justification submitted: \"\(text)\" for \"\(displayName)\"")

        Task {
            // Re-run relevance check with justification as additional context
            let enrichedDescription = "\(block.description)\nUser explains why this is relevant: \(text)"
            let result = await scorer.scoreRelevance(
                pageTitle: displayName,
                intention: block.title,
                intentionDescription: enrichedDescription,
                profile: manager.profile,
                dailyPlan: manager.todaySchedule?.dailyPlan ?? ""
            )

            await MainActor.run {
                if result.relevant {
                    // AI accepted
                    if blockType == .deepWork {
                        // Deep Work: shorter 3-min suppression, NO permanent whitelist
                        self.suppressedUntil[targetKey] = Date().addingTimeInterval(Self.deepWorkSuppressionSeconds)
                        // Pause grayscale during suppression
                        self.grayscaleController?.restoreSaturation()
                        self.deepWorkTimerController?.update(isDistracted: false)
                        self.appDelegate?.postLog("💬 Deep Work justification ACCEPTED for \"\(displayName)\" — 3 min suppression (no whitelist)")
                        self.logAssessment(title: displayName, appName: self.currentAppName, intention: block.title,
                                          relevant: true, confidence: 0, reason: "Justification accepted — grayscale paused",
                                          action: "grayscale_off", isEvent: true)
                    } else {
                        // Focus Hours: permanent session override + scorer whitelist
                        self.sessionOverrides.insert(targetKey)
                        scorer.approvePageTitle(displayName, for: block.title)
                    }
                    self.handleRelevantContent()
                    // Record work tick since the content is now considered relevant
                    self.appDelegate?.earnedBrowseManager?.recordWorkTick(seconds: Self.browserPollInterval)
                    self.appDelegate?.earnedBrowseManager?.recordAssessment(relevant: true)
                    self.logAssessment(
                        title: displayName, appName: self.currentAppName, intention: block.title,
                        relevant: true, confidence: result.confidence,
                        reason: "User justified: \(text)", action: "none"
                    )
                    self.appDelegate?.postLog("💬 Justification ACCEPTED for \"\(displayName)\"")
                } else {
                    // AI rejected: escalate
                    self.logAssessment(
                        title: displayName, appName: self.currentAppName, intention: block.title,
                        relevant: false, confidence: result.confidence,
                        reason: "Justification rejected: \(text)", action: blockType == .deepWork ? "blocked" : "nudge"
                    )
                    self.appDelegate?.postLog("💬 Justification REJECTED for \"\(displayName)\" — \(result.reason)")
                    self.escalateAfterRejectedJustification()
                }
            }
        }
    }

    /// Escalate enforcement after a rejected justification.
    /// Deep Work: show full blocking overlay.
    /// Focus Hours: show persistent level 2 nudge.
    private func escalateAfterRejectedJustification() {
        let blockType = scheduleManager?.currentBlock?.blockType ?? .focusHours
        let intention = scheduleManager?.currentBlock?.title ?? ""

        switch blockType {
        case .deepWork:
            if isEnforcementEnabled(.blockingOverlay) {
                // Show full blocking overlay immediately
                nudgeController?.dismiss()
                let focusDuration = computeFocusDurationMinutes()
                showOverlay(
                    intention: intention,
                    reason: "Content not related to your deep work focus.",
                    focusDurationMinutes: focusDuration,
                    isNoPlan: false,
                    displayName: currentTarget
                )
            }
            warnedTargets.insert(currentTargetKey)
            isCurrentlyIrrelevant = true

        case .focusHours:
            // Show persistent level 2 nudge (will re-show on next poll via threshold check)
            if isEnforcementEnabled(.nudge) {
                let distractionMinutes = Int(cumulativeDistractionSeconds / 60)
                showNudgeForContent(intention: intention, displayName: currentTarget,
                                   escalated: true, distractionMinutes: max(1, distractionMinutes))
            }

        case .freeTime:
            break
        }
    }

    // MARK: - Overlay Display

    /// Show a blocking native overlay (NSWindow) that covers the screen.
    /// Used for Deep Work blocks (after nudge timeout) and noPlan/unplanned time.
    private func showOverlay(intention: String, reason: String,
                             focusDurationMinutes: Int,
                             isNoPlan: Bool = false,
                             displayName: String? = nil) {
        appDelegate?.postLog("🌑 showOverlay called: intention=\"\(intention)\", isNoPlan=\(isNoPlan), displayName=\(displayName ?? "nil")")
        overlayController?.onBackToWork = { [weak self] in
            if isNoPlan {
                self?.handleOpenIntentional()
            } else {
                self?.handleOverlayAction(action: "back_to_work", reason: nil)
            }
        }
        overlayController?.onSnooze = { [weak self] in
            self?.handleSnooze()
        }
        overlayController?.onStartQuickBlock = { [weak self] (title: String, duration: Int, isFree: Bool) in
            self?.handleStartQuickBlock(title: title, durationMinutes: duration, isFree: isFree)
        }
        overlayController?.onPlanDay = { [weak self] in
            self?.handlePlanDay()
        }

        // Compute next block info for unplanned overlay
        let nextBlock = scheduleManager?.nextUpcomingBlock()
        let nextBlockTitle = nextBlock?.title
        let nextBlockTime: String? = nextBlock.map {
            let hour = $0.startHour > 12 ? $0.startHour - 12 : ($0.startHour == 0 ? 12 : $0.startHour)
            let ampm = $0.startHour >= 12 ? "PM" : "AM"
            return String(format: "%d:%02d %@", hour, $0.startMinute, ampm)
        }
        let minutesUntilNext: Int? = nextBlock.map { $0.startMinutes - ScheduleManager.currentMinuteOfDay() }

        // Log enforcement event for popover visibility
        let browserName = currentAppBundleId.flatMap { Self.browserAppNames[$0] } ?? ""
        let overlayDisplayName = displayName ?? currentTarget
        logAssessment(
            title: overlayDisplayName, appName: browserName.isEmpty ? overlayDisplayName : browserName,
            intention: intention, relevant: false, confidence: 0,
            reason: isNoPlan ? "Blocking overlay (no plan)" : "Blocking overlay",
            action: "blocked", isEvent: true
        )

        let canSnooze30 = (scheduleManager?.snoozeCount == 0) && isNoPlan
        appDelegate?.earnedBrowseManager?.recordNudge()
        DispatchQueue.main.async { [weak self] in
            self?.overlayController?.showOverlay(
                intention: intention,
                reason: reason,
                focusDurationMinutes: focusDurationMinutes,
                isNoPlan: isNoPlan,
                canSnooze: canSnooze30,
                nextBlockTitle: nextBlockTitle,
                nextBlockTime: nextBlockTime,
                minutesUntilNextBlock: minutesUntilNext,
                displayName: displayName
            )
        }
    }

    /// Handle "Open Intentional" — open the main app window and dismiss overlay.
    private func handleOpenIntentional() {
        overlayController?.dismiss()
        appDelegate?.showMainWindow()
        stopLingerTimer()
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 'Open Intentional' — opening main window")
    }

    /// Handle "Plan My Day" — open the focus/calendar page in the dashboard.
    private func handlePlanDay() {
        overlayController?.dismiss()
        appDelegate?.showDashboardPage("today")
        stopLingerTimer()
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 'Plan My Day' — opening today page")
    }

    /// Handle quick block creation from the unplanned overlay.
    private func handleStartQuickBlock(title: String, durationMinutes: Int, isFree: Bool) {
        let calendar = Calendar.current
        let now = Date()
        let startHour = calendar.component(.hour, from: now)
        let startMinute = calendar.component(.minute, from: now)
        let endDate = now.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let endHour = calendar.component(.hour, from: endDate)
        let endMinute = calendar.component(.minute, from: endDate)

        let blockType: ScheduleManager.BlockType = isFree ? .freeTime : .focusHours

        let block = ScheduleManager.FocusBlock(
            id: UUID().uuidString,
            title: title,
            description: "",
            startHour: startHour,
            startMinute: startMinute,
            endHour: endHour,
            endMinute: endMinute,
            blockType: blockType
        )

        scheduleManager?.addBlock(block)
        overlayController?.dismiss()
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 Quick block created: \"\(title)\" (\(durationMinutes) min, type: \(blockType.rawValue))")
    }

    /// Handle "Snooze for 30 min" — snooze via ScheduleManager and dismiss overlay.
    private func handleSnooze() {
        overlayController?.dismiss()
        let accepted = scheduleManager?.snooze() ?? false
        stopLingerTimer()
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 'Snooze for 30 min' — accepted: \(accepted)")
    }

    // MARK: - Grace Period

    /// Start a grace period before showing the overlay.
    /// If grace is already active for this target, let it continue.
    /// If grace is active for a different target, cancel and restart.
    private func startGracePeriod(pending: PendingOverlayInfo) {
        // Already in grace for this exact target — let it run
        if pendingOverlay?.targetKey == pending.targetKey && graceTimer != nil {
            debugLog("⏳ Grace already running for \(pending.targetKey) — letting it continue")
            return
        }

        // Cancel any existing grace for a different target
        cancelGracePeriod()

        let duration: TimeInterval
        let isDeepWork = scheduleManager?.currentBlock?.blockType == .deepWork
        if pending.isNoPlan {
            // Unplanned/noPlan: short grace — prompt to plan quickly
            duration = Self.unplannedGraceDurationSeconds
        } else if isDeepWork {
            // Deep Work native app: short 5s grace (aggressive enforcement)
            duration = Self.deepWorkNativeGraceSeconds
        } else if pending.isRevisit {
            duration = Self.revisitGraceDurationSeconds
        } else {
            duration = Self.graceDurationSeconds
        }

        // Deep Work native apps: mark timer as distracted during grace
        if isDeepWork {
            deepWorkTimerController?.update(isDistracted: true)
        }

        pendingOverlay = pending
        graceTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.graceTimerFired()
        }

        debugLog("⏳ Grace period started: \(Int(duration))s for \(pending.displayName) (revisit: \(pending.isRevisit))")
    }

    /// Grace timer fired — show overlay (Deep Work / noPlan) or nudge (Focus Hours).
    /// Only fires for native apps and noPlan/unplanned (browser work blocks use cumulative tracking).
    private func graceTimerFired() {
        guard let pending = pendingOverlay else { return }

        debugLog("⏳ Grace expired for \(pending.displayName)")

        // Mark as warned (for revisit tracking)
        if !pending.isRevisit {
            warnedTargets.insert(pending.targetKey)
        }

        let blockType = scheduleManager?.currentBlock?.blockType ?? .focusHours

        // noPlan/unplanned always get overlay (regardless of block type)
        if pending.isNoPlan {
            logAssessment(title: pending.displayName, appName: currentAppName, intention: pending.intention,
                         relevant: false, confidence: pending.confidence, reason: pending.reason, action: "overlay")
            showOverlay(intention: pending.intention, reason: pending.reason,
                       focusDurationMinutes: pending.focusDurationMinutes, isNoPlan: true, displayName: pending.displayName)
        } else if blockType == .deepWork {
            // Deep Work native app: show full blocking overlay + start grayscale
            if !(grayscaleController?.isActive ?? false) && isEnforcementEnabled(.screenRedShift) {
                grayscaleController?.startDesaturation()
                grayscaleTriggeredThisBlock = true
                appDelegate?.postLog("🌫️ Deep Work: grayscale started on native app overlay")
                logAssessment(title: pending.displayName, appName: currentAppName, intention: pending.intention,
                             relevant: false, confidence: 0, reason: "Deep Work native app overlay grayscale",
                             action: "grayscale_on", isEvent: true)
            }
            if isEnforcementEnabled(.blockingOverlay) {
                logAssessment(title: pending.displayName, appName: currentAppName, intention: pending.intention,
                             relevant: false, confidence: pending.confidence, reason: pending.reason, action: "blocked")
                showOverlay(intention: pending.intention, reason: pending.reason,
                           focusDurationMinutes: pending.focusDurationMinutes, isNoPlan: false, displayName: pending.displayName)
            } else if isEnforcementEnabled(.nudge) {
                logAssessment(title: pending.displayName, appName: currentAppName, intention: pending.intention,
                             relevant: false, confidence: pending.confidence, reason: pending.reason, action: "nudge")
                showNudgeForContent(intention: pending.intention, displayName: pending.displayName, escalated: false)
            }
        } else {
            // Focus Hours native app: show nudge instead of overlay
            if isEnforcementEnabled(.nudge) {
                logAssessment(title: pending.displayName, appName: currentAppName, intention: pending.intention,
                             relevant: false, confidence: pending.confidence, reason: pending.reason, action: "nudge")
                showNudgeForContent(intention: pending.intention, displayName: pending.displayName, escalated: false)
            }
        }

        // Update state
        currentTarget = pending.displayName
        currentTargetKey = pending.targetKey
        currentOverlayIsNoPlan = pending.isNoPlan
        isCurrentlyIrrelevant = true

        // Clear pending
        pendingOverlay = nil
        graceTimer = nil
    }

    /// Cancel any active grace period.
    private func cancelGracePeriod() {
        if pendingOverlay != nil {
            debugLog("⏳ Grace cancelled")
        }
        graceTimer?.invalidate()
        graceTimer = nil
        pendingOverlay = nil
    }

    // MARK: - Linger Timer (kept as fallback for unplanned/noPlan blocking)

    private func startLingerTimer() {
        stopLingerTimer()
        lingerTimer = Timer.scheduledTimer(withTimeInterval: Self.lingerDurationSeconds, repeats: false) { [weak self] _ in
            self?.lingerTimerFired()
        }
    }

    private func stopLingerTimer() {
        lingerTimer?.invalidate()
        lingerTimer = nil
        lingerStart = nil
    }

    private func lingerTimerFired() {
        // Fallback: used for unplanned/noPlan states where extension overlay isn't available
        guard isCurrentlyIrrelevant,
              let manager = scheduleManager,
              manager.currentTimeState.isWork || manager.currentTimeState == .unplanned || manager.currentTimeState == .noPlan,
              let bundleId = currentAppBundleId,
              Self.browserBundleIds.contains(bundleId) else { return }

        if let until = suppressedUntil[currentTargetKey], Date() < until { return }

        let intention = scheduleManager?.currentBlock?.title ?? "Plan your day"
        var originalURL: String? = nil
        if let info = readActiveTabInfo(for: bundleId) {
            originalURL = info.url
        }
        blockActiveTab(intention: intention, pageTitle: currentTarget, hostname: currentTargetKey, originalURL: originalURL)
        appDelegate?.postLog("👁️ Linger expired — blocked \(currentTarget)")
    }

    // MARK: - Overlay User Actions (called by NativeMessagingHost or native overlay)

    /// Handle user action from the blocking overlay (browser or native).
    func handleOverlayAction(action: String, reason: String?) {
        switch action {
        case "back_to_work":
            handleBackToWork()
        default:
            break
        }
    }

    private func handleBackToWork() {
        // Dismiss all overlays
        overlayController?.dismiss()
        nudgeController?.dismiss()
        appDelegate?.socketRelayServer?.broadcastHideFocusOverlay()

        // Navigate browser to last relevant URL or google.com
        if let bundleId = currentAppBundleId, Self.browserBundleIds.contains(bundleId) {
            let url = lastRelevantTabURL ?? "https://www.google.com"
            navigateActiveTab(to: url, bundleId: bundleId)
        }

        stopLingerTimer()
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 'Back to work' — navigating to \(lastRelevantTabURL ?? "google.com")")
    }

    // MARK: - Navigation Helpers

    /// Navigate the active browser tab to a specific URL via AppleScript.
    private func navigateActiveTab(to url: String, bundleId: String) {
        guard let appName = Self.browserAppNames[bundleId] else { return }

        let script: String
        if bundleId == "com.apple.Safari" {
            script = """
            tell application "Safari"
                set URL of current tab of front window to "\(url)"
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
                set URL of active tab of front window to "\(url)"
            end tell
            """
        }

        appleScriptQueue.async { [weak self] in
            guard let appleScript = NSAppleScript(source: script) else { return }
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let errorDict = error {
                let msg = errorDict["NSAppleScriptErrorMessage"] as? String ?? "Unknown"
                self?.debugLog("👁️ Failed to navigate tab: \(msg)")
            }
        }
    }

    /// Compute how many minutes since the current block started.
    private func computeFocusDurationMinutes() -> Int {
        guard let block = scheduleManager?.currentBlock else { return 0 }
        let calendar = Calendar.current
        let now = calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())
        return max(0, now - block.startMinutes)
    }

    deinit {
        stop()
    }
}

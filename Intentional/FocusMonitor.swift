import Cocoa
import Foundation

/// Monitors the frontmost application and manages focus enforcement via progressive overlays.
///
/// When irrelevant content is detected during a work block, shows a progressive overlay
/// that gradually darkens the page/screen, making the content unreadable over 30 seconds.
///
/// Tiered enforcement:
/// 1. **First encounter** → progressive overlay (starts subtle, darkens over 30s)
/// 2. **Revisit** (same site already warned) → overlay starts at 60% immediately
/// 3. **Block mode**: overlay reaches 95% and stays (page unreadable)
/// 4. **Nudge mode**: overlay reaches 70%, holds briefly, then fades out
///
/// Overlay is a native NSWindow (FocusOverlayWindowController) that covers the screen.
/// Works for all apps — browsers and non-browsers — without requiring a browser extension.
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

    // MARK: - Constants

    /// Seconds before blocking after first nudge (only used for first encounter in "block" mode)
    static let lingerDurationSeconds: TimeInterval = 30.0
    /// Suppression duration when user clicks "5 more min"
    static let suppressionSeconds: TimeInterval = 300.0
    /// How often to re-check the active browser tab (seconds)
    static let browserPollInterval: TimeInterval = 10.0
    /// Rolling window for cumulative irrelevance tracking (seconds)
    static let irrelevanceWindowSeconds: TimeInterval = 180.0
    /// Cumulative irrelevance threshold before blocking (seconds)
    static let irrelevanceThresholdSeconds: TimeInterval = 60.0
    /// Maximum relevance log entries to keep in memory
    static let maxLogEntries = 50

    // MARK: - Relevance Log

    struct RelevanceEntry {
        let timestamp: Date
        let title: String        // page title or app name
        let intention: String    // current block intention
        let relevant: Bool
        let confidence: Int
        let reason: String
        let action: String       // "none", "nudge", "blocked"
    }

    private(set) var relevanceLog: [RelevanceEntry] = []

    private func logAssessment(title: String, intention: String, relevant: Bool, confidence: Int, reason: String, action: String) {
        let entry = RelevanceEntry(
            timestamp: Date(), title: title, intention: intention,
            relevant: relevant, confidence: confidence, reason: reason, action: action
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
        let dict: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
            "title": entry.title,
            "intention": entry.intention,
            "relevant": entry.relevant,
            "confidence": entry.confidence,
            "reason": entry.reason,
            "action": entry.action,
            "model": aiModel
        ]

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

    // Cumulative irrelevance tracking: timestamps of poll ticks where browser content was irrelevant
    private var irrelevanceSamples: [Date] = []
    /// Whether the last browser tab score was irrelevant (for sampling unchanged tabs)
    private var lastScoreWasIrrelevant = false

    // Snooze tracking: targets that used their one free snooze this block
    private var snoozedTargets: Set<String> = []

    // Global noPlan snooze: suppresses ALL noPlan/unplanned overlays (not per-target)
    private var noPlanSnoozeUntil: Date?
    private var noPlanSnoozed: Bool = false

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
        let enforcement: String
        let isRevisit: Bool
        let focusDurationMinutes: Int
        let isNoPlan: Bool
        let confidence: Int
    }

    // Browser tab polling
    private var browserPollTimer: Timer?
    private var lastScoredTitle: String?
    private var lastScoredURL: String?

    /// Last relevant browser tab URL for smart "Back to work" navigation
    private var lastRelevantTabURL: String?

    // Serial queue for AppleScript execution (not thread-safe)
    private let appleScriptQueue = DispatchQueue(label: "com.intentional.focusmonitor.applescript", qos: .userInitiated)

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

        appDelegate?.postLog("👁️ FocusMonitor started — watching frontmost app")
    }

    /// Stop monitoring and dismiss any active nudge/overlay.
    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        cancelGracePeriod()
        stopLingerTimer()
        stopBrowserPolling()
        nudgeController?.dismiss()
        overlayController?.dismiss()
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
        snoozedTargets.removeAll()
        noPlanSnoozeUntil = nil
        noPlanSnoozed = false
        cancelGracePeriod()
        stopLingerTimer()
        stopBrowserPolling()
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
        irrelevanceSamples.removeAll()
        lastScoreWasIrrelevant = false

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

        appDelegate?.postLog("👁️ evaluateApp: \(appName) (\(bundleId)), state=\(currentState), block=\(currentBlock)")

        guard let manager = scheduleManager else {
            appDelegate?.postLog("👁️ EXIT: no scheduleManager — treating as relevant")
            handleRelevantContent()
            stopBrowserPolling()
            return
        }

        let state = manager.currentTimeState
        appDelegate?.postLog("👁️ State check: enabled=\(manager.isEnabled), state=\(state.rawValue), hasPlan=\(manager.todaySchedule != nil), blocks=\(manager.todaySchedule?.blocks.count ?? 0)")

        // States where browsing is allowed freely
        // disabled = feature off, freeBlock = scheduled break, snoozed = user chose to delay
        if state == .disabled || state == .freeBlock || state == .snoozed {
            appDelegate?.postLog("👁️ EXIT: state=\(state.rawValue) — browsing allowed freely")
            handleRelevantContent()
            stopBrowserPolling()
            return
        }

        guard let bid = app.bundleIdentifier else { return }

        // Our own app — two cases:
        // 1. Overlay is showing → user clicked the overlay (which activates our app).
        //    Do NOT dismiss it — let the buttons inside the overlay handle the interaction.
        // 2. Overlay is NOT showing → user switched to the Intentional dashboard.
        //    Allow freely, but preserve grace timer.
        if bid == "com.intentional.app" || bid == Bundle.main.bundleIdentifier {
            if overlayController?.isShowing == true {
                appDelegate?.postLog("👁️ EXIT: own app activated by overlay click — keeping overlay")
                return
            }
            appDelegate?.postLog("👁️ EXIT: own app — allowing (grace timer preserved)")
            stopLingerTimer()
            isCurrentlyIrrelevant = false
            nudgeController?.dismiss()
            appDelegate?.socketRelayServer?.broadcastHideFocusOverlay()
            stopBrowserPolling()
            return
        }

        // UNPLANNED or NO_PLAN: use grace period before showing overlay
        if state == .unplanned || state == .noPlan {
            // Check global noPlan snooze (applies to ALL apps, not per-target)
            if let until = noPlanSnoozeUntil, Date() < until {
                appDelegate?.postLog("👁️ EXIT: \(state.rawValue) — globally snoozed until \(until)")
                stopBrowserPolling()
                return
            }
            // Check per-target suppression (from "5 more min")
            if let until = suppressedUntil[bid], Date() < until {
                appDelegate?.postLog("👁️ EXIT: \(state.rawValue) but suppressed until \(until)")
                stopBrowserPolling()
                return
            }
            // If already showing overlay for this target, skip
            if isCurrentlyIrrelevant && currentTargetKey == bid {
                appDelegate?.postLog("👁️ EXIT: \(state.rawValue) — overlay already showing for \(bid)")
                stopBrowserPolling()
                return
            }

            let intention = state == .noPlan ? "Plan your day" : "Unscheduled time"
            let reason = state == .noPlan
                ? "Set up your daily plan to start browsing."
                : "This time isn't scheduled — add a block or take a break."
            let enforcement = scheduleManager?.focusEnforcement ?? "block"

            let pending = PendingOverlayInfo(
                targetKey: bid,
                displayName: appName,
                intention: intention,
                reason: reason,
                enforcement: enforcement,
                isRevisit: warnedTargets.contains(bid),
                focusDurationMinutes: 0,
                isNoPlan: true,
                confidence: 0
            )

            appDelegate?.postLog("👁️ \(state.rawValue) — starting grace period on \(appName)")
            startGracePeriod(pending: pending)
            stopBrowserPolling()
            return
        }

        // WORK BLOCK: score content for relevance
        guard state == .workBlock else { return }

        // Apple system apps: auto-allow com.apple.* unless it's an entertainment app
        if bid.hasPrefix("com.apple.") && !Self.appleEntertainmentBundleIds.contains(bid) {
            appDelegate?.postLog("👁️ EXIT: Apple system app \(appName) — always allowed")
            handleRelevantContent()
            stopBrowserPolling()
            return
        }

        // Always-allowed apps: never block system utilities, terminals, password managers, etc.
        if Self.alwaysAllowedBundleIds.contains(bid) {
            appDelegate?.postLog("👁️ EXIT: \(appName) is always-allowed — skipping scoring")
            handleRelevantContent()
            stopBrowserPolling()
            return
        }

        // If it's a browser, read tab title via AppleScript and start polling
        if Self.browserBundleIds.contains(bid) {
            appDelegate?.postLog("👁️ Browser detected (\(bid)) — reading tab via AppleScript")
            lastScoredTitle = nil
            lastScoredURL = nil
            lastScoreWasIrrelevant = false
            readAndScoreActiveTab(bundleId: bid)
            startBrowserPolling(bundleId: bid)
            return
        }

        // Non-browser app: stop browser polling and score the app name
        stopBrowserPolling()
        appDelegate?.postLog("👁️ App switched to: \(appName) (\(bid))")

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
                self.logAssessment(
                    title: appName, intention: block.title,
                    relevant: result.relevant, confidence: result.confidence,
                    reason: result.reason, action: "none"
                )
                if result.relevant {
                    self.appDelegate?.postLog("👁️ App is relevant: \(appName)")
                    self.handleRelevantContent()
                } else {
                    self.appDelegate?.postLog("👁️ App is NOT relevant: \(appName) — \(result.reason)")
                    self.handleIrrelevantContent(targetKey: bid, displayName: appName)
                }
            }
        }
    }

    // MARK: - AppleScript Tab Reading

    /// Read the active tab title and URL via AppleScript, then score for relevance.
    private func readAndScoreActiveTab(bundleId: String) {
        guard let manager = scheduleManager,
              manager.currentTimeState == .workBlock,
              let block = manager.currentBlock,
              let scorer = relevanceScorer else { return }

        let tabInfo = readActiveTabInfo(for: bundleId)

        guard let info = tabInfo else {
            appDelegate?.postLog("👁️ Could not read tab info for \(bundleId)")
            return
        }

        // Detect transition FROM blocking page (user justified or left)
        if tabIsOnBlockingPage {
            if !info.url.contains("focus-blocked.html") {
                tabIsOnBlockingPage = false
                blockedOriginalURL = nil
                irrelevanceSamples.removeAll()
                if info.hostname == currentTargetKey {
                    // Justified return → 5-min suppression + whitelist in scorer
                    suppressedUntil[currentTargetKey] = Date().addingTimeInterval(Self.suppressionSeconds)
                    if let title = lastScoredTitle, let block = scheduleManager?.currentBlock {
                        relevanceScorer?.approvePageTitle(title, for: block.title)
                    }
                    isCurrentlyIrrelevant = false
                    lastScoredTitle = nil
                    lastScoredURL = nil
                    appDelegate?.postLog("👁️ Justified return to \(currentTargetKey) — whitelisted + 5-min suppression set")
                } else {
                    // Left to different site or about:blank → clear state
                    isCurrentlyIrrelevant = false
                    lastScoredTitle = nil
                    lastScoredURL = nil
                    appDelegate?.postLog("👁️ Left blocking page to \(info.hostname) — state cleared")
                }
                return
            } else {
                // Still on blocking page — skip scoring, preserve state
                return
            }
        }

        // Skip if tab hasn't changed since last score
        // But still record a cumulative sample if the tab is irrelevant
        if info.title == lastScoredTitle && info.url == lastScoredURL {
            if lastScoreWasIrrelevant {
                handleIrrelevantContent(targetKey: info.hostname, displayName: info.title)
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

        appDelegate?.postLog("👁️ Scoring tab: \"\(info.title)\" (\(info.hostname))")

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
                if result.relevant {
                    self.lastScoreWasIrrelevant = false
                    self.logAssessment(
                        title: info.title, intention: block.title,
                        relevant: true, confidence: result.confidence,
                        reason: result.reason, action: "none"
                    )
                    self.appDelegate?.postLog("👁️ Tab is relevant: \"\(info.title)\"")
                    self.handleRelevantContent()
                } else {
                    self.lastScoreWasIrrelevant = true
                    // Action will be determined by handleIrrelevantContent; log after
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

    private func pollActiveTab(bundleId: String) {
        guard currentAppBundleId == bundleId,
              let manager = scheduleManager,
              manager.currentTimeState == .workBlock else {
            stopBrowserPolling()
            return
        }

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

        // First check if already on the blocked page
        if let info = readActiveTabInfo(for: bundleId), info.url.contains("focus-blocked.html") {
            appDelegate?.postLog("👁️ Already on focus-blocked page, skipping redirect")
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
                    self?.appDelegate?.postLog("👁️ Failed to redirect tab: \(msg)")
                } else {
                    self?.tabIsOnBlockingPage = true
                    self?.blockedOriginalURL = originalURL
                    self?.appDelegate?.postLog("👁️ Redirected tab to focus-blocked page")
                }
            }
        }
    }

    // MARK: - Relevance Handling

    private func handleRelevantContent() {
        appDelegate?.postLog("👁️ handleRelevantContent() — dismissing overlays, cancelling grace")
        cancelGracePeriod()
        stopLingerTimer()
        isCurrentlyIrrelevant = false
        tabIsOnBlockingPage = false
        blockedOriginalURL = nil
        nudgeController?.dismiss()
        overlayController?.dismiss()
        appDelegate?.socketRelayServer?.broadcastHideFocusOverlay()

        // Track last relevant browser tab for smart "Back to work"
        if let bundleId = currentAppBundleId,
           Self.browserBundleIds.contains(bundleId),
           let info = readActiveTabInfo(for: bundleId),
           !info.url.contains("focus-blocked.html") {
            lastRelevantTabURL = info.url
        }
    }

    /// Tiered enforcement for irrelevant content.
    /// Browser tabs during work blocks use cumulative irrelevance tracking (rolling window).
    /// Native apps and noPlan/unplanned use grace periods before showing native overlay.
    private func handleIrrelevantContent(targetKey: String, displayName: String, confidence: Int = 0, reason: String = "") {
        // Check suppression ("5 more min" or snooze)
        if let until = suppressedUntil[targetKey], Date() < until { return }

        // If already showing overlay for this same target, don't re-trigger
        if isCurrentlyIrrelevant && currentTargetKey == targetKey {
            return
        }

        let isBrowser = currentAppBundleId.map { Self.browserBundleIds.contains($0) } ?? false
        let isWorkBlock = scheduleManager?.currentTimeState == .workBlock

        if isBrowser && isWorkBlock {
            // ── Cumulative irrelevance tracking (browser work blocks) ──
            let now = Date()

            // Deduplicate: at most one sample per ~half poll interval
            if irrelevanceSamples.last.map({ now.timeIntervalSince($0) >= Self.browserPollInterval / 2 }) ?? true {
                irrelevanceSamples.append(now)
            }

            // Prune samples outside window
            let windowStart = now.addingTimeInterval(-Self.irrelevanceWindowSeconds)
            irrelevanceSamples.removeAll { $0 < windowStart }

            let cumulativeSeconds = TimeInterval(irrelevanceSamples.count) * Self.browserPollInterval
            appDelegate?.postLog("👁️ Cumulative irrelevance: \(Int(cumulativeSeconds))s / \(Int(Self.irrelevanceThresholdSeconds))s")

            if cumulativeSeconds >= Self.irrelevanceThresholdSeconds {
                // Threshold met → block
                warnedTargets.insert(targetKey)
                logAssessment(title: displayName, intention: scheduleManager?.currentBlock?.title ?? "",
                             relevant: false, confidence: confidence, reason: reason, action: "blocked")

                var originalURL: String? = nil
                if let bundleId = currentAppBundleId, let info = readActiveTabInfo(for: bundleId) {
                    originalURL = info.url
                    if info.url.contains("focus-blocked.html") { return }
                }

                let intention = scheduleManager?.currentBlock?.title ?? ""
                blockActiveTab(intention: intention, pageTitle: displayName,
                              hostname: targetKey, originalURL: originalURL)

                currentTarget = displayName
                currentTargetKey = targetKey
                isCurrentlyIrrelevant = true
                irrelevanceSamples.removeAll()  // Reset for after suppression
            }
        } else {
            // ── Grace period for native apps and noPlan/unplanned (unchanged) ──
            let enforcement = scheduleManager?.focusEnforcement ?? "block"
            let alreadyWarned = warnedTargets.contains(targetKey)
            let intention = scheduleManager?.currentBlock?.title ?? ""
            let focusDuration = computeFocusDurationMinutes()

            let pending = PendingOverlayInfo(
                targetKey: targetKey,
                displayName: displayName,
                intention: intention,
                reason: reason,
                enforcement: enforcement,
                isRevisit: alreadyWarned,
                focusDurationMinutes: focusDuration,
                isNoPlan: false,
                confidence: confidence
            )

            startGracePeriod(pending: pending)
        }
    }

    // MARK: - Overlay Display

    /// Show a progressive native overlay (NSWindow) that covers the screen.
    /// Works for all apps — browsers and non-browsers — without requiring a browser extension.
    private func showOverlay(intention: String, reason: String, enforcement: String,
                             isRevisit: Bool, focusDurationMinutes: Int,
                             isNoPlan: Bool = false, canSnooze5Min: Bool = true,
                             displayName: String? = nil) {
        appDelegate?.postLog("🌑 showOverlay called: intention=\"\(intention)\", enforcement=\(enforcement), isRevisit=\(isRevisit), isNoPlan=\(isNoPlan), displayName=\(displayName ?? "nil")")
        overlayController?.onBackToWork = { [weak self] in
            if isNoPlan {
                self?.handleOpenIntentional()
            } else {
                self?.handleOverlayAction(action: "back_to_work", reason: nil)
            }
        }
        overlayController?.onFiveMoreMinutes = { [weak self] reason in
            self?.handleOverlayAction(action: "five_more_min", reason: reason)
        }
        overlayController?.onSnooze = { [weak self] in
            self?.handleSnooze()
        }
        overlayController?.onSnooze5Min = { [weak self] in
            self?.handleSnooze5Min()
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

        let canSnooze30 = (scheduleManager?.snoozeCount == 0) && isNoPlan
        DispatchQueue.main.async { [weak self] in
            self?.overlayController?.showOverlay(
                intention: intention,
                reason: reason,
                enforcement: enforcement,
                isRevisit: isRevisit,
                focusDurationMinutes: focusDurationMinutes,
                isNoPlan: isNoPlan,
                canSnooze: canSnooze30,
                canSnooze5Min: canSnooze5Min,
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

        let block = ScheduleManager.FocusBlock(
            id: UUID().uuidString,
            title: title,
            description: "",
            startHour: startHour,
            startMinute: startMinute,
            endHour: endHour,
            endMinute: endMinute,
            isFree: isFree
        )

        scheduleManager?.addBlock(block)
        overlayController?.dismiss()
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 Quick block created: \"\(title)\" (\(durationMinutes) min, free: \(isFree))")
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
            appDelegate?.postLog("⏳ Grace already running for \(pending.targetKey) — letting it continue")
            return
        }

        // Cancel any existing grace for a different target
        cancelGracePeriod()

        let duration: TimeInterval
        if pending.isNoPlan {
            // Unplanned/noPlan: short grace — prompt to plan quickly
            duration = Self.unplannedGraceDurationSeconds
        } else if pending.isRevisit {
            duration = Self.revisitGraceDurationSeconds
        } else {
            duration = Self.graceDurationSeconds
        }

        pendingOverlay = pending
        graceTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.graceTimerFired()
        }

        appDelegate?.postLog("⏳ Grace period started: \(Int(duration))s for \(pending.displayName) (revisit: \(pending.isRevisit))")
    }

    /// Grace timer fired — show native overlay.
    /// Only fires for native apps and noPlan/unplanned (browser work blocks use cumulative tracking).
    private func graceTimerFired() {
        guard let pending = pendingOverlay else { return }

        appDelegate?.postLog("⏳ Grace expired for \(pending.displayName)")

        // Mark as warned (for revisit tracking)
        if !pending.isRevisit {
            warnedTargets.insert(pending.targetKey)
        }

        // Log assessment
        logAssessment(
            title: pending.displayName,
            intention: pending.intention,
            relevant: false,
            confidence: pending.confidence,
            reason: pending.reason,
            action: pending.enforcement == "block" ? (pending.isRevisit ? "blocked" : "overlay") : "nudge"
        )

        // Always show native overlay (grace only used for native apps + noPlan)
        let canSnooze5Min = pending.isNoPlan ? !noPlanSnoozed : !snoozedTargets.contains(pending.targetKey)
        showOverlay(
            intention: pending.intention,
            reason: pending.reason,
            enforcement: pending.enforcement,
            isRevisit: pending.isRevisit,
            focusDurationMinutes: pending.focusDurationMinutes,
            isNoPlan: pending.isNoPlan,
            canSnooze5Min: canSnooze5Min,
            displayName: pending.displayName
        )

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
            appDelegate?.postLog("⏳ Grace cancelled")
        }
        graceTimer?.invalidate()
        graceTimer = nil
        pendingOverlay = nil
    }

    // MARK: - Snooze (5 min, no reason required)

    /// Handle the simple "Snooze 5 min" action — suppresses target for 5 min with no reason needed.
    /// For noPlan/unplanned overlays, uses a global snooze (applies to ALL apps).
    /// For work block overlays, uses per-target suppression. Limited to 1 use per target per block.
    private func handleSnooze5Min() {
        let targetKey = currentTargetKey
        snoozedTargets.insert(targetKey)

        if currentOverlayIsNoPlan {
            // Global snooze: suppress ALL noPlan overlays for 5 minutes
            noPlanSnoozeUntil = Date().addingTimeInterval(Self.suppressionSeconds)
            noPlanSnoozed = true
        } else {
            // Per-target suppression for work block overlays
            suppressedUntil[targetKey] = Date().addingTimeInterval(Self.suppressionSeconds)
        }

        // Dismiss all overlays
        overlayController?.dismiss()
        nudgeController?.dismiss()
        appDelegate?.socketRelayServer?.broadcastHideFocusOverlay()

        stopLingerTimer()
        isCurrentlyIrrelevant = false

        // Re-check after suppression expires
        Timer.scheduledTimer(withTimeInterval: Self.suppressionSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.lastScoredTitle = nil
            self.lastScoredURL = nil
            self.noPlanSnoozeUntil = nil
            self.appDelegate?.postLog("👁️ Snooze expired for \(targetKey)")
        }

        appDelegate?.postLog("💬 'Snooze 5 min' — \(currentOverlayIsNoPlan ? "global noPlan snooze" : "target: \(currentTarget)")")
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
              manager.currentTimeState == .workBlock || manager.currentTimeState == .unplanned || manager.currentTimeState == .noPlan,
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

    /// Handle user action from the progressive overlay (browser or native).
    func handleOverlayAction(action: String, reason: String?) {
        switch action {
        case "back_to_work":
            handleBackToWork()
        case "five_more_min":
            handleFiveMoreMinutesWithReason(reason: reason ?? "")
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

    private func handleFiveMoreMinutesWithReason(reason: String) {
        let targetKey = currentTargetKey
        suppressedUntil[targetKey] = Date().addingTimeInterval(Self.suppressionSeconds)

        // Whitelist so it's never re-blocked for this block
        // Use lastScoredTitle for browser tabs, currentTarget for native apps
        let titleToApprove = lastScoredTitle ?? (currentTarget.isEmpty ? nil : currentTarget)
        if let title = titleToApprove, let block = scheduleManager?.currentBlock {
            relevanceScorer?.approvePageTitle(title, for: block.title)
        }

        // Dismiss all overlays
        overlayController?.dismiss()
        nudgeController?.dismiss()
        appDelegate?.socketRelayServer?.broadcastHideFocusOverlay()

        stopLingerTimer()
        isCurrentlyIrrelevant = false

        // After suppression expires, re-check if still on irrelevant content
        Timer.scheduledTimer(withTimeInterval: Self.suppressionSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.lastScoredTitle = nil
            self.lastScoredURL = nil
            self.appDelegate?.postLog("👁️ Suppression expired for \(targetKey)")
        }

        appDelegate?.postLog("💬 '5 more min' for \(currentTarget) — reason: \(reason)")
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
                self?.appDelegate?.postLog("👁️ Failed to navigate tab: \(msg)")
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

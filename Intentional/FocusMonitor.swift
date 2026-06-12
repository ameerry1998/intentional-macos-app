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
///   - 20s cumulative: auto-redirect to last relevant URL + red shift
///   - 20s+ (revisit): instant redirect if site already redirected this block
///   - 300s cumulative: intervention overlay (60s/90s/120s escalating)
///
/// **Focus Hours** — gentle reminders:
///   - 10s: level 1 nudge (auto-dismiss 8s)
///   - 30s: red shift starts (30s fade)
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

    /// Source of truth for "should we be enforcing right now."
    /// Replaces the old TimeState-based allowlist. Wired by AppDelegate
    /// after init.
    weak var focusModeController: FocusModeController?
    var nudgeController: NudgeWindowController?
    var overlayController: FocusOverlayWindowController?
    var interventionController: InterventionOverlayController?
    var redShiftController: RedShiftController?
    var deepWorkTimerController: DeepWorkTimerController?
    var endRitualController: BlockEndRitualController?

    /// Whether the block start ritual is showing (enforcement paused)
    private var awaitingRitual = false

    /// Skip showing ritual on the next onBlockChanged (set when ritual's Start saves edits,
    /// which triggers updateBlock → recalculateState → onBlockChanged synchronously)
    private var skipNextRitual = false

    /// Guards against showing the start ritual repeatedly for the same block
    private var lastRitualShownForBlockId: String?

    // MARK: - Onboarding Tooltips (one-time explanations)

    private enum OnboardingTooltip: String {
        case nudge = "onboarding_tooltip_nudge"
        case redShift = "onboarding_tooltip_grayscale"  // raw value kept — persisted before the grayscale→red-shift rename
        case redirect = "onboarding_tooltip_redirect"
        case intervention = "onboarding_tooltip_intervention"
    }

    private func hasSeenTooltip(_ tooltip: OnboardingTooltip) -> Bool {
        UserDefaults.standard.bool(forKey: tooltip.rawValue)
    }

    private func markTooltipSeen(_ tooltip: OnboardingTooltip) {
        UserDefaults.standard.set(true, forKey: tooltip.rawValue)
    }

    /// Whether we're waiting for celebration to finish before starting the next block
    private var pendingBlockStartAfterCelebration = false

    /// Tracks which block the celebration is currently showing for, to prevent
    /// re-showing a start ritual for the same (just-finished) block.
    private var celebrationForBlockId: String?

    /// User-configured distracting apps: always treated as irrelevant during work blocks
    var distractingAppBundleIds: Set<String> = []

    /// User-configured always-relevant sites: skip AI scoring, treat as relevant during work blocks
    /// (e.g. Gmail, Slack — ambiguous sites where AI can't determine relevance from title/URL alone)
    var alwaysRelevantHostnames: Set<String> = []

    /// BlockRuleEnforcer-driven blocked apps. Engages enforcement even when no
    /// focus session is active — that's the whole point of Blocks-with-schedule.
    /// Composes with focus-session enforcement via union.
    private var standaloneBlockedBundleIds: Set<String> = []

    /// Public setter — called by BlockRuleEnforcer on every tick (30s) and on
    /// every BlockingProfile mutation. Pure setter; the next `evaluateApp`
    /// invocation (driven by polling / app switch) picks up the new set.
    func setStandaloneBlockedBundleIds(_ bundles: [String]) {
        let next = Set(bundles)
        guard next != standaloneBlockedBundleIds else { return }
        standaloneBlockedBundleIds = next
        appDelegate?.postLog("👁️🛡 FocusMonitor: standaloneBlockedBundleIds updated (\(next.count) apps): \(Array(next).sorted())")
        // Re-evaluate the current foreground app immediately so a newly engaged
        // rule blocks on the next instant instead of waiting for an app switch.
        if let app = currentApp { evaluateApp(app) }
    }

    /// Per-project allow/block overlay, populated while a project session is active.
    /// Evaluated BEFORE the global distraction checks so project rules win.
    struct ProjectEnforcement {
        let projectId: UUID
        let allowedBundleIds: Set<String>
        let allowedDomains: Set<String>       // lowercased
        let blockedBundleIds: Set<String>
        let blockedDomains: Set<String>       // lowercased

        enum Verdict { case allow, block, noDecision }

        func verdict(bundleId: String?, hostname: String?) -> Verdict {
            if let bid = bundleId, allowedBundleIds.contains(bid) { return .allow }
            if let host = hostname?.lowercased(), Self.matchesDomain(host, in: allowedDomains) { return .allow }
            if let bid = bundleId, blockedBundleIds.contains(bid) { return .block }
            if let host = hostname?.lowercased(), Self.matchesDomain(host, in: blockedDomains) { return .block }
            return .noDecision
        }

        private static func matchesDomain(_ host: String, in set: Set<String>) -> Bool {
            if set.contains(host) { return true }
            for d in set where host.hasSuffix(".\(d)") { return true }
            return false
        }
    }
    var projectEnforcement: ProjectEnforcement? {
        didSet {
            // Changing project policy must re-evaluate any in-view tab on the next poll
            // rather than short-circuiting via the unchanged-tab cache.
            lastScoredTitle = nil
            lastScoredURL = nil
            lastScoreWasIrrelevant = false
        }
    }

    /// R4(c): inputs for the ONE precedence (EnforcementResolver) — per-goal
    /// allow > ✅ rule > 🚫 rule/⏳ gate > goal blocklist > default lists.
    /// `defaultBlockedDomains` stays empty on purpose: domain-level
    /// default-profile blocking is owned by WebsiteBlocker's 0.5s sweep
    /// (engine 1); duplicating it on the frontmost-tab path would change UX
    /// beyond this slice.
    private func enforcementInputs() -> EnforcementResolver.Inputs {
        var inputs = EnforcementResolver.Inputs()
        inputs.inFocusSession = focusModeController?.isOn == true
        if let pe = projectEnforcement {
            inputs.goalAllowedDomains = pe.allowedDomains
            inputs.goalAllowedBundleIds = pe.allowedBundleIds
            inputs.goalBlockedDomains = pe.blockedDomains
            inputs.goalBlockedBundleIds = pe.blockedBundleIds
        }
        inputs.rules = RuleEnforcementMirror.shared.activeSets()
        inputs.defaultBlockedBundleIds = distractingAppBundleIds.union(standaloneBlockedBundleIds)
        // R5: ⏳ targets gate as blocked once the shared allowance is spent.
        inputs.allowanceExhausted = AllowanceBalance.shared.isExhausted
        return inputs
    }

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

    /// Check if a hostname is in the user's always-relevant whitelist.
    /// Matches both exact hostname and base domain (e.g. "mail.google.com" matches "google.com").
    private func isAlwaysRelevant(_ hostname: String) -> Bool {
        let host = hostname.lowercased()
        if alwaysRelevantHostnames.contains(host) { return true }
        // Check if base domain matches (e.g. user whitelists "google.com", hostname is "mail.google.com")
        for whitelisted in alwaysRelevantHostnames {
            if host.hasSuffix(".\(whitelisted)") { return true }
        }
        return false
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
        // AI-powered Chromium browsers — full browsers, support Chrome's
        // AppleScript dialect, must be inspected per-tab during focus sessions.
        "ai.perplexity.comet",
        "com.openai.atlas",
        "com.openai.atlas.web",
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
        "ai.perplexity.comet": "Comet",
        "com.openai.atlas": "ChatGPT Atlas",
        "com.openai.atlas.web": "ChatGPT Atlas Web",
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

    /// Backup poll interval for browser tabs (seconds).
    /// Primary detection is via AXObserver (instant). Poll is a safety net
    /// in case AX notifications fail to fire.
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
    /// Red shift start threshold
    static let focusRedShiftThreshold: TimeInterval = 30.0
    /// Interval between repeating level 1 nudges (after first nudge)
    static let focusNudgeRepeatInterval: TimeInterval = 60.0
    /// Warning nudge threshold — red warning before intervention
    static let focusWarningThreshold: TimeInterval = 240.0
    /// Intervention threshold (and re-intervention interval)
    static let focusInterventionThreshold: TimeInterval = 300.0

    // ── Deep Work thresholds ──
    /// First nudge + timer dot red
    static let deepWorkNudgeThreshold: TimeInterval = 10.0
    /// Auto-redirect to last relevant URL + red shift starts
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
        var userOverride: Bool   // true when the user corrected this assessment (e.g. "this was wrong")
        let path: ScoringPath
        let ocrExcerpt: String?
        /// Stages the scorer walked through to reach this verdict (keyword → cache → metadata → OCR),
        /// each stamped with elapsed-ms-since-scoring-entry. Empty for non-scorer entries
        /// (red shift/intervention events, neutral-app logs, etc.).
        let trace: [TraceStep]
    }

    private(set) var relevanceLog: [RelevanceEntry] = []

    private func logAssessment(title: String, appName: String = "", hostname: String = "", intention: String, relevant: Bool, confidence: Int, reason: String, action: String, neutral: Bool = false, isEvent: Bool = false, userOverride: Bool = false, path: ScoringPath = .metadataRelevant, ocrExcerpt: String? = nil, trace: [TraceStep] = []) {
        let entry = RelevanceEntry(
            timestamp: Date(), title: title, appName: appName.isEmpty ? title : appName, hostname: hostname, intention: intention,
            relevant: relevant, confidence: confidence, reason: reason, action: action, neutral: neutral, isEvent: isEvent,
            userOverride: userOverride, path: path, ocrExcerpt: ocrExcerpt, trace: trace
        )
        relevanceLog.append(entry)
        if relevanceLog.count > Self.maxLogEntries {
            relevanceLog.removeFirst(relevanceLog.count - Self.maxLogEntries)
        }
        // Live focus tally — mirror SessionFocusScore.compute()'s qualifying set
        // exactly: count real on-screen relevance judgments only, excluding
        // EVENT lines (red-shift/intervention/override) and neutral-app entries.
        if !isEvent && !neutral {
            sessionAssessmentTotal += 1
            if relevant { sessionAssessmentRelevant += 1 }
        }
        persistAssessment(entry)
    }

    private func persistAssessment(_ entry: RelevanceEntry) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("relevance_log.jsonl")

        // S2 (2026-06-10): model is hardcoded to Qwen3-4B (no user picker).
        let aiModel = "qwen"
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
        if entry.userOverride { dict["userOverride"] = true }
        dict["path"] = entry.path.rawValue
        if let excerpt = entry.ocrExcerpt { dict["ocrExcerpt"] = excerpt }
        if !entry.trace.isEmpty {
            dict["trace"] = entry.trace.map { ["step": $0.step, "elapsedMs": $0.elapsedMs, "detail": $0.detail] }
        }

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

    // Context-switching overlay (v1)
    var switchCoordinator: SwitchInterventionCoordinator?
    var switchOverlayController: SwitchOverlayController?
    /// The target the user was about to open when the overlay appeared.
    private var pendingSwitchTarget: SwitchTarget?
    /// Snapshot of the app/tab the user was in BEFORE the pending switch (for Back-to-work restoration).
    private var priorAppBundleIdBeforeSwitch: String?
    private var priorTabURLBeforeSwitch: String?
    /// Suppressed bundle IDs: when the overlay dismisses or we programmatically `activateApp`,
    /// macOS fires NSWorkspace activation for the new frontmost app. We arm the suppression BEFORE
    /// `dismiss()` / `activate()` so the synchronous notification is always swallowed and the
    /// coordinator intercept never runs for our own self-induced activations.
    ///
    /// Map of bundle-id → expiry-date. Time-based (not single-shot) because:
    ///   - Continue/Back-to-work can cause multiple cascading activations (overlay dismiss
    ///     auto-activates underlying app, then applyReturnTarget calls app.activate again).
    ///   - macOS can fire `didActivate` multiple times for the same app in rapid succession
    ///     (e.g. when a window becomes key after app becomes frontmost).
    /// Consuming does NOT remove the entry — entries naturally expire, so every didActivate
    /// inside the window is suppressed without bookkeeping fragility.
    private var pendingActivationSuppressions: [String: Date] = [:]
    /// Monotonic count of switch overlays presented. Drives the rotating reminder copy so each
    /// interception sees a stable line and consecutive interceptions rotate. Not reset per session —
    /// variety across sessions is fine, and this keeps the counter simple.
    private var switchOverlayInterceptCount: Int = 0
    /// Rolling "last non-Intentional regular app" the user was in. Used as a Back-to-work fallback
    /// when `priorAppBundleIdBeforeSwitch` is nil or Intentional itself (e.g. if the user clicked
    /// something in Intentional's dashboard and that's why we saw a switch). Updated on every
    /// appDidActivate for regular apps other than Intentional.
    private var lastNonIntentionalAppBundleId: String?

    /// Arm a self-activation suppression for the given bundle. Any `didActivate` for this
    /// bundle within `seconds` is treated as our own doing (not a user-driven switch) and
    /// won't re-fire the switch-overlay intercept.
    private func armActivationSuppression(_ bundleId: String, seconds: TimeInterval = 2.0) {
        pendingActivationSuppressions[bundleId] = Date().addingTimeInterval(seconds)
    }

    /// True if we're still within the armed suppression window for this bundle.
    /// Does NOT remove the entry — lets multiple rapid didActivate calls all be suppressed.
    private func isActivationSuppressed(_ bundleId: String) -> Bool {
        guard let expiresAt = pendingActivationSuppressions[bundleId] else { return false }
        if Date() > expiresAt {
            pendingActivationSuppressions.removeValue(forKey: bundleId)
            return false
        }
        return true
    }

    // Linger tracking
    private var lingerTimer: Timer?
    private var lingerStart: Date?
    private var currentTarget: String = ""      // Display name (app name or page title)
    private var currentTargetKey: String = ""    // Key for counting (bundle ID or hostname)
    private var isCurrentlyIrrelevant = false
    private var isOnBreak = false
    private var currentOverlayIsNoPlan = false   // Whether the current overlay is for noPlan/unplanned

    // Overlay trigger tracking (Why? / approve / mark-wrong affordances)
    /// Full assessment entry that triggered the currently-visible blocking overlay.
    /// Captured at overlay-show time so "This was wrong" still works even if the row
    /// has been evicted from the in-memory `relevanceLog` (capped at maxLogEntries=50).
    private var overlayTriggerEntry: RelevanceEntry?
    /// URL (if any) of the page that triggered the overlay — surfaced in the "Why?" disclosure.
    private var overlayTriggerURL: String?
    /// Display name (page title or app) that triggered the overlay — used for "Approve for this block".
    private var overlayDisplayName: String?

    // Tiered enforcement: targets already warned once in this block
    private var warnedTargets: Set<String> = []
    private var suppressedUntil: [String: Date] = [:]

    // Grace period: delay before showing overlay on new irrelevant content
    private var graceTimer: Timer?
    private var pendingOverlay: PendingOverlayInfo?

    // Per-tab blocking: tracks when a browser tab has been redirected to focus-blocked.html
    private var tabIsOnBlockingPage = false
    private var blockedOriginalURL: String?

    /// Most recent (bundleId, hostname) seen by the browser poll — used to detect tab switches.
    private var lastSeenBrowserTab: (bundleId: String, host: String)?

    // Cumulative distraction counter (seconds). Increases when on irrelevant content,
    // decays when user returns to relevant content. Resets on block change.
    private var cumulativeDistractionSeconds: TimeInterval = 0
    /// Whether the last browser tab score was irrelevant (for sampling unchanged tabs)
    private var lastScoreWasIrrelevant = false

    // Mid-block celebration: track consecutive focused seconds and variable thresholds
    private var consecutiveFocusSeconds: TimeInterval = 0
    private var nextCelebrationThreshold: TimeInterval = 0
    private var celebrationCount: Int = 0

    // Nudge escalation state (all threshold-driven off cumulativeDistractionSeconds)
    /// Whether a nudge has been shown for the current irrelevant content
    private var nudgeShownForCurrentContent = false
    /// Cumulative distraction seconds at which the last nudge was shown (for repeat interval)
    private var lastNudgeShownAtDistraction: TimeInterval = 0
    /// Whether a justification flow is in progress (enforcement paused while user types)
    private var justificationInProgress = false
    /// How many interventions have been triggered during this distraction run (for escalating duration)
    private var interventionCount: Int = 0
    /// Cumulative distraction seconds at which the last intervention was triggered
    private var lastInterventionAtDistraction: TimeInterval = 0
    /// Whether the Deep Work auto-redirect has fired for the current distraction run
    private var deepWorkRedirectFired = false
    /// Whether red shift has been triggered at least once this block (instant re-trigger on revisit)
    private var redShiftTriggeredThisBlock = false
    /// When the user last transitioned from irrelevant to relevant (for graduated vignette decay)
    private var lastDistractionEndTime: Date?
    /// Number of distraction→focus recoveries during the current block
    private var blockRecoveryCount: Int = 0

    // MARK: - Live in-session focus tally
    // Running counters that mirror SessionFocusScore's derivation (relevant /
    // total over the session window, excluding `isEvent` + `neutral` entries),
    // maintained in-memory at the single logAssessment() funnel so the pill can
    // show a live focus % without re-reading the multi-MB relevance_log.jsonl
    // tail on every poll tick. Reset per session in resetEnforcementState().
    /// Qualifying assessments this session (excludes events + neutral entries).
    private var sessionAssessmentTotal: Int = 0
    /// Of those, how many were judged relevant.
    private var sessionAssessmentRelevant: Int = 0

    // AI override state
    /// When the current override expires (nil = no active override)
    private var overrideActiveUntil: Date? = nil
    /// Whether the current override is active
    private var isOverrideActive: Bool {
        if let until = overrideActiveUntil, Date() < until { return true }
        return false
    }
    /// Whether partner approval is required for AI overrides (loaded from settings)
    var overridePartnerApprovalRequired: Bool = false
    /// Whether a partner is configured (loaded from settings by AppDelegate)
    var hasConfiguredPartner: Bool = false
    /// Pending partner override request ID (for code verification)
    private var pendingOverrideRequestId: String? = nil

    // Deep Work aggressive enforcement
    /// Sites that have been auto-redirected during this Deep Work block (instant redirect on revisit)
    private var deepWorkRedirectedSites: Set<String> = []
    /// Deep Work native app grace: shorter than normal (5s instead of 30s)
    static let deepWorkNativeGraceSeconds: TimeInterval = 5.0
    /// Deep Work justification suppression: shorter (3 min instead of 5 min)
    static let deepWorkSuppressionSeconds: TimeInterval = 180.0

    // Graduated vignette decay: anti-gaming minimum and full recovery thresholds
    /// Minimum sustained focus time before any vignette decay (anti-gaming)
    static let vignetteMinRecoverySeconds: TimeInterval = 60.0
    /// Sustained focus time for full vignette reset (flag clears, must re-accumulate 30s distraction)
    static let vignetteFullRecoverySeconds: TimeInterval = 180.0

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

    // Browser tab detection: AXObserver for instant title-change events + backup poll
    private var browserPollTimer: Timer?
    private var axObserver: AXObserver?
    private var axObservedPid: pid_t = 0
    private var axObservedWindow: AXUIElement?
    private var axDebounceTimer: Timer?
    private var axBundleId: String?

    /// Fast fallback poller (2s) that runs ONLY when AXObserver couldn't start (missing
    /// Accessibility permission, or AXObserverCreate failed). Without AX, the 10s browser poll
    /// is the user's only path to tab-switch detection — too slow for the switch overlay. This
    /// timer runs a lightweight AppleScript read, dispatches tab-switch-only logic, and skips
    /// the heavier scoring path.
    private var tabSwitchFallbackTimer: Timer?
    private static let tabSwitchFallbackInterval: TimeInterval = 2.0
    /// Whether the AX observer successfully installed for the currently-observed browser.
    private var axObserverActive: Bool = false
    // Work tick timer for always-allowed non-browser apps (Xcode, Terminal, etc.)
    private var workTickTimer: Timer?
    // Neutral tick timer for screen lock, Intentional app, etc. (logs grey entries)
    private var neutralTickTimer: Timer?
    private var lastScoredTitle: String?
    private var lastScoredURL: String?

    /// Focus Agent S2 (CoachTelemetry): host of the current browser tab.
    /// Names-only privacy — exposes the host, never the title or full URL/path.
    var currentTabHost: String? {
        if let host = lastSeenBrowserTab?.host, !host.isEmpty { return host }
        guard let url = lastScoredURL else { return nil }
        return URL(string: url)?.host
    }

    /// Focus Agent telemetry: read the frontmost browser tab's host LIVE on the
    /// AppleScript queue, independent of enforcement gating (the cached state
    /// above is only maintained while enforcement drives browser polling, i.e.
    /// during sessions). Completion fires on the AppleScript queue with nil
    /// when the frontmost app isn't a readable browser.
    func fetchTabHostForTelemetry(completion: @escaping (String?) -> Void) {
        fetchTabInfoForTelemetry { host, _ in completion(host) }
    }

    /// Richer variant: host + tab title (titles are content-derived — gated by
    /// the telemetry privacy level at the CoachTelemetry call site).
    func fetchTabInfoForTelemetry(completion: @escaping (String?, String?) -> Void) {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              Self.browserBundleIds.contains(bid) else {
            completion(nil, nil)
            return
        }
        appleScriptQueue.async { [weak self] in
            guard let info = self?.readActiveTabInfo(for: bid) else {
                completion(nil, nil)
                return
            }
            let host = info.hostname.isEmpty ? nil : info.hostname
            let title = info.title.isEmpty ? nil : String(info.title.prefix(100))
            completion(host, title)
        }
    }

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

        redShiftController = RedShiftController()
        deepWorkTimerController = DeepWorkTimerController()

        // Listen for End Block button tapped on the floating pill
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePillEndBlock),
            name: .pillEndBlockTapped, object: nil
        )

        // Listen for pill minimize and mute
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePillMinimize),
            name: .pillMinimizeTapped, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePillMuteToggle),
            name: .pillMuteToggled, object: nil
        )

        // Listen for pill edit mode transitions
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePillEnterEdit),
            name: .pillEnterEditMode, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePillExitEdit),
            name: .pillExitEditMode, object: nil
        )

        // Listen for "Back to Task" button in the in-pill distraction card
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePillBackToTask),
            name: .pillBackToTaskTapped, object: nil
        )

        // Listen for "This is relevant" link in the in-pill distraction card
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePillThisIsRelevant),
            name: .pillThisIsRelevantTapped, object: nil
        )

        // Listen for "Take a Break" button in the pill hover state
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePillBreak),
            name: .pillBreakTapped, object: nil
        )

        // Listen for "Override AI" button in the pill distraction card
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePillOverrideAI),
            name: .pillOverrideAITapped, object: nil
        )

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
        allowanceMeterTimer?.invalidate()
        allowanceMeterTimer = nil
        nudgeController?.dismiss()
        overlayController?.dismiss()
        redShiftController?.dismiss()
        deepWorkTimerController?.dismiss()
        endRitualController?.dismiss()
        appDelegate?.postLog("👁️ FocusMonitor stopped")
    }

    // MARK: - Block Change

    /// Called when the active focus block changes.
    /// Resets all warning state, timers, and suppression.
    func onBlockChanged() {
        signalCoordinatorBlockChange()
        // If pill is in blockComplete/celebration mode, defer — AppDelegate will call showCelebration()
        if let pillMode = deepWorkTimerController?.viewModel?.mode,
           pillMode == .blockComplete || pillMode == .celebration {
            pendingBlockStartAfterCelebration = true
            appDelegate?.postLog("👁️ onBlockChanged() — pill in celebration mode, deferring block start")
            // Still reset enforcement state below, but don't dismiss pill or show ritual
            resetEnforcementState()
            return
        }

        appDelegate?.postLog("👁️ onBlockChanged() — resetting all state, will re-evaluate current app")
        resetEnforcementState()

        awaitingRitual = false

        // Skip ritual if the user just clicked Start (which saves edits via updateBlock,
        // triggering this method synchronously). Proceed directly to timer + enforcement.
        if skipNextRitual {
            skipNextRitual = false
            // Keep lastRitualShownForBlockId — it was set in handleRitualStart()
            // so subsequent onBlockChanged calls won't re-show the ritual
            showTimerForCurrentBlock()
            if let app = currentApp { evaluateApp(app) }
            return
        }

        // Block Start Ritual (pill-centric): show pill in start ritual mode BEFORE enforcement.
        // Skip if block is already >90s in progress (e.g. app restart mid-block).
        if let block = scheduleManager?.currentBlock {
            // Guard: don't re-show ritual for the same block
            if block.id == lastRitualShownForBlockId {
                appDelegate?.postLog("🧘 Block ritual: skipped — already shown for block \(block.id)")
                showTimerForCurrentBlock()
                if let app = currentApp { evaluateApp(app) }
                return
            }
            let calendar = Calendar.current
            let nowMinutes = calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())
            let elapsedSeconds = (nowMinutes - block.startMinutes) * 60
            let blockJustStarted = elapsedSeconds < 90

            // R6: earned-browse pool deleted — ritual card renders without minutes.
            let availableMinutes: Double = 0

            if !blockJustStarted {
                appDelegate?.postLog("🧘 Block ritual: skipped — block already \(elapsedSeconds / 60) min in progress")
                showTimerForCurrentBlock()
                if let app = currentApp { evaluateApp(app) }
                return
            }

            if block.blockType == .deepWork || block.blockType == .focusHours {
                awaitingRitual = true
                lastRitualShownForBlockId = block.id
                appDelegate?.postLog("🧘 Block ritual (pill): showing for \(block.blockType.rawValue) block \"\(block.title)\"")

                let data = StartRitualData(
                    block: block,
                    availableMinutes: availableMinutes,
                    isFreeTime: false,
                    onStart: { [weak self] in self?.handleRitualStart() },
                    onSaveEdit: { [weak self] updatedBlock in
                        self?.scheduleManager?.updateBlock(updatedBlock)
                    },
                    onPushBack: { [weak self] in
                        guard let self = self else { return }
                        self.awaitingRitual = false
                        self.deepWorkTimerController?.dismiss()
                        self.appDelegate?.postLog("🧘 Block ritual: pushed back 15 min")
                        self.scheduleManager?.pushBlockBack(id: block.id)
                    }
                )

                let now = Date()
                let endOfBlock = Calendar.current.date(
                    bySettingHour: block.endHour, minute: block.endMinute, second: 0, of: now
                ) ?? now
                deepWorkTimerController?.showStartRitual(block: block, endsAt: endOfBlock, data: data)
                return

            }
            // Spec 2: .freeTime removed — was a dead branch (block.blockType is always deepWork/focusHours).
        }

        // No ritual (nil block or no ritual controller) — proceed as before
        showTimerForCurrentBlock()

        // Re-evaluate current frontmost app against the new block
        if let app = currentApp {
            evaluateApp(app)
        }
    }

    /// Show the floating timer pill for the current block (extracted for reuse by ritual flow).
    private func showTimerForCurrentBlock() {
        if let block = scheduleManager?.currentBlock {
            let now = Date()
            let endOfBlock = Calendar.current.date(
                bySettingHour: block.endHour, minute: block.endMinute, second: 0, of: now
            ) ?? now
            deepWorkTimerController?.show(intention: block.title, endsAt: endOfBlock)
            deepWorkTimerController?.update(isDistracted: false)
            pushFocusStatsToTimer()
        } else {
            deepWorkTimerController?.dismiss()
        }
    }

    /// Signal the switch coordinator about a block change.
    /// Work blocks start a session; non-work blocks end it. If an overlay is up
    /// when the session changes, it's dismissed with a sessionEndedMidCountdown resolution.
    private func signalCoordinatorBlockChange() {
        guard let coord = switchCoordinator else { return }
        if let block = scheduleManager?.currentBlock,
           block.blockType == .deepWork || block.blockType == .focusHours {
            coord.sessionStarted(at: Date())
        } else {
            coord.sessionEnded()
        }
        if switchOverlayController?.isShowing == true {
            coord.resolve(outcome: .sessionEndedMidCountdown, intendedTarget: nil, returnTarget: nil, at: Date())
            switchOverlayController?.dismiss()
            pendingSwitchTarget = nil
        }
    }

    // MARK: - Enforcement State Reset

    /// Resets all enforcement counters and dismisses overlays. Used by onBlockChanged
    /// and when deferring block start during celebration.
    private func resetEnforcementState() {
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
        isCurrentlyIrrelevant = false
        isOnBreak = false
        currentTarget = ""
        currentTargetKey = ""
        lastScoredTitle = nil
        lastScoredURL = nil
        lastRelevantTabURL = nil
        tabIsOnBlockingPage = false
        blockedOriginalURL = nil
        cumulativeDistractionSeconds = 0
        consecutiveFocusSeconds = 0
        nextCelebrationThreshold = pickNextCelebrationThreshold()
        celebrationCount = 0
        lastScoreWasIrrelevant = false
        nudgeShownForCurrentContent = false
        lastNudgeShownAtDistraction = 0
        justificationInProgress = false
        interventionCount = 0
        lastInterventionAtDistraction = 0
        deepWorkRedirectFired = false
        redShiftTriggeredThisBlock = false
        lastDistractionEndTime = nil
        blockRecoveryCount = 0
        sessionAssessmentTotal = 0
        sessionAssessmentRelevant = 0
        interventionController?.dismiss()
        deepWorkRedirectedSites.removeAll()
        overrideActiveUntil = nil
        pendingOverrideRequestId = nil
        reconcileRedShift()
    }

    // MARK: - Red shift Helper (with one-time tooltip)

    /// Start red shift and show one-time onboarding tooltip if this is the user's first encounter.
    private func triggerRedShift() {
        guard !(redShiftController?.isActive ?? false), isEnforcementEnabled(.screenRedShift) else { return }
        redShiftController?.startRedShift(fromIntensity: vignetteRetriggerIntensity())
        redShiftTriggeredThisBlock = true
        if !hasSeenTooltip(.redShift) {
            markTooltipSeen(.redShift)
            // Show brief info nudge explaining the screen dimming
            deepWorkTimerController?.showDistractionCard(
                explanation: "The screen dims when you're off-task. It clears when you return to your work."
            )
        }
    }

    // MARK: - Mid-Block Focus Celebration

    /// Pick a variable threshold (in seconds) for the next focus celebration.
    /// Uses variable intervals so the celebration isn't perfectly predictable.
    private func pickNextCelebrationThreshold() -> TimeInterval {
        // Base intervals: ~8-12 min for first, ~15-20 for second, ~25-30 for third+
        let baseMins: Double
        switch celebrationCount {
        case 0: baseMins = Double.random(in: 8...12)
        case 1: baseMins = Double.random(in: 15...20)
        default: baseMins = Double.random(in: 25...35)
        }
        return consecutiveFocusSeconds + baseMins * 60
    }

    /// Called on each focus tick. Increments consecutive counter and checks celebration threshold.
    private func tickFocusCelebration(seconds: TimeInterval) {
        consecutiveFocusSeconds += seconds
        if consecutiveFocusSeconds >= nextCelebrationThreshold {
            celebrationCount += 1
            deepWorkTimerController?.flashCelebration()
            nextCelebrationThreshold = pickNextCelebrationThreshold()
        }
    }

    /// Reset consecutive focus counter on distraction.
    private func resetFocusStreak() {
        consecutiveFocusSeconds = 0
        // Don't reset celebrationCount — escalating thresholds persist across the block
        nextCelebrationThreshold = pickNextCelebrationThreshold()
    }

    // MARK: - Celebration (pill-centric block end)

    /// Show celebration by expanding the existing pill. Called by AppDelegate after capturing prev block stats.
    func showCelebration(
        block: ScheduleManager.FocusBlock,
        stats: BlockFocusStats,
        nextBlock: ScheduleManager.FocusBlock?,
        onDone: @escaping () -> Void
    ) {
        celebrationForBlockId = block.id
        // Spec 2: .freeTime removed — every block is deepWork or focusHours.
        let isFreeTime = false

        // Load app breakdown for work blocks
        var appBreakdown: [(appName: String, seconds: Int)] = []
        if !isFreeTime {
            appBreakdown = BlockEndRitualController.loadAppBreakdown(
                startHour: block.startHour, startMinute: block.startMinute,
                endHour: block.endHour, endMinute: block.endMinute
            )
        }

        let data = CelebrationData(
            blockTitle: block.title,
            blockType: block.blockType,
            startHour: block.startHour,
            startMinute: block.startMinute,
            endHour: block.endHour,
            endMinute: block.endMinute,
            focusScore: stats.focusScore,
            earnedMinutes: stats.earnedMinutes,
            totalTicks: stats.totalTicks,
            nextBlock: nextBlock,
            appBreakdown: appBreakdown,
            isFreeTime: isFreeTime,
            nextBlockAvailableMinutes: 0,  // R6: earned-browse pool deleted
            recoveryCount: stats.recoveryCount
        )

        deepWorkTimerController?.enterCelebration(data: data) { [weak self] in
            self?.resumeAfterCelebration()
            onDone()
        }

        // Wire Up Next card's Start button to skip the separate start ritual
        deepWorkTimerController?.viewModel?.onStartFromUpNext = { [weak self] in
            self?.handleStartFromUpNext()
            onDone()
        }
    }

    /// Called when celebration was skipped (e.g. 0 ticks) but pill was in blockComplete mode.
    /// Unblocks the deferred block start so the start ritual can show.
    /// Does NOT fire if celebration is currently showing — that has its own Done → resume flow.
    func resumeIfPendingBlockStart() {
        guard pendingBlockStartAfterCelebration else { return }
        // Don't interrupt an active celebration — it calls resumeAfterCelebration via Done button
        if deepWorkTimerController?.viewModel?.mode == .celebration { return }
        appDelegate?.postLog("👁️ resumeIfPendingBlockStart — celebration skipped, resuming")
        resumeAfterCelebration()
    }

    /// Called when user clicks Done on celebration cards. Runs deferred block start logic.
    /// Keeps the pill window alive and contracts into start ritual (smooth transition).
    func resumeAfterCelebration() {
        appDelegate?.postLog("👁️ resumeAfterCelebration — transitioning pill to next block")
        pendingBlockStartAfterCelebration = false
        awaitingRitual = false

        // Force ScheduleManager to re-evaluate which block is current RIGHT NOW,
        // instead of relying on the last 10s poll. This ensures currentBlock is accurate.
        scheduleManager?.forceRecalculate()

        if let block = scheduleManager?.currentBlock {
            // Don't show start ritual for the block we just celebrated
            if block.id == celebrationForBlockId {
                appDelegate?.postLog("👁️ resumeAfterCelebration — skipping ritual for celebrated block \(block.id)")
                celebrationForBlockId = nil
                deepWorkTimerController?.dismiss()
                showTimerForCurrentBlock()
                if let app = currentApp { evaluateApp(app) }
                return
            }

            let calendar = Calendar.current
            let nowMinutes = calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())
            let elapsedSeconds = (nowMinutes - block.startMinutes) * 60

            // Show start ritual if block is new enough (within first 120s to account for celebration time)
            if elapsedSeconds < 120 && block.id != lastRitualShownForBlockId {
                let availableMinutes: Double = 0  // R6: earned-browse pool deleted
                lastRitualShownForBlockId = block.id

                if block.blockType == .deepWork || block.blockType == .focusHours {
                    awaitingRitual = true

                    let data = StartRitualData(
                        block: block,
                        availableMinutes: availableMinutes,
                        isFreeTime: false,
                        onStart: { [weak self] in self?.handleRitualStart() },
                        onSaveEdit: { [weak self] updatedBlock in
                            self?.scheduleManager?.updateBlock(updatedBlock)
                        },
                        onPushBack: { [weak self] in
                            guard let self = self else { return }
                            self.awaitingRitual = false
                            self.deepWorkTimerController?.dismiss()
                            self.scheduleManager?.pushBlockBack(id: block.id)
                        }
                    )

                    celebrationForBlockId = nil
                    // Keep pill alive — just transition mode (smooth contraction)
                    deepWorkTimerController?.enterStartRitual(data: data)
                    return

                }
                // Spec 2: .freeTime branch removed — was a dead path.
            }
        }

        // Fallback: no ritual needed, just show timer
        celebrationForBlockId = nil
        deepWorkTimerController?.dismiss()
        showTimerForCurrentBlock()
        if let app = currentApp { evaluateApp(app) }
    }

    /// Consolidates ritual completion logic when user clicks Start.
    private func handleRitualStart() {
        awaitingRitual = false
        appDelegate?.postLog("🧘 Block ritual (pill): user started — activating timer + enforcement")

        // Play Glass sound on session start
        NSSound(named: "Glass")?.play()

        // Lock in the block ID so the ritual is never re-shown for this block
        if let blockId = scheduleManager?.currentBlock?.id {
            lastRitualShownForBlockId = blockId
        }

        // Save any inline edits from the pill edit mode.
        // Set skipNextRitual because updateBlock → recalculateState → onBlockChanged
        // fires synchronously, which would re-show the ritual.
        if let updatedBlock = deepWorkTimerController?.buildUpdatedBlockFromEdit() {
            skipNextRitual = true
            scheduleManager?.updateBlock(updatedBlock)
        }

        deepWorkTimerController?.viewModel?.stopAutoStartTimer()
        showTimerForCurrentBlock()
        if let app = currentApp {
            evaluateApp(app)
        }
    }

    /// Handle Start from Up Next celebration card — skip separate start ritual, go straight to timer.
    private func handleStartFromUpNext() {
        appDelegate?.postLog("👁️ handleStartFromUpNext — skipping start ritual, going straight to timer")
        pendingBlockStartAfterCelebration = false
        awaitingRitual = false
        celebrationForBlockId = nil

        if let block = scheduleManager?.currentBlock {
            lastRitualShownForBlockId = block.id
        }

        showTimerForCurrentBlock()
        if let app = currentApp {
            evaluateApp(app)
        }
    }

    /// Handle pill entering edit mode: expand window, enable keyboard.
    @objc private func handlePillEnterEdit() {
        guard let window = deepWorkTimerController?.timerWindow else { return }
        window.allowKeyboardInput = true
        appDelegate?.postLog("🚨 ACTIVATE: FocusMonitor.handlePillEnterEdit — makeKeyAndOrderFront (panel)")
        window.makeKeyAndOrderFront(nil)
        deepWorkTimerController?.animateWindowResize(to: NSSize(width: 460, height: 340))
    }

    /// Handle pill exiting edit mode: save edits, contract, resume auto-start.
    @objc private func handlePillExitEdit() {
        guard let vm = deepWorkTimerController?.viewModel,
              let data = vm.startRitualData else { return }

        // Save edits
        var updatedBlock = data.block
        updatedBlock.title = vm.editBlockTitle
        updatedBlock.description = vm.editBlockDescription
        updatedBlock.blockType = vm.editBlockType
        data.onSaveEdit?(updatedBlock)

        // Update start ritual data with edited block
        vm.startRitualData = StartRitualData(
            block: updatedBlock,
            availableMinutes: data.availableMinutes,
            isFreeTime: data.isFreeTime,
            onStart: data.onStart,
            onSaveEdit: data.onSaveEdit,
            onPushBack: data.onPushBack
        )

        // Disable keyboard, contract, resume auto-start
        deepWorkTimerController?.timerWindow?.allowKeyboardInput = false
        vm.mode = .startRitual
        deepWorkTimerController?.animateWindowResize(to: NSSize(width: 460, height: 160))
        vm.resumeAutoStartTimer()
    }

    /// Handle End Block button tapped on the floating pill.
    /// Slice 9 of 2026-05-05 redesign: gate by Focus Mode strictness preset.
    /// - Strict: refuse to end early (log + ignore)
    /// - Standard: present 10s confirmation (TODO — for now: allow with log warning)
    /// - Soft: allow immediately
    @objc private func handlePillEndBlock() {
        // Look up active Focus Mode strictness, if any
        let strictness = currentBlockStrictness()
        if strictness == "strict" {
            appDelegate?.postLog("🚫 End Block ignored — Focus Mode is Strict")
            return
        }
        if strictness == "standard" {
            // TODO(slice 9 followup): show 10s confirmation dialog before proceeding.
            appDelegate?.postLog("⚠️ End Block on Standard mode — friction confirmation TBD; allowing for now")
        }
        appDelegate?.postLog("👁️ End Block tapped on pill — triggering early block end")
        if let vm = deepWorkTimerController?.viewModel, vm.mode == .timer {
            vm.mode = .blockComplete
        }
        if let block = scheduleManager?.currentBlock {
            let now = Date()
            let cal = Calendar.current
            var updated = block
            updated.endHour = cal.component(.hour, from: now)
            updated.endMinute = cal.component(.minute, from: now)
            scheduleManager?.updateBlock(updated)
        }
    }

    /// Returns the strictness preset string ("strict" | "standard" | "soft")
    /// of the active Focus Mode, or "standard" as fallback when none is set.
    private func currentBlockStrictness() -> String {
        // Spec 1 + slice 2: each block has an intention (Focus Mode) id.
        // Look it up via IntentionStore.
        guard let uuid = scheduleManager?.currentBlock?.intentionId else {
            return "standard"
        }
        // IntentionStore is an actor; we sync-fetch here via a quick blocking call.
        // For now use a best-effort cached lookup pattern that's already common in the codebase.
        var preset = "standard"
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            if let intention = await IntentionStore.shared.intention(id: uuid) {
                preset = intention.strictnessPreset.rawValue
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 0.05)  // 50ms cap; default to standard if slow
        return preset
    }

    @objc private func handlePillMinimize() {
        deepWorkTimerController?.minimize()
        noPlanSnoozeUntil = Date().addingTimeInterval(30 * 60)
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 Pill: minimized via button — snoozed 30 min")
    }

    @objc private func handlePillMuteToggle() {
        let wasMuted = DeepWorkTimerController.soundEnabled == false
        DeepWorkTimerController.soundEnabled = wasMuted  // toggle: was muted → unmute, was unmuted → mute
        deepWorkTimerController?.viewModel?.isMuted = !wasMuted
        appDelegate?.postLog("🔇 Pill: sound \(wasMuted ? "unmuted" : "muted")")
    }

    @objc private func handlePillBackToTask() {
        deepWorkTimerController?.dismissDistractionCard()
        handleBackToWork()
        appDelegate?.postLog("💬 Pill: 'Back to Task' tapped — navigating to last relevant content")
    }

    @objc private func handlePillThisIsRelevant() {
        justificationInProgress = true
        // Dismiss the in-pill card immediately
        deepWorkTimerController?.dismissDistractionCard()

        // Show the NudgeWindowController with justification field pre-expanded
        let intention = scheduleManager?.currentBlock?.title ?? ""
        let displayName = currentTarget

        setupNudgeCallbacks()
        nudgeController?.pillWindow = deepWorkTimerController?.timerWindow
        nudgeController?.showNudge(
            intention: intention,
            appOrPage: displayName,
            escalated: true,                 // persistent (won't auto-dismiss)
            distractionMinutes: 0,
            warning: false,
            showJustificationExpanded: true   // pre-expand justification field
        )
        appDelegate?.postLog("💬 Pill: 'This is relevant' tapped — showing justification")
    }

    // MARK: - AI Override

    @objc private func handlePillOverrideAI() {
        let blockId = scheduleManager?.currentBlock?.id ?? ""
        let partnerRequired = overridePartnerApprovalRequired && hasConfiguredPartner

        // R6: the per-block override budget lived in EarnedBrowseManager and
        // had returned 0 since its feature flag went false — preserved as a
        // constant. Partner-approved overrides remain the live path.
        let remaining = 0

        if partnerRequired {
            // Show partner code flow via nudge
            deepWorkTimerController?.dismissDistractionCard()
            startPartnerOverrideRequest()
        } else if remaining > 0 {
            // Immediate budget override
            activateOverride(blockId: blockId)
        } else {
            appDelegate?.postLog("🔓 Override AI tapped but no overrides remaining")
        }
    }

    /// Activate a 5-minute AI override — pauses enforcement and assessment recording.
    private func activateOverride(blockId: String) {
        overrideActiveUntil = Date().addingTimeInterval(300)  // 5 min

        // Clear enforcement state
        cumulativeDistractionSeconds = 0
        isCurrentlyIrrelevant = false
        redShiftController?.restoreColor()
        nudgeController?.dismiss()
        deepWorkTimerController?.dismissDistractionCard()
        deepWorkTimerController?.update(isDistracted: false)

        // Update pill with remaining overrides (R6: budget engine deleted — 0).
        let remaining = 0
        deepWorkTimerController?.viewModel?.overridesRemaining = remaining
        pushFocusStatsToTimer()

        logAssessment(title: currentTarget, appName: currentAppName, intention: scheduleManager?.currentBlock?.title ?? "",
                     relevant: true, confidence: 0, reason: "User override (5 min)",
                     action: "override", neutral: true, isEvent: true)
        appDelegate?.postLog("🔓 Override activated (5 min) — \(remaining) remaining")
    }

    /// Start the partner override request flow — requests a code from backend and shows code entry in nudge.
    private func startPartnerOverrideRequest() {
        guard let backendClient = appDelegate?.backendClient else {
            appDelegate?.postLog("🔓 Override: no backend client")
            return
        }

        let blockType = scheduleManager?.currentBlock?.blockType.rawValue ?? "focusHours"
        let pageTitle = currentTarget
        let intention = scheduleManager?.currentBlock?.title ?? ""

        appDelegate?.postLog("🔓 Requesting partner override code...")

        Task {
            let result = await backendClient.requestOverride(blockType: blockType, pageTitle: pageTitle, intention: intention)
            await MainActor.run {
                if result.success, let requestId = result.requestId {
                    self.pendingOverrideRequestId = requestId
                    // Show nudge with code entry
                    self.setupNudgeCallbacks()
                    self.nudgeController?.viewModel?.showOverrideCodeEntry = true
                    self.nudgeController?.viewModel?.overrideRequestId = requestId
                    self.nudgeController?.viewModel?.overridePartnerName = result.partnerName ?? "Partner"
                    self.nudgeController?.pillWindow = self.deepWorkTimerController?.timerWindow
                    self.nudgeController?.showNudge(
                        intention: intention,
                        appOrPage: pageTitle,
                        escalated: true,
                        distractionMinutes: 0,
                        warning: false
                    )
                    self.nudgeController?.viewModel?.showOverrideCodeEntry = true
                    self.appDelegate?.postLog("🔓 Override code sent to \(result.partnerName ?? "partner")")
                } else {
                    self.appDelegate?.postLog("🔓 Override request failed: \(result.message)")
                    // R6: the budget-override fallback is gone with the
                    // earned-browse engine (its budget had been 0 since the
                    // feature flag went false, so this branch never fired).
                }
            }
        }
    }

    /// Verify a partner override code and activate override if valid.
    func verifyOverrideCode(_ code: String, requestId: String) {
        guard let backendClient = appDelegate?.backendClient else { return }

        Task {
            let result = await backendClient.verifyOverride(code: code, requestId: requestId)
            await MainActor.run {
                if result.success {
                    let blockId = self.scheduleManager?.currentBlock?.id ?? ""
                    self.nudgeController?.dismiss()
                    self.activateOverride(blockId: blockId)
                    self.appDelegate?.postLog("🔓 Partner override code verified — override activated")
                } else {
                    self.nudgeController?.viewModel?.overrideCodeError = result.message
                    self.appDelegate?.postLog("🔓 Partner override code rejected: \(result.message)")
                }
            }
        }
    }

    @objc private func handlePillBreak() {
        guard !isOnBreak else { return }
        isOnBreak = true

        switchCoordinator?.breakStarted(at: Date())
        if switchOverlayController?.isShowing == true {
            switchCoordinator?.resolve(outcome: .sessionEndedMidCountdown, intendedTarget: nil, returnTarget: nil, at: Date())
            switchOverlayController?.dismiss()
            pendingSwitchTarget = nil
        }

        // Dismiss any active nudge/overlay
        nudgeController?.dismiss()
        isCurrentlyIrrelevant = false

        // Stop monitoring timers
        stopBrowserPolling()
        stopWorkTickTimer()

        // Restore red shift if active
        redShiftController?.restoreColor()

        // Tell the pill to show break UI
        deepWorkTimerController?.startBreak()

        appDelegate?.postLog("☕ Break started (5 min)")

        // Schedule auto-resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60) { [weak self] in
            self?.endBreak()
        }
    }

    private func endBreak() {
        guard isOnBreak else { return }
        isOnBreak = false
        switchCoordinator?.breakEnded(at: Date())
        deepWorkTimerController?.endBreak()
        appDelegate?.postLog("☕ Break ended — resuming monitoring")
        // checkForegroundApp will restart on next timer tick (called by ScheduleManager every 10s)
    }

    // MARK: - Browser Tab Scoring

    /// Supplementary entry-point for reporting browser-tab scoring results.
    /// AppleScript polling is the primary path; this method has no current callers post-extension-removal
    /// but is retained for potential future scoring integrations.
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
        let newBundleId = app.bundleIdentifier ?? ""

        let priorApp = currentApp
        let priorBundleId = currentAppBundleId
        currentApp = app
        currentAppBundleId = newBundleId

        appDelegate?.postLog("🔀 appDidActivate: \(priorBundleId ?? "nil") → \(newBundleId) (policy=\(app.activationPolicy.rawValue))")

        // Track last non-Intentional, non-accessory app so Back-to-work has a sane fallback even
        // when priorAppBundleIdBeforeSwitch is stale or Intentional itself.
        if newBundleId != "com.arayan.intentional",
           !newBundleId.isEmpty,
           app.activationPolicy == .regular {
            lastNonIntentionalAppBundleId = newBundleId
        }

        // Consume suppression set by our own dismiss() / activateApp() calls — self-induced
        // activation events must not re-enter the coordinator as a fresh switch. Time-based:
        // every didActivate for this bundle within the armed window is suppressed, so cascading
        // macOS auto-activations don't poke through.
        if isActivationSuppressed(newBundleId) {
            appDelegate?.postLog("🎯 Switch overlay: suppressed self-activation for [\(newBundleId)] (active suppressions: \(pendingActivationSuppressions.keys.sorted().joined(separator: ",")))")
            evaluateApp(app)
            return
        }

        // Context-switching overlay intercept.
        //
        // Defaults applied here per the v1 plan's open questions:
        //   #7 menu-bar apps — suppress switches FROM or TO NSApplication.ActivationPolicy.accessory.
        //      Prevents battery/menu-bar clicks (which activate an .accessory app for an instant)
        //      from firing the overlay. Flag: revert by removing this guard.
        //   #3 overlay-on-overlay — suppress when FocusOverlayWindow or InterventionOverlayController
        //      is already on-screen. Avoids stacking overlays when the user is mid-intervention.
        //      Flag: revert by removing this guard.
        if let coord = switchCoordinator,
           isEnforcementEnabled(.contextSwitchOverlay),
           app.activationPolicy != .accessory,
           (priorApp?.activationPolicy ?? .regular) != .accessory,
           !(overlayController?.isShowing ?? false),
           !(interventionController?.isShowing ?? false),
           !(switchOverlayController?.isShowing ?? false)
        {
            let target = SwitchTarget.app(bundleId: newBundleId)
            let decision = coord.onSwitch(to: target, at: Date())
            switch decision {
            case .showOverlay(let seconds):
                priorAppBundleIdBeforeSwitch = priorBundleId
                priorTabURLBeforeSwitch = nil
                pendingSwitchTarget = target
                appDelegate?.postLog("🎯 Switch overlay fire → \(app.localizedName ?? newBundleId) [\(newBundleId)] priorApp=\(priorBundleId ?? "nil") tier=\(coordinatorTier()) countdown=\(seconds)s")
                presentSwitchOverlay(for: target, countdown: seconds, displayName: app.localizedName ?? newBundleId)
                // Do NOT early-return — evaluateApp still needs to run so scorer/enforcement stays accurate.
                // The overlay is orthogonal to enforcement.
            case .suppress(let reason):
                appDelegate?.postLog("🎯 Switch overlay suppressed (\(reason.rawValue)) → \(app.localizedName ?? newBundleId) [\(newBundleId)]")
            }
        }

        evaluateApp(app)
    }

    private func presentSwitchOverlay(for target: SwitchTarget, countdown: Int, displayName: String) {
        let block = scheduleManager?.currentBlock
        let project = block?.title ?? "Focus session"
        let task = block?.description ?? ""
        let remainingText = Self.formatSessionRemaining(block: block)
        switchOverlayInterceptCount += 1
        let presentation = SwitchOverlayPresentation(
            project: project,
            task: task,
            sessionLeft: remainingText,
            targetName: displayName,
            countdownSeconds: countdown,
            interceptIndex: switchOverlayInterceptCount
        )
        switchOverlayController?.show(presentation: presentation, delegate: self)
        appDelegate?.postLog("👁️ Switch overlay: \(displayName) (\(countdown)s, tier \(coordinatorTier()))")
    }

    private func coordinatorTier() -> Int {
        switchCoordinator?.currentTier(at: Date()) ?? 1
    }

    private static func formatSessionRemaining(block: ScheduleManager.FocusBlock?) -> String {
        guard let block = block else { return "" }
        let minuteOfDay = ScheduleManager.currentMinuteOfDay()
        let remainingMinutes = max(0, block.endMinutes - minuteOfDay)
        if remainingMinutes >= 60 {
            let h = remainingMinutes / 60
            let m = remainingMinutes % 60
            return m == 0 ? "\(h)h left" : "\(h)h \(m)m left"
        }
        return "\(remainingMinutes) min left"
    }

    private func evaluateApp(_ app: NSRunningApplication) {
        // On break — skip all monitoring
        if isOnBreak {
            debugLog("👁️ evaluateApp: skipped — on break, monitoring paused")
            return
        }

        // Block start ritual is showing — skip all enforcement until user starts
        if awaitingRitual {
            debugLog("👁️ evaluateApp: skipped — awaiting block start ritual")
            return
        }

        // Justification flow is open — skip enforcement while user types
        if justificationInProgress {
            debugLog("👁️ evaluateApp: skipped — justification in progress")
            return
        }

        let appName = app.localizedName ?? app.bundleIdentifier ?? "unknown"
        let bundleId = app.bundleIdentifier ?? "no-bundle-id"
        let currentState = scheduleManager?.currentTimeState.rawValue ?? "nil"
        let currentBlock = scheduleManager?.currentBlock?.title ?? "none"

        // Stop tick timers from previous app (will restart if new app needs them)
        stopWorkTickTimer()
        stopNeutralTickTimer()

        debugLog("👁️ evaluateApp: \(appName) (\(bundleId)), state=\(currentState), block=\(currentBlock)")

        // Skip reconciliation for browsers — handled below with proper state
        // (prevents red shift turning OFF briefly before async scoring re-enables it)
        if !Self.browserBundleIds.contains(bundleId) {
            reconcileRedShift()
        }

        guard let manager = scheduleManager else {
            debugLog("👁️ EXIT: no scheduleManager — treating as relevant")
            handleRelevantContent()
            stopBrowserPolling()
            return
        }

        let state = manager.currentTimeState
        debugLog("👁️ State check: enabled=\(manager.isEnabled), state=\(state.rawValue), hasPlan=\(manager.todaySchedule != nil), blocks=\(manager.todaySchedule?.blocks.count ?? 0)")

        // BlockRuleEnforcer (Opal-style Blocks): a BlockingProfile in its
        // scheduled window blocks the listed apps EVEN WHEN no focus session
        // is active. Must engage BEFORE the focusModeController gate below
        // because that gate would otherwise return early.
        // Composes with session enforcement via union: if Focus Mode IS on,
        // we still hit the existing distractingAppBundleIds branch below (which
        // gives the full session-style UX). Here we only handle the
        // "no session, but a rule says block this app" case.
        if let bidStandalone = app.bundleIdentifier,
           standaloneBlockedBundleIds.contains(bidStandalone),
           focusModeController?.isOn != true {
            handleStandaloneBlockedApp(app: app, bundleId: bidStandalone)
            return
        }

        // R6: 🚫 app RULES block outside sessions too. Pre-R6 this signal
        // arrived via BlockingProfile → BlockRuleEnforcer →
        // standaloneBlockedBundleIds (the branch above); the migration moves
        // those profiles into rules, so without this branch an "always
        // blocked" app would silently stop blocking out-of-session. Same
        // precedence as the resolver: ✅ allow beats 🚫 (goal lists don't
        // apply out of session). Schedule-active sets only.
        if let bidRule = app.bundleIdentifier,
           focusModeController?.isOn != true {
            let sets = RuleEnforcementMirror.shared.activeSets()
            if sets.blockedApps.contains(bidRule),
               !sets.allowedApps.contains(bidRule) {
                handleStandaloneBlockedApp(app: app, bundleId: bidRule)
                return
            }
        }

        // R5: ⏳ (limited) apps hard-block outside sessions once the shared
        // allowance is exhausted. Same pre-gate slot as the standalone rule
        // branch above — the focus-off gate below would otherwise return
        // early and never reach the resolver. With balance remaining, the
        // allowance meter (5s tick) spends against the app instead.
        if let bidLimited = app.bundleIdentifier,
           focusModeController?.isOn != true,
           AllowanceBalance.shared.isExhausted {
            let sets = RuleEnforcementMirror.shared.activeSets()
            if sets.limitedApps.contains(bidLimited),
               !sets.allowedApps.contains(bidLimited) {
                handleAllowanceExhaustedApp(app: app, bundleId: bidLimited)
                return
            }
        }

        // Enforcement runs IFF Focus Mode is ON. Bedtime and Off both bypass.
        // (Replaces the earlier TimeState allowlist — disabled, freeTime, snoozed,
        // and unplanned all route through Focus Mode being off rather than this
        // gate. The unplanned-bypass behavior is preserved by definition: with
        // no schedule block and no active session, FocusModeController is .off.)
        if focusModeController?.isOn != true {
            // Focus Mode off — if the user has the plan-first prompt enabled and
            // currently has no block scheduled, show the noPlan pill. Restores
            // the trigger that was wired before the April 2026 TimeState
            // consolidation (see the long-standing TODO that used to live here).
            maybeShowNoPlanPill(currentApp: app)
            debugLog("👁️ EXIT: focus mode not on (state=\(focusModeController?.state.rawValue ?? "nil")) — browsing allowed freely")
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
        // Keep enforcement state frozen — neutral apps shouldn't clear red shift/overlays
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
        if bid == "com.arayan.intentional" || bid == Bundle.main.bundleIdentifier {
            if overlayController?.isShowing == true || interventionController?.isShowing == true {
                debugLog("👁️ EXIT: own app activated by overlay click — keeping overlay")
                return
            }
            debugLog("👁️ EXIT: own app — allowing (grace timer preserved)")
            stopLingerTimer()
            isCurrentlyIrrelevant = false
            nudgeController?.dismiss()
            stopBrowserPolling()
            stopWorkTickTimer()
            startNeutralTickTimer(appName: "Intentional")
            return
        }

        // NOTE (TimeState consolidation): Previously .unplanned and .noPlan showed a
        // floating pill card here. With TimeState collapsed to {off, focus, bedtime},
        // both of those sub-states are now .off and return early above (browsing allowed freely).
        // TODO (Task 5): When FocusModeController.isOn replaces TimeState gates, restore
        // noPlan pill-card logic using scheduleManager.todaySchedule != nil as the discriminator.

        // Was: `guard state.isWork else { handleRelevantContent(); return }`.
        // Removed because manual Focus Mode sessions (started via Start on a
        // Focus Mode card, or via cross-device push) don't have a corresponding
        // ScheduleManager block — they live only in /focus/active. So
        // `state.isWork` is false for them, and the guard skipped AI scoring +
        // work-tick recording entirely (focus score stuck at 0%). The earlier
        // `focusModeController.isOn == true` guard (line ~1618) is the correct
        // gate: if Focus Mode is on, we score. Schedule state is irrelevant.

        // R4(c): ONE precedence for apps, owned by EnforcementResolver —
        // per-goal allow > ✅ rule > 🚫 rule/⏳ gate > goal blocklist >
        // default lists (distracting ∪ standalone). The switch below maps
        // verdict sources onto the two existing treatment paths: goal-block
        // forces the overlay regardless of block type; rule/default blocks
        // keep the block-type softness (overlay on deep work, nudge on focus
        // hours). Allowed apps skip AI scoring and earn work ticks.
        let appVerdict = EnforcementResolver.resolveApp(bundleId: bid, inputs: enforcementInputs())
        switch appVerdict {
        case .allow(let source):
            let reason = (source == .goalAllow) ? "Project allow list" : "Allowed by rule"
            debugLog("👁️ EXIT: \(appName) allowed (\(reason))")
            handleRelevantContent()
            stopBrowserPolling()
            logAssessment(
                title: appName,
                intention: scheduleManager?.currentBlock?.title ?? "",
                relevant: true, confidence: 100,
                reason: reason, action: "none"
            )
            startWorkTickTimer(appName: appName)
            return
        case .block(.goalBlock):
            debugLog("👁️ \(appName) blocked by active project — hard block")
            stopBrowserPolling()
            logAssessment(
                title: appName,
                intention: scheduleManager?.currentBlock?.title ?? "",
                relevant: false, confidence: 100,
                reason: "Project block list", action: "overlay", isEvent: true
            )
            // Project blocklist apps are explicit user rules — force the blocking
            // overlay regardless of block type. Soft nudges are only for the AI's
            // ambiguous verdicts, not for content the user has already ruled out.
            if isOverrideActive { return }
            cancelGracePeriod()
            warnedTargets.insert(bid)
            currentTarget = appName
            currentTargetKey = bid
            isCurrentlyIrrelevant = true
            resetFocusStreak()
            triggerRedShift()
            deepWorkTimerController?.update(isDistracted: true)
            if isEnforcementEnabled(.blockingOverlay) {
                let intention = scheduleManager?.currentBlock?.title ?? ""
                let focusDuration = computeFocusDurationMinutes()
                showOverlay(intention: intention, reason: "Project block list",
                           focusDurationMinutes: focusDuration, isNoPlan: false, displayName: appName)
            }
            return
        case .block(let blockSource):
            // 🚫 rule, ⏳ gate (in-session), or the default distracting/standalone
            // union — the pre-R4 "user-configured distracting app" path.
            let reason: String
            switch blockSource {
            case .blockRule: reason = "Blocked by rule"
            case .limitGate: reason = "Limited app — focus session"
            default:         reason = "User-configured distracting app"
            }
            debugLog("👁️ \(appName) blocked (\(reason)) — direct enforcement (no grace)")
            stopBrowserPolling()
            logAssessment(
                title: appName,
                intention: scheduleManager?.currentBlock?.title ?? "",
                relevant: false,
                confidence: 100,
                reason: reason,
                action: "none"
            )
            // Increment distraction counter
            cumulativeDistractionSeconds += Self.browserPollInterval
            // Set state directly — no grace period limbo
            cancelGracePeriod()
            warnedTargets.insert(bid)
            currentTarget = appName
            currentTargetKey = bid
            isCurrentlyIrrelevant = true
            resetFocusStreak()
            // Start gradual red shift (same slow shift as distracting websites)
            let blockType = scheduleManager?.currentBlock?.blockType ?? .focusHours
            triggerRedShift()
            deepWorkTimerController?.update(isDistracted: true)
            // Show overlay (deep work) or nudge (focus hours)
            let intention = scheduleManager?.currentBlock?.title ?? ""
            let focusDuration = computeFocusDurationMinutes()
            if blockType == .deepWork && isEnforcementEnabled(.blockingOverlay) {
                showOverlay(intention: intention, reason: reason,
                           focusDurationMinutes: focusDuration, isNoPlan: false, displayName: appName)
            } else if isEnforcementEnabled(.nudge) {
                showNudgeForContent(intention: intention, displayName: appName, escalated: false)
            }
            return
        case .noDecision:
            break
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
            startWorkTickTimer(appName: appName)
            // Background audio detection: mute distracting sources even when switching to always-allowed apps
            if state.isWork && isEnforcementEnabled(.backgroundAudioDetection) {
                muteBackgroundDistractingAudio()
            }
            return
        }

        // If it's a browser, read tab title via AppleScript and start polling
        if Self.browserBundleIds.contains(bid) {
            debugLog("👁️ Browser detected (\(bid)) — reading tab via AppleScript")

            // If red shift was triggered this block, maintain it when returning to browser.
            // Assume content is irrelevant until AI scoring proves otherwise (prevents flicker).
            if redShiftTriggeredThisBlock && scheduleManager?.currentTimeState.isWork == true && isEnforcementEnabled(.screenRedShift) {
                isCurrentlyIrrelevant = true
                if !(redShiftController?.isActive ?? false) {
                    redShiftController?.startRedShift(fromIntensity: vignetteRetriggerIntensity())
                    appDelegate?.postLog("🌫️ Browser activated: red shift maintained (pending AI score)")
                    logAssessment(title: "Red shift", appName: appName, intention: scheduleManager?.currentBlock?.title ?? "",
                                 relevant: false, confidence: 0, reason: "Browser activated — maintaining red shift pending AI score",
                                 action: "grayscale_on", isEvent: true)
                }
            }

            lastScoredTitle = nil
            lastScoredURL = nil
            lastScoreWasIrrelevant = false
            readAndScoreActiveTab(bundleId: bid)
            // AXObserver for instant tab-switch detection + backup poll timer
            startBrowserAXObserver(pid: app.processIdentifier, bundleId: bid)
            startBrowserPolling(bundleId: bid)
            return
        }

        // Non-browser app: stop browser polling and score the app name
        stopBrowserPolling()
        debugLog("👁️ App switched to: \(appName) (\(bid))")

        // Background audio detection: mute distracting browser tabs + apps
        if state.isWork && isEnforcementEnabled(.backgroundAudioDetection) {
            muteBackgroundDistractingAudio()
        }

        // Score app name asynchronously
        Task {
            guard let scorer = self.relevanceScorer,
                  let block = manager.currentBlock else { return }

            // FIX-11: Resolve the active Weekly Goal's intentText + aiScoringEnabled so the
            // scorer can short-circuit when the user has disabled AI scoring for this goal
            // and so prompts use the goal's own intent text rather than legacy block.description.
            var intentText = ""
            var aiEnabled = true
            if let intentionId = block.intentionId,
               let intention = await IntentionStore.shared.intention(id: intentionId) {
                intentText = intention.intentText ?? ""
                aiEnabled = intention.aiScoringEnabled
            }

            let result = await scorer.scoreRelevance(
                pageTitle: appName,
                intention: block.title,
                intentionDescription: block.description,
                intentText: intentText,
                aiScoringEnabled: aiEnabled,
                profile: block.ignoreProfile ? "" : manager.profile,
                dailyPlan: manager.todaySchedule?.dayNotes ?? "",
                contentType: .application,
                bundleIdentifier: bid
            )

            await MainActor.run {
                // Stale check: app may no longer be frontmost (scoring is async)
                guard self.currentAppBundleId == bid else {
                    self.appDelegate?.postLog("👁️ Scoring completed but \(appName) no longer frontmost — ignoring")
                    return
                }

                let shouldEnforceOffTask = ConfidenceGate.shouldEnforceOffTask(
                    relevant: result.relevant, confidence: result.confidence, path: result.path)
                let isLowConfPassthrough = !result.relevant && !shouldEnforceOffTask
                let loggedPath: ScoringPath = isLowConfPassthrough ? .metadataOffTaskLowConf : result.path

                self.logAssessment(
                    title: appName, intention: block.title,
                    relevant: result.relevant, confidence: result.confidence,
                    reason: result.reason, action: "none", neutral: isLowConfPassthrough,
                    path: loggedPath, ocrExcerpt: result.ocrExcerpt, trace: result.trace
                )
                if result.relevant {
                    self.debugLog("👁️ App is relevant: \(appName)")
                    self.handleRelevantContent()
                    // Let the work tick timer handle earning (no initial tick to avoid double-counting)
                    if self.scheduleManager?.currentTimeState.isWork == true {
                        // Start continuous work tick timer so earning + decay continues
                        self.startWorkTickTimer(appName: appName)
                    }
                } else if isLowConfPassthrough {
                    self.appDelegate?.postLog("👁️ App off-task at \(result.confidence)% confidence — below threshold, letting through: \(appName)")
                } else {
                    self.appDelegate?.postLog("👁️ App is NOT relevant: \(appName) — \(result.reason)")
                    // Record irrelevant assessment for deep work tracking
                    self.handleIrrelevantContent(targetKey: bid, displayName: appName)
                }
            }
        }
    }

    // MARK: - AppleScript Tab Reading

    /// Read the active tab title and URL via AppleScript, then score for relevance.
    /// AppleScript runs on background queue to avoid blocking main thread 200-600ms.
    /// (Same fix as WebsiteBlocker — see CLAUDE.md Bug #9)
    private func readAndScoreActiveTab(bundleId: String) {
        guard let manager = scheduleManager,
              manager.currentTimeState.isWork,
              let block = manager.currentBlock,
              let scorer = relevanceScorer else { return }

        // Read tab info on background queue — AppleScript blocks 200-600ms
        // waiting for the browser's Apple Event reply (mach_msg).
        appleScriptQueue.async { [weak self] in
            let tabInfo = self?.readActiveTabInfo(for: bundleId)
            DispatchQueue.main.async {
                self?.processActiveTabInfo(tabInfo, bundleId: bundleId, block: block, scorer: scorer, manager: manager)
            }
        }
    }

    /// Process tab info after AppleScript read completes (runs on main thread).
    private func processActiveTabInfo(_ tabInfo: (title: String, url: String, hostname: String)?,
                                      bundleId: String, block: ScheduleManager.FocusBlock,
                                      scorer: RelevanceScorer, manager: ScheduleManager) {
        // Stale check: browser may no longer be frontmost, or block may have ended
        // during the 200-600ms AppleScript wait
        guard currentAppBundleId == bundleId,
              let currentManager = scheduleManager,
              currentManager.currentTimeState.isWork,
              currentManager.currentBlock?.id == block.id else { return }

        guard let info = tabInfo else {
            // Surface this at info level — repeated failures here are almost always missing
            // Automation permission for the browser (System Settings → Privacy & Security →
            // Automation → Intentional). Without it, the switch overlay can't detect tab switches.
            appDelegate?.postLog("👁️ readActiveTabInfo returned nil for \(bundleId) — check Automation permission for the browser")
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

        // Context-switching overlay: detect tab-level switch on each poll.
        //
        // Default #3 (overlay-on-overlay) applied: skip if FocusOverlayWindow or
        // InterventionOverlayController is already visible. Flag: revert by removing
        // the isShowing guards.
        // readActiveTabInfo() falls back to `hostname = bundleId` when URL parsing fails
        // (e.g. chrome://newtab, about:blank, empty URL). That's NOT a real host and must not
        // drive the switch-overlay — treat as no hostname for this path only.
        let hostIsReal = !info.hostname.isEmpty && info.hostname != bundleId
        if hostIsReal {
            let tupleNow = (bundleId: bundleId, host: info.hostname)
            let changed: Bool
            if let prior = lastSeenBrowserTab {
                changed = (prior.bundleId != tupleNow.bundleId) || (prior.host != tupleNow.host)
            } else {
                changed = true
            }
            if changed,
               let coord = switchCoordinator,
               isEnforcementEnabled(.contextSwitchOverlay),
               !(overlayController?.isShowing ?? false),
               !(interventionController?.isShowing ?? false),
               !(switchOverlayController?.isShowing ?? false)
            {
                let target = SwitchTarget.tab(bundleId: bundleId, host: info.hostname)
                let decision = coord.onSwitch(to: target, at: Date())
                switch decision {
                case .showOverlay(let seconds):
                    priorAppBundleIdBeforeSwitch = nil
                    priorTabURLBeforeSwitch = lastSeenBrowserTab.map { "http://\($0.host)" }
                    pendingSwitchTarget = target
                    let display = "\(Self.browserAppNames[bundleId] ?? "Browser") — \(info.hostname)"
                    appDelegate?.postLog("🎯 Switch overlay fire → tab \(display) priorHost=\(lastSeenBrowserTab?.host ?? "nil") tier=\(coordinatorTier()) countdown=\(seconds)s")
                    presentSwitchOverlay(for: target, countdown: seconds, displayName: display)
                case .suppress(let reason):
                    appDelegate?.postLog("🎯 Switch overlay suppressed (\(reason.rawValue)) → tab \(bundleId) · \(info.hostname)")
                }
            }
            lastSeenBrowserTab = tupleNow
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
                if isOverrideActive {
                    // During override: skip assessment recording, still earn work ticks, log as override
                    let browserName = Self.browserAppNames[bundleId] ?? "Browser"
                    logAssessment(
                        title: info.title, appName: browserName, hostname: info.hostname, intention: scheduleManager?.currentBlock?.title ?? "",
                        relevant: true, confidence: 0, reason: "AI override active", action: "override", neutral: true
                    )
                } else {
                    // Log assessment so the popover time tracking is accurate for irrelevant tabs too
                    let browserName = Self.browserAppNames[bundleId] ?? "Browser"
                    logAssessment(
                        title: info.title, appName: browserName, hostname: info.hostname, intention: scheduleManager?.currentBlock?.title ?? "",
                        relevant: false, confidence: 0, reason: "unchanged tab (irrelevant)", action: "none"
                    )
                    handleIrrelevantContent(targetKey: info.hostname, displayName: info.title)
                }
            } else if scheduleManager?.currentTimeState.isWork == true {
                // Tab is still relevant — record ongoing work tick + assessment
                tickFocusCelebration(seconds: Self.browserPollInterval)
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

        // R4(c): ONE precedence for browser tabs, owned by EnforcementResolver —
        // per-goal allow > ✅ rule > 🚫 rule/⏳ gate > goal blocklist. (The
        // default-profile domain layer stays with WebsiteBlocker's sweep —
        // see enforcementInputs().) Allow verdicts skip AI scoring; block
        // verdicts hard-redirect regardless of block type — explicit user
        // rules, not AI ambiguity.
        let tabVerdict = EnforcementResolver.resolveSite(host: info.hostname, inputs: enforcementInputs())
        if tabVerdict != .noDecision {
            let browserName = Self.browserAppNames[bundleId] ?? "Browser"
            switch tabVerdict {
            case .allow(let source):
                let reason = (source == .goalAllow) ? "Project allow list" : "Allowed by rule"
                lastScoreWasIrrelevant = false
                logAssessment(
                    title: info.title, appName: browserName, hostname: info.hostname, intention: block.title,
                    relevant: true, confidence: 100, reason: reason, action: "none"
                )
                appDelegate?.postLog("👁️ \(reason): \"\(info.title)\" (\(info.hostname)) — skipping AI")
                handleRelevantContent()
                if manager.currentTimeState.isWork {
                    startWorkTickTimer(appName: browserName)
                }
                return
            case .block(let source):
                let reason: String
                switch source {
                case .blockRule: reason = "Blocked by rule"
                case .limitGate: reason = "Limited site — focus session"
                default:         reason = "Project block list"
                }
                lastScoreWasIrrelevant = true
                logAssessment(
                    title: info.title, appName: browserName, hostname: info.hostname, intention: block.title,
                    relevant: false, confidence: 100, reason: reason, action: "blocked", isEvent: true
                )
                // Blocklist entries are explicit user rules — hard-block immediately
                // regardless of block type (bypasses the Focus Hours soft red shift+nudge path).
                // Still respects active AI overrides so the user can escape if they really need to.
                if isOverrideActive { return }
                appDelegate?.postLog("👁️ \(reason) (hard): \"\(info.title)\" (\(info.hostname)) — redirecting")
                isCurrentlyIrrelevant = true
                currentTarget = info.title
                currentTargetKey = info.hostname
                deepWorkRedirectedSites.insert(info.hostname)
                if let tabInfo = readActiveTabInfo(for: bundleId),
                   !tabInfo.url.contains("focus-blocked.html") {
                    blockActiveTab(intention: block.title, pageTitle: info.title,
                                   hostname: info.hostname, originalURL: tabInfo.url)
                }
                return
            case .noDecision:
                break
            }
        }

        // Social media sites are always irrelevant during work blocks — skip AI scoring.
        // This prevents the AI from incorrectly scoring e.g. YouTube Shorts as "relevant"
        // when navigating between pages on the same social media site.
        if isSocialMedia(info.hostname) {
            lastScoreWasIrrelevant = true
            let browserName = Self.browserAppNames[bundleId] ?? "Browser"
            logAssessment(
                title: info.title, appName: browserName, hostname: info.hostname, intention: block.title,
                relevant: false, confidence: 100, reason: "Social media site", action: "none"
            )
            appDelegate?.postLog("👁️ Social media bypass: \"\(info.title)\" (\(info.hostname)) — skipping AI, treating as irrelevant")
            handleIrrelevantContent(targetKey: info.hostname, displayName: info.title, confidence: 100, reason: "Social media site")
            return
        }

        // Always-relevant sites: user whitelisted these as work tools — skip AI scoring.
        // (e.g. Gmail, Slack — sites where AI can't determine relevance from title/URL alone)
        if isAlwaysRelevant(info.hostname) {
            lastScoreWasIrrelevant = false
            let browserName = Self.browserAppNames[bundleId] ?? "Browser"
            logAssessment(
                title: info.title, appName: browserName, hostname: info.hostname, intention: block.title,
                relevant: true, confidence: 100, reason: "On your always-allowed list", action: "none"
            )
            appDelegate?.postLog("👁️ Whitelist bypass: \"\(info.title)\" (\(info.hostname)) — skipping AI, treating as relevant")
            handleRelevantContent()
            if manager.currentTimeState.isWork {
                startWorkTickTimer(appName: Self.browserAppNames[bundleId] ?? "Browser")
            }
            return
        }

        debugLog("👁️ Scoring tab: \"\(info.title)\" (\(info.hostname))")

        // Score asynchronously
        Task {
            // FIX-11: Resolve per-goal AI flag + intentText so the scorer honors them.
            var intentText = ""
            var aiEnabled = true
            if let intentionId = block.intentionId,
               let intention = await IntentionStore.shared.intention(id: intentionId) {
                intentText = intention.intentText ?? ""
                aiEnabled = intention.aiScoringEnabled
            }

            let result = await scorer.scoreRelevance(
                pageTitle: info.title,
                intention: block.title,
                intentionDescription: block.description,
                intentText: intentText,
                aiScoringEnabled: aiEnabled,
                profile: block.ignoreProfile ? "" : manager.profile,
                dailyPlan: manager.todaySchedule?.dayNotes ?? "",
                url: info.url,
                bundleIdentifier: bundleId
            )

            await MainActor.run {
                // Stale check: browser may no longer be frontmost (scoring is async)
                guard self.currentAppBundleId == bundleId else {
                    self.appDelegate?.postLog("👁️ Scoring completed but \(bundleId) no longer frontmost — ignoring")
                    return
                }

                let shouldEnforceOffTask = ConfidenceGate.shouldEnforceOffTask(
                    relevant: result.relevant, confidence: result.confidence, path: result.path)
                let isLowConfPassthrough = !result.relevant && !shouldEnforceOffTask
                let browserName = Self.browserAppNames[bundleId] ?? "Browser"

                if result.relevant {
                    self.lastScoreWasIrrelevant = false
                    self.logAssessment(
                        title: info.title, appName: browserName, hostname: info.hostname, intention: block.title,
                        relevant: true, confidence: result.confidence,
                        reason: result.reason, action: "none",
                        path: result.path, ocrExcerpt: result.ocrExcerpt, trace: result.trace
                    )
                    self.debugLog("👁️ Tab is relevant: \"\(info.title)\"")
                    self.handleRelevantContent()
                    // No initial tick here — browser poll timer handles ongoing earning
                } else if isLowConfPassthrough {
                    // Low-confidence off-task: don't enforce, don't count toward distraction stats.
                    self.lastScoreWasIrrelevant = false
                    self.logAssessment(
                        title: info.title, appName: browserName, hostname: info.hostname, intention: block.title,
                        relevant: false, confidence: result.confidence,
                        reason: result.reason, action: "none", neutral: true,
                        path: .metadataOffTaskLowConf, ocrExcerpt: result.ocrExcerpt, trace: result.trace
                    )
                    self.appDelegate?.postLog("👁️ Tab off-task at \(result.confidence)% confidence — below threshold, letting through: \"\(info.title)\"")
                } else {
                    self.lastScoreWasIrrelevant = true

                    if self.isOverrideActive {
                        // During override: skip assessment, still earn work ticks, log as override
                        self.logAssessment(
                            title: info.title, appName: browserName, hostname: info.hostname, intention: block.title,
                            relevant: true, confidence: 0, reason: "AI override active", action: "override", neutral: true
                        )
                        self.appDelegate?.postLog("👁️ Tab scored irrelevant but override active: \"\(info.title)\"")
                    } else {
                        self.logAssessment(
                            title: info.title, appName: browserName, hostname: info.hostname, intention: block.title,
                            relevant: false, confidence: result.confidence,
                            reason: result.reason, action: "none",
                            path: result.path, ocrExcerpt: result.ocrExcerpt, trace: result.trace
                        )
                        // Record irrelevant assessment for earned browse tracking
                        self.appDelegate?.postLog("👁️ Tab is NOT relevant: \"\(info.title)\" — \(result.reason)")
                        self.handleIrrelevantContent(targetKey: info.hostname, displayName: info.title, confidence: result.confidence, reason: result.reason)
                    }
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
        stopBrowserAXObserver()
        stopTabSwitchFallbackPoll()
        lastSeenBrowserTab = nil
    }

    /// 2s poll for tab-switch detection, running only while the AX observer isn't active.
    /// Reads the current tab via AppleScript and routes through processActiveTabInfo, same as
    /// the 10s browserPollTimer — the difference is cadence. The scoring/cache layers dedupe
    /// repeated reads of the same tab, so this isn't wasted work.
    private func startTabSwitchFallbackPoll(bundleId: String) {
        stopTabSwitchFallbackPoll()
        tabSwitchFallbackTimer = Timer.scheduledTimer(withTimeInterval: Self.tabSwitchFallbackInterval, repeats: true) { [weak self] _ in
            guard let self = self,
                  self.currentAppBundleId == bundleId,
                  !self.awaitingRitual,
                  !self.isOnBreak,
                  !self.justificationInProgress else { return }
            guard let mgr = self.scheduleManager, mgr.currentTimeState.isWork else { return }
            self.readAndScoreActiveTab(bundleId: bundleId)
        }
        appDelegate?.postLog("👁️ AXObserver unavailable — started \(Int(Self.tabSwitchFallbackInterval))s tab-switch fallback poll for \(bundleId)")
    }

    private func stopTabSwitchFallbackPoll() {
        tabSwitchFallbackTimer?.invalidate()
        tabSwitchFallbackTimer = nil
    }

    // MARK: - AXObserver (instant tab-switch detection)

    /// Start observing a browser's window title changes via the Accessibility API.
    /// Watches the focused window directly (not the app element) for reliable
    /// kAXTitleChangedNotification delivery across all browsers.
    /// Re-observes the window when kAXFocusedWindowChangedNotification fires.
    private func startBrowserAXObserver(pid: pid_t, bundleId: String) {
        // Already observing this process
        if axObservedPid == pid && axObserver != nil { return }
        stopBrowserAXObserver()

        guard AXIsProcessTrusted() else {
            appDelegate?.postLog("👁️ AXObserver: accessibility NOT trusted — falling back to 2s tab-switch poll for \(bundleId). Grant Accessibility in System Settings for instant tab-switch detection.")
            axObserverActive = false
            startTabSwitchFallbackPoll(bundleId: bundleId)
            return
        }

        // passRetained so the C callback holds a strong reference to self.
        // Balanced by takeRetainedValue in stopBrowserAXObserver.
        let refcon = Unmanaged.passRetained(self).toOpaque()

        var observer: AXObserver?
        let result = AXObserverCreate(pid, { (_: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) in
            guard let refcon = refcon else { return }
            // Safe: refcon is a retained pointer — self is guaranteed alive.
            let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let notifName = notification as String
            DispatchQueue.main.async { [weak monitor] in
                guard let monitor = monitor else { return }
                if notifName == kAXFocusedWindowChangedNotification as String {
                    monitor.axFocusedWindowChanged()
                } else {
                    monitor.axTitleDidChange()
                }
            }
        }, &observer)

        guard result == .success, let observer = observer else {
            // Balance the retain since we won't store the observer
            Unmanaged<FocusMonitor>.fromOpaque(refcon).release()
            appDelegate?.postLog("👁️ AXObserver: create failed for pid \(pid) — error \(result.rawValue); falling back to 2s tab-switch poll")
            axObserverActive = false
            startTabSwitchFallbackPoll(bundleId: bundleId)
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Observe focused-window changes on the app element (fires on window switch)
        let winResult = AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        if winResult != .success {
            appDelegate?.postLog("👁️ AXObserver: kAXFocusedWindowChanged add failed — \(winResult.rawValue)")
        }

        // Observe title changes on the focused window element (not the app element).
        // kAXTitleChangedNotification is emitted by the window, and some browsers
        // don't propagate it to the application element.
        observeTitleOnFocusedWindow(observer: observer, appElement: appElement, refcon: refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        axObserver = observer
        axObservedPid = pid
        axBundleId = bundleId
        axObserverActive = true
        // AX observer is our instant-detection path; stop any fallback timer started previously
        // (e.g. from a prior browser that had no accessibility permission).
        stopTabSwitchFallbackPoll()
        appDelegate?.postLog("👁️ AXObserver: started for pid \(pid) (\(bundleId)) — instant tab-switch detection active")
    }

    /// Add kAXTitleChangedNotification on the browser's focused window element.
    private func observeTitleOnFocusedWindow(observer: AXObserver, appElement: AXUIElement, refcon: UnsafeMutableRawPointer) {
        // Remove old window observation if any
        if let oldWindow = axObservedWindow {
            AXObserverRemoveNotification(observer, oldWindow, kAXTitleChangedNotification as CFString)
            axObservedWindow = nil
        }

        var windowRef: AnyObject?
        let attrResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard attrResult == .success, let window = windowRef else {
            debugLog("👁️ AXObserver: no focused window (error \(attrResult.rawValue)) — title observation skipped")
            return
        }

        let windowElement = window as! AXUIElement
        let addResult = AXObserverAddNotification(observer, windowElement, kAXTitleChangedNotification as CFString, refcon)
        if addResult == .success || addResult == .notificationAlreadyRegistered {
            axObservedWindow = windowElement
        } else {
            appDelegate?.postLog("👁️ AXObserver: kAXTitleChanged add on window failed — \(addResult.rawValue)")
        }
    }

    private func stopBrowserAXObserver() {
        axDebounceTimer?.invalidate()
        axDebounceTimer = nil
        axObserverActive = false

        guard let observer = axObserver else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        // Balance the passRetained from startBrowserAXObserver
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        Unmanaged<FocusMonitor>.fromOpaque(refcon).release()

        axObserver = nil
        axObservedPid = 0
        axObservedWindow = nil
        axBundleId = nil
    }

    /// Browser's focused window changed → re-observe title on the new window.
    private func axFocusedWindowChanged() {
        guard let observer = axObserver else { return }
        let appElement = AXUIElementCreateApplication(axObservedPid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        observeTitleOnFocusedWindow(observer: observer, appElement: appElement, refcon: refcon)
        // Also score the new window's tab immediately
        axTitleDidChange()
    }

    /// AXObserver callback: browser title changed.
    /// Debounced — page loads cause rapid title changes ("" → "Loading…" → "Title").
    /// Coalesces into one readAndScoreActiveTab call after 300ms of quiet.
    private func axTitleDidChange() {
        guard let bundleId = axBundleId ?? currentAppBundleId,
              Self.browserBundleIds.contains(bundleId) else { return }

        if awaitingRitual || isOnBreak || justificationInProgress { return }
        guard let manager = scheduleManager, manager.currentTimeState.isWork else { return }

        // Debounce: reset the 300ms timer on each title change
        axDebounceTimer?.invalidate()
        axDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.axDebounceTimer = nil
            // Final stale check before dispatching
            guard let bid = self.currentAppBundleId,
                  Self.browserBundleIds.contains(bid) else { return }
            self.readAndScoreActiveTab(bundleId: bid)
        }
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
            self.tickFocusCelebration(seconds: Self.browserPollInterval)
            self.pushFocusStatsToTimer()
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
        // Don't poll during block start ritual
        if awaitingRitual { return }

        guard currentAppBundleId == bundleId,
              let manager = scheduleManager,
              manager.currentTimeState.isWork else {
            stopBrowserPolling()
            return
        }

        reconcileRedShift()
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

        // Both the "already on block page?" check and the redirect run on the
        // background queue to avoid blocking main thread with AppleScript calls.
        appleScriptQueue.async { [weak self] in
            // Check if already on the blocked page
            if let info = self?.readActiveTabInfo(for: bundleId), info.url.contains("focus-blocked.html") {
                DispatchQueue.main.async {
                    self?.debugLog("👁️ Already on focus-blocked page, skipping redirect")
                }
                return
            }

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

    // MARK: - Red shift Reconciliation

    /// Compute vignette starting intensity based on recovery time since last distraction.
    /// < 60s focus → 1.0 (anti-gaming), 60-180s → linear decay, ≥ 180s → 0.0 (full reset)
    private func vignetteRetriggerIntensity() -> CGGammaValue {
        guard redShiftTriggeredThisBlock, let lastEnd = lastDistractionEndTime else {
            return 0.0 // Never triggered or no timestamp → fresh start
        }
        let recovery = Date().timeIntervalSince(lastEnd)
        if recovery < Self.vignetteMinRecoverySeconds { return 1.0 }
        if recovery >= Self.vignetteFullRecoverySeconds { return 0.0 }
        let range = Self.vignetteFullRecoverySeconds - Self.vignetteMinRecoverySeconds
        return CGGammaValue(1.0 - (recovery - Self.vignetteMinRecoverySeconds) / range)
    }

    /// Reconciliation check: ensure red shift matches current state.
    /// Called on every poll tick and on app-switch evaluation.
    /// Red shift should be ON only when ALL of these are true:
    ///   1. We're in a work block (deep work or focus hours)
    ///   2. redShiftTriggeredThisBlock is true (we already decided to trigger it)
    ///   3. The user is currently on irrelevant content (isCurrentlyIrrelevant)
    /// If any condition is false and red shift is active, restore color.
    private func reconcileRedShift() {
        // Graduated decay: full reset after 180s of sustained focus
        // Only decay if user is NOT currently distracted — otherwise the timer
        // from a brief recovery would expire while still on distracting content
        if redShiftTriggeredThisBlock, !isCurrentlyIrrelevant,
           let lastEnd = lastDistractionEndTime,
           Date().timeIntervalSince(lastEnd) >= Self.vignetteFullRecoverySeconds {
            redShiftTriggeredThisBlock = false
            lastDistractionEndTime = nil
            appDelegate?.postLog("🌫️ Vignette fully decayed — 180s focus recovery complete")
        }

        guard redShiftController?.isActive == true else { return }

        let inWorkBlock = scheduleManager?.currentTimeState.isWork == true
        let shouldBeGray = inWorkBlock && redShiftTriggeredThisBlock && isCurrentlyIrrelevant

        if !shouldBeGray {
            redShiftController?.restoreColor()
            appDelegate?.postLog("🌫️ Reconciler: red shift OFF (work=\(inWorkBlock), triggered=\(redShiftTriggeredThisBlock), irrelevant=\(isCurrentlyIrrelevant))")
            logAssessment(title: currentTarget.isEmpty ? currentAppName : currentTarget, appName: currentAppName,
                         intention: scheduleManager?.currentBlock?.title ?? "",
                         relevant: true, confidence: 0, reason: "Content now relevant — red shift removed",
                         action: "grayscale_off", isEvent: true)
        }
    }

    // MARK: - Floating Timer Stats

    /// Push the live in-session focus percentage to the floating timer widget.
    ///
    /// R6 deleted the old source (EarnedBrowseManager.blockFocusStats) and the
    /// stub that replaced it hardcoded (0, 0), so the pill read "0% focused"
    /// for the whole session. We now derive the % the same way SessionFocusScore
    /// does at session stop — relevant ÷ total qualifying assessments — but from
    /// the in-memory running tally (sessionAssessmentRelevant/Total) instead of
    /// re-reading the relevance_log.jsonl tail, since this fires on every poll
    /// tick / recovery and must stay cheap.
    ///
    /// `samples == 0` (just-started session, nothing scored yet) → the pill
    /// keeps its neutral "Focusing" placeholder rather than an angry "0%".
    ///
    /// Earned minutes: there is no honest live source — the allowance earn rule
    /// grants minutes once, on session stop (AppDelegate.postAllowanceEarn on
    /// .focus→.off), not incrementally. So we pass 0 and the pill suppresses the
    /// earned chip until real data exists (see DeepWorkTimerController.update).
    private func pushFocusStatsToTimer() {
        let samples = sessionAssessmentTotal
        let percent = samples > 0
            ? Int((Double(sessionAssessmentRelevant) / Double(samples) * 100).rounded())
            : 0
        deepWorkTimerController?.update(focusPercent: percent, earnedMinutes: 0, samples: samples)
    }

    // MARK: - Relevance Handling

    private func handleRelevantContent() {
        debugLog("👁️ handleRelevantContent — dismissing overlays")
        cancelGracePeriod()
        stopLingerTimer()

        // Celebrate recovery: flash pill green + track recovery count
        if isCurrentlyIrrelevant && scheduleManager?.currentTimeState.isWork == true {
            blockRecoveryCount += 1
            deepWorkTimerController?.flashRecovery()
            appDelegate?.postLog("💚 Recovery #\(blockRecoveryCount) — focus restored")

            // Track vignette decay timestamp (only when red shift was triggered)
            if redShiftTriggeredThisBlock {
                lastDistractionEndTime = Date()
            }
        }

        isCurrentlyIrrelevant = false
        tabIsOnBlockingPage = false
        blockedOriginalURL = nil
        nudgeController?.dismiss()
        deepWorkTimerController?.dismissDistractionCard()
        overlayController?.dismiss()

        // Restore red shift whenever user is on relevant content (any app, any tab)
        reconcileRedShift()
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

        // Track last relevant browser tab for smart "Back to work".
        // Uses lastScoredURL from the scoring pipeline — no AppleScript needed.
        if let bundleId = currentAppBundleId,
           Self.browserBundleIds.contains(bundleId),
           let url = lastScoredURL,
           !url.contains("focus-blocked.html") {
            lastRelevantTabURL = url
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

        // Check AI override — enforcement paused during active override
        if isOverrideActive { return }

        let isBrowser = currentAppBundleId.map { Self.browserBundleIds.contains($0) } ?? false
        guard let timeState = scheduleManager?.currentTimeState, timeState.isWork else { return }
        let blockType = scheduleManager?.currentBlock?.blockType ?? .focusHours

        // Increment cumulative distraction counter (always — even for extension-handled sites)
        cumulativeDistractionSeconds += Self.browserPollInterval

        // Reset consecutive focus streak on distraction
        resetFocusStreak()

        // Mark as irrelevant so reconciler maintains red shift/vignette across poll cycles.
        // Must be set for ALL irrelevant content (not just extension-handled social media),
        // otherwise reconcileRedShift() tears down the vignette on the next poll.
        isCurrentlyIrrelevant = true

        appDelegate?.postLog("👁️ Distraction: \(Int(cumulativeDistractionSeconds))s [\(blockType.rawValue)]")

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

    /// Deep Work aggressive browser enforcement:
    /// - Immediate: blocking overlay on tab switch to new irrelevant content
    /// - 20s cumulative: auto-redirect to last relevant URL + red shift starts
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

        // Track current target — show overlay on switch to NEW irrelevant content.
        // Check both hostname (targetKey) and page title (displayName) so navigating
        // within the same domain (e.g. reddit.com/r/a → reddit.com/r/b) is detected.
        if currentTargetKey != targetKey || currentTarget != displayName {
            nudgeShownForCurrentContent = false
            currentTarget = displayName
            currentTargetKey = targetKey

            // Show full-screen blocking overlay immediately on tab switch
            if isEnforcementEnabled(.blockingOverlay) && !(overlayController?.isShowing ?? false) {
                let focusDuration = computeFocusDurationMinutes()
                showOverlay(intention: intention,
                           reason: reason.isEmpty ? "Not related to your task" : reason,
                           focusDurationMinutes: focusDuration,
                           isNoPlan: false,
                           displayName: displayName)
                return
            }
        }

        // Skip cumulative enforcement while overlay is showing
        if overlayController?.isShowing == true { return }

        // Check cumulative thresholds in descending order (highest priority first)

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

        // 20s: Auto-redirect + red shift
        if cumulativeDistractionSeconds >= Self.deepWorkRedirectThreshold && !deepWorkRedirectFired {
            deepWorkRedirectFired = true
            if isEnforcementEnabled(.autoRedirect) {
                deepWorkAutoRedirect()
                return
            }
        }

        // 10s: First nudge (backup if overlay is disabled)
        if cumulativeDistractionSeconds >= Self.deepWorkNudgeThreshold && !nudgeShownForCurrentContent {
            nudgeShownForCurrentContent = true
            if isEnforcementEnabled(.nudge) {
                showNudgeForContent(intention: intention, displayName: displayName, escalated: false)
            }
        }
    }

    /// Deep Work: cumulative threshold reached → auto-redirect tab to last relevant URL + start red shift.
    private func deepWorkAutoRedirect() {
        guard scheduleManager?.currentBlock?.blockType == .deepWork else { return }

        // One-time tooltip for redirect
        if !hasSeenTooltip(.redirect) {
            markTooltipSeen(.redirect)
        }

        nudgeController?.dismiss()

        let intention = scheduleManager?.currentBlock?.title ?? ""
        let targetKey = currentTargetKey

        // Add to redirected set for instant redirect on revisit
        deepWorkRedirectedSites.insert(targetKey)

        // Start red shift at the second notification (the redirect)
        if !(redShiftController?.isActive ?? false) && isEnforcementEnabled(.screenRedShift) {
            redShiftController?.startRedShift(fromIntensity: vignetteRetriggerIntensity())
            redShiftTriggeredThisBlock = true
            appDelegate?.postLog("🌫️ Deep Work: red shift started on redirect")
            logAssessment(title: currentTarget, appName: currentAppName, intention: scheduleManager?.currentBlock?.title ?? "",
                         relevant: false, confidence: 0, reason: "Deep Work auto-redirect red shift",
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
        // Use lastScoredURL for the original URL — avoids blocking main thread.
        // readActiveTabInfo was already called during scoring; lastScoredURL is current.
        let originalURL = lastScoredURL
        if let url = originalURL, url.contains("focus-blocked.html") { return }

        blockActiveTab(intention: intention, pageTitle: displayName,
                      hostname: targetKey, originalURL: originalURL)

        cumulativeDistractionSeconds = 0  // Reset after redirect
        appDelegate?.postLog("👁️ Deep work: redirected tab to focus-blocked page")
    }

    // MARK: - Focus Hours Browser Enforcement

    /// Focus Hours browser enforcement:
    /// - Immediate: blocking overlay on tab switch to new irrelevant content
    /// - 30s: Red shift starts (30s fade to dark)
    /// - 10s+: Level 1 nudges (backup if overlay disabled)
    /// - 240s: Warning nudge (red, "intervention in 60s")
    /// - 300s: Intervention overlay (60s mandatory, escalating)
    /// Between interventions: Level 2 persistent nudges (re-show on each poll if dismissed)
    private func handleFocusHoursBrowserIrrelevance(targetKey: String, displayName: String,
                                                     intention: String, confidence: Int, reason: String) {
        // Show overlay on switch to NEW irrelevant content (same pattern as Deep Work)
        if currentTargetKey != targetKey || currentTarget != displayName {
            nudgeShownForCurrentContent = false
            currentTarget = displayName
            currentTargetKey = targetKey

            if isEnforcementEnabled(.blockingOverlay) && !(overlayController?.isShowing ?? false) {
                let focusDuration = computeFocusDurationMinutes()
                showOverlay(intention: intention,
                           reason: reason.isEmpty ? "Not related to your task" : reason,
                           focusDurationMinutes: focusDuration,
                           isNoPlan: false,
                           displayName: displayName)
                return
            }
        } else {
            currentTarget = displayName
            currentTargetKey = targetKey
        }

        // Skip cumulative enforcement while overlay is showing
        if overlayController?.isShowing == true { return }

        // Update floating timer distraction dot (red) for focus hours too
        deepWorkTimerController?.update(isDistracted: true)
        pushFocusStatsToTimer()

        // ── Red shift: instant if already triggered this block, otherwise at 30s ──
        let shouldRedShift = redShiftTriggeredThisBlock
            || cumulativeDistractionSeconds >= Self.focusRedShiftThreshold
        if shouldRedShift && !(redShiftController?.isActive ?? false) && isEnforcementEnabled(.screenRedShift) {
            redShiftController?.startRedShift(fromIntensity: vignetteRetriggerIntensity())
            redShiftTriggeredThisBlock = true
            appDelegate?.postLog("🌫️ Focus Hours: red shift at \(Int(cumulativeDistractionSeconds))s\(redShiftTriggeredThisBlock ? " (re-trigger)" : "")")
            logAssessment(title: displayName, appName: currentAppName, intention: intention,
                         relevant: false, confidence: 0, reason: "Focus Hours red shift at \(Int(cumulativeDistractionSeconds))s",
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

    /// Enforce a BlockRuleEnforcer-driven block (rule active outside a focus
    /// session). Shows the blocking overlay with a copy that names the rule
    /// rather than the user's focus intention. Mirrors the distractingApp branch
    /// for during-session enforcement but skips the parts that require an active
    /// block (recordAssessment, red shift that's coupled to focus minutes, etc).
    private func handleStandaloneBlockedApp(app: NSRunningApplication, bundleId bid: String) {
        let appName = app.localizedName ?? bid
        debugLog("👁️🛡 \(appName) blocked by active BlockingProfile rule (no session) — direct enforcement")
        stopBrowserPolling()
        stopWorkTickTimer()
        stopNeutralTickTimer()
        logAssessment(
            title: appName,
            intention: "",
            relevant: false,
            confidence: 100,
            reason: "Blocked by your rule",
            action: "overlay",
            isEvent: true
        )
        // Update transient state minimally (no grace, no streak math — there's
        // no focus session to score against).
        cancelGracePeriod()
        warnedTargets.insert(bid)
        currentTarget = appName
        currentTargetKey = bid
        isCurrentlyIrrelevant = true
        deepWorkTimerController?.update(isDistracted: true)
        // Show blocking overlay. Rules are explicit user intent, so always
        // show the overlay regardless of block-type enforcement settings.
        showOverlay(
            intention: "Active block rule",
            reason: "App blocked by rule",
            focusDurationMinutes: 0,
            isNoPlan: false,
            displayName: appName
        )
    }

    // MARK: - R5: Allowance Spend Metering (out-of-session ⏳ targets)
    //
    // Sessions treat ⏳ as 🚫 (resolver limit gate). OUTSIDE sessions, time on
    // a ⏳ app/site spends the shared daily allowance: a 5s tick meters the
    // frontmost app / active browser tab against the limited rule sets,
    // accumulates seconds, and POSTs whole-minute batches (≥30s apart) via
    // RuleStore.spend. When server-available minus locally-pending hits zero,
    // AllowanceBalance.isExhausted flips and the resolver gates ⏳ targets as
    // blocked — WebsiteBlocker's 0.5s sweep walls limited SITES (the
    // focus-blocked.html allowance variant) and this meter walls limited APPS
    // with the blocking overlay. The pill shows "⏳ N min" while relevant.

    private var allowanceMeterTimer: Timer?
    private static let allowanceMeterInterval: TimeInterval = 5.0
    private static let allowanceSpendPostThrottle: TimeInterval = 30.0
    private var allowancePendingSpendSeconds: Double = 0
    private var allowanceLastSpendPostAt: Date?
    private var allowanceSpendPostInFlight = false
    private var allowanceTabReadInFlight = false

    /// Start the 5s metering tick. Idempotent. Called from AppDelegate after
    /// focusModeController is wired. Also subscribes to .allowanceDidChange so
    /// the pill balance updates the moment server truth lands.
    func startAllowanceMeter() {
        guard allowanceMeterTimer == nil else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAllowanceDidChange),
            name: .allowanceDidChange, object: nil
        )
        let t = Timer.scheduledTimer(withTimeInterval: Self.allowanceMeterInterval, repeats: true) { [weak self] _ in
            self?.allowanceMeterTick()
        }
        t.tolerance = 1.0
        RunLoop.main.add(t, forMode: .common)
        allowanceMeterTimer = t
        appDelegate?.postLog("⏳ Allowance meter started (\(Int(Self.allowanceMeterInterval))s tick)")
    }

    @objc private func handleAllowanceDidChange() {
        updateAllowancePill()
    }

    /// One-shot diagnostic so a silent meter is debuggable from the log.
    private var allowanceMeterLoggedGates = false

    private func allowanceMeterTick() {
        // Sessions: ⏳ acts as 🚫 via the resolver — never spend in-session.
        guard focusModeController?.isOn != true else {
            updateAllowancePill()
            return
        }
        let sets = RuleEnforcementMirror.shared.activeSets()
        guard !sets.limitedApps.isEmpty || !sets.limitedSites.isEmpty else {
            updateAllowancePill()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier else {
            updateAllowancePill()
            return
        }
        if !allowanceMeterLoggedGates {
            allowanceMeterLoggedGates = true
            appDelegate?.postLog("⏳ Meter gates: limitedSites=\(sets.limitedSites.count) limitedApps=\(sets.limitedApps.count) frontmost=\(bid) isBrowser=\(Self.browserBundleIds.contains(bid))")
        }

        // Limited APP frontmost → meter directly (✅ rule beats ⏳ per the
        // one precedence; goal lists don't apply out of session). Once
        // exhausted, wall instead of metering — server clamps spends at zero
        // anyway, so further posts would be pure waste.
        if sets.limitedApps.contains(bid), !sets.allowedApps.contains(bid) {
            if AllowanceBalance.shared.isExhausted {
                handleAllowanceExhaustedApp(app: app, bundleId: bid)
                updateAllowancePill()
            } else {
                registerAllowanceUse(target: bid)
                if AllowanceBalance.shared.isExhausted {
                    handleAllowanceExhaustedApp(app: app, bundleId: bid)
                }
            }
            return
        }

        // Browser frontmost → read the active tab (AppleScript on the
        // background queue; never on main per CLAUDE.md bug #9) and meter if
        // its host matches a limited site. The wall-at-zero for sites is
        // owned by WebsiteBlocker's 0.5s sweep, not this meter.
        if Self.browserBundleIds.contains(bid), !allowanceTabReadInFlight {
            allowanceTabReadInFlight = true
            appleScriptQueue.async { [weak self] in
                let info = self?.readActiveTabInfo(for: bid)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.allowanceTabReadInFlight = false
                    guard self.focusModeController?.isOn != true,
                          let host = info?.hostname.lowercased(),
                          EnforcementResolver.matches(host, sets.limitedSites),
                          !EnforcementResolver.matches(host, sets.allowedSites),
                          // At zero, the sweep owns the wall — don't keep
                          // metering a tab that's about to be redirected.
                          !AllowanceBalance.shared.isExhausted else {
                        self.updateAllowancePill()
                        return
                    }
                    self.registerAllowanceUse(target: host)
                }
            }
            return
        }
        updateAllowancePill()
    }

    /// Targets we've already announced metering for (one log line per target
    /// per app run — the per-tick detail stays behind debugLog).
    private var allowanceMeterAnnouncedTargets: Set<String> = []

    /// Accumulate one tick of ⏳ usage and post whole-minute batches.
    private func registerAllowanceUse(target: String) {
        allowancePendingSpendSeconds += Self.allowanceMeterInterval
        AllowanceBalance.shared.recordLimitedUse()
        AllowanceBalance.shared.setPendingSpendSeconds(allowancePendingSpendSeconds)
        if !allowanceMeterAnnouncedTargets.contains(target) {
            allowanceMeterAnnouncedTargets.insert(target)
            appDelegate?.postLog("⏳ Metering started on \(target) (allowance spends while it's frontmost)")
        }
        debugLog("⏳ Metering \(target): pending=\(Int(allowancePendingSpendSeconds))s, available(after pending)=\(AllowanceBalance.shared.availableMinutesAfterPending.map(String.init) ?? "unknown")")
        maybePostAllowanceSpend()
        updateAllowancePill()
    }

    private func maybePostAllowanceSpend() {
        guard !allowanceSpendPostInFlight else { return }
        let wholeMinutes = Int(allowancePendingSpendSeconds / 60.0)
        guard wholeMinutes >= 1 else { return }
        if let last = allowanceLastSpendPostAt,
           Date().timeIntervalSince(last) < Self.allowanceSpendPostThrottle { return }
        allowanceSpendPostInFlight = true
        allowanceLastSpendPostAt = Date()
        appDelegate?.postLog("⏳ Posting allowance spend: \(wholeMinutes) min")
        Task { @MainActor [weak self] in
            let fresh = await RuleStore.shared.spend(minutes: wholeMinutes)
            guard let self else { return }
            self.allowanceSpendPostInFlight = false
            if let fresh {
                self.allowancePendingSpendSeconds = max(0, self.allowancePendingSpendSeconds - Double(wholeMinutes * 60))
                AllowanceBalance.shared.setPendingSpendSeconds(self.allowancePendingSpendSeconds)
                self.appDelegate?.postLog("⏳ Spend posted: \(fresh.spentApplied ?? wholeMinutes) min applied — available now \(fresh.availableMinutes)")
            } else {
                // Offline / server error: keep the pending seconds local so
                // nothing is lost; throttle stamp above prevents hammering.
                self.appDelegate?.postLog("⚠️ Allowance spend post failed — keeping \(Int(self.allowancePendingSpendSeconds))s pending locally")
            }
            self.updateAllowancePill()
        }
    }

    /// Wall a ⏳ app when the allowance is exhausted (out-of-session). The
    /// earn path lives in the copy: focusing refills the balance.
    private func handleAllowanceExhaustedApp(app: NSRunningApplication, bundleId bid: String) {
        guard overlayController?.isShowing != true else { return }
        let appName = app.localizedName ?? bid
        let rate = AllowanceBalance.shared.earnRate
        let earnExample = max(1, 30 / max(1, rate))
        appDelegate?.postLog("⏳ Allowance empty — walling limited app \(appName)")
        stopBrowserPolling()
        stopWorkTickTimer()
        stopNeutralTickTimer()
        logAssessment(
            title: appName,
            intention: "",
            relevant: false,
            confidence: 100,
            reason: "Allowance empty (limited app)",
            action: "overlay",
            isEvent: true
        )
        cancelGracePeriod()
        currentTarget = appName
        currentTargetKey = bid
        showOverlay(
            intention: "Allowance empty",
            reason: "Focus 30 min to earn \(earnExample) more",
            focusDurationMinutes: 0,
            isNoPlan: false,
            displayName: appName
        )
    }

    /// Show/refresh/dismiss the "⏳ N min" pill. Shown only out-of-session
    /// when the balance is interesting (a ⏳ target was used in the last
    /// 15 min, or the balance dipped below the daily base). Never stomps
    /// another pill mode.
    private func updateAllowancePill() {
        guard let controller = deepWorkTimerController else { return }
        let bal = AllowanceBalance.shared
        let available = bal.availableMinutesAfterPending
        let inSession = focusModeController?.isOn == true
        let interesting = bal.usedLimitedRecently
            || (available != nil && bal.baseMinutes > 0 && available! < bal.baseMinutes)
        if !inSession, let available, interesting {
            if controller.isShowing {
                if controller.viewModel?.mode == .allowanceBalance {
                    controller.showAllowanceBalance(minutes: available)
                }
                // Another mode owns the pill — leave it alone.
            } else {
                controller.showAllowanceBalance(minutes: available)
            }
        } else if controller.viewModel?.mode == .allowanceBalance {
            controller.dismiss()
        }
    }

    /// Show the full-screen intervention overlay with a random game.
    /// Duration escalates: 60s (1st), 90s (2nd), 120s (3rd+).
    private func showInterventionOverlay(intention: String, displayName: String, duration: Int = 60) {
        // Show one-time tooltip for first intervention
        if !hasSeenTooltip(.intervention) {
            markTooltipSeen(.intervention)
        }
        let distractionMinutes = Int(cumulativeDistractionSeconds / 60)
        // R6: per-block focus stats source deleted (was zeros at runtime anyway).
        let focusScore = 0
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
        // Level 1 (non-escalated, non-warning): use in-pill distraction card instead of external nudge toast
        if !escalated && !warning {
            let explanation: String? = hasSeenTooltip(.nudge) ? nil :
                "This is a gentle reminder to check if you're still on track."
            if explanation != nil { markTooltipSeen(.nudge) }
            // Update override state in pill
            let blockId = scheduleManager?.currentBlock?.id ?? ""
            let partnerRequired = overridePartnerApprovalRequired && hasConfiguredPartner
            deepWorkTimerController?.viewModel?.partnerApprovalRequired = partnerRequired
            // R6: override budget engine deleted — 0, as it was at runtime.
            deepWorkTimerController?.viewModel?.overridesRemaining = 0
            deepWorkTimerController?.showDistractionCard(explanation: explanation)
        } else {
            // Escalated / warning: use external nudge toast below the pill
            setupNudgeCallbacks()
            nudgeController?.pillWindow = deepWorkTimerController?.timerWindow
            nudgeController?.showNudge(
                intention: intention,
                appOrPage: displayName,
                escalated: escalated,
                distractionMinutes: distractionMinutes,
                warning: warning
            )
        }
        // Log enforcement event for popover visibility
        let browserName = currentAppBundleId.flatMap { Self.browserAppNames[$0] } ?? ""
        let reason: String
        if warning {
            reason = "Warning nudge (intervention in 60s)"
        } else if escalated {
            reason = "Level 2 nudge (persistent)"
        } else {
            reason = "Level 1 nudge (in-pill)"
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
            self?.justificationInProgress = false
            self?.appDelegate?.postLog("💬 Nudge: 'Got it'")
            // Don't clear isCurrentlyIrrelevant — user acknowledged but content is still irrelevant
        }
        nudgeController?.onThisIsRelevant = { [weak self] justification in
            self?.justificationInProgress = false
            self?.handleJustification(text: justification)
        }
        nudgeController?.viewModel?.onOverrideAI = { [weak self] in
            self?.handlePillOverrideAI()
        }
        nudgeController?.viewModel?.onVerifyOverrideCode = { [weak self] code, requestId in
            self?.verifyOverrideCode(code, requestId: requestId)
        }
        // Update override state in nudge
        let partnerRequired = overridePartnerApprovalRequired && hasConfiguredPartner
        nudgeController?.viewModel?.partnerApprovalRequired = partnerRequired
        // R6: override budget engine deleted — 0, as it was at runtime.
        nudgeController?.viewModel?.overridesRemaining = 0
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
            // Re-run relevance check with justification as additional context.
            // FIX-11: enrich whichever source is active (per-goal intentText preferred,
            // legacy block.description as fallback) so the model sees consistent context.
            var goalIntentText = ""
            var aiEnabled = true
            if let intentionId = block.intentionId,
               let intention = await IntentionStore.shared.intention(id: intentionId) {
                goalIntentText = intention.intentText ?? ""
                aiEnabled = intention.aiScoringEnabled
            }
            let baseDescription = goalIntentText.isEmpty ? block.description : goalIntentText
            let enrichedDescription = "\(baseDescription)\nUser explains why this is relevant: \(text)"
            let result = await scorer.scoreRelevance(
                pageTitle: displayName,
                intention: block.title,
                intentionDescription: enrichedDescription,
                intentText: "",                        // already merged into intentionDescription above
                aiScoringEnabled: aiEnabled,
                profile: block.ignoreProfile ? "" : manager.profile,
                dailyPlan: manager.todaySchedule?.dayNotes ?? ""
            )

            await MainActor.run {
                if result.relevant {
                    // AI accepted
                    if blockType == .deepWork {
                        // Deep Work: shorter 3-min suppression, NO permanent whitelist
                        self.suppressedUntil[targetKey] = Date().addingTimeInterval(Self.deepWorkSuppressionSeconds)
                        // Pause red shift during suppression
                        self.redShiftController?.restoreColor()
                        self.deepWorkTimerController?.update(isDistracted: false)
                        self.appDelegate?.postLog("💬 Deep Work justification ACCEPTED for \"\(displayName)\" — 3 min suppression (no whitelist)")
                        self.logAssessment(title: displayName, appName: self.currentAppName, intention: block.title,
                                          relevant: true, confidence: 0, reason: "Justification accepted — red shift paused",
                                          action: "grayscale_off", isEvent: true)
                    } else {
                        // Focus Hours: scorer whitelist (page-title-specific, not hostname-wide)
                        scorer.approvePageTitle(displayName, for: block.title)
                    }
                    self.handleRelevantContent()
                    // Record work tick since the content is now considered relevant
                    self.tickFocusCelebration(seconds: Self.browserPollInterval)
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
        overlayController?.onApproveForBlock = { [weak self] in
            self?.approveCurrentOverlay()
        }
        overlayController?.onMarkWrong = { [weak self] in
            self?.markCurrentOverlayAsWrong()
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
        let overlayName = displayName ?? currentTarget
        logAssessment(
            title: overlayName, appName: browserName.isEmpty ? overlayName : browserName,
            intention: intention, relevant: false, confidence: 0,
            reason: isNoPlan ? "Blocking overlay (no plan)" : "Blocking overlay",
            action: "blocked", isEvent: true
        )

        // Capture trigger handles for Why? / approve / mark-wrong affordances.
        // Use the event row we just logged as the anchor for "This was wrong".
        // Capture the full entry (not just the timestamp) so mark-wrong still works
        // even if the row has been evicted from the in-memory log by the time the user clicks.
        overlayTriggerEntry = relevanceLog.last
        overlayDisplayName = overlayName
        // Pull the most recent non-event assessment for this target to surface real confidence
        // (the event row we just wrote has confidence=0; the scoring row before it has the real score).
        let lastScored = relevanceLog.last(where: { $0.title == overlayName && !$0.isEvent })
        let triggerConfidence = lastScored?.confidence ?? 0
        let triggerPath: ScoringPath? = lastScored?.path
        let triggerOCRExcerpt: String? = lastScored?.ocrExcerpt
        let triggerTrace: [TraceStep] = lastScored?.trace ?? []
        // Use lastScoredURL from the scoring pipeline — no AppleScript needed.
        var triggerURL: String? = nil
        if let bid = currentAppBundleId, Self.browserBundleIds.contains(bid),
           let url = lastScoredURL, !url.isEmpty {
            triggerURL = url
        }
        overlayTriggerURL = triggerURL

        let canSnooze30 = (scheduleManager?.snoozeCount == 0) && isNoPlan
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
                displayName: displayName,
                confidence: triggerConfidence,
                urlString: triggerURL,
                path: triggerPath,
                ocrExcerpt: triggerOCRExcerpt,
                trace: triggerTrace
            )
        }
    }

    /// Plan-first prompt: when Focus Mode is off AND no block is current AND the user has
    /// the planFirstPrompt setting enabled, show the full-screen noPlan overlay so the user
    /// is FORCED to plan / start a block / snooze (this is the aggressive version the user
    /// remembered — covers the screen, doesn't politely sit in the corner). Restores the
    /// trigger that lived here before the April 2026 TimeState consolidation refactor.
    ///
    /// Cheap guard chain — bails out fast in the common steady-state cases so it's safe to
    /// call from every evaluateApp tick.
    private func maybeShowNoPlanPill(currentApp: NSRunningApplication) {
        // User-controllable feature toggle. Default true; if the key is missing
        // (fresh install) UserDefaults returns false, so we treat that as enabled too via the
        // register call in AppDelegate.
        guard UserDefaults.standard.bool(forKey: "planFirstPromptEnabled") else { return }

        // Re-entrancy: overlay already showing — don't re-trigger.
        if overlayController?.isShowing == true { return }
        // Pill in noPlan mode is also a valid "already prompting" state.
        if deepWorkTimerController?.viewModel?.mode == .noPlan { return }

        // Don't pop the prompt while the user is INSIDE Intentional itself —
        // they're already engaging with the planning surface.
        let bid = currentApp.bundleIdentifier
        if bid == "com.arayan.intentional" || bid == Bundle.main.bundleIdentifier { return }

        // Don't pop during other overlay-driven flows.
        if interventionController?.isShowing == true { return }
        if awaitingRitual { return }

        // Snooze respected — user asked for 30 min of quiet.
        if let until = noPlanSnoozeUntil, Date() < until { return }

        // Safety net — caller already gated on focusModeController.isOn != true, but defend
        // against a future caller forgetting that contract.
        if focusModeController?.isOn == true { return }

        // The whole point of the prompt is "you don't have a block scheduled right now."
        guard let manager = scheduleManager, manager.currentBlock == nil else { return }

        // Compose a reason string for the overlay header. Mirror the CardState
        // logic the deleted trigger used so the overlay can show context-aware copy:
        //   no schedule today           → "No plan for today yet"
        //   all blocks done + 9pm+      → "Day complete"
        //   gap (mid-day, between)      → "No block scheduled right now"
        let hasScheduleToday = (manager.todaySchedule?.blocks.isEmpty == false)
        let remaining = manager.remainingBlocks()
        let allDone = hasScheduleToday && remaining.isEmpty
        let hour = Calendar.current.component(.hour, from: Date())
        let reason: String
        if !hasScheduleToday {
            reason = "No plan for today yet"
        } else if allDone && hour >= 21 {
            reason = "Day complete"
        } else {
            reason = "No block scheduled right now"
        }

        appDelegate?.postLog("📋 Plan-first prompt: showing full-screen noPlan overlay (reason: \(reason))")
        // Wire the overlay handlers — these mirror the existing button callbacks
        // already used by the pill flow so the dashboard still gets opened, quick
        // blocks still get created, snooze still respects the 30-min cap, etc.
        overlayController?.onPlanDay = { [weak self] in self?.handlePlanDay() }
        overlayController?.onStartQuickBlock = { [weak self] (title, duration, isFree) in
            self?.handleStartQuickBlock(title: title, durationMinutes: duration, isFree: isFree)
        }
        overlayController?.onSnooze = { [weak self] in self?.handleNoPlanSnooze() }
        overlayController?.onBackToWork = { [weak self] in self?.handleOpenIntentional() }

        // Call into FocusMonitor.showOverlay so existing trace logging /
        // logAssessment book-keeping continues to fire.
        showOverlay(
            intention: "",
            reason: reason,
            focusDurationMinutes: 0,
            isNoPlan: true,
            displayName: nil
        )
    }

    /// Approve the currently-overlaid content for the current block (wires to RelevanceScorer).
    /// Dismisses the overlay and resumes normal evaluation (same flow as Back to work).
    func approveCurrentOverlay() {
        guard let block = scheduleManager?.currentBlock,
              let name = overlayDisplayName, !name.isEmpty else {
            overlayController?.dismiss()
            return
        }
        relevanceScorer?.approvePageTitle(name, for: block.title)
        appDelegate?.postLog("👍 User approved current overlay target: \"\(name)\" for \"\(block.title)\"")
        // Dismiss overlay + navigate back (same flow as Back to work).
        handleOverlayAction(action: "back_to_work", reason: nil)
    }

    /// Mark the assessment row that triggered the current overlay as userOverride=true.
    /// Also appends a correction row to the JSONL so the signal persists across restarts.
    func markCurrentOverlayAsWrong() {
        guard var trigger = overlayTriggerEntry else {
            appDelegate?.postLog("🚩 markCurrentOverlayAsWrong: no trigger entry captured")
            overlayController?.dismiss()
            return
        }
        trigger.userOverride = true
        // If the row is still in the in-memory log, mutate in place so the dashboard
        // sees the flag on its next poll.
        if let idx = relevanceLog.firstIndex(where: { $0.timestamp == trigger.timestamp }) {
            relevanceLog[idx].userOverride = true
        }
        // Persist a correction row regardless of whether the original was evicted from
        // the in-memory log. handleGetBlockAssessments dedupes by timestamp, so this
        // won't double up in the UI.
        persistAssessment(trigger)
        appDelegate?.postLog("🚩 User marked assessment wrong: \"\(trigger.title)\"")

        // Feed the correction into the learned-override store so this host can be
        // promoted to "always OCR-verify" after 3+ corrections in the last 30 days.
        if !trigger.hostname.isEmpty {
            relevanceScorer?.recordUserOverride(host: trigger.hostname)
        }

        overlayController?.dismiss()
    }

    /// Handle "Open Intentional" — open the main app window and dismiss overlay.
    private func handleOpenIntentional() {
        overlayController?.dismiss()
        appDelegate?.showMainWindow()
        stopLingerTimer()
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 'Open Intentional' — opening main window")
    }

    /// Handle "Plan My Day" — open the dashboard.
    private func handlePlanDay() {
        overlayController?.dismiss()
        appDelegate?.showDashboardPage("today")
        stopLingerTimer()
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 'Plan My Day' — opening dashboard")
    }

    /// Handle "Plan My Day" from noPlan pill card.
    private func handleNoPlanPlanDay() {
        deepWorkTimerController?.dismiss()
        appDelegate?.showDashboardPage("today")
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 noPlan pill: opening dashboard")
    }

    /// Handle "Schedule Now" from gap pill card — open dashboard with new block prefilled.
    private func handleScheduleNow() {
        deepWorkTimerController?.dismiss()
        appDelegate?.showMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.appDelegate?.mainWindowController?.openScheduleWithNewBlock()
        }
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 noPlan pill: 'Schedule Now' — opening dashboard with new block")
    }

    /// Handle "Snooze 30 min" from noPlan pill card.
    private func handleNoPlanSnooze() {
        deepWorkTimerController?.dismiss()
        let accepted = scheduleManager?.snooze() ?? false
        isCurrentlyIrrelevant = false
        if accepted {
            noPlanSnoozeUntil = Date().addingTimeInterval(30 * 60)
        }
        appDelegate?.postLog("💬 noPlan pill: 'Snooze 30 min' — accepted: \(accepted)")
    }

    /// Handle quick block creation from noPlan pill card.
    private func handleQuickBlockFromPill(type: ScheduleManager.BlockType, duration: Int) {
        let title: String
        switch type {
        case .deepWork: title = "Deep Focus"
        case .focusHours: title = "Focus"
        }
        deepWorkTimerController?.dismiss()
        // Spec 2: .freeTime removed; isFree always false for explicit quick blocks.
        handleStartQuickBlock(title: title, durationMinutes: duration, isFree: false, blockType: type)
    }

    /// Handle minimize (−) from gap/doneForDay pill card — hide to dock + snooze 30 min.
    private func handleNoPlanDismiss() {
        deepWorkTimerController?.minimize()
        noPlanSnoozeUntil = Date().addingTimeInterval(30 * 60)
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 noPlan pill: minimized to dock — snoozed 30 min")
    }

    /// Handle quick block creation from the unplanned overlay.
    private func handleStartQuickBlock(title: String, durationMinutes: Int, isFree: Bool, blockType: ScheduleManager.BlockType? = nil) {
        let calendar = Calendar.current
        let now = Date()
        let startHour = calendar.component(.hour, from: now)
        let startMinute = calendar.component(.minute, from: now)
        let endDate = now.addingTimeInterval(TimeInterval(durationMinutes * 60))
        let endHour = calendar.component(.hour, from: endDate)
        let endMinute = calendar.component(.minute, from: endDate)

        // Spec 2: .freeTime removed; isFree=true legacy callers map to .focusHours (no enforcement).
        let resolvedBlockType: ScheduleManager.BlockType = blockType ?? .focusHours
        _ = isFree  // unused now; retained in signature for legacy callers

        let block = ScheduleManager.FocusBlock(
            id: UUID().uuidString,
            title: title,
            description: "",
            startHour: startHour,
            startMinute: startMinute,
            endHour: endHour,
            endMinute: endMinute,
            blockType: resolvedBlockType
        )

        scheduleManager?.addBlock(block)
        overlayController?.dismiss()
        isCurrentlyIrrelevant = false
        appDelegate?.postLog("💬 Quick block created: \"\(title)\" (\(durationMinutes) min, type: \(resolvedBlockType.rawValue))")
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
            // Deep Work native app: show full blocking overlay + start red shift
            if !(redShiftController?.isActive ?? false) && isEnforcementEnabled(.screenRedShift) {
                redShiftController?.startRedShift(fromIntensity: vignetteRetriggerIntensity())
                redShiftTriggeredThisBlock = true
                appDelegate?.postLog("🌫️ Deep Work: red shift started on native app overlay")
                logAssessment(title: pending.displayName, appName: currentAppName, intention: pending.intention,
                             relevant: false, confidence: 0, reason: "Deep Work native app overlay red shift",
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
              manager.currentTimeState.isWork || manager.currentTimeState == .off,
              let bundleId = currentAppBundleId,
              Self.browserBundleIds.contains(bundleId) else { return }

        if let until = suppressedUntil[currentTargetKey], Date() < until { return }

        let intention = scheduleManager?.currentBlock?.title ?? "Plan your day"
        // Use lastScoredURL — avoids blocking main thread with AppleScript.
        let originalURL = lastScoredURL
        blockActiveTab(intention: intention, pageTitle: currentTarget, hostname: currentTargetKey, originalURL: originalURL)
        appDelegate?.postLog("👁️ Linger expired — blocked \(currentTarget)")
    }

    // MARK: - Overlay User Actions (called by native overlay)

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

    // MARK: - Background Audio Muting

    /// Mute all background distracting audio sources (browser tabs + apps).
    private func muteBackgroundDistractingAudio() {
        pauseDistractingApps()
        debugLog("🔇 Background audio: muted distracting sources")
    }

    /// Iterate running apps, pause any that are user-configured as distracting.
    private func pauseDistractingApps() {
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            guard let bid = app.bundleIdentifier,
                  distractingAppBundleIds.contains(bid),
                  bid != currentAppBundleId else { continue }
            pauseAppViaAppleScript(bundleId: bid, appName: app.localizedName ?? bid)
        }
    }

    /// Send AppleScript pause to a specific app.
    private func pauseAppViaAppleScript(bundleId: String, appName: String) {
        let script: String
        switch bundleId {
        case "com.spotify.client":
            script = "tell application \"Spotify\" to pause"
        case "com.apple.Music":
            script = "tell application \"Music\" to pause"
        case "com.apple.TV":
            script = "tell application \"TV\" to pause"
        case "com.apple.Podcasts":
            script = "tell application \"Podcasts\" to pause"
        default:
            return
        }
        appleScriptQueue.async { [weak self] in
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                if let err = error {
                    self?.debugLog("🔇 Failed to pause \(appName): \(err)")
                } else {
                    self?.debugLog("🔇 Paused \(appName) via AppleScript")
                }
            }
        }
    }

    deinit {
        stop()
    }
}

// MARK: - Context-switching overlay delegate

extension FocusMonitor: SwitchOverlayDelegate {
    func switchOverlayDidTapBackToWork() {
        guard let coord = switchCoordinator, let pending = pendingSwitchTarget else {
            appDelegate?.postLog("🎯 Back-to-work tapped but no pending target; dismissing")
            switchOverlayController?.dismiss()
            pendingSwitchTarget = nil
            return
        }
        // Simplified return policy: always go back to whatever target was frontmost right before
        // the intercepted switch. Prefer the prior tab URL if we were in a browser, else the prior
        // app bundle id. Skips the coordinator's known-target/dwell heuristic entirely.
        let rawPriorApp = priorAppBundleIdBeforeSwitch
        let rawPriorURL = priorTabURLBeforeSwitch
        let priorAppCandidate: String?
        if let p = rawPriorApp, !p.isEmpty, p != "com.arayan.intentional" {
            priorAppCandidate = p
        } else {
            priorAppCandidate = nil
        }
        let fallbackApp: String?
        if priorAppCandidate == nil,
           let last = lastNonIntentionalAppBundleId,
           !last.isEmpty,
           last != pending.bundleId {
            fallbackApp = last
        } else {
            fallbackApp = nil
        }

        var returnTarget: SwitchTarget? = nil
        var branch: String = "none"
        if let priorURL = rawPriorURL, let host = URL(string: priorURL)?.host, !host.isEmpty,
           case .tab(let bid, _) = pending {
            returnTarget = .tab(bundleId: bid, host: host)
            branch = "prior-tab"
        } else if let app = priorAppCandidate {
            returnTarget = .app(bundleId: app)
            branch = "prior-app"
        } else if let app = fallbackApp {
            returnTarget = .app(bundleId: app)
            branch = "mru-fallback"
        }

        appDelegate?.postLog("🎯 Back-to-work tapped — pending=\(describe(pending)) rawPriorApp=\(rawPriorApp ?? "nil") rawPriorURL=\(rawPriorURL ?? "nil") mruLast=\(lastNonIntentionalAppBundleId ?? "nil") branch=\(branch) → \(returnTarget.map(describe) ?? "(none; hiding Intentional)")")
        coord.resolve(outcome: .backToWork, intendedTarget: nil, returnTarget: returnTarget, at: Date())
        // Arm suppression BEFORE dismiss(): closing our key window causes macOS to synchronously
        // re-activate whatever was underneath, which fires .didActivate on the main queue before
        // activateApp() gets a chance to arm its own flag. Cover both the pending target (the app
        // the user tried to open — may briefly gain focus) and the return target (where we're
        // heading). Entries expire after 2s so they don't poison the next real user switch.
        armActivationSuppression(pending.bundleId)
        if let r = returnTarget, r.bundleId != pending.bundleId {
            armActivationSuppression(r.bundleId)
        }
        appDelegate?.postLog("🎯 Back-to-work: arming pre-dismiss suppressions \(pendingActivationSuppressions.keys.sorted())")
        switchOverlayController?.dismiss()
        pendingSwitchTarget = nil
        priorAppBundleIdBeforeSwitch = nil
        priorTabURLBeforeSwitch = nil
        if let t = returnTarget {
            applyReturnTarget(t)
        } else {
            // No usable return target — don't strand the user on Intentional (overlay host).
            // Activate Finder as a neutral fallback: always running, benign, and we arm a
            // suppression so the coordinator treats the synthetic switch as our own doing,
            // not a fresh user-driven switch that would re-fire the overlay.
            //
            // Previous behaviour called NSApp.hide(nil), which auto-activated whatever was
            // underneath (often the pending app), which immediately re-fired the tab-switch
            // intercept → infinite overlay loop. Activating Finder explicitly avoids both
            // strandedness AND the loop because we pre-arm the suppression for Finder.
            let fallbackBundle = "com.apple.finder"
            if fallbackBundle != pending.bundleId {
                appDelegate?.postLog("🎯 Back-to-work: no return target — activating Finder as neutral fallback")
                // activateApp arms its own suppression, so the didActivate that follows is
                // suppressed and doesn't re-enter the coordinator as a new user switch.
                activateApp(bundleId: fallbackBundle)
            } else {
                // Pending WAS Finder (weird case) — just dismiss overlay, stay where we are.
                appDelegate?.postLog("🎯 Back-to-work: no return target + pending is Finder — overlay dismissed only")
            }
        }
    }

    func switchOverlayDidTapContinue() {
        guard let coord = switchCoordinator, let pending = pendingSwitchTarget else {
            appDelegate?.postLog("🎯 Continue tapped but no pending target; dismissing")
            switchOverlayController?.dismiss()
            pendingSwitchTarget = nil
            return
        }
        appDelegate?.postLog("🎯 Continue → \(describe(pending))")
        coord.resolve(outcome: .continued, intendedTarget: pending, returnTarget: nil, at: Date())
        // Arm BEFORE dismiss(): closing our key window causes macOS to synchronously re-activate
        // the underlying app, firing .didActivate before activateApp() runs its own arm.
        armActivationSuppression(pending.bundleId)
        appDelegate?.postLog("🎯 Continue: arming pre-dismiss suppression for [\(pending.bundleId)]")
        switchOverlayController?.dismiss()
        pendingSwitchTarget = nil
        priorAppBundleIdBeforeSwitch = nil
        priorTabURLBeforeSwitch = nil
        // Actually navigate to the target. Without this, the user is stranded on Intentional
        // (the overlay's host app). Clicking the intended app in the dock would fire a fresh
        // switch and re-present the overlay, which users perceive as "the timer restarted."
        applyReturnTarget(pending)
    }

    private func describe(_ t: SwitchTarget) -> String {
        switch t {
        case .app(let b): return "app(\(b))"
        case .tab(let b, let h): return "tab(\(b) · \(h))"
        }
    }

    private func applyReturnTarget(_ target: SwitchTarget?) {
        guard let target = target else {
            appDelegate?.postLog("🎯 applyReturnTarget: nil — no-op")
            return
        }
        switch target {
        case .app(let bundleId):
            appDelegate?.postLog("🎯 applyReturnTarget: app → activating [\(bundleId)]")
            activateApp(bundleId: bundleId)
        case .tab(let bundleId, let host):
            // v1: activate the browser. Tab-level restoration punted to v2.
            appDelegate?.postLog("🎯 applyReturnTarget: tab [\(bundleId) · \(host)] → activating browser (tab restore is v2)")
            activateApp(bundleId: bundleId)
        }
    }

    private func activateApp(bundleId: String) {
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.bundleIdentifier == bundleId }) else {
            appDelegate?.postLog("🎯 activateApp [\(bundleId)] NOT FOUND in runningApplications")
            return
        }
        armActivationSuppression(bundleId)
        let ok: Bool
        if #available(macOS 14.0, *) {
            // Modern API: macOS 14 deprecated activate(options:) — the no-arg form handles
            // activation-policy checks and the "requesting app is frontmost" path that the
            // deprecated form silently drops.
            ok = app.activate()
        } else {
            ok = app.activate(options: [])
        }
        appDelegate?.postLog("🎯 activateApp [\(bundleId)] (\(app.localizedName ?? "?")) → activate()=\(ok), suppression armed")

        // If activate() returned false OR the target didn't actually become frontmost after a
        // short settle, retry with URL-based open — that path always activates the app on
        // modern macOS even when NSRunningApplication.activate is ignored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            if frontBundle == bundleId { return }
            self.appDelegate?.postLog("🎯 activateApp [\(bundleId)] fallback — frontmost is \(frontBundle.isEmpty ? "(nil)" : frontBundle), retrying via NSWorkspace.openApplication")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                self.armActivationSuppression(bundleId)
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { [weak self] _, err in
                    if let err = err {
                        self?.appDelegate?.postLog("🎯 activateApp [\(bundleId)] openApplication failed: \(err.localizedDescription)")
                    }
                }
            }
        }
    }
}

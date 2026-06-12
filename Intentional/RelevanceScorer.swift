import Foundation
import AppKit
import CryptoKit

#if canImport(FoundationModels)
import FoundationModels
#endif

import MLXLLM
import MLXLMCommon  // LanguageModel protocol
import MLX          // GPU cache configuration

/// Scores activity relevance against the current work block intention
/// using MLX Qwen3-4B-Instruct (on-device LLM via Apple Silicon GPU).
/// Falls back to Apple Foundation Models on macOS 26+ if Qwen is not selected.
///
/// Supports two content types with separate optimized prompts:
/// - `.webpage`: Scores a browser tab's page title + URL
/// - `.application`: Scores a desktop application with metadata enrichment
class RelevanceScorer {

    weak var appDelegate: AppDelegate?

    enum ContentType {
        case webpage
        case application
    }

    struct Result {
        var relevant: Bool
        var confidence: Int  // 0-100
        var reason: String
        var path: ScoringPath = .metadataRelevant
        /// First ~300 chars of OCR-extracted on-screen text; non-nil only on ocrVerified* paths.
        var ocrExcerpt: String? = nil
        /// Timestamped journey of which pipeline stages ran for this verdict. Populated
        /// by `ScoringTracer` inside scoreRelevance. Stripped/overwritten on cache hits
        /// so the trace always reflects THIS decision, not the one that seeded the cache.
        var trace: [TraceStep] = []
    }

    // MARK: - Cache

    /// Unified cache entry: result + timestamp. Cache key already encodes the page title,
    /// so a title change produces a new key and a natural cache miss — no extra titleHash needed.
    private struct CacheEntry {
        let result: Result
        let stampedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var currentIntention: String = ""

    /// Hosts where the URL doesn't reliably identify the content — same URL serves
    /// wildly different content as the user navigates. Approvals are time-limited
    /// on these hosts to prevent permanent whitelisting of one on-task video/page
    /// from laundering all future content on the same host.
    private let containerAppDomains: Set<String> = [
        "youtube.com",
        "twitter.com",
        "x.com",
        "reddit.com",
        "claude.ai",
        "chat.openai.com",
        "chatgpt.com",
        "notion.so",
        "docs.google.com",
        "substack.com",
        "news.ycombinator.com"
    ]

    /// Default TTL for metadata-relevant approvals on container apps (3 min).
    private let containerAppApprovalTTL: TimeInterval = 180
    /// TTL for OCR-verified-relevant verdicts on container apps (10 min — grounded in content).
    private let ocrVerifiedRelevantTTL: TimeInterval = 600

    // MLX model state
    private var mlxContext: ModelContext?
    private var mlxSession: ChatSession?
    private var mlxModelLoading = false
    private(set) var mlxModelLoaded = false

    /// Expose MLX model context for reuse by other components
    var modelContext: ModelContext? { mlxContext }

    // User-approved pages (survives cache clears within a block, cleared on block change)
    private var userApproved: Set<String> = []

    /// True after any successful SCScreenshotManager capture this session.
    /// Used to skip the `CGPreflightScreenCaptureAccess` gate once we know permission exists.
    private var hasCapturedBefore: Bool = false

    // MARK: - Inference busy tracking (telemetry yields to scoring)

    /// Count of scoring/inference passes currently in flight (scoreRelevance,
    /// batch sweep, justification). There is no explicit queue around the shared
    /// `mlxSession` — serialization is de-facto (FocusMonitor's evaluation loop
    /// is the single scoring caller). Telemetry screen descriptions check this
    /// counter and SKIP (never queue) when anything is mid-flight: in-session
    /// scoring always has priority over telemetry.
    private let inferenceLock = NSLock()
    private var inferenceInFlight = 0

    private func beginInference() {
        inferenceLock.lock(); inferenceInFlight += 1; inferenceLock.unlock()
    }

    private func endInference() {
        inferenceLock.lock(); inferenceInFlight -= 1; inferenceLock.unlock()
    }

    /// True while any scoring pass (metadata, OCR rescore, batch, justification)
    /// is running.
    var isInferenceBusy: Bool {
        inferenceLock.lock(); defer { inferenceLock.unlock() }
        return inferenceInFlight > 0
    }

    // Stop words excluded from keyword overlap matching
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "have", "some",
        "work", "working", "doing", "make", "get", "use", "using", "look",
        "find", "check", "need", "want", "will", "can", "all", "any", "more"
    ]

    // MARK: - Split System Prompts (Qwen3-optimized)

    /// System prompt for desktop app classification — short, affirmative-first
    private let appSystemPrompt = """
    You classify whether a desktop application is relevant to the user's current work task.

    Applications are relevant when their category directly belongs to the same professional workflow as the task. Video editing software is relevant to video production and filming tasks. IDEs and code editors are relevant to coding tasks. Design tools are relevant to design tasks. Audio editors are relevant to podcast and music tasks.

    Applications are NOT relevant when their domain differs from the task, regardless of indirect connections.

    TASK TITLE IS LITERAL — treat it as a specific project name, not a general concept. "Working on intentional" means a project called Intentional, not deliberate behavior.

    <output-format>
    Respond with exactly one JSON object, no markdown, no preface:
    {"reason": "one sentence", "relevant": true/false, "confidence": 0-100}
    </output-format>
    """

    /// System prompt for webpage classification — includes URL/path rules
    private let webSystemPrompt = """
    You classify whether a webpage is relevant to the user's current work task.

    Webpages are relevant when: the title or URL shows task-specific content; documentation, tutorials, or forums directly address the task subject; tools and editors used for the task are open.

    Webpages are NOT relevant when: the platform is entertainment or social media without task-specific content; the title is generic (e.g., "YouTube", "Reddit") without a task-relevant path; connecting the page to the task requires interpretation.

    A URL path like /r/learnpython IS relevant to "Learning Python". "YouTube" alone is NOT relevant to "Studying chemistry" — but "Organic Chemistry Lecture - YouTube" IS relevant.

    TASK TITLE IS LITERAL — treat it as a specific project name, not a general concept. "Working on intentional" means a project called Intentional, not deliberate behavior.

    <output-format>
    Respond with exactly one JSON object, no markdown, no preface:
    {"reason": "one sentence", "relevant": true/false, "confidence": 0-100}
    </output-format>
    """

    // Keep the combined prompt for Apple Foundation Models (uses @Generable, not JSON)
    private let systemPrompt = """
    Determine if the user's current activity (a webpage or desktop application) is \
    directly related to their current work task.
    The task title is LITERAL — treat it as the specific name of a project, topic, or activity. \
    Do NOT reinterpret the task title as a general concept or stretch its meaning. \
    For example, "Working on intentional" means working on a project called "Intentional" \
    (likely a software project), NOT doing things "intentionally" or anything related to \
    "deliberate decision-making" or "strategic thinking".
    Relevant activities: tools, docs, code, research, forums, and resources that DIRECTLY \
    help with the specific task described. Learning materials count only if they are about \
    the task's specific subject matter.
    NOT relevant: entertainment, news, social media, videos, or content that requires \
    creative interpretation to connect to the task. If you have to construct a chain of \
    reasoning to justify relevance, it is NOT relevant.
    CRITICAL: Consider the platform's primary purpose when judging ambiguous titles. \
    Platforms exist on a spectrum from creation to consumption: \
    - Creation/productivity tools (document editors, spreadsheets, design tools, IDEs, \
    project management) are built for work. A generic title like "Untitled document" on a \
    document editor is likely someone starting work, not procrastinating. Default to relevant \
    unless the title clearly indicates off-task content. \
    - Entertainment/consumption platforms (video streaming, social media, forums, news) are \
    built for browsing. A generic title like "YouTube" or "Reddit" is NOT relevant just \
    because the platform COULD be used for the task. The title must show specific on-task \
    content. "YouTube" alone is NOT relevant to "Studying for chemistry" — but \
    "Organic Chemistry Lecture - YouTube" IS relevant. \
    Use all available context (title, URL path, page description) to determine relevance. \
    A generic title like "Reddit" with URL path "/r/learnpython" IS relevant to "Learning Python". \
    A generic title like "Home - GitHub" with URL path "/myorg/myapp/pull/234" IS relevant to working on that project.
    The task title is what the user EXPLICITLY chose to work on right now. \
    If the activity clearly matches what the block title literally describes, it IS relevant. \
    For example, if the block is "watching YouTube" then YouTube videos are relevant. \
    If the block is "reading news" then news sites are relevant. \
    If the block is "doing taxes" then tax preparation sites and tax-related pages are relevant.
    """

    // MARK: - App Metadata Enrichment

    /// Curated descriptions for common apps where the name alone is ambiguous.
    /// Keyed by bundle identifier → human-readable description.
    private static let appDescriptions: [String: String] = [
        // Video/Audio Production
        "com.adobe.PremierePro": "professional video editing software",
        "com.adobe.PremierePro.24": "professional video editing software",
        "com.adobe.AfterEffects": "motion graphics and visual effects software",
        "com.apple.FinalCut": "professional video editing software",
        "com.apple.iMovieApp": "video editing software",
        "com.blackmagic-design.DaVinciResolve": "professional video editing and color grading software",
        "com.blackmagic-design.DaVinciResolve.ProjectManager": "video editing project manager",
        "com.apple.garageband": "music creation and audio recording software",
        "com.apple.Logic10": "professional music production and audio editing software",
        "com.audacityteam.audacity": "audio editing and recording software",
        "com.rogueamoeba.SoundSource": "audio routing and processing utility",
        "com.macpaw.CleanMyMac-setapp": "system maintenance utility",
        "com.telestream.screenflow10": "screen recording and video editing software",
        "com.techsmith.camtasia2": "screen recording and video editing software",
        "com.loom.desktop": "screen recording and video messaging tool",
        "com.obsproject.obs-studio": "live streaming and screen recording software",

        // Design/Creative
        "com.figma.Desktop": "collaborative interface design tool",
        "com.bohemiancoding.sketch3": "vector graphics and UI design tool",
        "com.adobe.Photoshop": "image editing and graphic design software",
        "com.adobe.Illustrator": "vector graphics design software",
        "com.adobe.Lightroom": "photo editing and management software",
        "com.adobe.LightroomClassicCC7": "photo editing and management software",
        "com.adobe.InDesign": "page layout and publishing software",
        "com.canva.CanvaDesktop": "graphic design platform",
        "com.pixelmatorteam.pixelmator.x": "image editing software",
        "com.cocoatech.Frenzic": "design utility",
        "com.arturia.Analog-Lab": "virtual instrument and sound design",

        // Development
        "com.apple.dt.Xcode": "Apple platform IDE and development environment",
        "com.microsoft.VSCode": "code editor for software development",
        "com.sublimetext.4": "code and text editor for development",
        "com.todesktop.230313mzl4w4u92": "AI-powered code editor (Cursor)",
        "com.panic.Nova": "native macOS code editor",
        "com.jetbrains.intellij": "Java and Kotlin IDE",
        "com.jetbrains.intellij.ce": "Java and Kotlin IDE",
        "com.jetbrains.pycharm": "Python IDE",
        "com.jetbrains.pycharm.ce": "Python IDE",
        "com.jetbrains.WebStorm": "JavaScript and TypeScript IDE",
        "com.jetbrains.goland": "Go IDE",
        "com.jetbrains.CLion": "C/C++ IDE",
        "com.jetbrains.rider": ".NET IDE",
        "com.jetbrains.rubymine": "Ruby IDE",
        "com.jetbrains.fleet": "polyglot code editor",
        "com.github.GitHubClient": "Git repository management",
        "com.todesktop.iterm2": "terminal emulator for development",
        "com.googlecode.iterm2": "terminal emulator for development",
        "net.kovidgoyal.kitty": "terminal emulator for development",
        "com.docker.docker": "container platform for development",
        "com.postmanlabs.mac": "API development and testing tool",
        "com.insomnia.app": "API development and testing tool",
        "io.tableplus.TablePlus": "database management tool",
        "com.sequel-pro.sequel-pro": "database management tool",
        "com.tinyapp.TableTool": "CSV and data viewer",

        // Writing/Notes
        "notion.id": "workspace for notes, docs, and project management",
        "md.obsidian": "knowledge base and note-taking app",
        "net.shinyfrog.bear": "note-taking and writing app",
        "com.ulyssesapp.mac": "writing and publishing app",
        "com.literatureandlatte.scrivener3": "long-form writing and manuscript editor",
        "pro.writer.mac": "distraction-free writing app",
        "com.multimarkdown.composer.mac": "Markdown writing app",
        "abnerworks.Typora": "Markdown editor",
        "com.logseq.logseq": "knowledge graph and note-taking",

        // Productivity/Office
        "com.apple.iWork.Pages": "document editor and word processor",
        "com.apple.iWork.Keynote": "presentation software",
        "com.apple.iWork.Numbers": "spreadsheet application",
        "com.microsoft.Word": "document editor and word processor",
        "com.microsoft.Excel": "spreadsheet and data analysis application",
        "com.microsoft.Powerpoint": "presentation software",
        "com.microsoft.onenote.mac": "digital notebook and note-taking",
        "com.airtable.mac": "spreadsheet-database hybrid for project tracking",

        // Project Management
        "com.linear": "project tracking and issue management",
        "com.atlassian.jira.mac": "project tracking and issue management",
        "com.asana.app": "project and task management",
        "com.trello.desktop": "kanban-style project management",
        "com.clickup.desktop-app": "project management platform",
        "com.monday.desktop": "work management platform",
        "com.todoist.mac.Todoist": "task management",
        "com.culturedcode.ThingsMac": "personal task manager",
        "com.omnigroup.OmniFocus4": "task and project management",

        // Communication
        "com.tinyspeck.slackmacgap": "team communication and messaging",
        "us.zoom.xos": "video conferencing",
        "com.microsoft.teams2": "team communication and video conferencing",
        "com.microsoft.teams": "team communication and video conferencing",
        "com.hnc.Discord": "community messaging platform",
        "com.apple.MobileSMS": "text messaging",
        "com.apple.mail": "email client",
        "com.readdle.smartemail-macos": "email client (Spark)",

        // Entertainment/Consumption (explicit so the model knows these are NOT work tools)
        "com.spotify.client": "music streaming service",
        "com.apple.Music": "music player and streaming",
        "com.apple.TV": "video streaming service",
        "com.netflix.Netflix": "video streaming service",
        "tv.twitch.TwitchDesktop": "live streaming entertainment platform",
        "com.apple.podcasts": "podcast listening app",
    ]

    /// Map macOS LSApplicationCategoryType to human-readable labels
    private static let lsCategoryLabels: [String: String] = [
        "public.app-category.business": "business software",
        "public.app-category.developer-tools": "developer tools",
        "public.app-category.education": "education software",
        "public.app-category.entertainment": "entertainment",
        "public.app-category.finance": "finance software",
        "public.app-category.games": "game",
        "public.app-category.action-games": "game",
        "public.app-category.adventure-games": "game",
        "public.app-category.arcade-games": "game",
        "public.app-category.board-games": "game",
        "public.app-category.card-games": "game",
        "public.app-category.casino-games": "game",
        "public.app-category.dice-games": "game",
        "public.app-category.educational-games": "educational game",
        "public.app-category.family-games": "game",
        "public.app-category.kids-games": "game",
        "public.app-category.music-games": "game",
        "public.app-category.puzzle-games": "game",
        "public.app-category.racing-games": "game",
        "public.app-category.role-playing-games": "game",
        "public.app-category.simulation-games": "game",
        "public.app-category.sports-games": "game",
        "public.app-category.strategy-games": "game",
        "public.app-category.trivia-games": "game",
        "public.app-category.word-games": "game",
        "public.app-category.graphics-design": "graphic design tool",
        "public.app-category.healthcare-fitness": "health and fitness",
        "public.app-category.lifestyle": "lifestyle app",
        "public.app-category.medical": "medical software",
        "public.app-category.music": "music creation tool",
        "public.app-category.news": "news app",
        "public.app-category.photography": "photography tool",
        "public.app-category.productivity": "productivity tool",
        "public.app-category.reference": "reference tool",
        "public.app-category.social-networking": "social networking app",
        "public.app-category.sports": "sports app",
        "public.app-category.travel": "travel app",
        "public.app-category.utilities": "system utility",
        "public.app-category.video": "video creation tool",
        "public.app-category.weather": "weather app",
    ]

    /// Enrich an app name with a description for the LLM.
    /// Returns e.g. "Adobe Premiere Pro (professional video editing software)"
    private func enrichAppName(_ localizedName: String, bundleIdentifier: String) -> String {
        // 1. Check curated dictionary first
        if let desc = Self.appDescriptions[bundleIdentifier] {
            return "\(localizedName) (\(desc))"
        }

        // 2. Try to read LSApplicationCategoryType from the app's Info.plist
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           let bundle = Bundle(url: appURL) {
            let infoDict = bundle.infoDictionary ?? [:]
            if let category = infoDict["LSApplicationCategoryType"] as? String,
               let label = Self.lsCategoryLabels[category] {
                return "\(localizedName) (\(label))"
            }
        }

        // 3. No enrichment available — return name as-is
        return localizedName
    }

    // MARK: - Few-Shot Examples

    /// Few-shot examples for app classification — 3 examples with a bridging case last
    private func appFewShotExamples() -> String {
        return """
        Examples:
        Task: "editing a podcast" | App: "Logic Pro (professional music production and audio editing software)" → {"reason": "Logic Pro is an audio editor directly used for podcast production", "relevant": true, "confidence": 95}
        Task: "editing a podcast" | App: "Spotify (music streaming service)" → {"reason": "Spotify is for listening to music, not editing audio", "relevant": false, "confidence": 92}
        Task: "filming a video" | App: "Adobe Premiere Pro (professional video editing software)" → {"reason": "Premiere Pro is a video editor; post-production is part of the video creation workflow", "relevant": true, "confidence": 90}
        """
    }

    /// Few-shot examples for webpage classification
    private func webFewShotExamples() -> String {
        return """
        Examples:
        Task: "learning Python" | Page: "Python List Comprehensions - Real Python" URL: /tutorials/list-comprehensions → {"reason": "Tutorial directly about Python programming concepts", "relevant": true, "confidence": 95}
        Task: "learning Python" | Page: "Reddit - Pair Programming" URL: /r/learnpython/comments/abc → {"reason": "Learn Python subreddit directly addresses the learning task", "relevant": true, "confidence": 85}
        Task: "writing a report" | Page: "YouTube" URL: /feed → {"reason": "YouTube feed is entertainment browsing, not report writing", "relevant": false, "confidence": 90}
        """
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct RelevanceOutput {
        @Guide(description: "One sentence explaining why this activity is or isn't related to the task")
        var reason: String
        @Guide(description: "Is this activity relevant to the user's current work intention?")
        var relevant: Bool
        @Guide(description: "Confidence from 0 to 100", .range(0...100))
        var confidence: Int
    }

    private var _session: Any? = nil

    @available(macOS 26.0, *)
    private var session: LanguageModelSession {
        get {
            if let s = _session as? LanguageModelSession { return s }
            let s = LanguageModelSession(instructions: systemPrompt)
            _session = s
            return s
        }
        set { _session = newValue }
    }
    #endif

    // MARK: - Learned Override Store

    private let learnedOverrideStore = LearnedOverrideStore()

    /// Load the learned-override store from UserDefaults (or scan the JSONL if first launch).
    /// Call once from AppDelegate after RelevanceScorer is initialized.
    func loadLearnedOverrides() {
        let logPath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional/relevance_log.jsonl")
        Task { [weak self] in
            guard let self else { return }
            await self.learnedOverrideStore.loadFromUserDefaults(logPath: logPath)
            let promoted = await self.learnedOverrideStore.promotedHostsSnapshot()
            self.appDelegate?.postLog("🧠 LearnedOverrideStore loaded — \(promoted.count) promoted host(s): \(promoted.sorted().joined(separator: ", "))")
        }
    }

    /// Record a user correction for the given host.
    /// Called by FocusMonitor when the user taps "This was wrong" on the blocking overlay.
    func recordUserOverride(host: String, at date: Date = Date()) {
        Task { [weak self] in
            guard let self else { return }
            await self.learnedOverrideStore.recordOverride(host: host, at: date)
            let promoted = await self.learnedOverrideStore.isPromoted(host: host)
            self.appDelegate?.postLog("🧠 LearnedOverride recorded for \"\(host)\" — promoted: \(promoted)")
        }
    }

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
        appDelegate?.postLog("🧠 RelevanceScorer initialized")
    }

    /// Clear the relevance cache (call when block changes)
    func clearCache() {
        cache.removeAll()
        userApproved.removeAll()
        currentIntention = ""
        // Reset the LLM session so it doesn't carry context from previous block
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            _session = nil
        }
        #endif
        // MLX: reset session so it doesn't carry context from previous block
        mlxSession = mlxContext.map { ChatSession($0) }
        if let s = mlxSession {
            s.generateParameters.temperature = 0.2
        }
        appDelegate?.postLog("🧠 Relevance cache cleared")
    }

    /// Approve a page title for the current intention (user justified it).
    /// Persists until block changes (cleared by clearCache()).
    func approvePageTitle(_ pageTitle: String, for intention: String) {
        let cacheKey = "\(intention)|\(pageTitle)"
        let result = Result(relevant: true, confidence: 100, reason: "User-approved", path: .metadataRelevant)
        cache[cacheKey] = CacheEntry(result: result, stampedAt: Date())
        userApproved.insert(cacheKey)
        appDelegate?.postLog("🧠 User approved: \"\(pageTitle)\" for \"\(intention)\"")
    }

    // MARK: - shouldVerifyWithOCR

    /// Confidence threshold above which metadata off-task verdicts are trusted without OCR.
    /// When the title is specific enough for the LLM to render a strong verdict (e.g.
    /// "Northeastern post bacc program — Claude" is clearly medical), running OCR adds
    /// risk: on platforms like Claude.ai the OCR captures sidebar/history chrome that
    /// may reference unrelated topics (past engineering conversations) and can flip a
    /// correct off-task verdict into a wrong relevant one.
    private let ocrEscalationMaxConfidence: Int = 70

    /// Gate: should we run a second-chance OCR pass for this off-task verdict?
    /// Returns true only when metadata said off-task with MODERATE confidence (below the
    /// threshold) AND either:
    ///   (a) the URL is a container app (dynamic content, same URL), OR
    ///   (b) the host has been promoted via learned overrides (3+ user corrections in 30 days).
    ///
    /// High-confidence off-task verdicts are trusted directly; OCR is reserved for
    /// ambiguous cases where the title alone isn't enough to decide.
    private func shouldVerifyWithOCR(metadataResult: Result, url: String, bundleIdentifier: String) async -> Bool {
        guard !metadataResult.relevant else { return false }
        // Trust high-confidence off-task metadata verdicts — don't let OCR chrome override them.
        if metadataResult.confidence >= ocrEscalationMaxConfidence { return false }
        if isContainerAppURL(url) { return true }
        let host = URLComponents(string: url)?.host ?? ""
        return await learnedOverrideStore.isPromoted(host: host)
    }

    // MARK: - OCR Screen-Recording Permission Gate

    /// Show a gentle NSAlert prompting the user to enable screen recording for OCR verification.
    ///
    /// Rules:
    /// - Never called in DEBUG builds (CGPreflightScreenCaptureAccess() lies in Xcode builds).
    /// - Capped at once per 24 hours via "lastOCRPromptDate" in UserDefaults.
    /// - Fire-and-forget: called after capture returns nil; scoring already returns metadataOffTask.
    /// - Must run on the main thread (NSAlert requirement).
    private func promptForScreenRecordingIfNeeded() async {
        #if DEBUG
        // Preflight always returns false in Xcode builds — never prompt.
        return
        #else
        // Skip if preflight says permission is already granted, or if we've captured before.
        if hasCapturedBefore || CGPreflightScreenCaptureAccess() { return }

        // Throttle: at most once per 24 hours (cheap early-exit, NOT authoritative — race guard below).
        let defaults = UserDefaults.standard
        if let lastDate = defaults.object(forKey: "lastOCRPromptDate") as? Date,
           Date().timeIntervalSince(lastDate) < 86400 { return }

        await MainActor.run {
            // Authoritative re-check with main-thread exclusivity (race guard: two concurrent Tasks
            // can both pass the outer throttle before either writes; re-reading here under the
            // MainActor serializes the write and prevents a double-prompt).
            if let lastDate = defaults.object(forKey: "lastOCRPromptDate") as? Date,
               Date().timeIntervalSince(lastDate) < 86400 { return }
            defaults.set(Date(), forKey: "lastOCRPromptDate")

            let alert = NSAlert()
            alert.messageText = "Enable Content Verification?"
            alert.informativeText = "Intentional uses on-screen text to verify that what you're viewing matches your focus intention. This runs entirely on your Mac — nothing is uploaded."
            alert.addButton(withTitle: "Enable in Settings")
            alert.addButton(withTitle: "Not Now")
            alert.alertStyle = .informational

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        #endif
    }

    // MARK: - scoreRelevance

    /// Score a page title or app name against the current work intention.
    /// Returns cached result if available.
    ///
    /// For container-app URLs where metadata scores off-task, kicks off a second-chance
    /// OCR verification pass before returning a blocking verdict.
    func scoreRelevance(
        pageTitle: String,
        intention: String,
        intentionDescription: String = "",
        intentText: String = "",                  // FIX-11: ≤140-char per-goal intent string from Weekly Goal editor
        aiScoringEnabled: Bool = true,            // FIX-11: per-goal toggle; when false, AI scoring is skipped entirely
        profile: String,
        dailyPlan: String,
        url: String = "",
        pageDescription: String = "",
        contentType: ContentType = .webpage,
        bundleIdentifier: String = ""
    ) async -> Result {
        // Mark the whole pass busy (incl. OCR capture) so telemetry descriptions
        // yield — skip, never queue — while enforcement scoring runs.
        beginInference()
        defer { endInference() }
        let tracer = ScoringTracer()
        // Helper that stamps the terminal "final" step, attaches the trace to the result,
        // and emits a one-line trace summary to postLog. Every return path goes through this
        // so the user sees the full step-by-step journey for every verdict.
        let traceLabel = "\"\(pageTitle)\"" + (url.isEmpty ? "" : " " + (URL(string: url)?.host ?? ""))
        func finalize(_ r: Result) -> Result {
            tracer.record("final", "relevant=\(r.relevant) conf=\(r.confidence) path=\(r.path.rawValue)")
            var out = r
            out.trace = tracer.steps
            appDelegate?.postLog(tracer.summary(label: traceLabel))
            return out
        }

        // FIX-11: When the active Weekly Goal has AI scoring disabled, short-circuit
        // before keyword/cache/LLM work and allow the page through. The user opted out
        // of relevance enforcement for this goal — defer to the dumb blocklist only.
        if !aiScoringEnabled {
            tracer.record("ai_disabled", "ai_scoring_enabled=false → allow")
            return finalize(Result(
                relevant: true,
                confidence: 100,
                reason: "AI scoring disabled for this goal",
                path: .metadataRelevant
            ))
        }

        // FIX-11: Prefer the explicit per-goal `intentText` when present; fall back to
        // legacy `intentionDescription` for callers that haven't been updated yet.
        let effectiveDescription = intentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? intentionDescription
            : intentText

        // Include URL in cache key so same-title pages on different URLs get scored separately.
        // Append a short hash of profile+dailyPlan so edits to either invalidate stale cache entries.
        //
        // Include the query string so different YouTube videos (/watch?v=X vs /watch?v=Y) don't
        // collide on the shared `/watch` path.
        let parsedURL = URL(string: url)
        let urlPath = parsedURL?.path ?? ""
        let urlPathWithQuery = urlPath + (parsedURL?.query.map { "?\($0)" } ?? "")
        let urlHost = parsedURL?.host?.lowercased() ?? ""
        let contextHash: String = {
            let bytes = Array("\(profile)|\(dailyPlan)".utf8)
            let digest = SHA256.hash(data: bytes)
            return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        }()
        let isContainer = isContainerAppURL(url)
        // For container apps (Claude, YouTube, Notion, docs.google.com) the tab title churns
        // as the conversation/video/doc state changes, which made the title-keyed cache miss
        // whenever the user tabbed away and back. Key off host+path+query only for these
        // hosts — stable per-content-item, so a verdict sticks across tab switches.
        // Non-container webpages still use the title (some static pages share a path).
        let cacheKey: String = isContainer
            ? "\(intention)|@\(urlHost)\(urlPathWithQuery)|\(contextHash)"
            : "\(intention)|\(pageTitle)|\(urlPath)|\(contextHash)"

        // Keyword overlap: catch obvious matches without hitting the LLM
        let urlSegments = urlPathSegments(url)
        let titleMatch = hasKeywordOverlap(intention: intention, pageTitle: pageTitle)
        let urlMatch = !url.isEmpty && hasKeywordOverlap(intention: intention, pageTitle: urlSegments)
        if titleMatch || urlMatch {
            let matchSource = titleMatch ? "title" : "URL path"
            tracer.record("keyword", "hit(\(matchSource))")
            appDelegate?.postLog("🧠 [Keyword] Match in \(matchSource): \"\(pageTitle)\" url=\(url.isEmpty ? "(none)" : url)")
            var result = Result(relevant: true, confidence: 95, reason: "Keyword match with task (\(matchSource))")
            result.path = .metadataRelevant
            let finalR = finalize(result)
            cache[cacheKey] = CacheEntry(result: finalR, stampedAt: Date())
            return finalR
        }
        tracer.record("keyword", "miss")

        // User-approved whitelist (from justification) — keyed by title only (no URL).
        // Approved pages never trigger OCR; they return early here.
        let approvalKey = "\(intention)|\(pageTitle)"
        if userApproved.contains(approvalKey) {
            tracer.record("approval", "hit")
            return finalize(Result(relevant: true, confidence: 100, reason: "User-approved", path: .metadataRelevant))
        }

        // Check cache
        if let entry = cache[cacheKey] {
            let ageSec = Int(Date().timeIntervalSince(entry.stampedAt))
            if isContainer {
                if entry.result.relevant {
                    // Apply path-aware TTL
                    let ttl: TimeInterval = entry.result.path == .ocrVerifiedRelevant
                        ? ocrVerifiedRelevantTTL
                        : containerAppApprovalTTL
                    if Date().timeIntervalSince(entry.stampedAt) < ttl {
                        tracer.record("cache", "hit(age=\(ageSec)s path=\(entry.result.path.rawValue))")
                        return finalize(entry.result)
                    }
                    // TTL elapsed: drop stale entry and fall through to fresh scoring.
                    cache.removeValue(forKey: cacheKey)
                    tracer.record("cache", "expired(age=\(ageSec)s)")
                    appDelegate?.postLog("🧠 [Cache] Container-app TTL expired for \"\(pageTitle)\" on \(urlHost.isEmpty ? "?" : urlHost) — re-scoring")
                } else {
                    // Off-task cached result for container app — always re-score (don't cache off-task)
                    cache.removeValue(forKey: cacheKey)
                    tracer.record("cache", "stale-offtask")
                }
            } else {
                tracer.record("cache", "hit(age=\(ageSec)s path=\(entry.result.path.rawValue))")
                return finalize(entry.result)
            }
        } else {
            tracer.record("cache", "miss")
        }

        // Track intention changes — clear cache when block switches
        if intention != currentIntention {
            cache.removeAll()
            currentIntention = intention
        }

        // Grab frontmost PID at scoring entry for drift detection on the OCR path.
        // Compared later to capture.pid so we discard OCR output if the user switched apps
        // between scoring-start and capture-time. Only needed when the OCR path is possible.
        let startPID: pid_t? = isContainer
            ? await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            : nil

        // S2 (2026-06-10): model selection is hardcoded — always Qwen3-4B via MLX.
        // The user-facing model picker was removed; Apple Foundation Models below
        // is an automatic fallback when MLX fails to load, not a selectable option.

        // --- Metadata scoring pass ---
        var metadataResult: Result? = nil

        do {
            await loadMLXModelIfNeeded()
            if mlxModelLoaded {
                do {
                    metadataResult = try await scoreWithMLX(
                        pageTitle: pageTitle,
                        intention: intention,
                        intentionDescription: effectiveDescription, // FIX-11
                        profile: profile,
                        dailyPlan: dailyPlan,
                        url: url,
                        pageDescription: pageDescription,
                        contentType: contentType,
                        bundleIdentifier: bundleIdentifier
                    )
                } catch {
                    appDelegate?.postLog("⚠️ RelevanceScorer: MLX scoring error: \(error)")
                }
            }
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), metadataResult == nil {
            do {
                metadataResult = try await scoreWithFoundationModels(
                    pageTitle: pageTitle,
                    intention: intention,
                    intentionDescription: effectiveDescription, // FIX-11
                    profile: profile,
                    dailyPlan: dailyPlan,
                    url: url,
                    pageDescription: pageDescription,
                    contentType: contentType,
                    bundleIdentifier: bundleIdentifier
                )
            } catch {
                appDelegate?.postLog("⚠️ RelevanceScorer: Foundation Models error: \(error)")
            }
        }
        #endif

        // Fallback if all scoring paths failed
        guard var rawResult = metadataResult else {
            tracer.record("metadata", "unavailable")
            return finalize(Result(relevant: true, confidence: 0, reason: "Scoring unavailable on this macOS version", path: .metadataRelevant))
        }
        tracer.record("metadata", "\(rawResult.relevant ? "relevant" : "off-task")/\(rawResult.confidence)")

        // --- OCR verification pass (second-chance for off-task verdicts on container apps) ---
        let gateAllowsOCR = await shouldVerifyWithOCR(metadataResult: rawResult, url: url, bundleIdentifier: bundleIdentifier)
        if gateAllowsOCR {
            tracer.record("ocr-gate", "yes")
            // Serial capture only when OCR is actually needed. This avoids window-server
            // contention with ContentSafetyMonitor's CGWindowListCreateImage poll.
            let captureResult = (try? await ScreenCapture().captureFrontmostWindow()) ?? nil
            if captureResult != nil {
                await MainActor.run { self.hasCapturedBefore = true }
            }

            // PID drift guard (Flag 1): compare startPID (sampled at scoring entry) with
            // capture.pid. If they differ the user switched apps mid-flight — discard capture.
            if let capture = captureResult,
               capture.pid == startPID {
                tracer.record("ocr-capture", "ok")
                let ocrEngine = OCREngine()
                let ocrText = (try? await ocrEngine.extractText(from: capture.image)) ?? ""

                if !ocrText.isEmpty {
                    tracer.record("ocr-ocr", "\(ocrText.count)ch")
                    appDelegate?.postLog("🧠 [OCR] Running verification pass for \"\(pageTitle)\" (\(ocrText.count) chars)")
                    let verifiedResult = await rescoreWithOCR(
                        pageTitle: pageTitle,
                        intention: intention,
                        intentionDescription: effectiveDescription, // FIX-11
                        profile: profile,
                        dailyPlan: dailyPlan,
                        url: url,
                        pageDescription: pageDescription,
                        contentType: contentType,
                        bundleIdentifier: bundleIdentifier,
                        ocrText: ocrText
                    )
                    tracer.record("ocr-rescore", "\(verifiedResult.relevant ? "relevant" : "off-task")/\(verifiedResult.confidence)")
                    var finalResult = verifiedResult
                    finalResult.path = verifiedResult.relevant ? .ocrVerifiedRelevant : .ocrVerifiedOffTask
                    finalResult.ocrExcerpt = String(ocrText.prefix(300))
                    appDelegate?.postLog("🧠 [OCR] Verdict: \"\(pageTitle)\" → \(finalResult.relevant ? "relevant" : "NOT relevant") (\(finalResult.confidence)%) path=\(finalResult.path.rawValue)")
                    let finalized = finalize(finalResult)
                    // Cache OCR-verified relevant results; don't cache off-task (re-score on next tick)
                    if finalized.relevant {
                        cache[cacheKey] = CacheEntry(result: finalized, stampedAt: Date())
                    }
                    return finalized
                } else {
                    tracer.record("ocr-ocr", "empty")
                    appDelegate?.postLog("🧠 [OCR] Empty OCR text for \"\(pageTitle)\" — falling through to metadata verdict")
                }
            } else if captureResult == nil && !hasCapturedBefore {
                // Capture returned nil — likely denied permission. Show gentle prompt (capped 1/24h, skipped in DEBUG).
                tracer.record("ocr-capture", "nil(no-perm?)")
                appDelegate?.postLog("🧠 [OCR] Capture returned nil for \"\(pageTitle)\" — prompting for screen recording if needed")
                Task { [weak self] in await self?.promptForScreenRecordingIfNeeded() }
            } else {
                // PID drifted — user switched apps between capture and scoring.
                tracer.record("ocr-capture", "drift")
                appDelegate?.postLog("🧠 [OCR] PID drift for \"\(pageTitle)\" — using metadata verdict")
            }

            // Fall-through: OCR unavailable/drifted — return metadata off-task verdict without caching
            rawResult.path = .metadataOffTask
            return finalize(rawResult)
        }
        tracer.record("ocr-gate", "no")

        // Metadata-only path: label correctly based on verdict
        rawResult.path = rawResult.relevant ? .metadataRelevant : .metadataOffTask
        let finalized = finalize(rawResult)
        // Cache relevant results; for container apps use stampedAt for TTL tracking
        if finalized.relevant {
            cache[cacheKey] = CacheEntry(result: finalized, stampedAt: Date())
        }
        // Don't cache off-task metadata verdicts for container apps — re-score each tick
        // For non-container-app off-task, cache normally (no TTL)
        if !finalized.relevant && !isContainer {
            cache[cacheKey] = CacheEntry(result: finalized, stampedAt: Date())
        }
        return finalized
    }

    // MARK: - OCR Rescore

    /// Re-score relevance using both metadata AND on-screen OCR text.
    ///
    /// IMPORTANT — Flag 2 (clean prompt): this builds a FRESH prompt that includes the OCR excerpt
    /// as additional context. It does NOT reference a prior verdict, does NOT say "re-evaluate,"
    /// and does NOT anchor the model on a previous decision. The model sees exactly the same
    /// metadata it would have seen in the regular pass, plus the on-screen text.
    private func rescoreWithOCR(
        pageTitle: String,
        intention: String,
        intentionDescription: String,
        profile: String,
        dailyPlan: String,
        url: String,
        pageDescription: String,
        contentType: ContentType,
        bundleIdentifier: String,
        ocrText: String
    ) async -> Result {
        // S2 (2026-06-10): always Qwen3-4B; Apple FM below is automatic fallback only.
        if mlxModelLoaded {
            do {
                return try await scoreWithMLX(
                    pageTitle: pageTitle,
                    intention: intention,
                    intentionDescription: intentionDescription,
                    profile: profile,
                    dailyPlan: dailyPlan,
                    url: url,
                    pageDescription: pageDescription,
                    contentType: contentType,
                    bundleIdentifier: bundleIdentifier,
                    ocrText: ocrText
                )
            } catch {
                appDelegate?.postLog("⚠️ RelevanceScorer: OCR rescore MLX error: \(error)")
            }
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                return try await scoreWithFoundationModels(
                    pageTitle: pageTitle,
                    intention: intention,
                    intentionDescription: intentionDescription,
                    profile: profile,
                    dailyPlan: dailyPlan,
                    url: url,
                    pageDescription: pageDescription,
                    contentType: contentType,
                    bundleIdentifier: bundleIdentifier,
                    ocrText: ocrText
                )
            } catch {
                appDelegate?.postLog("⚠️ RelevanceScorer: OCR rescore Foundation Models error: \(error)")
            }
        }
        #endif

        // Could not rescore — return fail-closed off-task
        return Result(relevant: false, confidence: 0, reason: "OCR rescore unavailable", path: .ocrVerifiedOffTask)
    }

    // MARK: - Keyword Overlap

    /// Check if a keyword from the intention matches a word in the page title strongly
    /// enough to short-circuit the LLM.
    ///
    /// A positive verdict here skips the LLM entirely, so the bar is intentionally high:
    ///   - exact match on a ≥4-char word, OR
    ///   - shared prefix of ≥5 chars between two ≥5-char words (catches "engineer"↔"engineering",
    ///     "program"↔"programming", but NOT "apply"↔"application" which share only 4 chars)
    ///
    /// The previous `hasPrefix` rule (min 3 chars) allowed weak single-word matches like
    /// "tech"↔"technology" to falsely mark a page RELEVANT before the LLM ever ran.
    private func hasKeywordOverlap(intention: String, pageTitle: String) -> Bool {
        let intentWords = extractKeywords(intention)
        let titleWords = extractKeywords(pageTitle)
        for iw in intentWords {
            for tw in titleWords {
                if iw == tw && iw.count >= 4 { return true }
                if iw.count >= 5 && tw.count >= 5 && iw.commonPrefix(with: tw).count >= 5 {
                    return true
                }
            }
        }
        return false
    }

    /// Extract meaningful keywords from text (3+ chars, no stop words).
    private func extractKeywords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 3 && !Self.stopWords.contains($0) }
    }

    /// Returns true if the URL's host matches or is a subdomain of a container-app domain.
    /// Example: "www.youtube.com" → matches "youtube.com"; "m.reddit.com" → matches "reddit.com".
    private func isContainerAppURL(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        for domain in containerAppDomains {
            if host == domain || host.hasSuffix(".\(domain)") {
                return true
            }
        }
        return false
    }

    /// Extract readable words from a URL path (split on /, -, _, %20).
    /// e.g. "https://reddit.com/r/learnpython/comments/abc" → "r learnpython comments abc"
    private func urlPathSegments(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return "" }
        let path = parsed.path + (parsed.query.map { "?\($0)" } ?? "")
        return path
            .replacingOccurrences(of: "%20", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: "/-_"))
            .joined(separator: " ")
    }

    /// Build the shared profile/plan header lines used by both scoring backends.
    /// Returns an empty string when both inputs are empty/whitespace.
    private func contextHeader(profile: String, dailyPlan: String) -> String {
        let p = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = dailyPlan.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileLine = p.isEmpty ? "" : "About the user: \(p)\n"
        let planLine    = d.isEmpty ? "" : "Today's focus: \(d)\n"
        return profileLine + planLine
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    /// When `ocrText` is provided (OCR verification pass), it is appended as additional context.
    /// No reference to a prior verdict is included (Flag 2).
    private func scoreWithFoundationModels(
        pageTitle: String,
        intention: String,
        intentionDescription: String = "",
        profile: String,
        dailyPlan: String,
        url: String = "",
        pageDescription: String = "",
        contentType: ContentType = .webpage,
        bundleIdentifier: String = "",
        ocrText: String = ""
    ) async throws -> Result {
        let descLine = intentionDescription.isEmpty ? "" : "\nBlock description: \(intentionDescription)"
        let urlLine = url.isEmpty ? "" : "\nURL path: \(URL(string: url)?.path ?? url)"
        let pageDescLine = pageDescription.isEmpty ? "" : "\nPage description: \(pageDescription)"
        let ocrBlock = ocrText.isEmpty ? "" : """

        On-screen text (may include sidebar, history, and navigation chrome — use to CONFIRM the page title's topic, not to override a clearly off-task title):
        \(ocrText)
        """
        // Clean page title: strip HTML entities and non-ASCII punctuation that confuse the model
        let cleanTitle = pageTitle
            .replacingOccurrences(of: #"&[a-zA-Z0-9#]+;"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "™", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Enrich app name for application scoring
        let displayTitle: String
        let contentLabel: String
        if contentType == .application {
            displayTitle = enrichAppName(cleanTitle, bundleIdentifier: bundleIdentifier)
            contentLabel = "Application in use"
        } else {
            displayTitle = cleanTitle
            contentLabel = "Webpage title"
        }

        // App line: prefer `App: <bundleID> ("<displayTitle>")` when bundleIdentifier is present,
        // otherwise fall back to `<contentLabel>: "<displayTitle>"`. Names are always quoted so
        // values containing parentheses (e.g. "Visual Studio Code (Insiders)") don't confuse the model.
        let appLine: String
        if !bundleIdentifier.isEmpty {
            appLine = "App: \(bundleIdentifier) (\"\(displayTitle)\")"
        } else {
            appLine = "\(contentLabel): \"\(displayTitle)\""
        }

        let userMessage = """
        \(contextHeader(profile: profile, dailyPlan: dailyPlan))Current time block task: "\(intention)"\(descLine)
        \(appLine)\(urlLine)\(pageDescLine)\(ocrBlock)
        """

        appDelegate?.postLog("🧠 [Prompt] Foundation Models input\(ocrText.isEmpty ? "" : " +OCR"):\n\(userMessage)")

        let response = try await session.respond(to: userMessage, generating: RelevanceOutput.self)
        let output = response.content

        let result = Result(
            relevant: output.relevant,
            confidence: output.confidence,
            reason: output.reason
        )

        appDelegate?.postLog("🧠 Score: \"\(pageTitle)\" → \(result.relevant ? "relevant" : "NOT relevant") (\(result.confidence)%) — \(result.reason)")
        return result
    }
    #endif

    // MARK: - MLX (Qwen)

    /// Default model. The benchmark can override via reloadModel(id:).
    /// 2026-05-18: bumped 4B → 8B after benchmark showed 4B's documented
    /// classification-flip bug. See SweepBenchmark for accuracy numbers.
    /// 2026-05-20: swapped back to 4B for speed testing; 8B was too slow at runtime.
    var currentModelId: String = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    /// Lazily load the currently-configured MLX model on first use.
    func loadMLXModelIfNeeded() async {
        guard !mlxModelLoaded && !mlxModelLoading else { return }
        await loadModelFresh(id: currentModelId)
    }

    /// Force-load a specific model, unloading any current one first.
    /// Used by the benchmark to A/B between models (4B vs 8B vs others)
    /// without restarting the app.
    func reloadModel(id newId: String) async {
        currentModelId = newId
        mlxModelLoaded = false
        mlxSession = nil
        mlxContext = nil
        // Drop GPU cache so the new weights don't fight the old ones for RAM.
        MLX.GPU.clearCache()
        await loadModelFresh(id: newId)
    }

    private func loadModelFresh(id: String) async {
        mlxModelLoading = true
        do {
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
            let model = try await loadModel(id: id)
            mlxContext = model
            let session = ChatSession(model)
            // Greedy decoding (temp=0) for classification — deterministic
            // verdicts across runs, so benchmark numbers don't drift.
            session.generateParameters.temperature = 0.0
            mlxSession = session
            mlxModelLoaded = true
            appDelegate?.postLog("🧠 MLX loaded successfully: \(id) (temp=0.0)")
        } catch {
            appDelegate?.postLog("⚠️ MLX model load failed (\(id)): \(error)")
        }
        mlxModelLoading = false
    }

    /// Score relevance using MLX Qwen3-4B with split prompts, enrichment, and few-shot examples.
    /// When `ocrText` is provided (OCR verification pass), it is appended as additional context
    /// to the same prompt structure — no reference to a prior verdict (Flag 2).
    private func scoreWithMLX(
        pageTitle: String,
        intention: String,
        intentionDescription: String,
        profile: String,
        dailyPlan: String,
        url: String = "",
        pageDescription: String = "",
        contentType: ContentType,
        bundleIdentifier: String = "",
        ocrText: String = ""
    ) async throws -> Result {
        guard let session = mlxSession else {
            throw NSError(domain: "RelevanceScorer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "MLX model not loaded"])
        }

        let header = contextHeader(profile: profile, dailyPlan: dailyPlan)
        let descLine = intentionDescription.isEmpty ? "" : "\nDescription: \(intentionDescription)"
        let cleanTitle = pageTitle
            .replacingOccurrences(of: #"&[a-zA-Z0-9#]+;"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "™", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Select prompt and build user message based on content type
        let selectedSystemPrompt: String
        let fewShot: String
        let evaluationPart: String

        // OCR excerpt block — appended only when present. The preface warns the model that
        // the text may include platform chrome (sidebars, conversation history, nav links)
        // and should CONFIRM — not override — what the page title says. Without this guard,
        // a single tangential URL in Claude's sidebar (e.g. "anthropic.com/engineering/...")
        // was flipping clearly off-task medical/personal pages to RELEVANT for coding tasks.
        let ocrBlock = ocrText.isEmpty ? "" : """

        On-screen text (may include sidebar, history, and navigation chrome — use to CONFIRM the page title's topic, not to override a clearly off-task title):
        \(ocrText)
        """

        if contentType == .application {
            selectedSystemPrompt = appSystemPrompt
            fewShot = appFewShotExamples()

            let enrichedName = enrichAppName(cleanTitle, bundleIdentifier: bundleIdentifier)
            let appLine: String
            if !bundleIdentifier.isEmpty {
                appLine = "App: \(bundleIdentifier) (\"\(enrichedName)\")"
            } else {
                appLine = "App: \"\(enrichedName)\""
            }
            evaluationPart = """
            \(header)Now classify:
            Task: "\(intention)"\(descLine)
            \(appLine)\(ocrBlock)
            """
        } else {
            selectedSystemPrompt = webSystemPrompt
            fewShot = webFewShotExamples()

            let browserLine = bundleIdentifier.isEmpty ? "" : "Browser: \(bundleIdentifier)\n"
            let urlLine = url.isEmpty ? "" : "\nURL: \(URL(string: url)?.path ?? url)"
            let pageDescLine = pageDescription.isEmpty ? "" : "\nPage description: \(pageDescription)"
            evaluationPart = """
            \(header)Now classify:
            Task: "\(intention)"\(descLine)
            \(browserLine)Page: "\(cleanTitle)"\(urlLine)\(pageDescLine)\(ocrBlock)
            """
        }

        // Build the full prompt: system + few-shot + evaluation + /no_think
        let prompt = """
        \(selectedSystemPrompt)

        \(fewShot)

        \(evaluationPart)

        /no_think
        """

        appDelegate?.postLog("🧠 [Prompt] MLX (\(contentType == .application ? "app" : "web")\(ocrText.isEmpty ? "" : "+OCR")):\n\(evaluationPart)")

        let response = try await session.respond(to: prompt)

        // Parse JSON from response
        let result = parseMLXResponse(response)
        appDelegate?.postLog("🧠 MLX Score: \"\(pageTitle)\" → \(result.relevant ? "relevant" : "NOT relevant") (\(result.confidence)%) — \(result.reason)")
        return result
    }

    /// Parse JSON response from MLX model output.
    private func parseMLXResponse(_ text: String) -> Result {
        // Strip any <think>...</think> blocks that might appear despite /no_think
        var cleanedText = text
        if let thinkStart = cleanedText.range(of: "<think>"),
           let thinkEnd = cleanedText.range(of: "</think>") {
            cleanedText.removeSubrange(thinkStart.lowerBound...thinkEnd.upperBound)
        }

        // Try to extract JSON object from the response
        guard let jsonStart = cleanedText.firstIndex(of: "{"),
              let jsonEnd = cleanedText[jsonStart...].lastIndex(of: "}") else {
            appDelegate?.postLog("⚠️ MLX: No JSON found in response: \(text.prefix(200))")
            return Result(relevant: false, confidence: 0, reason: "Could not assess - AI model error")
        }

        let jsonString = String(cleanedText[jsonStart...jsonEnd])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let relevant = json["relevant"] as? Bool,
              let reason = json["reason"] as? String else {
            appDelegate?.postLog("⚠️ MLX: Failed to parse JSON: \(jsonString.prefix(200))")
            return Result(relevant: false, confidence: 0, reason: "Could not assess - AI model error")
        }

        let confidence = json["confidence"] as? Int ?? 0
        return Result(relevant: relevant, confidence: confidence, reason: reason)
    }

    // MARK: - Batch Tab Scoring (close-the-noise sweep)

    /// Verdict for a single tab in a batch scoring call.
    struct TabVerdict: Equatable {
        let title: String
        let url: String
        let relevant: Bool
        let confidence: Int
    }

    /// Score N browser tabs against a single intent in one LLM call.
    /// Used by the close-the-noise sweep to decide which tabs to stash.
    ///
    /// Prompt asks the model to emit one JSON line per tab so we can stream-parse
    /// (vs returning a single giant array that's brittle on truncation).
    /// Unparseable / missing entries default to `relevant: false, confidence: 0` —
    /// matches the spec's "default-stash for unsure" rule (stash is recoverable).
    ///
    /// 2026-05-18: rewrote prompt with single-mode-style scaffolding (system
    /// message defining the task, few-shot examples, explicit confidence
    /// calibration). Bare prompt was producing "relevant=true confidence=10"
    /// on obvious distractors (ZipRecruiter, ADHD competitors) — Qwen had no
    /// frame for what 'on-task' meant.
    func scoreTabBatch(intent: String,
                       tabs: [(title: String, url: String)]) async -> [TabVerdict] {
        guard !tabs.isEmpty else { return [] }

        var lines = [String]()
        for (i, t) in tabs.enumerated() {
            let trimmedTitle = String(t.title.prefix(140))
            let trimmedURL = String(t.url.prefix(200))
            lines.append("\(i + 1). [\(trimmedTitle)] \(trimmedURL)")
        }

        let prompt = """
        You are a tab-classification assistant for a focus app. Your job is
        to decide which browser tabs are ON-TASK for the user's current
        focus session and which are distractions that should be closed.

        ─── User's session intent ───
        \(intent)

        ─── Rules ───
        ON-TASK = the tab is directly useful for the stated intent.
          * Same project name / same domain owned by the user.
          * A tool the user explicitly named (IDE, terminal, Claude, etc.).
          * A topic the user said they're working on.
          * A site whose category the user said is allowed (e.g. "domains",
            "email setup", "software dev").

        OFF-TASK = the tab is unrelated to the stated intent.
          * Personal email / inbox (unless intent specifically names it).
          * Job boards / job listings (unless intent says job search).
          * News, social media, recreational video, shopping.
          * Competitor research, unrelated reading, old searches.
          * Generic newtab / chrome://newtab pages.

        ─── Confidence calibration ───
        Use the FULL confidence range. Don't default to 30 for everything.

          * 90-100: OBVIOUS off-task / on-task. The category is unmistakable.
          * 70-89: clear signal but title is a bit ambiguous.
          * 40-69: genuine uncertainty — weak signal, could go either way.
          * 0-39: title gives literally no clue what the tab is.

        IMPORTANT: when a tab is OBVIOUSLY OFF-TASK because of its CATEGORY
        — a job board (ZipRecruiter, SmartRecruiters, LinkedIn jobs), a
        news site, social media, recreational video, shopping, competitor
        research, an unrelated app's marketing page — return confidence
        80-95 with relevant=false. Do NOT use confidence=30 for these.
        Confidence=30 is reserved for tabs whose category itself is unclear.

        Same applies in reverse: an OBVIOUS on-task tab (the user's own
        project domain, a tool they explicitly named) should return
        confidence 80-95 with relevant=true.

        ─── Examples ───
        Intent: "Working on website setup for thebeseen.app — domains, email, Claude, IDE"
          1. [DNS records | thebeseen.app | Cloudflare] https://dash.cloudflare.com/.../thebeseen.app/dns
             → {"i": 1, "relevant": true, "confidence": 95}
          2. [Inbox - Gmail] https://mail.google.com/mail/u/0/#inbox
             → {"i": 2, "relevant": false, "confidence": 75}
          3. [5 TOOL PERFORMANCE Jobs - ZipRecruiter] https://ziprecruiter.com/co/...
             → {"i": 3, "relevant": false, "confidence": 95}
          4. [Claude.ai conversation - wellness brand] https://claude.ai/chat/...
             → {"i": 4, "relevant": true, "confidence": 70}
          5. [Saner.AI ADHD assistant] https://saner.ai/
             → {"i": 5, "relevant": false, "confidence": 90}
          6. [Reddit /r/programming] https://reddit.com/r/programming
             → {"i": 6, "relevant": false, "confidence": 80}
          7. [Supabase API Keys | beseen-prod] https://supabase.com/dashboard/project/.../settings/api-keys
             → {"i": 7, "relevant": true, "confidence": 90}

        ─── Tabs to classify ───
        \(lines.joined(separator: "\n"))

        ─── Output ───
        One JSON object per line, in the same numbered order. No other text.

        /no_think
        """

        let raw = await runBatchPrompt(prompt: prompt)
        return parseTabBatchOutput(raw: raw, tabs: tabs)
    }

    /// Routes the batch prompt to whichever model is loaded. Prefers Qwen
    /// (the user's chosen model); falls back to Apple Foundation Models on
    /// macOS 26+ if Qwen isn't loaded. Fail-closed: returns empty string on
    /// any failure (caller will default-stash all tabs).
    private func runBatchPrompt(prompt: String) async -> String {
        beginInference()
        defer { endInference() }
        // Ensure MLX model is loaded before the first scoring call. Without
        // this await, scoreTabBatch races the lazy load and returns empty on
        // first invocation (every tab default-stashes / default-keeps).
        // scoreRelevance already has this guard — mirror it here.
        await loadMLXModelIfNeeded()

        // Prefer MLX Qwen if loaded.
        if mlxModelLoaded, let session = mlxSession {
            do {
                return try await session.respond(to: prompt)
            } catch {
                appDelegate?.postLog("⚠️ scoreTabBatch MLX error: \(error)")
            }
        }

        // Fallback: Apple Foundation Models (macOS 26+).
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let response = try await session.respond(to: prompt)
                return response.content
            } catch {
                appDelegate?.postLog("⚠️ scoreTabBatch Apple FM error: \(error)")
            }
        }
        #endif

        // No model available — caller will default-stash everything.
        appDelegate?.postLog("⚠️ scoreTabBatch: no LLM available; defaulting all tabs to stash")
        return ""
    }

    private func parseTabBatchOutput(raw: String,
                                     tabs: [(title: String, url: String)]) -> [TabVerdict] {
        // Strip any <think>...</think> blocks that might appear despite /no_think.
        var cleaned = raw
        while let thinkStart = cleaned.range(of: "<think>"),
              let thinkEnd = cleaned.range(of: "</think>") {
            cleaned.removeSubrange(thinkStart.lowerBound...thinkEnd.upperBound)
        }

        var byIndex: [Int: (Bool, Int)] = [:]
        for line in cleaned.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let i = json["i"] as? Int,
                  let rel = json["relevant"] as? Bool else { continue }
            let conf = (json["confidence"] as? Int) ?? 0
            byIndex[i] = (rel, conf)
        }
        return tabs.enumerated().map { i, t in
            let (rel, conf) = byIndex[i + 1] ?? (false, 0)
            return TabVerdict(title: t.title, url: t.url, relevant: rel, confidence: conf)
        }
    }

    // MARK: - Justification Assessment

    /// Assess whether a user's justification for visiting social media is work-related.
    /// (R6: former EarnedBrowseManager consumer deleted; still used by the
    /// justification flow in FocusMonitor.)
    func assessJustification(text: String, intention: String, intentionDescription: String = "") async -> (approved: Bool, reason: String) {
        beginInference()
        defer { endInference() }
        let userMessage = """
        The user is working on: "\(intention)"\(intentionDescription.isEmpty ? "" : " — \(intentionDescription)")
        They want to visit social media and gave this reason: "\(text)"

        Is this reason DIRECTLY related to their work task?
        Only approve if the social media visit would genuinely help with the specific task.
        Do NOT approve vague reasons like "I need a break" or "checking something".

        Respond with JSON: {"approved": true/false, "reason": "one sentence explanation"}

        /no_think
        """

        // Try MLX model first — Qwen3-4B is the hardcoded model (S2, 2026-06-10).
        if mlxModelLoaded, let session = mlxSession {
            do {
                let response = try await session.respond(to: userMessage)
                if let jsonStart = response.firstIndex(of: "{"),
                   let jsonEnd = response[jsonStart...].lastIndex(of: "}") {
                    let jsonString = String(response[jsonStart...jsonEnd])
                    if let data = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let approved = json["approved"] as? Bool,
                       let reason = json["reason"] as? String {
                        appDelegate?.postLog("🧠 Justification assessed (MLX): approved=\(approved), reason=\(reason)")
                        return (approved: approved, reason: reason)
                    }
                }
            } catch {
                appDelegate?.postLog("⚠️ MLX justification assessment error: \(error)")
            }
        }

        // Try Apple Foundation Models
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let response = try await session.respond(to: userMessage, generating: RelevanceOutput.self)
                let approved = response.content.relevant
                let reason = response.content.reason
                appDelegate?.postLog("🧠 Justification assessed (Apple FM): approved=\(approved), reason=\(reason)")
                return (approved: approved, reason: reason)
            } catch {
                appDelegate?.postLog("⚠️ Foundation Models justification error: \(error)")
            }
        }
        #endif

        // Fallback: deny by default (conservative)
        return (approved: false, reason: "Scoring unavailable — defaulting to standard rate")
    }

    // MARK: - Telemetry Screen Description (Focus Agent)

    /// ONE locally-generated sentence about what the user appears to be doing
    /// on screen, for coach telemetry. Pipeline: ScreenCapture → Vision OCR →
    /// Qwen3-4B (text) — the on-device bridge until a VLM replaces the
    /// capture→understand step.
    ///
    /// Guarantees:
    /// - Never throws, never blocks the caller's cadence — returns nil on ANY
    ///   failure (no model, no permission, empty OCR, unparseable output).
    /// - Never races in-session scoring: checks `isInferenceBusy` before AND
    ///   after the model-load await and SKIPs (returns nil) if scoring is
    ///   mid-flight. Scoring has priority; descriptions are best-effort.
    /// - Uses a fresh one-shot ChatSession so the shared scoring session's
    ///   conversation history stays clean, with temperature 0 pinned
    ///   (clearCache resets the shared session to 0.2).
    func describeScreenForTelemetry() async -> String? {
        // Yield to scoring: skip rather than queue.
        guard !isInferenceBusy else { return nil }

        // MLX lazy load does NOT auto-await — mirror scoreRelevance's guard.
        await loadMLXModelIfNeeded()
        guard mlxModelLoaded, let context = mlxContext else { return nil }

        // Re-check after the (potentially long) model-load suspension.
        guard !isInferenceBusy else { return nil }
        beginInference()
        defer { endInference() }

        // Capture frontmost window. nil == no screen-recording permission or no
        // capturable window — fail silently (telemetry never prompts; the OCR
        // verification path owns the permission prompt).
        guard let capture = (try? await ScreenCapture().captureFrontmostWindow()) ?? nil else {
            return nil
        }
        await MainActor.run { self.hasCapturedBefore = true }

        let ocrText = (try? await OCREngine().extractText(from: capture.image)) ?? ""
        guard !ocrText.isEmpty else { return nil }
        let excerpt = String(ocrText.prefix(600))

        // App name + window title — cheap context, read on the main actor
        // (NSWorkspace + AX, mirroring scoreRelevance's frontmost-PID read).
        let (appName, windowTitle): (String, String?) = await MainActor.run {
            let front = NSWorkspace.shared.frontmostApplication
            let name = front?.localizedName ?? front?.bundleIdentifier ?? "unknown app"
            let title = CoachTelemetry.frontmostWindowTitle().map { String($0.prefix(100)) }
            return (name, title)
        }
        let titleLine = windowTitle.map { "\nWindow title: \($0)" } ?? ""

        let prompt = """
        In one short sentence, state what the user appears to be doing based on this screen text. Then on a new line one category: work | communication | entertainment | shopping | neutral.

        App: \(appName)\(titleLine)
        Screen text: \(excerpt)

        /no_think
        """

        // One-shot session: temp=0 (deterministic), ~60-token cap (one sentence
        // + one category word), no shared-session history pollution.
        let session = ChatSession(context)
        session.generateParameters.temperature = 0.0
        session.generateParameters.maxTokens = 60

        guard let raw = try? await session.respond(to: prompt) else { return nil }
        return Self.parseDescriptionResponse(raw)
    }

    /// Parse the model's "sentence\ncategory" output into a single
    /// "sentence [category]" string. Returns nil if no usable sentence.
    /// Internal (not private) for testability.
    static func parseDescriptionResponse(_ raw: String) -> String? {
        // Strip any <think>...</think> blocks that appear despite /no_think.
        var cleaned = raw
        while let thinkStart = cleaned.range(of: "<think>"),
              let thinkEnd = cleaned.range(of: "</think>"),
              thinkStart.lowerBound < thinkEnd.upperBound {
            cleaned.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }
        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let sentence = lines.first, sentence.count >= 3 else { return nil }

        let categories: Set<String> = ["work", "communication", "entertainment", "shopping", "neutral"]
        var category = "neutral"
        for line in lines.dropFirst() {
            let token = line.lowercased()
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if categories.contains(token) {
                category = token
                break
            }
        }
        return "\(String(sentence.prefix(200))) [\(category)]"
    }
}

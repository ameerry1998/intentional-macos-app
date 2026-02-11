import Foundation

/// Tracks time spent on YouTube/Instagram across ALL browsers
/// This is the single source of truth for time tracking that can't be bypassed by switching browsers
class TimeTracker {

    weak var appDelegate: AppDelegate?
    weak var backendClient: BackendClient?

    // Daily usage storage (persisted)
    private var dailyUsage: [String: DailyUsage] = [:] // platform -> usage

    // Budget settings (synced from backend/settings)
    private var budgets: [String: Int] = [:] // platform -> minutes

    // Active sessions per browser
    private var activeSessions: [String: BrowserSession] = [:] // "platform:browser" -> session

    // Deduplication: track last heartbeat time per platform to prevent double-counting
    private var lastHeartbeatTime: [String: Date] = [:] // platform -> last heartbeat time

    // Canonical sessions per platform (shared across all browsers)
    private var platformSessions: [String: PlatformSession] = [:] // "youtube" -> PlatformSession

    /// Called when session state changes. The NativeMessagingHost sets this to broadcast SESSION_SYNC.
    var onSessionChanged: ((_ platform: String) -> Void)?

    // Session expiry timer
    private var sessionExpiryTimer: Timer?

    // File paths for persistence
    private let usageFileURL: URL
    private let settingsFileURL: URL
    private let sessionsFileURL: URL

    // Sync timer
    private var syncTimer: Timer?

    struct DailyUsage: Codable {
        var date: String // "YYYY-MM-DD"
        var minutesUsed: Double
        var videoMinutes: Double // Time when video was actually playing
        var lastUpdated: Date

        static func today() -> DailyUsage {
            return DailyUsage(
                date: Self.todayString(),
                minutesUsed: 0,
                videoMinutes: 0,
                lastUpdated: Date()
            )
        }

        static func todayString() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: Date())
        }
    }

    struct BrowserSession {
        var platform: String
        var browser: String
        var intent: String?
        var startTime: Date
        var lastHeartbeat: Date
        var totalSeconds: Int
        var videoSeconds: Int
    }

    /// Canonical session state per platform — shared across ALL browsers.
    /// When a session starts in one browser, it's the same session in every browser.
    struct PlatformSession: Codable {
        var active: Bool
        var intent: String?
        var categories: [String]?
        var startedAt: Double?       // Date.now() timestamp (ms since epoch)
        var endsAt: Double?          // Date.now() + duration, or nil for unlimited
        var durationMinutes: Int

        static func inactive() -> PlatformSession {
            return PlatformSession(active: false, intent: nil, categories: nil, startedAt: nil, endsAt: nil, durationMinutes: 0)
        }
    }

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate

        // Set up file paths in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let intentionalDir = appSupport.appendingPathComponent("Intentional")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: intentionalDir, withIntermediateDirectories: true)

        usageFileURL = intentionalDir.appendingPathComponent("daily_usage.json")
        settingsFileURL = intentionalDir.appendingPathComponent("time_settings.json")
        sessionsFileURL = intentionalDir.appendingPathComponent("platform_sessions.json")

        // Load persisted data
        loadUsage()
        loadSettings()
        loadPlatformSessions()

        // Start sync timer (sync to backend every 60 seconds)
        startSyncTimer()

        // Start session expiry timer (checks every 5 seconds)
        startSessionExpiryTimer()

        appDelegate?.postLog("⏱️ TimeTracker initialized")
    }

    deinit {
        syncTimer?.invalidate()
        sessionExpiryTimer?.invalidate()
    }

    // MARK: - Public API

    /// Record time spent on a platform (called by NativeMessagingHost)
    func recordTime(platform: String, browser: String, seconds: Int, isVideoPlaying: Bool, url: String?) {
        let key = platform.lowercased()

        // Sanity check: reject absurd values (max 60 seconds per update, since interval is 10s)
        // This prevents bugs like the extension sending Date.now()/1000 as seconds
        let clampedSeconds = min(seconds, 60)
        if seconds > 60 {
            appDelegate?.postLog("⚠️ recordTime: Clamped \(platform) seconds from \(seconds) to \(clampedSeconds) (likely bug in extension)")
        }

        // Ensure we have a daily usage entry for today
        ensureTodayEntry(for: key)

        // Add time
        let minutes = Double(clampedSeconds) / 60.0
        dailyUsage[key]?.minutesUsed += minutes
        dailyUsage[key]?.lastUpdated = Date()

        if isVideoPlaying {
            dailyUsage[key]?.videoMinutes += minutes
        }

        // Update session if exists
        let sessionKey = "\(key):\(browser)"
        if activeSessions[sessionKey] != nil {
            activeSessions[sessionKey]?.totalSeconds += clampedSeconds
            activeSessions[sessionKey]?.lastHeartbeat = Date()
            if isVideoPlaying {
                activeSessions[sessionKey]?.videoSeconds += clampedSeconds
            }
        }

        // Save periodically (every 10 updates)
        saveUsage()

        // Log every minute of usage
        if let usage = dailyUsage[key], Int(usage.minutesUsed) != Int(usage.minutesUsed - minutes) {
            appDelegate?.postLog("⏱️ \(platform): \(Int(usage.minutesUsed)) min used (video: \(Int(usage.videoMinutes)) min)")
        }
    }

    /// Record usage heartbeat from extension (new cross-browser tracking)
    /// Called when tab is visible OR audio is playing
    /// DEDUPLICATION: Multiple tabs may send heartbeats - only count actual elapsed time
    func recordUsageHeartbeat(platform: String, browser: String, seconds: Int, timestamp: Double) {
        let key = platform.lowercased()
        let now = Date()

        // Ensure we have a daily usage entry for today
        ensureTodayEntry(for: key)

        // DEDUPLICATION: Calculate actual elapsed time since last heartbeat
        let actualSeconds: Int
        if let lastTime = lastHeartbeatTime[key] {
            let elapsed = now.timeIntervalSince(lastTime)
            // Guard against negative elapsed (clock skew, stale lastHeartbeatTime from previous run)
            // and clamp to reasonable maximum (60s for a 30s heartbeat interval)
            let clampedElapsed = max(0, min(elapsed, 60.0))
            // Use the MINIMUM of reported seconds and actual elapsed time
            // This prevents over-counting when multiple tabs send heartbeats
            actualSeconds = min(seconds, Int(clampedElapsed))

            if actualSeconds < seconds {
                appDelegate?.postLog("💓 \(platform) (\(browser)): +\(actualSeconds)s (reported \(seconds)s, clamped — \(Int(clampedElapsed))s since last heartbeat)")
            } else {
                appDelegate?.postLog("💓 \(platform) (\(browser)): +\(actualSeconds)s")
            }
        } else {
            // First heartbeat - trust the reported value
            actualSeconds = seconds
            appDelegate?.postLog("💓 \(platform) (\(browser)): +\(actualSeconds)s (first heartbeat)")
        }

        // Update last heartbeat time
        lastHeartbeatTime[key] = now

        // Add time
        let minutes = Double(actualSeconds) / 60.0
        dailyUsage[key]?.minutesUsed += minutes
        dailyUsage[key]?.lastUpdated = now

        // Update session if exists
        let sessionKey = "\(key):\(browser)"
        if activeSessions[sessionKey] != nil {
            activeSessions[sessionKey]?.totalSeconds += actualSeconds
            activeSessions[sessionKey]?.lastHeartbeat = now
        }

        // Save periodically
        saveUsage()

        // Log when crossing a minute boundary
        if let usage = dailyUsage[key], Int(usage.minutesUsed) != Int(usage.minutesUsed - minutes) {
            appDelegate?.postLog("⏱️ \(platform) total: \(Int(usage.minutesUsed)) min")
        }
    }

    /// Start a session for a platform/browser
    func startSession(platform: String, browser: String, intent: String?) {
        let key = "\(platform.lowercased()):\(browser)"

        activeSessions[key] = BrowserSession(
            platform: platform,
            browser: browser,
            intent: intent,
            startTime: Date(),
            lastHeartbeat: Date(),
            totalSeconds: 0,
            videoSeconds: 0
        )

        appDelegate?.postLog("🎬 Session started: \(platform) on \(browser) (intent: \(intent ?? "none"))")
    }

    /// End a session for a platform/browser
    func endSession(platform: String, browser: String) {
        let key = "\(platform.lowercased()):\(browser)"

        if let session = activeSessions[key] {
            let duration = Int(Date().timeIntervalSince(session.startTime))
            appDelegate?.postLog("🛑 Session ended: \(platform) on \(browser) (duration: \(duration)s)")

            // Send session summary to backend
            Task {
                await backendClient?.sendEvent(type: "session_ended", details: [
                    "platform": platform,
                    "browser": browser,
                    "duration_seconds": duration,
                    "video_seconds": session.videoSeconds,
                    "intent": session.intent ?? ""
                ])
            }
        }

        activeSessions.removeValue(forKey: key)
    }

    /// Check if budget is exceeded for a platform
    func isBudgetExceeded(for platform: String) -> Bool {
        let key = platform.lowercased()
        guard let budget = budgets[key], budget > 0 else { return false }
        guard let usage = dailyUsage[key] else { return false }

        return Int(usage.minutesUsed) >= budget
    }

    /// Get minutes used for a platform
    func getMinutesUsed(for platform: String) -> Int {
        return Int(dailyUsage[platform.lowercased()]?.minutesUsed ?? 0)
    }

    /// Get budget for a platform
    func getBudget(for platform: String) -> Int {
        return budgets[platform.lowercased()] ?? 0
    }

    /// Set budget for a platform (called when syncing from backend/settings)
    func setBudget(for platform: String, minutes: Int) {
        budgets[platform.lowercased()] = minutes
        saveSettings()
    }

    /// Get all usage data (for syncing to backend)
    func getAllUsage() -> [String: Any] {
        var result: [String: Any] = [:]

        for (platform, usage) in dailyUsage {
            result[platform] = [
                "date": usage.date,
                "minutesUsed": Int(usage.minutesUsed),
                "videoMinutes": Int(usage.videoMinutes)
            ]
        }

        return result
    }

    /// Get daily usage for UI display
    func getDailyUsage() -> [String: DailyUsage] {
        return dailyUsage
    }

    /// Get active sessions for UI display
    func getActiveSessions() -> [BrowserSession] {
        return Array(activeSessions.values)
    }

    /// Get per-browser usage breakdown
    func getUsageBreakdown() -> [(platform: String, browser: String, minutes: Int, videoMinutes: Int)] {
        var breakdown: [(platform: String, browser: String, minutes: Int, videoMinutes: Int)] = []

        // Get usage from active sessions
        for session in activeSessions.values {
            let minutes = session.totalSeconds / 60
            let videoMinutes = session.videoSeconds / 60
            breakdown.append((platform: session.platform, browser: session.browser, minutes: minutes, videoMinutes: videoMinutes))
        }

        return breakdown.sorted { (a, b) in a.minutes > b.minutes }
    }

    // MARK: - Platform Sessions (Cross-Browser)

    /// Get the canonical session for a platform
    func getPlatformSession(for platform: String) -> PlatformSession {
        return platformSessions[platform.lowercased()] ?? .inactive()
    }

    /// Get all platform sessions (used by NativeMessagingHost for SESSION_SYNC)
    func getAllPlatformSessions() -> [String: PlatformSession] {
        return platformSessions
    }

    /// Set/update a platform session (first-writer-wins: ignores if already active)
    /// Returns true if the session was set, false if an active session already exists
    @discardableResult
    func setPlatformSession(for platform: String, session: PlatformSession) -> Bool {
        let key = platform.lowercased()

        // First-writer-wins: if a session is already active, reject the new one
        if let existing = platformSessions[key], existing.active {
            appDelegate?.postLog("🔒 \(platform) session already active (first-writer-wins), ignoring new session")
            return false
        }

        platformSessions[key] = session
        savePlatformSessions()
        appDelegate?.postLog("🌐 Platform session set: \(platform) active=\(session.active) intent=\(session.intent ?? "none") duration=\(session.durationMinutes)min")

        onSessionChanged?(key)
        return true
    }

    /// Clear a platform session (on SESSION_END or expiry)
    func clearPlatformSession(for platform: String) {
        let key = platform.lowercased()

        guard platformSessions[key]?.active == true else { return }

        platformSessions[key] = .inactive()
        savePlatformSessions()
        appDelegate?.postLog("🌐 Platform session cleared: \(platform)")

        onSessionChanged?(key)
    }

    /// Build the SESSION_SYNC message payload for sending to extensions.
    /// Used by both NativeMessagingHost (single connection) and SocketRelayServer (broadcast).
    func getSessionSyncPayload() -> [String: Any] {
        var message: [String: Any] = ["type": "SESSION_SYNC"]

        for platform in ["youtube", "instagram", "facebook"] {
            let session = getPlatformSession(for: platform)
            var platformData: [String: Any] = [
                "active": session.active,
                "durationMinutes": session.durationMinutes
            ]
            // Use NSNull for nil values so JSON serialization includes them as null
            platformData["intent"] = session.intent ?? NSNull()
            platformData["categories"] = session.categories ?? NSNull()
            platformData["startedAt"] = session.startedAt ?? NSNull()
            platformData["endsAt"] = session.endsAt ?? NSNull()
            message[platform] = platformData
        }

        return message
    }

    /// Update an existing platform session (e.g. extend timer)
    func updatePlatformSession(for platform: String, endsAt: Double?, durationMinutes: Int?) {
        let key = platform.lowercased()
        guard platformSessions[key]?.active == true else { return }

        if let endsAt = endsAt {
            platformSessions[key]?.endsAt = endsAt
        }
        if let durationMinutes = durationMinutes {
            platformSessions[key]?.durationMinutes = durationMinutes
        }

        savePlatformSessions()
        appDelegate?.postLog("🌐 Platform session updated: \(platform) endsAt=\(endsAt.map { String($0) } ?? "unchanged")")

        onSessionChanged?(key)
    }

    // MARK: - Persistence

    private func ensureTodayEntry(for platform: String) {
        let today = DailyUsage.todayString()

        if dailyUsage[platform]?.date != today {
            // New day - reset usage
            dailyUsage[platform] = DailyUsage.today()
            appDelegate?.postLog("📅 New day - reset \(platform) usage")
        }
    }

    private func loadUsage() {
        guard FileManager.default.fileExists(atPath: usageFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: usageFileURL)
            dailyUsage = try JSONDecoder().decode([String: DailyUsage].self, from: data)

            // Check if data is from today, otherwise reset
            let today = DailyUsage.todayString()
            for (platform, usage) in dailyUsage {
                if usage.date != today {
                    dailyUsage[platform] = DailyUsage.today()
                }
            }

            appDelegate?.postLog("📂 Loaded usage data: \(dailyUsage.keys.joined(separator: ", "))")
        } catch {
            appDelegate?.postLog("⚠️ Failed to load usage: \(error)")
        }
    }

    private func saveUsage() {
        do {
            let data = try JSONEncoder().encode(dailyUsage)
            try data.write(to: usageFileURL)
        } catch {
            appDelegate?.postLog("⚠️ Failed to save usage: \(error)")
        }
    }

    private func loadSettings() {
        guard FileManager.default.fileExists(atPath: settingsFileURL.path) else {
            // Default budgets
            budgets = ["youtube": 30, "instagram": 30, "facebook": 30]
            return
        }

        do {
            let data = try Data(contentsOf: settingsFileURL)
            budgets = try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            budgets = ["youtube": 30, "instagram": 30, "facebook": 30]
        }
    }

    private func saveSettings() {
        do {
            let data = try JSONEncoder().encode(budgets)
            try data.write(to: settingsFileURL)
        } catch {
            appDelegate?.postLog("⚠️ Failed to save settings: \(error)")
        }
    }

    private func loadPlatformSessions() {
        guard FileManager.default.fileExists(atPath: sessionsFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: sessionsFileURL)
            platformSessions = try JSONDecoder().decode([String: PlatformSession].self, from: data)

            // Check for expired sessions on load
            let now = Date().timeIntervalSince1970 * 1000 // ms since epoch
            for (platform, session) in platformSessions {
                if session.active, let endsAt = session.endsAt, endsAt <= now {
                    platformSessions[platform] = .inactive()
                    appDelegate?.postLog("🌐 Cleared expired session on load: \(platform)")
                }
            }

            let activePlatforms = platformSessions.filter { $0.value.active }.keys.joined(separator: ", ")
            if !activePlatforms.isEmpty {
                appDelegate?.postLog("📂 Loaded platform sessions: \(activePlatforms)")
            }
        } catch {
            appDelegate?.postLog("⚠️ Failed to load platform sessions: \(error)")
        }
    }

    private func savePlatformSessions() {
        do {
            let data = try JSONEncoder().encode(platformSessions)
            try data.write(to: sessionsFileURL)
        } catch {
            appDelegate?.postLog("⚠️ Failed to save platform sessions: \(error)")
        }
    }

    // MARK: - Session Expiry

    private func startSessionExpiryTimer() {
        sessionExpiryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkSessionExpiry()
        }
    }

    private func checkSessionExpiry() {
        let now = Date().timeIntervalSince1970 * 1000 // ms since epoch

        for (platform, session) in platformSessions {
            guard session.active, let endsAt = session.endsAt else { continue }

            if endsAt <= now {
                appDelegate?.postLog("⏰ Platform session expired: \(platform)")
                clearPlatformSession(for: platform)
            }
        }
    }

    // MARK: - Backend Sync

    private func startSyncTimer() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.syncToBackend()
        }
    }

    private func syncToBackend() {
        guard !dailyUsage.isEmpty else { return }

        Task { [weak self] in
            guard let self = self else { return }

            var details: [String: Any] = [:]
            for (platform, usage) in self.dailyUsage {
                details["\(platform)_minutes"] = Int(usage.minutesUsed)
                details["\(platform)_video_minutes"] = Int(usage.videoMinutes)
            }

            await self.backendClient?.sendEvent(type: "time_sync", details: details)
        }
    }

    /// Force sync (call before app terminates)
    func forceSync() {
        saveUsage()
        savePlatformSessions()
        syncToBackend()
    }
}

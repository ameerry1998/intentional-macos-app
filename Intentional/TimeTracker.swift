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

    // File paths for persistence
    private let usageFileURL: URL
    private let settingsFileURL: URL

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

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate

        // Set up file paths in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let intentionalDir = appSupport.appendingPathComponent("Intentional")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: intentionalDir, withIntermediateDirectories: true)

        usageFileURL = intentionalDir.appendingPathComponent("daily_usage.json")
        settingsFileURL = intentionalDir.appendingPathComponent("time_settings.json")

        // Load persisted data
        loadUsage()
        loadSettings()

        // Start sync timer (sync to backend every 60 seconds)
        startSyncTimer()

        appDelegate?.postLog("⏱️ TimeTracker initialized")
    }

    deinit {
        syncTimer?.invalidate()
    }

    // MARK: - Public API

    /// Record time spent on a platform (called by NativeMessagingHost)
    func recordTime(platform: String, browser: String, seconds: Int, isVideoPlaying: Bool, url: String?) {
        let key = platform.lowercased()

        // Ensure we have a daily usage entry for today
        ensureTodayEntry(for: key)

        // Add time
        let minutes = Double(seconds) / 60.0
        dailyUsage[key]?.minutesUsed += minutes
        dailyUsage[key]?.lastUpdated = Date()

        if isVideoPlaying {
            dailyUsage[key]?.videoMinutes += minutes
        }

        // Update session if exists
        let sessionKey = "\(key):\(browser)"
        if activeSessions[sessionKey] != nil {
            activeSessions[sessionKey]?.totalSeconds += seconds
            activeSessions[sessionKey]?.lastHeartbeat = Date()
            if isVideoPlaying {
                activeSessions[sessionKey]?.videoSeconds += seconds
            }
        }

        // Save periodically (every 10 updates)
        saveUsage()

        // Log every minute of usage
        if let usage = dailyUsage[key], Int(usage.minutesUsed) != Int(usage.minutesUsed - minutes) {
            appDelegate?.postLog("⏱️ \(platform): \(Int(usage.minutesUsed)) min used (video: \(Int(usage.videoMinutes)) min)")
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
            budgets = ["youtube": 30, "instagram": 30]
            return
        }

        do {
            let data = try Data(contentsOf: settingsFileURL)
            budgets = try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            budgets = ["youtube": 30, "instagram": 30]
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
        syncToBackend()
    }
}

import Foundation

/// Manages the "Earn Your Browse" budget system.
///
/// Focused work earns social media browsing time. During work blocks, social media
/// costs 2x by default; if the user provides a work-related justification, cost drops
/// to 1x as a reward. Free blocks cost 1x.
///
/// This is the "accountant" — manages the earned pool, cost multipliers, delay
/// escalation, and partner extra time. Does NOT handle heartbeat dedup (TimeTracker
/// owns that).
class EarnedBrowseManager {

    weak var appDelegate: AppDelegate?

    // MARK: - Earned Pool

    /// Total minutes earned today through focused work
    private(set) var earnedMinutes: Double = 0
    /// Total minutes used today on social media
    private(set) var usedMinutes: Double = 0
    /// Minutes available for browsing
    var availableMinutes: Double { earnedMinutes - usedMinutes }
    /// Whether the earned pool is exhausted (no browse time left)
    var isPoolExhausted: Bool { availableMinutes <= 0 }

    // MARK: - Earning Rates (min browsing earned per min worked)

    /// Standard rate: 5 min work → 1 min browse
    private let standardRate: Double = 0.2
    /// Deep work bonus: ~3.33 min work → 1 min browse (1.5x standard)
    private let deepWorkRate: Double = 0.3

    // MARK: - Cost Multipliers

    /// Cost multiplier during work blocks (no justification)
    let workBlockCost: Double = 2.0
    /// Cost multiplier during free blocks
    let freeBlockCost: Double = 1.0
    /// Cost multiplier when user provides valid work-related justification
    let justifiedCost: Double = 1.0

    // MARK: - Delay Escalation (per work block, resets on block change)

    /// Current delay in seconds before social media access
    private(set) var currentDelay: Int = 30
    /// Escalation steps
    private let delaySteps = [30, 60, 120, 300]
    /// Current index into delaySteps
    private var delayIndex: Int = 0
    /// Number of social media visits this work block
    private(set) var visitCount: Int = 0

    // MARK: - Deep Work Detection

    /// Rolling window of relevance assessments
    private var assessmentWindow: [(timestamp: Date, relevant: Bool)] = []
    /// Duration of the deep work assessment window
    private let deepWorkWindowMinutes: Double = 25
    /// Whether the user is currently in deep work mode
    private(set) var isDeepWork: Bool = false

    // MARK: - Partner Extra Time

    /// Minutes added per partner extra time request
    var partnerExtraTimeAmount: Double = 30
    /// Maximum partner extra time requests per day
    var maxDailyPartnerRequests: Int = 2
    /// Number of partner extra time requests today
    private(set) var dailyRequestCount: Int = 0

    // MARK: - Welcome Credit

    /// Minutes granted on first launch of the day
    private let welcomeCredit: Double = 5.0

    // MARK: - Day Tracking

    /// Current date string for daily reset (YYYY-MM-DD)
    private var currentDate: String = ""

    // MARK: - Per-Block Focus Tracking

    /// Focus stats for a single schedule block
    struct BlockFocusStats {
        var blockId: String
        var blockTitle: String
        var relevantTicks: Int = 0
        var totalTicks: Int = 0
        var earnedMinutes: Double = 0
        /// Focus score: percentage of ticks that were relevant (0-100)
        var focusScore: Int { totalTicks > 0 ? Int(round(Double(relevantTicks) / Double(totalTicks) * 100)) : 0 }
    }

    /// Focus stats keyed by block ID for today
    private(set) var blockFocusStats: [String: BlockFocusStats] = [:]
    /// ID of the currently active block (set by FocusMonitor on block change)
    private(set) var activeBlockId: String?

    // MARK: - Last Active App (reported by FocusMonitor)

    /// Name of the last relevant non-browser app
    private(set) var lastActiveApp: String = ""
    /// Timestamp when lastActiveApp was recorded
    private(set) var lastActiveAppTimestamp: Date?

    // MARK: - Persistence

    private let stateFileURL: URL

    // MARK: - Init

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let intentionalDir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: intentionalDir, withIntermediateDirectories: true)
        stateFileURL = intentionalDir.appendingPathComponent("earned_browse.json")
    }

    // MARK: - Work Tick (called by FocusMonitor on each relevant scoring tick)

    /// Record a work tick. Called by FocusMonitor on each relevant scoring tick (~10s).
    /// Adds time × rate to earnedMinutes. Uses deepWorkRate if isDeepWork.
    func recordWorkTick(seconds: Double) {
        ensureToday()
        let rate = isDeepWork ? deepWorkRate : standardRate
        let earned = (seconds / 60.0) * rate
        earnedMinutes += earned

        // Track per-block earning
        if let blockId = activeBlockId, var stats = blockFocusStats[blockId] {
            stats.relevantTicks += 1
            stats.totalTicks += 1
            stats.earnedMinutes += earned
            blockFocusStats[blockId] = stats
        }

        save()
        appDelegate?.mainWindowController?.pushEarnedUpdate()
        appDelegate?.socketRelayServer?.broadcastEarnedMinutesUpdate(self)
    }

    // MARK: - Social Media Time (called by TimeTracker callback)

    /// Record social media time usage. Called by TimeTracker.onSocialMediaTimeRecorded.
    /// Deducts minutes × costMultiplier from pool.
    /// Returns remaining available minutes after deduction.
    @discardableResult
    func recordSocialMediaTime(minutes: Double, isWorkBlock: Bool, isJustified: Bool) -> Double {
        ensureToday()
        let multiplier: Double
        if isWorkBlock {
            multiplier = isJustified ? justifiedCost : workBlockCost
        } else {
            multiplier = freeBlockCost
        }
        usedMinutes += minutes * multiplier
        save()
        return availableMinutes
    }

    // MARK: - Justification Assessment

    /// Assess whether a user's justification for visiting social media is work-related.
    /// Delegates to RelevanceScorer.assessJustification().
    func assessJustification(text: String, intention: String) async -> (approved: Bool, reason: String) {
        guard let scorer = appDelegate?.relevanceScorer else {
            return (approved: false, reason: "Scorer not available")
        }
        return await scorer.assessJustification(text: text, intention: intention)
    }

    // MARK: - Visit Tracking & Delay Escalation

    /// Record a social media visit during a work block.
    /// Increments visitCount and advances delay escalation.
    func recordVisit() {
        visitCount += 1
        if delayIndex < delaySteps.count - 1 {
            delayIndex += 1
        }
        currentDelay = delaySteps[delayIndex]
    }

    // MARK: - Block Change

    /// Called when the active focus block changes.
    /// Resets delay, visitCount, and deep work window.
    /// Does NOT reset earned/used pool (those are daily).
    func onBlockChanged(blockId: String? = nil, blockTitle: String? = nil) {
        delayIndex = 0
        currentDelay = delaySteps[0]
        visitCount = 0
        assessmentWindow.removeAll()
        isDeepWork = false

        // Set up per-block tracking
        activeBlockId = blockId
        if let blockId = blockId, let blockTitle = blockTitle {
            if blockFocusStats[blockId] == nil {
                blockFocusStats[blockId] = BlockFocusStats(blockId: blockId, blockTitle: blockTitle)
            }
        }

        appDelegate?.postLog("💰 EarnedBrowseManager: block changed → \(blockTitle ?? "none") — delay reset to \(currentDelay)s")
    }

    // MARK: - Deep Work Assessment

    /// Record a relevance assessment for deep work tracking.
    /// Called by FocusMonitor on each scoring tick.
    func recordAssessment(relevant: Bool) {
        let now = Date()
        assessmentWindow.append((timestamp: now, relevant: relevant))

        // Track per-block: irrelevant ticks increment totalTicks only
        if !relevant, let blockId = activeBlockId, var stats = blockFocusStats[blockId] {
            stats.totalTicks += 1
            blockFocusStats[blockId] = stats
        }

        // Prune old entries outside the window
        let cutoff = now.addingTimeInterval(-deepWorkWindowMinutes * 60)
        assessmentWindow.removeAll { $0.timestamp < cutoff }

        // Deep work: ALL assessments in the window must be relevant,
        // and we need at least (windowMinutes / poll_interval) entries
        let minEntries = Int(deepWorkWindowMinutes * 60 / 10) // ~150 entries for 25min at 10s intervals
        let wasDeepWork = isDeepWork
        if assessmentWindow.count >= minEntries && assessmentWindow.allSatisfy({ $0.relevant }) {
            isDeepWork = true
        } else {
            isDeepWork = false
        }

        if isDeepWork != wasDeepWork {
            appDelegate?.postLog("💰 Deep work: \(isDeepWork ? "ACTIVATED (1.5x earning rate)" : "deactivated")")
        }
    }

    // MARK: - Daily Reset

    /// Ensure state is for today. Resets pool on new day with welcome credit.
    func ensureToday() {
        let today = todayString()
        guard currentDate != today else { return }

        // New day — reset
        let hadPreviousDate = !currentDate.isEmpty
        currentDate = today
        earnedMinutes = welcomeCredit
        usedMinutes = 0
        dailyRequestCount = 0
        assessmentWindow.removeAll()
        isDeepWork = false
        blockFocusStats.removeAll()
        activeBlockId = nil

        if hadPreviousDate {
            appDelegate?.postLog("💰 New day — pool reset. Welcome credit: \(welcomeCredit) min")
        }
        save()
    }

    // MARK: - Partner Extra Time

    /// Request partner extra time. Returns true if granted.
    func requestPartnerExtraTime() -> Bool {
        ensureToday()
        guard dailyRequestCount < maxDailyPartnerRequests else { return false }
        dailyRequestCount += 1
        earnedMinutes += partnerExtraTimeAmount
        save()
        appDelegate?.postLog("💰 Partner extra time granted: +\(partnerExtraTimeAmount) min (request \(dailyRequestCount)/\(maxDailyPartnerRequests))")
        return true
    }

    // MARK: - Last Active App

    /// Update the last active non-browser app name and timestamp.
    func updateLastActiveApp(name: String, timestamp: Date) {
        lastActiveApp = name
        lastActiveAppTimestamp = timestamp
    }

    // MARK: - State for Extension Broadcast

    /// Build the state dictionary matching WORK_BLOCK_STATE / EARNED_MINUTES_UPDATE message format.
    func getWorkBlockState(intention: String) -> [String: Any] {
        ensureToday()
        let isWorkBlock = (appDelegate?.scheduleManager?.currentTimeState == .workBlock) == true
        let costMultiplier = isWorkBlock ? workBlockCost : freeBlockCost
        let effectiveBrowseTime = costMultiplier > 0 ? availableMinutes / costMultiplier : availableMinutes

        return [
            "type": "WORK_BLOCK_STATE",
            "isWorkBlock": isWorkBlock,
            "earnedMinutes": earnedMinutes,
            "usedMinutes": usedMinutes,
            "availableMinutes": availableMinutes,
            "effectiveBrowseTime": effectiveBrowseTime,
            "costMultiplier": costMultiplier,
            "poolExhausted": isPoolExhausted,
            "currentDelay": currentDelay,
            "visitCount": visitCount,
            "isDeepWork": isDeepWork,
            "intention": intention,
            "lastActiveApp": lastActiveApp,
            "dailyRequestCount": dailyRequestCount,
            "maxDailyRequests": maxDailyPartnerRequests
        ]
    }

    // MARK: - Persistence

    func save() {
        // Serialize block focus stats
        var blockStatsArray: [[String: Any]] = []
        for (_, stats) in blockFocusStats {
            blockStatsArray.append([
                "blockId": stats.blockId,
                "blockTitle": stats.blockTitle,
                "relevantTicks": stats.relevantTicks,
                "totalTicks": stats.totalTicks,
                "earnedMinutes": stats.earnedMinutes
            ])
        }

        let state: [String: Any] = [
            "currentDate": currentDate,
            "earnedMinutes": earnedMinutes,
            "usedMinutes": usedMinutes,
            "dailyRequestCount": dailyRequestCount,
            "delayIndex": delayIndex,
            "visitCount": visitCount,
            "blockFocusStats": blockStatsArray
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: state)
            try data.write(to: stateFileURL)
        } catch {
            appDelegate?.postLog("⚠️ EarnedBrowseManager: Failed to save: \(error)")
        }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: stateFileURL.path) else {
            ensureToday()
            return
        }

        do {
            let data = try Data(contentsOf: stateFileURL)
            guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                ensureToday()
                return
            }

            let savedDate = state["currentDate"] as? String ?? ""
            let today = todayString()

            if savedDate == today {
                // Same day — restore state
                currentDate = savedDate
                earnedMinutes = state["earnedMinutes"] as? Double ?? welcomeCredit
                usedMinutes = state["usedMinutes"] as? Double ?? 0
                dailyRequestCount = state["dailyRequestCount"] as? Int ?? 0
                delayIndex = state["delayIndex"] as? Int ?? 0
                visitCount = state["visitCount"] as? Int ?? 0
                currentDelay = delayIndex < delaySteps.count ? delaySteps[delayIndex] : delaySteps.last!

                // Restore per-block focus stats
                if let statsArray = state["blockFocusStats"] as? [[String: Any]] {
                    blockFocusStats = [:]
                    for entry in statsArray {
                        guard let blockId = entry["blockId"] as? String,
                              let blockTitle = entry["blockTitle"] as? String else { continue }
                        var stats = BlockFocusStats(blockId: blockId, blockTitle: blockTitle)
                        stats.relevantTicks = entry["relevantTicks"] as? Int ?? 0
                        stats.totalTicks = entry["totalTicks"] as? Int ?? 0
                        stats.earnedMinutes = entry["earnedMinutes"] as? Double ?? 0
                        blockFocusStats[blockId] = stats
                    }
                }

                appDelegate?.postLog("💰 EarnedBrowseManager loaded: earned=\(String(format: "%.1f", earnedMinutes))m, used=\(String(format: "%.1f", usedMinutes))m, available=\(String(format: "%.1f", availableMinutes))m")
            } else {
                // New day — reset with welcome credit
                ensureToday()
            }
        } catch {
            appDelegate?.postLog("⚠️ EarnedBrowseManager: Failed to load: \(error)")
            ensureToday()
        }
    }

    // MARK: - Helpers

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

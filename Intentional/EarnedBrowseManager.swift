import Foundation

/// Manages the "Earn Your Browse" budget system.
///
/// Focused work earns social media browsing time. Cost multipliers vary by block type:
/// - Deep Work (0x): ALL browsing blocked
/// - Focus Hours (2x): ALL browsing costs 2x from pool
/// - Free Time (1x): ALL browsing costs 1x; setting an intent earns +10 min bonus (once per block)
///
/// This is the "accountant" — manages the earned pool, cost multipliers, intent bonus,
/// and partner extra time. Does NOT handle heartbeat dedup (TimeTracker owns that).
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

    /// Standard rate: 5 min work → 1 min browse (Focus Hours)
    private let standardRate: Double = 0.2
    /// Deep work rate: ~3.33 min work → 1 min browse (Deep Work blocks — immediate, no warmup)
    private let deepWorkRate: Double = 0.3

    // MARK: - Cost Multipliers (by block type)

    /// Deep Work: browsing is blocked entirely (should never be charged, but 0 prevents earning deduction)
    let deepWorkCost: Double = 0.0
    /// Focus Hours: browsing costs 2x from pool
    let focusHoursCost: Double = 2.0
    /// Free Time: browsing costs 1x from pool
    let freeTimeCost: Double = 1.0

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

    // MARK: - Welcome Credit

    /// Minutes granted on first launch of the day
    private let welcomeCredit: Double = 5.0

    // MARK: - Intent Bonus (Free Time incentive)

    /// Minutes granted as bonus when user sets an intent during Free Time
    private let intentBonusAmount: Double = 10.0
    /// Block IDs where intent bonus has already been granted today
    private(set) var intentBonusGrantedBlockIds: Set<String> = []

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
        var nudgeCount: Int = 0
        var recoveryCount: Int = 0     // Distraction→focus transitions this block
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
    /// Adds time × rate to earnedMinutes. Uses deepWorkRate if in deep work block or sustained deep work.
    func recordWorkTick(seconds: Double) {
        ensureToday()
        let blockType = appDelegate?.scheduleManager?.currentBlock?.blockType ?? .focusHours
        let rate = (blockType == .deepWork || isDeepWork) ? deepWorkRate : standardRate
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
    /// Deducts minutes × costMultiplier from pool based on block type.
    /// Returns remaining available minutes after deduction.
    @discardableResult
    func recordSocialMediaTime(minutes: Double, blockType: ScheduleManager.BlockType, isFreeBrowse: Bool = false) -> Double {
        ensureToday()
        let multiplier: Double
        if isFreeBrowse {
            multiplier = focusHoursCost  // 2x — free browse costs double
        } else {
            switch blockType {
            case .deepWork: multiplier = deepWorkCost
            case .focusHours: multiplier = focusHoursCost
            case .freeTime: multiplier = freeTimeCost
            }
        }
        usedMinutes += minutes * multiplier
        save()
        return availableMinutes
    }

    // MARK: - Block Change

    /// Called when the active focus block changes.
    /// Resets deep work window. Does NOT reset earned/used pool (those are daily).
    func onBlockChanged(blockId: String? = nil, blockTitle: String? = nil) {
        assessmentWindow.removeAll()
        isDeepWork = false

        // Set up per-block tracking
        activeBlockId = blockId
        if let blockId = blockId, let blockTitle = blockTitle {
            if blockFocusStats[blockId] == nil {
                blockFocusStats[blockId] = BlockFocusStats(blockId: blockId, blockTitle: blockTitle)
            }
        }

        appDelegate?.postLog("💰 EarnedBrowseManager: block changed → \(blockTitle ?? "none")")
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

    /// Record a nudge/intervention event for the current block.
    func recordNudge() {
        guard let blockId = activeBlockId, var stats = blockFocusStats[blockId] else { return }
        stats.nudgeCount += 1
        blockFocusStats[blockId] = stats
        save()
    }

    /// Increment recovery count (distraction→focus transition) for the current block.
    func incrementRecoveryCount() {
        guard let blockId = activeBlockId, var stats = blockFocusStats[blockId] else { return }
        stats.recoveryCount += 1
        blockFocusStats[blockId] = stats
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
        assessmentWindow.removeAll()
        isDeepWork = false
        blockFocusStats.removeAll()
        activeBlockId = nil
        intentBonusGrantedBlockIds.removeAll()

        if hadPreviousDate {
            appDelegate?.postLog("💰 New day — pool reset. Welcome credit: \(welcomeCredit) min")
        }
        save()
    }

    // MARK: - Partner Extra Time

    /// Grant minutes after backend code verification succeeds.
    func grantPartnerExtraTime(minutes: Double) {
        ensureToday()
        earnedMinutes += minutes
        save()
        appDelegate?.postLog("💰 Partner extra time granted: +\(minutes) min")
    }

    // MARK: - Intent Bonus

    /// Grant the intent bonus for a specific block. Returns true if bonus was granted.
    /// Only grants once per block ID per day. Requires a non-nil block ID.
    @discardableResult
    func grantIntentBonus(blockId: String?) -> Bool {
        guard let blockId = blockId else { return false }
        ensureToday()
        guard !intentBonusGrantedBlockIds.contains(blockId) else { return false }
        intentBonusGrantedBlockIds.insert(blockId)
        earnedMinutes += intentBonusAmount
        save()
        appDelegate?.postLog("💰 Intent bonus granted: +\(intentBonusAmount) min (block: \(blockId))")
        return true
    }

    /// Whether the intent bonus is available for the current block.
    /// True only during Free Time blocks where the bonus hasn't been claimed yet.
    var intentBonusAvailable: Bool {
        guard let blockId = appDelegate?.scheduleManager?.currentBlock?.id else { return false }
        let blockType = appDelegate?.scheduleManager?.currentBlock?.blockType ?? .freeTime
        return blockType == .freeTime && !intentBonusGrantedBlockIds.contains(blockId)
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
        let blockType = appDelegate?.scheduleManager?.currentBlock?.blockType ?? .freeTime
        let timeState = appDelegate?.scheduleManager?.currentTimeState
        let costMultiplier: Double
        switch blockType {
        case .deepWork: costMultiplier = deepWorkCost
        case .focusHours: costMultiplier = focusHoursCost
        case .freeTime: costMultiplier = freeTimeCost
        }
        let effectiveBrowseTime = costMultiplier > 0 ? availableMinutes / costMultiplier : availableMinutes

        return [
            "type": "WORK_BLOCK_STATE",
            "blockType": blockType.rawValue,
            "isWorkBlock": timeState?.isWork ?? false,  // backwards compat
            "earnedMinutes": earnedMinutes,
            "usedMinutes": usedMinutes,
            "availableMinutes": availableMinutes,
            "effectiveBrowseTime": effectiveBrowseTime,
            "costMultiplier": costMultiplier,
            "poolExhausted": isPoolExhausted,
            "isDeepWork": blockType == .deepWork || isDeepWork,
            "intention": intention,
            "lastActiveApp": lastActiveApp,
            "intentBonusAvailable": intentBonusAvailable,
            "intentBonusAmount": intentBonusAmount
        ]
    }

    // MARK: - Persistence

    func save() {
        // Serialize block focus stats
        var blockStatsArray: [[String: Any]] = []
        for (_, stats) in blockFocusStats {
            let entry: [String: Any] = [
                "blockId": stats.blockId,
                "blockTitle": stats.blockTitle,
                "relevantTicks": stats.relevantTicks,
                "totalTicks": stats.totalTicks,
                "earnedMinutes": stats.earnedMinutes,
                "nudgeCount": stats.nudgeCount,
                "recoveryCount": stats.recoveryCount
            ]
            blockStatsArray.append(entry)
        }

        let state: [String: Any] = [
            "currentDate": currentDate,
            "earnedMinutes": earnedMinutes,
            "usedMinutes": usedMinutes,
            "blockFocusStats": blockStatsArray,
            "intentBonusGrantedBlockIds": Array(intentBonusGrantedBlockIds)
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

                // Restore intent bonus granted block IDs
                if let bonusIds = state["intentBonusGrantedBlockIds"] as? [String] {
                    intentBonusGrantedBlockIds = Set(bonusIds)
                }

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
                        stats.nudgeCount = entry["nudgeCount"] as? Int ?? 0
                        stats.recoveryCount = entry["recoveryCount"] as? Int ?? 0
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

    // MARK: - Summary

    /// Returns today's aggregate stats across all completed blocks.
    func todaySummary() -> (blockCount: Int, focusedMinutes: Double, avgFocusScore: Int) {
        let stats = Array(blockFocusStats.values)
        guard !stats.isEmpty else { return (0, 0, 0) }
        let totalMinutes = stats.reduce(0.0) { $0 + Double($1.totalTicks) * 10.0 / 60.0 }
        let avgFocus = stats.reduce(0) { $0 + $1.focusScore } / stats.count
        return (stats.count, totalMinutes, avgFocus)
    }

    // MARK: - Helpers

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

import Foundation

/// Manages the daily focus schedule — time blocks, goals, plan text.
/// Determines the current time state (work block, free block, unplanned, no plan).
/// This is opt-in: when disabled, it's invisible to the rest of the system.
class ScheduleManager {

    weak var appDelegate: AppDelegate?

    // MARK: - Data Types

    enum BlockType: String, Codable {
        case deepWork = "deepWork"
        case focusHours = "focusHours"
        case freeTime = "freeTime"
    }

    struct FocusBlock: Codable, Equatable {
        let id: String       // UUID string
        var title: String
        var description: String  // Optional extra context for AI relevance scoring
        var startHour: Int   // 0-23
        var startMinute: Int // 0-59
        var endHour: Int     // 0-23
        var endMinute: Int   // 0-59
        var blockType: BlockType

        /// Backwards compat
        var isFree: Bool { blockType == .freeTime }

        // Custom coding to migrate legacy `isFree` → `blockType`
        enum CodingKeys: String, CodingKey {
            case id, title, description, startHour, startMinute, endHour, endMinute, blockType, isFree
        }

        init(id: String, title: String, description: String, startHour: Int, startMinute: Int,
             endHour: Int, endMinute: Int, blockType: BlockType) {
            self.id = id
            self.title = title
            self.description = description
            self.startHour = startHour
            self.startMinute = startMinute
            self.endHour = endHour
            self.endMinute = endMinute
            self.blockType = blockType
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            description = try container.decode(String.self, forKey: .description)
            startHour = try container.decode(Int.self, forKey: .startHour)
            startMinute = try container.decode(Int.self, forKey: .startMinute)
            endHour = try container.decode(Int.self, forKey: .endHour)
            endMinute = try container.decode(Int.self, forKey: .endMinute)
            // Migration: try blockType first, fall back to isFree
            if let bt = try? container.decode(BlockType.self, forKey: .blockType) {
                blockType = bt
            } else if let free = try? container.decode(Bool.self, forKey: .isFree) {
                blockType = free ? .freeTime : .focusHours
            } else {
                blockType = .focusHours
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(description, forKey: .description)
            try container.encode(startHour, forKey: .startHour)
            try container.encode(startMinute, forKey: .startMinute)
            try container.encode(endHour, forKey: .endHour)
            try container.encode(endMinute, forKey: .endMinute)
            try container.encode(blockType, forKey: .blockType)
        }

        /// Start time as minutes from midnight
        var startMinutes: Int { startHour * 60 + startMinute }
        /// End time as minutes from midnight
        var endMinutes: Int { endHour * 60 + endMinute }

        /// Check if a minute-of-day falls within this block
        func contains(minuteOfDay: Int) -> Bool {
            return minuteOfDay >= startMinutes && minuteOfDay < endMinutes
        }

        static func == (lhs: FocusBlock, rhs: FocusBlock) -> Bool {
            return lhs.id == rhs.id
        }
    }

    struct DailySchedule: Codable {
        var date: String  // "yyyy-MM-dd"
        var goals: [String]
        var dailyPlan: String
        var blocks: [FocusBlock]
    }

    // MARK: - Enforcement Settings

    struct BlockEnforcementSettings: Codable {
        var nudgeNotifications: Bool
        var screenRedShift: Bool
        var autoRedirect: Bool
        var blockingOverlay: Bool
        var interventionExercises: Bool
        var backgroundAudioDetection: Bool

        func toDict() -> [String: Bool] {
            return [
                "nudgeNotifications": nudgeNotifications,
                "screenRedShift": screenRedShift,
                "autoRedirect": autoRedirect,
                "blockingOverlay": blockingOverlay,
                "interventionExercises": interventionExercises,
                "backgroundAudioDetection": backgroundAudioDetection
            ]
        }
    }

    struct EnforcementSettings: Codable {
        var deepWork: BlockEnforcementSettings
        var focusHours: BlockEnforcementSettings

        func settings(for blockType: BlockType) -> BlockEnforcementSettings {
            switch blockType {
            case .deepWork: return deepWork
            case .focusHours: return focusHours
            case .freeTime: return BlockEnforcementSettings(
                nudgeNotifications: false, screenRedShift: false, autoRedirect: false,
                blockingOverlay: false, interventionExercises: false, backgroundAudioDetection: false)
            }
        }

        static let defaults = EnforcementSettings(
            deepWork: BlockEnforcementSettings(
                nudgeNotifications: true, screenRedShift: true, autoRedirect: true,
                blockingOverlay: true, interventionExercises: true, backgroundAudioDetection: false),
            focusHours: BlockEnforcementSettings(
                nudgeNotifications: true, screenRedShift: true, autoRedirect: false,
                blockingOverlay: false, interventionExercises: false, backgroundAudioDetection: false)
        )

        func toDict() -> [String: Any] {
            return [
                "deepWork": deepWork.toDict(),
                "focusHours": focusHours.toDict()
            ]
        }
    }

    enum EnforcementMechanism {
        case nudge
        case screenRedShift
        case autoRedirect
        case blockingOverlay
        case interventionExercises
        case backgroundAudioDetection
    }

    enum TimeState: String {
        case deepWork = "deep_work"
        case focusHours = "focus_hours"
        case freeTime = "free"
        case unplanned = "unplanned"
        case snoozed = "snoozed"
        case noPlan = "no_plan"
        case disabled = "disabled"

        /// Whether this is a monitored work state (deep work or focus hours)
        var isWork: Bool { self == .deepWork || self == .focusHours }
    }

    // MARK: - State

    /// Whether Daily Focus Plan is enabled (opt-in toggle)
    private(set) var isEnabled: Bool = false

    /// User profile (set once during opt-in, persisted)
    private(set) var profile: String = ""

    /// Today's schedule (nil if no plan set today)
    private(set) var todaySchedule: DailySchedule?

    /// Currently active block (nil if unplanned/no plan)
    private(set) var currentBlock: FocusBlock?

    /// Current time state
    private(set) var currentTimeState: TimeState = .disabled

    /// Enforcement mode: "nudge" (notify only) or "block" (nudge + redirect tab)
    private(set) var focusEnforcement: String = "block"

    /// AI model for relevance scoring: "apple" (Foundation Models) or "qwen" (MLX Qwen3-4B)
    private(set) var aiModel: String = "apple"

    /// Snooze state
    private(set) var snoozeUntil: Date?
    private(set) var snoozeCount: Int = 0
    static let maxSnoozes = 1
    static let snoozeDurationMinutes = 30

    // MARK: - Callbacks

    /// Called when the active block changes. SocketRelayServer uses this to broadcast SCHEDULE_SYNC.
    var onBlockChanged: ((_ block: FocusBlock?, _ state: TimeState) -> Void)?

    // MARK: - Persistence

    private let profileFileURL: URL
    private let scheduleFileURL: URL
    private let settingsFileURL: URL
    private let historyFileURL: URL

    /// Calendar zoom level (px per hour): 42 (default) → 140 (max)
    private(set) var calendarZoom: Int = 42

    /// Per-block-type enforcement toggles
    private(set) var enforcementSettings: EnforcementSettings = .defaults

    // MARK: - Timer

    private var blockCheckTimer: Timer?

    // MARK: - Init

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        profileFileURL = dir.appendingPathComponent("focus_profile.json")
        scheduleFileURL = dir.appendingPathComponent("daily_schedule.json")
        settingsFileURL = dir.appendingPathComponent("focus_settings.json")
        historyFileURL = dir.appendingPathComponent("schedule_history.json")

        loadSettings()
        loadProfile()
        loadSchedule()

        // Start checking for block transitions every 10 seconds
        startBlockCheckTimer()

        // Set initial state
        recalculateState()

        appDelegate?.postLog("📋 ScheduleManager initialized (enabled: \(isEnabled))")
    }

    deinit {
        blockCheckTimer?.invalidate()
    }

    // MARK: - Public API

    /// Enable/disable the Daily Focus Plan feature
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        saveSettings()
        recalculateState()
        appDelegate?.postLog("📋 Daily Focus Plan: \(enabled ? "enabled" : "disabled")")
    }

    func setFocusEnforcement(_ mode: String) {
        focusEnforcement = mode
        saveSettings()
        appDelegate?.postLog("📋 Focus enforcement: \(mode)")
    }

    func setAIModel(_ model: String) {
        aiModel = model
        saveSettings()
        appDelegate?.postLog("📋 AI model: \(model)")
    }

    func setCalendarZoom(_ zoom: Int) {
        calendarZoom = max(42, min(140, zoom))
        saveSettings()
    }

    func setEnforcementSettings(_ settings: EnforcementSettings) {
        enforcementSettings = settings
        saveSettings()
        appDelegate?.postLog("📋 Enforcement settings updated")
    }

    /// Check if a specific enforcement mechanism is enabled for the current block type.
    func isEnforcementEnabled(_ mechanism: EnforcementMechanism) -> Bool {
        guard let blockType = currentBlock?.blockType else { return true }
        let settings = enforcementSettings.settings(for: blockType)
        switch mechanism {
        case .nudge: return settings.nudgeNotifications
        case .screenRedShift: return settings.screenRedShift
        case .autoRedirect: return settings.autoRedirect
        case .blockingOverlay: return settings.blockingOverlay
        case .interventionExercises: return settings.interventionExercises
        case .backgroundAudioDetection: return settings.backgroundAudioDetection
        }
    }

    /// Set user profile (one-time during opt-in)
    func setProfile(_ text: String) {
        profile = text
        saveProfile()
        appDelegate?.postLog("📋 Profile updated (\(text.count) chars)")
    }

    /// Set today's plan (goals + daily plan text + time blocks)
    func setTodaySchedule(goals: [String], dailyPlan: String, blocks: [FocusBlock]) {
        let today = Self.todayString()
        todaySchedule = DailySchedule(
            date: today,
            goals: goals,
            dailyPlan: dailyPlan,
            blocks: blocks.sorted { $0.startMinutes < $1.startMinutes }
        )
        snoozeUntil = nil
        snoozeCount = 0
        saveSchedule()
        recalculateState(forceCallback: true)
        appDelegate?.postLog("📋 Schedule set: \(blocks.count) blocks, \(goals.count) goals")
    }

    /// Add a single block to today's schedule (e.g., "Quick: free block" from extension)
    func addBlock(_ block: FocusBlock) {
        if todaySchedule == nil {
            todaySchedule = DailySchedule(
                date: Self.todayString(),
                goals: [],
                dailyPlan: "",
                blocks: []
            )
        }
        todaySchedule?.blocks.append(block)
        todaySchedule?.blocks.sort { $0.startMinutes < $1.startMinutes }
        saveSchedule()
        recalculateState(forceCallback: true)
        appDelegate?.postLog("📋 Block added: \"\(block.title)\" \(block.startHour):\(String(format: "%02d", block.startMinute))–\(block.endHour):\(String(format: "%02d", block.endMinute))")
    }

    /// Update an existing block
    func updateBlock(_ block: FocusBlock) {
        guard var schedule = todaySchedule,
              let index = schedule.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        schedule.blocks[index] = block
        schedule.blocks.sort { $0.startMinutes < $1.startMinutes }
        todaySchedule = schedule
        saveSchedule()
        recalculateState(forceCallback: true)
    }

    /// Remove a block
    func removeBlock(id: String) {
        todaySchedule?.blocks.removeAll { $0.id == id }
        saveSchedule()
        recalculateState(forceCallback: true)
    }

    /// Push a block's start time forward by N minutes.
    /// Used by the block start ritual's "+15 min" button.
    func pushBlockBack(id: String, minutes: Int = 15) {
        guard var schedule = todaySchedule,
              let index = schedule.blocks.firstIndex(where: { $0.id == id }) else { return }
        var block = schedule.blocks[index]
        let newStartMinutes = block.startMinutes + minutes
        block = FocusBlock(
            id: block.id,
            title: block.title,
            description: block.description,
            startHour: newStartMinutes / 60,
            startMinute: newStartMinutes % 60,
            endHour: block.endHour,
            endMinute: block.endMinute,
            blockType: block.blockType
        )
        // Only apply if the block still has positive duration
        guard block.startMinutes < block.endMinutes else { return }
        schedule.blocks[index] = block
        schedule.blocks.sort { $0.startMinutes < $1.startMinutes }
        todaySchedule = schedule
        saveSchedule()
        recalculateState(forceCallback: true)
        appDelegate?.postLog("📋 Block \"\(block.title)\" pushed back \(minutes) min → \(block.startHour):\(String(format: "%02d", block.startMinute))")
    }

    /// Snooze the morning planning prompt (30 min, up to 3 times)
    /// Returns true if snooze was accepted
    func snooze() -> Bool {
        guard snoozeCount < Self.maxSnoozes else {
            appDelegate?.postLog("📋 Snooze limit reached (\(Self.maxSnoozes))")
            return false
        }
        snoozeCount += 1
        snoozeUntil = Date().addingTimeInterval(TimeInterval(Self.snoozeDurationMinutes * 60))
        recalculateState()
        appDelegate?.postLog("📋 Snoozed (\(snoozeCount)/\(Self.maxSnoozes)) until \(snoozeUntil!)")
        return true
    }

    /// Get the current time state and active block info for extensions
    func getScheduleState() -> [String: Any] {
        var result: [String: Any] = [
            "enabled": isEnabled,
            "state": currentTimeState.rawValue,
            "hasPlan": todaySchedule != nil && todaySchedule?.date == Self.todayString(),
            "focusEnforcement": focusEnforcement,
            "aiModel": aiModel,
            "calendarZoom": calendarZoom,
            "enforcementSettings": enforcementSettings.toDict()
        ]

        if let block = currentBlock {
            result["currentBlock"] = blockToDict(block)
        }

        // Profile is persisted independently — always include it
        result["profile"] = profile

        if let schedule = todaySchedule {
            result["goals"] = schedule.goals
            result["dailyPlan"] = schedule.dailyPlan
            result["blockCount"] = schedule.blocks.count
        }

        if let snooze = snoozeUntil {
            result["snoozeUntil"] = snooze.timeIntervalSince1970 * 1000
            result["snoozeCount"] = snoozeCount
            result["maxSnoozes"] = Self.maxSnoozes
        }

        return result
    }

    /// Get full schedule payload for SCHEDULE_SYNC message
    func getScheduleSyncPayload() -> [String: Any] {
        var payload = getScheduleState()
        payload["type"] = "SCHEDULE_SYNC"

        // Include all blocks so extension can render/display them
        if let schedule = todaySchedule {
            payload["blocks"] = schedule.blocks.map { blockToDict($0) }
        }

        return payload
    }

    // MARK: - State Recalculation

    /// Recalculate the current time state based on time of day.
    /// Called every 10 seconds by the timer, and after any schedule change.
    /// - Parameter forceCallback: When true, always fire onBlockChanged even if state didn't change.
    ///   Used when the schedule is explicitly modified (blocks added/removed/updated) so FocusMonitor
    ///   re-evaluates even if the computed state happens to be the same.
    private func recalculateState(forceCallback: Bool = false) {
        let previousState = currentTimeState
        let previousBlockId = currentBlock?.id

        guard isEnabled else {
            currentTimeState = .disabled
            currentBlock = nil
            if forceCallback || previousState != .disabled {
                onBlockChanged?(nil, .disabled)
            }
            return
        }

        // Check if plan exists for today
        guard let schedule = todaySchedule, schedule.date == Self.todayString() else {
            // No plan — check snooze
            if let snooze = snoozeUntil, Date() < snooze {
                currentTimeState = .snoozed
                currentBlock = nil
            } else {
                currentTimeState = .noPlan
                currentBlock = nil
                // Reset snooze if expired
                if snoozeUntil != nil && Date() >= snoozeUntil! {
                    snoozeUntil = nil
                }
            }
            if forceCallback || currentTimeState != previousState || currentBlock?.id != previousBlockId {
                onBlockChanged?(nil, currentTimeState)
            }
            return
        }

        // Find which block we're in based on current time
        let minuteOfDay = Self.currentMinuteOfDay()

        if let block = schedule.blocks.first(where: { $0.contains(minuteOfDay: minuteOfDay) }) {
            currentBlock = block
            switch block.blockType {
            case .deepWork: currentTimeState = .deepWork
            case .focusHours: currentTimeState = .focusHours
            case .freeTime: currentTimeState = .freeTime
            }
        } else {
            currentBlock = nil
            currentTimeState = .unplanned
        }

        if forceCallback || currentTimeState != previousState || currentBlock?.id != previousBlockId {
            appDelegate?.postLog("📋 State: \(previousState.rawValue) → \(currentTimeState.rawValue)" +
                                (currentBlock != nil ? " (\(currentBlock!.title))" : ""))
            onBlockChanged?(currentBlock, currentTimeState)
        }
    }

    // MARK: - Timer

    private func startBlockCheckTimer() {
        blockCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.recalculateState()
        }
    }

    // MARK: - Persistence

    private func loadSettings() {
        guard FileManager.default.fileExists(atPath: settingsFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: settingsFileURL)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                isEnabled = json["enabled"] as? Bool ?? false
                focusEnforcement = json["focusEnforcement"] as? String ?? "block"
                aiModel = json["aiModel"] as? String ?? "apple"
                calendarZoom = json["calendarZoom"] as? Int ?? 42

                // Parse enforcement settings (graceful fallback to defaults)
                if let enfDict = json["enforcementSettings"] as? [String: Any],
                   let enfData = try? JSONSerialization.data(withJSONObject: enfDict),
                   let enf = try? JSONDecoder().decode(EnforcementSettings.self, from: enfData) {
                    enforcementSettings = enf
                }
            }
        } catch {
            appDelegate?.postLog("⚠️ ScheduleManager: Failed to load settings: \(error)")
        }
    }

    private func saveSettings() {
        let json: [String: Any] = [
            "enabled": isEnabled,
            "focusEnforcement": focusEnforcement,
            "aiModel": aiModel,
            "calendarZoom": calendarZoom,
            "enforcementSettings": enforcementSettings.toDict()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: settingsFileURL)
        }
    }

    private func loadProfile() {
        guard FileManager.default.fileExists(atPath: profileFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: profileFileURL)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                profile = json["profile"] as? String ?? ""
            }
        } catch {
            appDelegate?.postLog("⚠️ ScheduleManager: Failed to load profile: \(error)")
        }
    }

    private func saveProfile() {
        let json: [String: Any] = ["profile": profile]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: profileFileURL)
        }
    }

    private func loadSchedule() {
        guard FileManager.default.fileExists(atPath: scheduleFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: scheduleFileURL)
            todaySchedule = try JSONDecoder().decode(DailySchedule.self, from: data)

            // Reset if from a different day — archive the old schedule first
            if todaySchedule?.date != Self.todayString() {
                if let oldSchedule = todaySchedule {
                    archiveSchedule(oldSchedule)
                }
                todaySchedule = nil
                snoozeUntil = nil
                snoozeCount = 0
            }
        } catch {
            appDelegate?.postLog("⚠️ ScheduleManager: Failed to load schedule: \(error)")
        }
    }

    // MARK: - Schedule History

    private func archiveSchedule(_ schedule: DailySchedule) {
        var history = loadHistory()
        // Don't archive duplicates
        if history.contains(where: { $0.date == schedule.date }) { return }
        // Don't archive empty schedules
        if schedule.blocks.isEmpty { return }
        history.append(schedule)
        // Cap at 90 entries
        if history.count > 90 {
            history = Array(history.suffix(90))
        }
        saveHistory(history)
        appDelegate?.postLog("📋 Archived schedule for \(schedule.date) (\(schedule.blocks.count) blocks)")
    }

    private func loadHistory() -> [DailySchedule] {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: historyFileURL)
            return try JSONDecoder().decode([DailySchedule].self, from: data)
        } catch {
            appDelegate?.postLog("⚠️ ScheduleManager: Failed to load history: \(error)")
            return []
        }
    }

    private func saveHistory(_ history: [DailySchedule]) {
        do {
            let data = try JSONEncoder().encode(history)
            try data.write(to: historyFileURL)
        } catch {
            appDelegate?.postLog("⚠️ ScheduleManager: Failed to save history: \(error)")
        }
    }

    /// Get schedule for a specific date (today or from history)
    func getScheduleForDate(_ dateString: String) -> DailySchedule? {
        if dateString == Self.todayString() {
            return todaySchedule
        }
        return loadHistory().first(where: { $0.date == dateString })
    }

    /// Get list of dates with archived schedules
    func availableHistoryDates() -> [String] {
        return loadHistory().map { $0.date }
    }

    private func saveSchedule() {
        guard let schedule = todaySchedule else { return }
        do {
            let data = try JSONEncoder().encode(schedule)
            try data.write(to: scheduleFileURL)
        } catch {
            appDelegate?.postLog("⚠️ ScheduleManager: Failed to save schedule: \(error)")
        }
    }

    // MARK: - Helpers

    /// Returns the next upcoming block after the current time, if any.
    func nextUpcomingBlock() -> FocusBlock? {
        guard let schedule = todaySchedule, schedule.date == Self.todayString() else { return nil }
        let now = Self.currentMinuteOfDay()
        return schedule.blocks.first(where: { $0.startMinutes > now })
    }

    private func blockToDict(_ block: FocusBlock) -> [String: Any] {
        return [
            "id": block.id,
            "title": block.title,
            "description": block.description,
            "startHour": block.startHour,
            "startMinute": block.startMinute,
            "endHour": block.endHour,
            "endMinute": block.endMinute,
            "blockType": block.blockType.rawValue,
            "isFree": block.isFree  // backwards compat for extension
        ]
    }

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func currentMinuteOfDay() -> Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: Date())
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

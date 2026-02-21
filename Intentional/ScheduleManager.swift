import Foundation

/// Manages the daily focus schedule — time blocks, goals, plan text.
/// Determines the current time state (work block, free block, unplanned, no plan).
/// This is opt-in: when disabled, it's invisible to the rest of the system.
class ScheduleManager {

    weak var appDelegate: AppDelegate?

    // MARK: - Data Types

    struct FocusBlock: Codable, Equatable {
        let id: String       // UUID string
        var title: String
        var description: String  // Optional extra context for AI relevance scoring
        var startHour: Int   // 0-23
        var startMinute: Int // 0-59
        var endHour: Int     // 0-23
        var endMinute: Int   // 0-59
        var isFree: Bool

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

    enum TimeState: String {
        case workBlock = "work"
        case freeBlock = "free"
        case unplanned = "unplanned"
        case snoozed = "snoozed"
        case noPlan = "no_plan"
        case disabled = "disabled"
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
            "aiModel": aiModel
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
            currentTimeState = block.isFree ? .freeBlock : .workBlock
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
            }
        } catch {
            appDelegate?.postLog("⚠️ ScheduleManager: Failed to load settings: \(error)")
        }
    }

    private func saveSettings() {
        let json: [String: Any] = [
            "enabled": isEnabled,
            "focusEnforcement": focusEnforcement,
            "aiModel": aiModel
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

            // Reset if from a different day
            if todaySchedule?.date != Self.todayString() {
                todaySchedule = nil
                snoozeUntil = nil
                snoozeCount = 0
            }
        } catch {
            appDelegate?.postLog("⚠️ ScheduleManager: Failed to load schedule: \(error)")
        }
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
            "isFree": block.isFree
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

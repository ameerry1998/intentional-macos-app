import Cocoa
import SwiftUI

/// Manages Intentional Mode: full-screen overlay that blocks the laptop
/// until the user sets an intention for their current time block.
///
/// State machine:
///   disabled  → feature off
///   inactive  → enabled but outside schedule
///   locked    → no active intention, overlay blocking screen
///   active    → block running, normal enforcement
///
/// The overlay is a KeyableWindow at .screenSaver level covering all screens,
/// with an interactive planning form (block type, intention, duration, start).
class IntentionalModeController {

    weak var appDelegate: AppDelegate?
    weak var scheduleManager: ScheduleManager?

    // MARK: - State

    enum State: String {
        case disabled   // Feature off
        case inactive   // Enabled but outside schedule
        case locked     // Overlay showing, must plan
        case active     // Block running, normal enforcement
    }

    private(set) var state: State = .disabled

    // MARK: - Settings

    enum Schedule: String, Codable {
        case always     // 24/7
        case custom     // Weekday/weekend hours
        case puckOnly   // Only when Puck triggers
    }

    struct CustomSchedule: Codable {
        var weekdayStartHour: Int = 8
        var weekdayStartMinute: Int = 0
        var weekdayEndHour: Int = 18
        var weekdayEndMinute: Int = 0
        var weekendEnabled: Bool = false
        var weekendStartHour: Int = 9
        var weekendStartMinute: Int = 0
        var weekendEndHour: Int = 17
        var weekendEndMinute: Int = 0
    }

    var isEnabled: Bool = false {
        didSet { recalculateState() }
    }
    var schedule: Schedule = .always
    var customSchedule: CustomSchedule = CustomSchedule()
    var gracePeriodMinutes: Int = 3

    // MARK: - Puck Toggle (external trigger)

    /// Set by Puck tap or manual toggle. Only relevant when schedule == .puckOnly
    private(set) var isPuckActive: Bool = false

    // MARK: - Grace Period

    private var graceTimer: Timer?
    private var graceEndTime: Date?

    // MARK: - Warning (3-min countdown before block ends)

    private var warningTimer: Timer?
    var isWarningActive: Bool = false

    // MARK: - Overlay Windows

    private var overlayWindows: [NSWindow] = []
    private var viewModel: IntentionalModeViewModel?

    var isOverlayShowing: Bool { !overlayWindows.isEmpty }

    // MARK: - Tick Timer

    private var tickTimer: Timer?

    // MARK: - Init

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    /// Start the periodic tick timer (every 30s) for schedule boundary and warning checks.
    func start() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        cancelGrace()
        cancelWarning()
        dismissOverlay()
        state = .disabled
    }

    // MARK: - State Machine

    /// Recalculate state based on current settings, schedule, and block status.
    /// Called when: settings change, block changes, schedule time boundary crossed, Puck toggle.
    func recalculateState() {
        let oldState = state

        guard isEnabled else {
            state = .disabled
            if oldState != .disabled { dismissOverlay() }
            cancelGrace()
            cancelWarning()
            return
        }

        guard isWithinSchedule() else {
            state = .inactive
            if oldState == .locked { dismissOverlay() }
            cancelGrace()
            cancelWarning()
            return
        }

        // Within schedule — check if there's an active block
        if scheduleManager?.currentBlock != nil {
            state = .active
            if oldState == .locked { dismissOverlay() }
            cancelGrace()
            return
        }

        // No active block — are we in grace period?
        if let graceEnd = graceEndTime, Date() < graceEnd {
            state = .active // Still in grace, don't lock yet
            return
        }

        // No block, no grace → lock
        state = .locked
        if !isOverlayShowing {
            showOverlay()
        }

        appDelegate?.postLog("🔒 IntentionalMode: \(oldState.rawValue) → \(state.rawValue)")
    }

    /// Called when the active block changes (from AppDelegate's onBlockChanged callback).
    func onBlockChanged(block: ScheduleManager.FocusBlock?, timeState: ScheduleManager.TimeState) {
        if block != nil {
            // Block started — unlock
            cancelGrace()
            cancelWarning()
            recalculateState()
        } else {
            // Block ended — start grace period
            startGrace()
        }
    }

    // MARK: - Schedule Check

    private func isWithinSchedule() -> Bool {
        switch schedule {
        case .always:
            return true

        case .puckOnly:
            return isPuckActive

        case .custom:
            let calendar = Calendar.current
            let now = Date()
            let weekday = calendar.component(.weekday, from: now) // 1=Sun, 7=Sat
            let isWeekend = weekday == 1 || weekday == 7

            if isWeekend && !customSchedule.weekendEnabled { return false }

            let currentMinute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

            if isWeekend {
                let start = customSchedule.weekendStartHour * 60 + customSchedule.weekendStartMinute
                let end = customSchedule.weekendEndHour * 60 + customSchedule.weekendEndMinute
                return currentMinute >= start && currentMinute < end
            } else {
                let start = customSchedule.weekdayStartHour * 60 + customSchedule.weekdayStartMinute
                let end = customSchedule.weekdayEndHour * 60 + customSchedule.weekdayEndMinute
                return currentMinute >= start && currentMinute < end
            }
        }
    }

    // MARK: - Puck Toggle

    func togglePuck() {
        isPuckActive.toggle()
        appDelegate?.postLog("🏒 Puck toggle: \(isPuckActive ? "ON" : "OFF")")
        recalculateState()
    }

    func setPuckActive(_ active: Bool) {
        isPuckActive = active
        appDelegate?.postLog("🏒 Puck set: \(active ? "ON" : "OFF")")
        recalculateState()
    }

    // MARK: - Grace Period

    private func startGrace() {
        guard isEnabled, isWithinSchedule() else { return }

        let graceSeconds = TimeInterval(gracePeriodMinutes * 60)
        graceEndTime = Date().addingTimeInterval(graceSeconds)

        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: graceSeconds, repeats: false) { [weak self] _ in
            self?.graceExpired()
        }

        appDelegate?.postLog("⏳ IntentionalMode: grace period started (\(gracePeriodMinutes) min)")
        recalculateState() // Will see grace is active, stay in .active
    }

    private func graceExpired() {
        graceEndTime = nil
        graceTimer = nil
        appDelegate?.postLog("⏳ IntentionalMode: grace period expired")
        recalculateState() // Will transition to .locked
    }

    private func cancelGrace() {
        graceTimer?.invalidate()
        graceTimer = nil
        graceEndTime = nil
    }

    // MARK: - Block End Warning

    /// Called periodically (e.g., from FocusMonitor's tick) to check if we should warn.
    func checkBlockEndWarning() {
        guard state == .active, isEnabled, isWithinSchedule() else {
            cancelWarning()
            return
        }

        guard let block = scheduleManager?.currentBlock else { return }

        // Check if there's already a next block scheduled
        if let nextBlock = scheduleManager?.nextUpcomingBlock(),
           nextBlock.startMinutes <= block.endMinutes + 5 {
            // Next block is within 5 min of current end — no warning needed
            cancelWarning()
            return
        }

        let currentMinute = ScheduleManager.currentMinuteOfDay()
        let blockEndMinute = block.endHour * 60 + block.endMinute
        let minutesLeft = blockEndMinute - currentMinute

        if minutesLeft <= 3 && minutesLeft > 0 && !isWarningActive {
            isWarningActive = true
            appDelegate?.postLog("⚠️ IntentionalMode: block ends in \(minutesLeft) min — warning active")
        }

        if minutesLeft <= 0 {
            cancelWarning()
        }
    }

    private func cancelWarning() {
        if isWarningActive {
            isWarningActive = false
        }
        warningTimer?.invalidate()
        warningTimer = nil
    }

    // MARK: - Overlay

    private func showOverlay() {
        dismissOverlay() // Clear any existing

        let vm = IntentionalModeViewModel(
            onStartBlock: { [weak self] title, durationMinutes, blockType in
                self?.handleStartBlock(title: title, durationMinutes: durationMinutes, blockType: blockType)
            }
        )
        self.viewModel = vm

        let view = IntentionalModeOverlayView(viewModel: vm)

        for screen in NSScreen.screens {
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = screen.frame

            let window = KeyableWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = hostingView
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)

            overlayWindows.append(window)
        }

        appDelegate?.postLog("🔒 IntentionalMode: overlay shown on \(NSScreen.screens.count) screen(s)")
    }

    func dismissOverlay() {
        for window in overlayWindows {
            window.close()
        }
        overlayWindows.removeAll()
        viewModel = nil
    }

    // MARK: - Block Creation (from overlay)

    private func handleStartBlock(title: String, durationMinutes: Int, blockType: ScheduleManager.BlockType) {
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
            blockType: blockType
        )

        dismissOverlay()
        scheduleManager?.addBlock(block)
        appDelegate?.postLog("🔒 IntentionalMode: block created from overlay — \"\(title)\" (\(durationMinutes)min, \(blockType.rawValue))")
    }

    // MARK: - Persistence

    func loadSettings() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: "intentionalModeEnabled")
        if let rawSchedule = defaults.string(forKey: "intentionalModeSchedule"),
           let sched = Schedule(rawValue: rawSchedule) {
            schedule = sched
        }
        gracePeriodMinutes = defaults.integer(forKey: "intentionalModeGracePeriod")
        if gracePeriodMinutes == 0 { gracePeriodMinutes = 3 }

        // Load custom schedule
        if let data = defaults.data(forKey: "intentionalModeCustomSchedule"),
           let custom = try? JSONDecoder().decode(CustomSchedule.self, from: data) {
            customSchedule = custom
        }

        appDelegate?.postLog("📋 IntentionalMode loaded: enabled=\(isEnabled), schedule=\(schedule.rawValue), grace=\(gracePeriodMinutes)min")
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: "intentionalModeEnabled")
        defaults.set(schedule.rawValue, forKey: "intentionalModeSchedule")
        defaults.set(gracePeriodMinutes, forKey: "intentionalModeGracePeriod")

        if let data = try? JSONEncoder().encode(customSchedule) {
            defaults.set(data, forKey: "intentionalModeCustomSchedule")
        }
    }

    // MARK: - Periodic Tick

    /// Called from FocusMonitor's evaluation loop or a dedicated timer.
    func tick() {
        guard isEnabled else { return }

        checkBlockEndWarning()

        // Check if schedule boundary crossed
        let wasInSchedule = (state == .active || state == .locked)
        let nowInSchedule = isWithinSchedule()

        if wasInSchedule && !nowInSchedule {
            recalculateState() // → inactive
        } else if !wasInSchedule && nowInSchedule && state == .inactive {
            recalculateState() // → locked or active
        }
    }
}

// MARK: - ViewModel

class IntentionalModeViewModel: ObservableObject {
    @Published var blockTitle: String = ""
    @Published var selectedBlockType: ScheduleManager.BlockType = .focusHours
    @Published var selectedDuration: Int = 60

    let durationOptions = [30, 60, 90, 120]

    var onStartBlock: (String, Int, ScheduleManager.BlockType) -> Void

    init(onStartBlock: @escaping (String, Int, ScheduleManager.BlockType) -> Void) {
        self.onStartBlock = onStartBlock
    }

    func startBlock() {
        let title = blockTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle: String
        if selectedBlockType == .freeTime {
            effectiveTitle = title.isEmpty ? "Free Time" : title
        } else {
            effectiveTitle = title.isEmpty ? "Focus" : title
        }
        onStartBlock(effectiveTitle, selectedDuration, selectedBlockType)
    }

    var canStart: Bool {
        // Free time doesn't require a title
        if selectedBlockType == .freeTime { return true }
        return !blockTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - SwiftUI Overlay View

struct IntentionalModeOverlayView: View {
    @ObservedObject var viewModel: IntentionalModeViewModel

    var body: some View {
        ZStack {
            // Background — dark blur
            Color.black.opacity(0.88)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Card
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.6))

                        Text("What are you working on?")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)

                        Text("Set an intention to unlock your laptop")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .padding(.bottom, 8)

                    // Block type picker
                    HStack(spacing: 12) {
                        blockTypeButton(.deepWork, label: "Deep Work", icon: "flame.fill", color: Color.red)
                        blockTypeButton(.focusHours, label: "Focus", icon: "eye.fill", color: Color(red: 0.39, green: 0.4, blue: 0.95))
                        blockTypeButton(.freeTime, label: "Free Time", icon: "cup.and.saucer.fill", color: Color(red: 0.2, green: 0.82, blue: 0.6))
                    }

                    // Title field (not required for free time)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.selectedBlockType == .freeTime ? "What are you doing? (optional)" : "What are you working on?")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))

                        TextField(
                            viewModel.selectedBlockType == .freeTime ? "e.g., Taking a break" : "e.g., Build auth module",
                            text: $viewModel.blockTitle
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                    }

                    // Duration picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Duration")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))

                        HStack(spacing: 10) {
                            ForEach(viewModel.durationOptions, id: \.self) { minutes in
                                durationButton(minutes)
                            }
                        }
                    }

                    // Start button
                    Button(action: { viewModel.startBlock() }) {
                        Text("Start")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(viewModel.canStart ? .white : .white.opacity(0.3))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(
                                viewModel.canStart
                                    ? Color(red: 0.39, green: 0.4, blue: 0.95)
                                    : Color.white.opacity(0.08)
                            )
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canStart)
                }
                .padding(32)
                .frame(width: 420)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )

                Spacer()
            }
        }
    }

    // MARK: - Block Type Button

    @ViewBuilder
    private func blockTypeButton(_ type: ScheduleManager.BlockType, label: String, icon: String, color: Color) -> some View {
        let isSelected = viewModel.selectedBlockType == type

        Button(action: { viewModel.selectedBlockType = type }) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.4))
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? color.opacity(0.25) : Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isSelected ? color.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Duration Button

    @ViewBuilder
    private func durationButton(_ minutes: Int) -> some View {
        let isSelected = viewModel.selectedDuration == minutes
        let label = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h\(minutes % 60 > 0 ? " \(minutes % 60)m" : "")"

        Button(action: { viewModel.selectedDuration = minutes }) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isSelected ? .white : .white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color(red: 0.39, green: 0.4, blue: 0.95).opacity(0.3) : Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isSelected ? Color(red: 0.39, green: 0.4, blue: 0.95).opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

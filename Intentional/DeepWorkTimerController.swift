import Cocoa
import SwiftUI

// MARK: - KeyablePanel (supports keyboard input when needed)

class KeyablePanel: NSPanel {
    var allowKeyboardInput = false
    override var canBecomeKey: Bool { allowKeyboardInput }
}

// MARK: - Pill Mode + Celebration Data

enum PillMode {
    case timer              // Normal countdown (300×70)
    case blockComplete      // Transitional "Block complete" at 0:00 (300×70, amber)
    case celebration        // Expanded cards (460×~400 work, 460×~200 free)
    case startRitual        // "Up next" with Start button (460×160)
    case startRitualEdit    // Inline edit (title, description, type) (460×~340)
    case noPlan             // "No plan set" floating card (460×~260)
}

struct CelebrationData {
    let blockTitle: String
    let blockType: ScheduleManager.BlockType
    let startHour: Int
    let startMinute: Int
    let endHour: Int
    let endMinute: Int
    let focusScore: Int
    let earnedMinutes: Double
    let totalTicks: Int
    let nextBlock: ScheduleManager.FocusBlock?
    let appBreakdown: [(appName: String, seconds: Int)]
    let isFreeTime: Bool
    let nextBlockAvailableMinutes: Double
}

struct StartRitualData {
    let block: ScheduleManager.FocusBlock
    let availableMinutes: Double
    let isFreeTime: Bool
    var onStart: () -> Void
    var onSaveEdit: ((ScheduleManager.FocusBlock) -> Void)?
    var onPushBack: (() -> Void)?
}

struct NoPlanData {
    let isNoPlan: Bool          // true = no plan, false = unplanned time
    let canSnooze: Bool
    let nextBlockTitle: String?
    let nextBlockTime: String?
    var onPlanDay: () -> Void
    var onSnooze: (() -> Void)?
}

// MARK: - Controller

/// Manages a floating pill-shaped timer widget shown during schedule blocks.
///
/// Displays the block intention + countdown timer in the top-right corner.
/// A colored dot indicates focus state: indigo = focused, red = distracted.
/// A stats row below shows focus percentage and earned browse time.
///
/// At block end, the pill transitions to "Block complete" state, then expands
/// into celebration cards showing session stats, focus score, and app breakdown.
///
/// - `show(intention:endsAt:)` — show the widget and start counting down
/// - `update(isDistracted:)` — change the dot color
/// - `update(focusPercent:earnedMinutes:)` — update stats display
/// - `enterCelebration(data:onDone:)` — expand into celebration cards
/// - `dismiss()` — hide the widget
class DeepWorkTimerController {

    // Internal access so FocusMonitor can manage keyboard/resize for edit mode
    var timerWindow: KeyablePanel?
    private var countdownTimer: Timer?
    private(set) var viewModel: DeepWorkTimerViewModel?

    var isShowing: Bool { timerWindow != nil }

    /// Toggle to disable sound effects (set to false to silence all pill sounds)
    static var soundEnabled = true

    private static func playSound(_ name: String) {
        guard soundEnabled else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - Public API

    /// Show the floating timer widget.
    func show(intention: String, endsAt: Date) {
        dismiss()

        let vm = DeepWorkTimerViewModel(intention: intention, endsAt: endsAt)
        self.viewModel = vm

        let view = DeepWorkTimerView(viewModel: vm)
        let hostingView = NSHostingView(rootView: view)
        hostingView.autoresizingMask = [.width, .height]

        let windowWidth: CGFloat = 300
        let windowHeight: CGFloat = 70
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let window = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.animationBehavior = .utilityWindow

        // Position in top-right corner
        if let screenFrame = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: screenFrame.maxX - windowWidth - 20,
                y: screenFrame.maxY - windowHeight - 20
            )
            window.setFrameOrigin(origin)
        }

        window.orderFrontRegardless()
        timerWindow = window
        Self.playSound("Glass")

        // Start 1s countdown
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let vm = self.viewModel else { return }
            let remaining = vm.endsAt.timeIntervalSinceNow
            if remaining <= 0 {
                vm.timeDisplay = "0:00"
                vm.isApproachingEnd = false
                if vm.mode == .timer {
                    vm.mode = .blockComplete
                }
                // Don't dismiss — wait for celebration or manual dismiss
            } else {
                let secs = Int(ceil(remaining))
                let mins = secs / 60
                let s = secs % 60
                vm.timeDisplay = String(format: "%d:%02d", mins, s)
                // Lead-up: last 60s → amber timer text
                vm.isApproachingEnd = remaining <= 60
                // Countdown tones at 3, 2, 1
                if secs >= 1 && secs <= 3 && vm.mode == .timer {
                    Self.playSound("Morse")
                }
            }
        }
    }

    /// Update the distraction state (changes dot color).
    func update(isDistracted: Bool) {
        viewModel?.isDistracted = isDistracted
    }

    /// Update focus stats displayed in the stats row.
    func update(focusPercent: Int, earnedMinutes: Double) {
        viewModel?.focusPercent = min(max(focusPercent, 0), 100)
        viewModel?.earnedMinutes = earnedMinutes
    }

    /// Update the focus goal (from block ritual selection).
    func update(focusGoal: Int) {
        viewModel?.focusGoal = focusGoal
    }

    /// Expand the pill into celebration cards.
    func enterCelebration(data: CelebrationData, onDone: @escaping () -> Void) {
        guard let vm = viewModel, timerWindow != nil else { return }
        vm.celebrationData = data
        vm.onCelebrationDone = onDone
        vm.mode = .celebration
        vm.celebrationCard = 0
        vm.startAutoAdvance()
        let targetSize = data.isFreeTime ? NSSize(width: 460, height: 220) : NSSize(width: 460, height: 420)
        animateWindowResize(to: targetSize)
        Self.playSound("Glass")
    }

    /// Trigger celebration early (from hover End Block button).
    var onEndBlockEarly: (() -> Void)?

    // MARK: - Start Ritual

    /// Transition existing pill into start ritual mode (e.g., after celebration Done).
    func enterStartRitual(data: StartRitualData) {
        guard let vm = viewModel, timerWindow != nil else { return }
        vm.startRitualData = data
        vm.editBlockTitle = data.block.title
        vm.editBlockDescription = data.block.description
        vm.editBlockType = data.block.blockType
        vm.mode = .startRitual

        let timeout: TimeInterval = data.isFreeTime ? 30.0 : 180.0
        vm.startAutoStartTimer(timeout: timeout)

        animateWindowResize(to: NSSize(width: 460, height: 160))
        Self.playSound("Funk")
    }

    /// Show pill directly in start ritual mode (no preceding timer/celebration).
    func showStartRitual(block: ScheduleManager.FocusBlock, endsAt: Date, data: StartRitualData) {
        if timerWindow == nil {
            // Create the pill window (reuse show logic but immediately transition)
            show(intention: block.title, endsAt: endsAt)
        }
        enterStartRitual(data: data)
    }

    /// Build updated block from current edit state.
    func buildUpdatedBlockFromEdit() -> ScheduleManager.FocusBlock? {
        guard let vm = viewModel, let data = vm.startRitualData else { return nil }
        var block = data.block
        block.title = vm.editBlockTitle
        block.description = vm.editBlockDescription
        block.blockType = vm.editBlockType
        return block
    }

    // MARK: - No Plan Card

    /// Show the floating pill in noPlan mode (no preceding timer).
    func showNoPlan(data: NoPlanData) {
        dismiss()

        let vm = DeepWorkTimerViewModel(intention: "", endsAt: Date())
        self.viewModel = vm
        vm.noPlanData = data
        vm.mode = .noPlan

        let view = DeepWorkTimerView(viewModel: vm)
        let hostingView = NSHostingView(rootView: view)
        hostingView.autoresizingMask = [.width, .height]

        let windowWidth: CGFloat = 460
        let windowHeight: CGFloat = 260
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let window = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.animationBehavior = .utilityWindow

        // Position in top-right corner
        if let screenFrame = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: screenFrame.maxX - windowWidth - 20,
                y: screenFrame.maxY - windowHeight - 20
            )
            window.setFrameOrigin(origin)
        }

        window.orderFrontRegardless()
        timerWindow = window
    }

    /// Hide the widget and stop the countdown.
    func dismiss() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        viewModel?.stopAutoAdvance()
        viewModel?.stopAutoStartTimer()
        timerWindow?.allowKeyboardInput = false
        timerWindow?.close()
        timerWindow = nil
        viewModel = nil
    }

    deinit {
        dismiss()
    }

    // MARK: - Window Animation

    func animateWindowResize(to newSize: NSSize) {
        guard let window = timerWindow else { return }
        let old = window.frame
        // Keep top-right corner fixed
        let newFrame = NSRect(
            x: old.maxX - newSize.width,
            y: old.maxY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            // Spring-like overshoot curve (revert to easeInEaseOut if too bouncy)
            // Old: ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            window.animator().setFrame(newFrame, display: true)
        }
    }
}

// MARK: - View Model

class DeepWorkTimerViewModel: ObservableObject {
    let intention: String
    let endsAt: Date

    @Published var timeDisplay: String
    @Published var isDistracted: Bool = false
    @Published var focusPercent: Int = 0
    @Published var earnedMinutes: Double = 0.0
    @Published var focusGoal: Int = 80
    @Published var isApproachingEnd: Bool = false
    @Published var isHovered: Bool = false

    // Mode
    @Published var mode: PillMode = .timer

    // Celebration
    @Published var celebrationData: CelebrationData? = nil
    @Published var celebrationCard: Int = 0
    var onCelebrationDone: (() -> Void)?
    private var autoAdvanceTimer: Timer?

    // Start Ritual
    @Published var startRitualData: StartRitualData? = nil
    @Published var autoStartRemaining: Int = 0

    // No Plan
    @Published var noPlanData: NoPlanData? = nil
    @Published var editBlockTitle: String = ""
    @Published var editBlockDescription: String = ""
    @Published var editBlockType: ScheduleManager.BlockType = .focusHours
    private var autoStartTimer: Timer?

    var onStartFromUpNext: (() -> Void)?

    var hasUpNextCard: Bool {
        guard let data = celebrationData, let next = data.nextBlock else { return false }
        let currentEnd = data.endHour * 60 + data.endMinute
        let nextStart = next.startHour * 60 + next.startMinute
        return nextStart - currentEnd <= 5  // within 5 min = back-to-back
    }

    var celebrationCardCount: Int {
        guard let data = celebrationData else { return 1 }
        if data.isFreeTime { return 1 }
        return hasUpNextCard ? 4 : 3
    }

    init(intention: String, endsAt: Date) {
        self.intention = intention
        self.endsAt = endsAt

        let remaining = max(0, endsAt.timeIntervalSinceNow)
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        self.timeDisplay = String(format: "%d:%02d", mins, secs)
    }

    func nextCelebrationCard() {
        if celebrationCard < celebrationCardCount - 1 {
            celebrationCard += 1
            restartAutoAdvance()
        } else {
            stopAutoAdvance()
            // If we're on the Up Next card, call its specific handler
            if hasUpNextCard && celebrationCard == 3 {
                onStartFromUpNext?()
            } else {
                onCelebrationDone?()
            }
        }
    }

    func startAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.nextCelebrationCard()
            }
        }
    }

    func restartAutoAdvance() {
        startAutoAdvance()
    }

    func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }

    // MARK: - Auto-Start Timer (Start Ritual)

    func startAutoStartTimer(timeout: TimeInterval) {
        stopAutoStartTimer()
        autoStartRemaining = Int(timeout)
        autoStartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.autoStartRemaining -= 1
                if self.autoStartRemaining <= 0 {
                    self.stopAutoStartTimer()
                    self.startRitualData?.onStart()
                }
            }
        }
    }

    func stopAutoStartTimer() {
        autoStartTimer?.invalidate()
        autoStartTimer = nil
    }

    func pauseAutoStartTimer() {
        autoStartTimer?.invalidate()
        autoStartTimer = nil
    }

    func resumeAutoStartTimer() {
        guard autoStartRemaining > 0 else { return }
        autoStartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.autoStartRemaining -= 1
                if self.autoStartRemaining <= 0 {
                    self.stopAutoStartTimer()
                    self.startRitualData?.onStart()
                }
            }
        }
    }

    var autoStartDisplay: String {
        let m = autoStartRemaining / 60
        let s = autoStartRemaining % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Start Ritual Duration Display

    var startRitualDurationDisplay: String {
        guard let data = startRitualData else { return "" }
        let total = (data.block.endHour * 60 + data.block.endMinute) - (data.block.startHour * 60 + data.block.startMinute)
        guard total > 0 else { return "" }
        let h = total / 60, m = total % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }

    var startRitualTimeDisplay: String {
        guard let data = startRitualData else { return "" }
        return "\(formatTime(hour: data.block.startHour, minute: data.block.startMinute)) — \(formatTime(hour: data.block.endHour, minute: data.block.endMinute))"
    }

    // Formatting helpers

    func formatTime(hour: Int, minute: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return minute == 0 ? "\(h12) \(ampm)" : "\(h12):\(String(format: "%02d", minute)) \(ampm)"
    }

    var durationDisplay: String {
        guard let data = celebrationData else { return "" }
        let total = (data.endHour * 60 + data.endMinute) - (data.startHour * 60 + data.startMinute)
        guard total > 0 else { return "" }
        let h = total / 60, m = total % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }

    var earnedDisplay: String {
        guard let data = celebrationData else { return "" }
        if data.earnedMinutes < 1 { return "less than a minute" }
        return "\(Int(round(data.earnedMinutes))) min"
    }

    var focusMessage: String {
        guard let data = celebrationData else { return "" }
        if data.focusScore >= 80 { return ["Great session!", "Crushed it!", "Nailed it!"].randomElement()! }
        if data.focusScore >= 50 { return "Good effort — next one's yours." }
        return "We'll get there. Keep showing up."
    }

    func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        } else if seconds >= 60 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds)s"
        }
    }
}

// MARK: - SwiftUI View

struct DeepWorkTimerView: View {
    @ObservedObject var viewModel: DeepWorkTimerViewModel

    // Dark pill palette
    private let bgColor = Color(red: 0.09, green: 0.09, blue: 0.11)
    private let textPrimary = Color(red: 0.95, green: 0.95, blue: 0.95)
    private let textSecondary = Color(red: 0.70, green: 0.70, blue: 0.70)
    private let borderColor = Color.white.opacity(0.12)
    private let separatorColor = Color.white.opacity(0.08)
    private let amberColor = Color(red: 0.95, green: 0.75, blue: 0.25)

    // Dot colors
    private let focusedStart = Color(red: 0.39, green: 0.4, blue: 0.95)
    private let focusedEnd = Color(red: 0.55, green: 0.36, blue: 0.96)
    private let distractedColor = Color(red: 0.95, green: 0.25, blue: 0.25)

    // Button / accent colors
    private let goGreen = Color(red: 0.25, green: 0.78, blue: 0.45)
    private let goGreenBright = Color(red: 0.30, green: 0.88, blue: 0.52)

    private let deepWorkColor = Color(red: 0.95, green: 0.35, blue: 0.35)
    private let focusHoursColor = Color(red: 0.45, green: 0.46, blue: 1.0)
    private let freeTimeColor = Color(red: 0.35, green: 0.85, blue: 0.55)

    private var focusColor: Color {
        let pct = viewModel.focusPercent
        if pct >= 80 { return Color(red: 0.39, green: 0.8, blue: 0.5) }
        if pct >= 50 { return Color(red: 0.95, green: 0.65, blue: 0.15) }
        return Color(red: 0.95, green: 0.25, blue: 0.25)
    }

    private var earnedText: String {
        let mins = viewModel.earnedMinutes
        if mins < 0.1 { return "+0m" }
        if mins < 10 { return String(format: "+%.1fm", mins) }
        return "+\(Int(mins))m"
    }

    var body: some View {
        Group {
            switch viewModel.mode {
            case .timer:
                timerBody
            case .blockComplete:
                blockCompleteBody
            case .celebration:
                celebrationBody
            case .startRitual:
                startRitualBody
            case .startRitualEdit:
                startRitualEditBody
            case .noPlan:
                noPlanBody
            }
        }
        .onHover { viewModel.isHovered = $0 }
    }

    // MARK: - Timer Mode (normal pill)

    private var timerBody: some View {
        VStack(spacing: 0) {
            // Top row: dot + intention + timer
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        viewModel.isDistracted
                            ? LinearGradient(colors: [distractedColor, distractedColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [focusedStart, focusedEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 8, height: 8)

                Text(viewModel.intention)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(viewModel.timeDisplay)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(viewModel.isApproachingEnd ? amberColor : textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 5)

            // Separator + stats row or End Block button
            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)
                .padding(.horizontal, 14)

            if viewModel.isHovered {
                // Hover: show End Block button
                Button(action: {
                    // Post notification — FocusMonitor will handle
                    NotificationCenter.default.post(name: .pillEndBlockTapped, object: nil)
                }) {
                    Text("End Block")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(amberColor.opacity(0.8))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.top, 5)
                .padding(.bottom, 6)
            } else {
                // Normal: stats row
                HStack {
                    Text("\(viewModel.focusPercent)% focused")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(focusColor)

                    Spacer()

                    Text(earnedText)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(Color(red: 0.3, green: 0.8, blue: 0.5))
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        }
        .background(bgColor)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
    }

    // MARK: - Block Complete Mode (transitional)

    private var blockCompleteBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(amberColor)
                    .frame(width: 8, height: 8)

                Text("Block complete")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(amberColor)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("0:00")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(amberColor)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 5)

            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)
                .padding(.horizontal, 14)

            HStack {
                Text("\(viewModel.focusPercent)% focused")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(focusColor)

                Spacer()

                Text(earnedText)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(Color(red: 0.3, green: 0.8, blue: 0.5))
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .background(bgColor)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(amberColor.opacity(0.5), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
    }

    // MARK: - Celebration Mode (expanded cards)

    private var celebrationBody: some View {
        VStack(spacing: 0) {
            if let data = viewModel.celebrationData {
                if data.isFreeTime {
                    freeTimeEndCard(data: data)
                } else {
                    workBlockCarousel(data: data)
                }
            }
        }
        .background(bgColor)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
    }

    // MARK: - Work Block Carousel

    private func workBlockCarousel(data: CelebrationData) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if viewModel.celebrationCard == 0 {
                    sessionCompleteCard(data: data)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                if viewModel.celebrationCard == 1 {
                    focusScoreCard(data: data)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                if viewModel.celebrationCard == 2 {
                    appBreakdownCard(data: data)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                if viewModel.celebrationCard == 3, viewModel.hasUpNextCard {
                    upNextCard(data: data)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: viewModel.celebrationCard)

            // Card navigation dots
            HStack(spacing: 6) {
                ForEach(0..<viewModel.celebrationCardCount, id: \.self) { i in
                    Circle()
                        .fill(i == viewModel.celebrationCard ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Card 1: Session Complete

    private func sessionCompleteCard(data: CelebrationData) -> some View {
        let typeColor = blockTypeColor(data.blockType)
        let typeLabel = blockTypeLabel(data.blockType)

        return VStack(spacing: 0) {
            Text("Session complete")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(textSecondary)
                .tracking(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)

            // Block title + duration
            HStack(alignment: .top) {
                Text(data.blockTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(textPrimary)
                    .lineLimit(2)
                Spacer()
                Text(viewModel.durationDisplay)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textSecondary)
            }
            .padding(.bottom, 6)

            // Block type + time
            HStack(spacing: 6) {
                Circle().fill(typeColor).frame(width: 6, height: 6)
                Text(typeLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(typeColor)
                    .tracking(0.8)
                Text("\u{00B7}")
                    .foregroundColor(textSecondary)
                Text(viewModel.formatTime(hour: data.startHour, minute: data.startMinute) + " — " +
                     viewModel.formatTime(hour: data.endHour, minute: data.endMinute))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textSecondary)
                Spacer()
            }
            .padding(.bottom, 20)

            // Divider
            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)
                .padding(.bottom, 16)

            // Earned minutes
            Text("You earned \(viewModel.earnedDisplay) of recharge time.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 20)

            // Next button
            celebrationNextButton(label: "Next")
        }
        .padding(20)
    }

    // MARK: - Card 2: Focus Score

    private func focusScoreCard(data: CelebrationData) -> some View {
        let barColor = celebrationFocusBarColor(data.focusScore)

        return ZStack {
            // Inline confetti for high focus scores
            if data.focusScore >= 80 {
                ConfettiCanvasView()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                Spacer().frame(height: 8)

                // Big focus score
                Text("\(data.focusScore)% focused")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(barColor)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 16)

                // Focus bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor)
                            .frame(width: geo.size.width * CGFloat(data.focusScore) / 100.0, height: 8)
                    }
                }
                .frame(height: 8)
                .padding(.horizontal, 4)
                .padding(.bottom, 20)

                // Encouragement
                Text(viewModel.focusMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 24)

                // Next button
                celebrationNextButton(label: "Next")
            }
            .padding(20)
        }
    }

    // MARK: - Card 3: App Breakdown

    private func appBreakdownCard(data: CelebrationData) -> some View {
        VStack(spacing: 0) {
            Text("Where you spent your time")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(textSecondary)
                .tracking(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 14)

            if data.appBreakdown.isEmpty {
                Text("No activity recorded.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 14)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(data.appBreakdown.prefix(6).enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.appName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(viewModel.formatDuration(entry.seconds))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(textSecondary)
                        }
                    }
                }
                .padding(.bottom, 14)
            }

            // Divider
            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)
                .padding(.bottom, 12)

            if viewModel.hasUpNextCard {
                // When Up Next card follows, show "Next" to advance to card 4
                celebrationNextButton(label: "Next")
            } else {
                // Next block preview (only when no Up Next card)
                if let next = data.nextBlock {
                    celebrationNextBlockPreview(next: next)
                        .padding(.bottom, 14)
                }

                // Done button
                celebrationDoneButton()
            }
        }
        .padding(20)
    }

    // MARK: - Card 4: Up Next (back-to-back blocks)

    private func upNextCard(data: CelebrationData) -> some View {
        guard let next = data.nextBlock else {
            return AnyView(EmptyView())
        }

        let nextTypeColor = blockTypeColor(next.blockType)
        let nextTypeLabel = blockTypeLabel(next.blockType)
        let nextIsFreeTime = next.blockType == .freeTime
        let nextDuration: Int = (next.endHour * 60 + next.endMinute) - (next.startHour * 60 + next.startMinute)
        let durationStr: String = {
            let h = nextDuration / 60, m = nextDuration % 60
            if h > 0 && m > 0 { return "\(h)h \(m)m" }
            return h > 0 ? "\(h)h" : "\(m)m"
        }()

        return AnyView(VStack(spacing: 0) {
            Text("Up next")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(textSecondary)
                .tracking(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)

            // Divider
            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)
                .padding(.bottom, 14)

            // Block type + time + duration
            HStack(spacing: 6) {
                Circle().fill(nextTypeColor).frame(width: 6, height: 6)
                Text(nextTypeLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(nextTypeColor)
                    .tracking(0.8)
                Text("\u{00B7}")
                    .foregroundColor(textSecondary)
                Text(viewModel.formatTime(hour: next.startHour, minute: next.startMinute) + " — " +
                     viewModel.formatTime(hour: next.endHour, minute: next.endMinute))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textSecondary)
                Text("\u{00B7}")
                    .foregroundColor(textSecondary)
                Text(durationStr)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textSecondary)
                Spacer()
            }
            .padding(.bottom, 12)

            if nextIsFreeTime {
                // Free time variant
                Text("Enjoy your break.")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)

                if data.nextBlockAvailableMinutes > 0 {
                    Text("\(Int(data.nextBlockAvailableMinutes)) min available")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 16)
                } else {
                    Spacer().frame(height: 16)
                }

                // Start Break button
                Button(action: {
                    viewModel.stopAutoAdvance()
                    viewModel.onStartFromUpNext?()
                }) {
                    Text("Start Break")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(freeTimeColor.opacity(0.9))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            } else {
                // Work block variant
                Text(next.title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)

                if !next.description.isEmpty {
                    Text(next.description)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 16)
                } else {
                    Spacer().frame(height: 16)
                }

                // Start button
                Button(action: {
                    viewModel.stopAutoAdvance()
                    viewModel.onStartFromUpNext?()
                }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(colors: [goGreen, goGreenBright],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20))
    }

    // MARK: - Free Time End Card

    private func freeTimeEndCard(data: CelebrationData) -> some View {
        VStack(spacing: 0) {
            Text("Break over")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(textSecondary)
                .tracking(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 14)

            // Block type + time
            HStack(spacing: 6) {
                Circle().fill(freeTimeColor).frame(width: 6, height: 6)
                Text("FREE TIME")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(freeTimeColor)
                    .tracking(0.8)
                Text("\u{00B7}")
                    .foregroundColor(textSecondary)
                Text(viewModel.formatTime(hour: data.startHour, minute: data.startMinute) + " — " +
                     viewModel.formatTime(hour: data.endHour, minute: data.endMinute))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textSecondary)
                Spacer()
            }
            .padding(.bottom, 16)

            // Next block preview
            if let next = data.nextBlock {
                celebrationNextBlockPreview(next: next)
                    .padding(.bottom, 14)
            }

            // Done button
            celebrationDoneButton()
        }
        .padding(20)
    }

    // MARK: - Start Ritual Mode

    private var startRitualBody: some View {
        VStack(spacing: 0) {
            if let data = viewModel.startRitualData {
                if data.isFreeTime {
                    freeTimeStartRitualContent(data: data)
                } else {
                    workStartRitualContent(data: data)
                }
            }
        }
        .background(bgColor)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(goGreen.opacity(0.35), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
    }

    private func workStartRitualContent(data: StartRitualData) -> some View {
        let typeColor = blockTypeColor(data.block.blockType)
        let typeLabel = blockTypeLabel(data.block.blockType)

        return VStack(spacing: 0) {
            // Header: type dot + label + duration
            HStack(spacing: 6) {
                Circle().fill(typeColor).frame(width: 7, height: 7)
                Text(typeLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(typeColor)
                    .tracking(0.8)
                Spacer()
                Text(viewModel.startRitualDurationDisplay)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Separator
            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)
                .padding(.horizontal, 14)

            // Block title
            Text(viewModel.editBlockTitle)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 2)

            // Block description (if non-empty)
            if !viewModel.editBlockDescription.isEmpty {
                Text(viewModel.editBlockDescription)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 2)
            }

            // Time range
            Text(viewModel.startRitualTimeDisplay)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            // Start button + Edit + auto-start
            HStack(spacing: 8) {
                Button(action: {
                    viewModel.stopAutoStartTimer()
                    viewModel.startRitualData?.onStart()
                }) {
                    Text("Start")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 7)
                        .background(
                            LinearGradient(colors: [goGreen, goGreenBright],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button(action: {
                    viewModel.pauseAutoStartTimer()
                    viewModel.mode = .startRitualEdit
                    NotificationCenter.default.post(name: .pillEnterEditMode, object: nil)
                }) {
                    Text("Edit")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("auto: \(viewModel.autoStartDisplay)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func freeTimeStartRitualContent(data: StartRitualData) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle().fill(freeTimeColor).frame(width: 7, height: 7)
                Text("FREE TIME")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(freeTimeColor)
                    .tracking(0.8)
                Spacer()
                Text(viewModel.startRitualDurationDisplay)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Separator
            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)
                .padding(.horizontal, 14)

            // Message
            Text("Enjoy your break.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)

            if data.availableMinutes > 0 {
                Text("\(Int(data.availableMinutes)) min recharge available")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                Spacer().frame(height: 10)
            }

            // Start Break button + auto-start
            HStack(spacing: 8) {
                Button(action: {
                    viewModel.stopAutoStartTimer()
                    viewModel.startRitualData?.onStart()
                }) {
                    Text("Start Break")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 7)
                        .background(freeTimeColor.opacity(0.9))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("auto: \(viewModel.autoStartDisplay)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    // MARK: - No Plan Mode

    private var noPlanBody: some View {
        VStack(spacing: 0) {
            if let data = viewModel.noPlanData {
                noPlanContent(data: data)
            }
        }
        .background(bgColor)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(amberColor.opacity(0.35), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
    }

    private func noPlanContent(data: NoPlanData) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle().fill(amberColor).frame(width: 7, height: 7)
                Text(data.isNoPlan ? "NO PLAN" : "UNSCHEDULED")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(amberColor)
                    .tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Separator
            Rectangle()
                .fill(separatorColor)
                .frame(height: 1)
                .padding(.horizontal, 16)

            // Title
            Text(data.isNoPlan ? "Plan your day to stay focused" : "This time isn't scheduled")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

            // Subtitle
            Text(data.isNoPlan
                 ? "Set up your daily plan to unlock browsing and track your focus."
                 : "Add a block to your schedule or take a planned break.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            // Next block preview
            if let title = data.nextBlockTitle, let time = data.nextBlockTime {
                HStack(spacing: 6) {
                    Circle().fill(focusHoursColor).frame(width: 5, height: 5)
                    Text("Next: \(title)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(time)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.4))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }

            // Plan My Day button
            Button(action: {
                data.onPlanDay()
            }) {
                Text("Plan My Day")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(colors: [goGreen, goGreenBright],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Snooze link
            if data.canSnooze {
                Button(action: {
                    data.onSnooze?()
                }) {
                    Text("Snooze 30 min")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            } else {
                Spacer().frame(height: 4)
            }
        }
    }

    // MARK: - Start Ritual Edit Mode

    private var startRitualEditBody: some View {
        let fieldBg = Color.white.opacity(0.07)
        let fieldBorder = Color.white.opacity(0.12)
        let textTertiary = Color(white: 0.40)

        return VStack(alignment: .leading, spacing: 0) {
            if let data = viewModel.startRitualData {
                let typeColor = blockTypeColor(data.block.blockType)
                let typeLabel = blockTypeLabel(data.block.blockType)

                // Header
                HStack(spacing: 6) {
                    Circle().fill(typeColor).frame(width: 7, height: 7)
                    Text(typeLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(typeColor)
                        .tracking(0.8)
                    Text("\u{00B7}")
                        .foregroundColor(textSecondary)
                    Text(viewModel.startRitualTimeDisplay)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textSecondary)
                    Spacer()
                }
                .padding(.bottom, 14)

                // Separator
                Rectangle()
                    .fill(separatorColor)
                    .frame(height: 1)
                    .padding(.bottom, 14)

                // Title field
                Text("Title")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textTertiary)
                    .padding(.bottom, 4)

                TextField("What are you working on?", text: $viewModel.editBlockTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(textPrimary)
                    .padding(10)
                    .background(fieldBg)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(fieldBorder, lineWidth: 1))
                    .padding(.bottom, 12)

                // Description field
                Text("Description")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textTertiary)
                    .padding(.bottom, 4)

                TextField("What will you accomplish?", text: $viewModel.editBlockDescription)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(textPrimary)
                    .padding(10)
                    .background(fieldBg)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(fieldBorder, lineWidth: 1))
                    .padding(.bottom, 14)

                // Block type toggle
                HStack(spacing: 8) {
                    startRitualTypePill(.deepWork, label: "Deep Work", color: deepWorkColor)
                    startRitualTypePill(.focusHours, label: "Focus Hours", color: focusHoursColor)
                }
                .padding(.bottom, 16)

                // Done button
                Button(action: {
                    NotificationCenter.default.post(name: .pillExitEditMode, object: nil)
                }) {
                    Text("Done")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            LinearGradient(colors: [goGreen, goGreenBright],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(bgColor)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
    }

    private func startRitualTypePill(_ type: ScheduleManager.BlockType, label: String, color: Color) -> some View {
        let selected = viewModel.editBlockType == type
        return Button(action: { viewModel.editBlockType = type }) {
            HStack(spacing: 5) {
                Circle().fill(selected ? color : Color.clear)
                    .overlay(Circle().stroke(selected ? Color.clear : Color(white: 0.40), lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                Text(label).font(.system(size: 11, weight: .medium))
                    .foregroundColor(selected ? textPrimary : textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? color.opacity(0.15) : Color.white.opacity(0.04))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? color.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Celebration Shared Components

    private func celebrationNextButton(label: String) -> some View {
        Button(action: {
            withAnimation {
                viewModel.nextCelebrationCard()
            }
        }) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 14, weight: .bold))
                Text("\u{2192}")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                LinearGradient(colors: [goGreen, goGreenBright],
                               startPoint: .leading, endPoint: .trailing)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func celebrationDoneButton() -> some View {
        Button(action: {
            viewModel.stopAutoAdvance()
            viewModel.onCelebrationDone?()
        }) {
            Text("Done")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(colors: [goGreen, goGreenBright],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func celebrationNextBlockPreview(next: ScheduleManager.FocusBlock) -> some View {
        let color = blockTypeColor(next.blockType)
        let typeLabel: String = {
            switch next.blockType {
            case .deepWork: return "Deep Work"
            case .focusHours: return "Focus Hours"
            case .freeTime: return "Free Time"
            }
        }()

        let now = Calendar.current.component(.hour, from: Date()) * 60
            + Calendar.current.component(.minute, from: Date())
        let diff = next.startMinutes - now
        let startsIn: String
        if diff <= 0 {
            startsIn = "now"
        } else if diff < 60 {
            startsIn = "in \(diff) min"
        } else {
            let h = diff / 60, m = diff % 60
            startsIn = m > 0 ? "in \(h)h \(m)m" : "in \(h)h"
        }

        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("Next: \(typeLabel) — \(next.title)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(textSecondary)
                .lineLimit(1)
            Spacer()
            Text(startsIn)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.white.opacity(0.4))
        }
    }

    // MARK: - Helpers

    private func blockTypeColor(_ type: ScheduleManager.BlockType) -> Color {
        switch type {
        case .deepWork: return deepWorkColor
        case .focusHours: return focusHoursColor
        case .freeTime: return freeTimeColor
        }
    }

    private func blockTypeLabel(_ type: ScheduleManager.BlockType) -> String {
        switch type {
        case .deepWork: return "DEEP WORK"
        case .focusHours: return "FOCUS HOURS"
        case .freeTime: return "FREE TIME"
        }
    }

    private func celebrationFocusBarColor(_ score: Int) -> Color {
        if score >= 80 { return goGreen }
        if score >= 50 { return amberColor }
        return Color(red: 0.95, green: 0.35, blue: 0.35)
    }
}

// MARK: - Inline Confetti (Canvas particle effect)

struct ConfettiCanvasView: View {
    @State private var startTime = Date()
    @State private var particles: [ConfettiParticle] = []

    private let confettiColors: [Color] = [
        Color(red: 0.25, green: 0.78, blue: 0.45),  // green
        Color(red: 0.35, green: 0.55, blue: 1.0),    // blue
        Color(red: 1.0, green: 0.85, blue: 0.2),     // yellow
        Color(red: 1.0, green: 0.55, blue: 0.2),     // orange
        Color(red: 1.0, green: 0.4, blue: 0.6),      // pink
        Color(red: 0.7, green: 0.4, blue: 1.0),      // purple
    ]

    struct ConfettiParticle {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var rotation: Double
        var rotationSpeed: Double
        var color: Color
        var size: CGFloat
        var isCircle: Bool
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startTime)
            let opacity = max(0, 1.0 - elapsed / 2.5)

            Canvas { context, size in
                guard opacity > 0 else { return }
                for p in particles {
                    let x = p.x + p.vx * elapsed
                    let y = p.y + p.vy * elapsed + 0.5 * 280 * elapsed * elapsed
                    let rot = Angle.degrees(p.rotation + p.rotationSpeed * elapsed)

                    guard x >= -20 && x <= size.width + 20 && y <= size.height + 20 else { continue }

                    context.opacity = opacity
                    context.translateBy(x: x, y: y)
                    context.rotate(by: rot)

                    if p.isCircle {
                        let rect = CGRect(x: -p.size/2, y: -p.size/2, width: p.size, height: p.size)
                        context.fill(Circle().path(in: rect), with: .color(p.color))
                    } else {
                        let rect = CGRect(x: -p.size/2, y: -p.size * 0.3, width: p.size, height: p.size * 0.6)
                        context.fill(Rectangle().path(in: rect), with: .color(p.color))
                    }

                    context.rotate(by: -rot)
                    context.translateBy(x: -x, y: -y)
                }
            }
        }
        .onAppear {
            startTime = Date()
            particles = (0..<40).map { _ in
                ConfettiParticle(
                    x: CGFloat.random(in: 40...420),
                    y: CGFloat.random(in: -10...10),
                    vx: CGFloat.random(in: -60...60),
                    vy: CGFloat.random(in: -180 ... -60),
                    rotation: Double.random(in: 0...360),
                    rotationSpeed: Double.random(in: -200...200),
                    color: confettiColors.randomElement()!,
                    size: CGFloat.random(in: 4...8),
                    isCircle: Bool.random()
                )
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let pillEndBlockTapped = Notification.Name("pillEndBlockTapped")
    static let pillEnterEditMode = Notification.Name("pillEnterEditMode")
    static let pillExitEditMode = Notification.Name("pillExitEditMode")
}

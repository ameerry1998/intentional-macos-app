import Cocoa
import SwiftUI

/// Manages the block start ritual overlay shown when a focus block begins.
///
/// Full-screen overlay with centered card. Uses `KeyableWindow`
/// (from FocusOverlayWindow.swift) so text fields accept keyboard input.
///
/// Supports multiple design variants (cycled via prev/next in preview mode).
class BlockRitualController {

    private var ritualWindow: NSWindow?
    private var autoDismissTimer: Timer?
    private var viewModel: BlockRitualViewModel?

    var isShowing: Bool { ritualWindow != nil }
    var currentFocusQuestion: String? { viewModel?.focusQuestion.isEmpty == false ? viewModel?.focusQuestion : nil }
    var currentIfThenPlan: Int? { viewModel?.selectedPlan }
    var currentFocusGoal: Int { viewModel?.focusGoal ?? 80 }

    func buildUpdatedBlock() -> ScheduleManager.FocusBlock? {
        viewModel?.buildUpdatedBlock()
    }

    static let ifThenPlans: [String] = [
        "Close the tab and return to my task",
        "Pause, re-read my intention above, and start again",
        "Write down what pulled me away for later, then refocus"
    ]

    static let designVariantCount = 8 // 0-1 = originals, 2-6 = Bright Airy iterations, 7 = combo

    func show(
        block: ScheduleManager.FocusBlock,
        availableMinutes: Double,
        onStart: @escaping () -> Void,
        onSaveEdit: @escaping (ScheduleManager.FocusBlock) -> Void,
        onPushBack: @escaping () -> Void
    ) {
        dismiss()

        let isFreeTime = block.blockType == .freeTime
        let defaultPlan = UserDefaults.standard.integer(forKey: "defaultIfThenPlan")
        let savedVariant = UserDefaults.standard.integer(forKey: "blockRitualDesign")

        let vm = BlockRitualViewModel(
            blockId: block.id,
            blockTitle: block.title,
            blockDescription: block.description,
            blockType: block.blockType,
            startHour: block.startHour,
            startMinute: block.startMinute,
            endHour: block.endHour,
            endMinute: block.endMinute,
            availableMinutes: availableMinutes,
            selectedPlan: Swift.min(defaultPlan, Self.ifThenPlans.count - 1),
            focusQuestion: block.description,
            focusGoal: 80,
            designVariant: savedVariant < Self.designVariantCount ? savedVariant : 3,
            onStart: { [weak self] in
                if let v = self?.viewModel?.designVariant {
                    UserDefaults.standard.set(v, forKey: "blockRitualDesign")
                }
                self?.dismiss()
                onStart()
            },
            onSaveEdit: onSaveEdit,
            onPushBack: { [weak self] in
                self?.dismiss()
                onPushBack()
            }
        )

        self.viewModel = vm

        let view = BlockRitualView(viewModel: vm, isFreeTime: isFreeTime)
        let hostingView = NSHostingView(rootView: view)

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        hostingView.frame = screenFrame

        let window = KeyableWindow(
            contentRect: screenFrame,
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

        window.setFrame(screenFrame, display: true)
        window.makeKeyAndOrderFront(nil)
        ritualWindow = window

        let timeout: TimeInterval = isFreeTime ? 30.0 : 180.0
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard self?.isShowing == true else { return }
            if let v = self?.viewModel?.designVariant {
                UserDefaults.standard.set(v, forKey: "blockRitualDesign")
            }
            self?.dismiss()
            onStart()
        }
    }

    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        ritualWindow?.close()
        ritualWindow = nil
    }

    deinit { dismiss() }
}

// MARK: - View Model

class BlockRitualViewModel: ObservableObject {
    let blockId: String
    @Published var blockTitle: String
    @Published var blockDescription: String
    @Published var blockType: ScheduleManager.BlockType
    @Published var startHour: Int
    @Published var startMinute: Int
    @Published var endHour: Int
    @Published var endMinute: Int
    @Published var availableMinutes: Double
    @Published var selectedPlan: Int
    @Published var focusQuestion: String
    @Published var focusGoal: Int
    @Published var isEditing: Bool = false
    @Published var designVariant: Int

    let onStart: () -> Void
    let onSaveEdit: (ScheduleManager.FocusBlock) -> Void
    let onPushBack: () -> Void

    var blockTypeLabel: String {
        switch blockType {
        case .deepWork: return "DEEP WORK"
        case .focusHours: return "FOCUS HOURS"
        case .freeTime: return "FREE TIME"
        }
    }

    var timeDisplay: String {
        "\(formatTime(hour: startHour, minute: startMinute)) — \(formatTime(hour: endHour, minute: endMinute))"
    }

    var durationDisplay: String {
        let total = (endHour * 60 + endMinute) - (startHour * 60 + startMinute)
        guard total > 0 else { return "" }
        let h = total / 60, m = total % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }

    init(blockId: String, blockTitle: String, blockDescription: String,
         blockType: ScheduleManager.BlockType,
         startHour: Int, startMinute: Int, endHour: Int, endMinute: Int,
         availableMinutes: Double, selectedPlan: Int, focusQuestion: String,
         focusGoal: Int, designVariant: Int,
         onStart: @escaping () -> Void,
         onSaveEdit: @escaping (ScheduleManager.FocusBlock) -> Void,
         onPushBack: @escaping () -> Void) {
        self.blockId = blockId; self.blockTitle = blockTitle
        self.blockDescription = blockDescription; self.blockType = blockType
        self.startHour = startHour; self.startMinute = startMinute
        self.endHour = endHour; self.endMinute = endMinute
        self.availableMinutes = availableMinutes; self.selectedPlan = selectedPlan
        self.focusQuestion = focusQuestion; self.focusGoal = focusGoal
        self.designVariant = designVariant
        self.onStart = onStart; self.onSaveEdit = onSaveEdit; self.onPushBack = onPushBack
    }

    func buildUpdatedBlock() -> ScheduleManager.FocusBlock {
        ScheduleManager.FocusBlock(
            id: blockId, title: blockTitle, description: focusQuestion,
            startHour: startHour, startMinute: startMinute,
            endHour: endHour, endMinute: endMinute, blockType: blockType
        )
    }

    func nextVariant() {
        designVariant = (designVariant + 1) % BlockRitualController.designVariantCount
    }
    func prevVariant() {
        designVariant = (designVariant - 1 + BlockRitualController.designVariantCount) % BlockRitualController.designVariantCount
    }

    private func formatTime(hour: Int, minute: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return minute == 0 ? "\(h12) \(ampm)" : "\(h12):\(String(format: "%02d", minute)) \(ampm)"
    }
}

// MARK: - Design variant names

private let variantNames = [
    "Floating Glass",        // 0: original dark glass
    "Light Card",            // 1: original white card
    "Ready to Focus",        // 2: warm greeting, accent bar
    "Up Next",               // 3: casual, compact header
    "Your Session",          // 4: centered greeting, spacious
    "Let's Go",              // 5: bold greeting, minimal
    "Next Block",            // 6: quiet, understated
    "Up Next + Quiet",       // 7: Next Block design + "Up next" header
]

// MARK: - SwiftUI View

struct BlockRitualView: View {
    @ObservedObject var viewModel: BlockRitualViewModel
    let isFreeTime: Bool

    // Shared colors
    private let goGreen = Color(red: 0.25, green: 0.78, blue: 0.45)
    private let goGreenBright = Color(red: 0.30, green: 0.88, blue: 0.52)
    private let accentStart = Color(red: 0.45, green: 0.46, blue: 1.0)
    private let deepWorkColor = Color(red: 0.95, green: 0.35, blue: 0.35)
    private let freeTimeColor = Color(red: 0.35, green: 0.85, blue: 0.55)

    private var blockTypeColor: Color {
        switch viewModel.blockType {
        case .deepWork: return deepWorkColor
        case .focusHours: return accentStart
        case .freeTime: return freeTimeColor
        }
    }

    var body: some View {
        ZStack {
            // Background layer
            backdropForVariant(viewModel.designVariant)
                .ignoresSafeArea()

            // Centered content
            VStack(spacing: 0) {
                Spacer()

                if viewModel.isEditing {
                    editCard
                } else if isFreeTime {
                    freeTimeCard
                } else {
                    cardForVariant(viewModel.designVariant)
                }

                Spacer()
            }
        }
    }

    // MARK: - Backdrop per variant

    @ViewBuilder
    private func backdropForVariant(_ v: Int) -> some View {
        switch v {
        case 0: // Floating Glass — no dim
            Color.clear
        case 1: // Light Card — very subtle dim
            Color.black.opacity(0.12)
        default: // All Bright Airy iterations — minimal dim
            Color.black.opacity(0.08)
        }
    }

    // MARK: - Card per variant

    @ViewBuilder
    private func cardForVariant(_ v: Int) -> some View {
        switch v {
        case 0: variant0_floatingGlass
        case 1: variant1_lightCard
        case 2: variant2_readyToFocus
        case 3: variant3_upNext
        case 4: variant4_yourSession
        case 5: variant5_letsGo
        case 6: variant6_nextBlock
        case 7: variant7_upNextQuiet
        default: variant0_floatingGlass
        }
    }

    // MARK: - Variant 0: Floating Glass (glassmorphic card, no backdrop)

    private var variant0_floatingGlass: some View {
        VStack(spacing: 0) {
            badge.padding(.bottom, 4)
            timeRow.padding(.bottom, 16)
            titleText.padding(.bottom, 6)
            descriptionText
            Spacer().frame(height: 24)
            greenStartButton
            editLink
        }
        .padding(32)
        .frame(maxWidth: 440)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                Color(red: 0.10, green: 0.10, blue: 0.14).opacity(0.55)
            }
        )
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 50, x: 0, y: 15)
    }

    // MARK: - Variant 1: Light Card (white card, subtle dim)

    private var variant1_lightCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(blockTypeColor).frame(width: 8, height: 8)
                Text(viewModel.blockTypeLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(blockTypeColor)
                    .tracking(1.2)
                Spacer()
                Text(viewModel.durationDisplay)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(white: 0.4))
            }
            .padding(.bottom, 4)

            Text(viewModel.timeDisplay)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)

            Text(viewModel.blockTitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Color(white: 0.1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .padding(.bottom, 6)

            if !viewModel.focusQuestion.isEmpty {
                Text(viewModel.focusQuestion)
                    .font(.system(size: 15))
                    .foregroundColor(Color(white: 0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }

            Spacer().frame(height: 24)

            lightStartButton
            lightEditLink
        }
        .padding(32)
        .frame(maxWidth: 440)
        .background(
            ZStack {
                VisualEffectBlur(material: .sidebar, blendingMode: .withinWindow)
                Color.white.opacity(0.88)
            }
        )
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.20), radius: 40, x: 0, y: 10)
    }

    // MARK: - Shared: Bright Airy card background

    private func airyCardBg(tint: Color = Color(white: 0.93)) -> some View {
        ZStack {
            VisualEffectBlur(material: .sidebar, blendingMode: .withinWindow)
            tint
        }
    }

    // MARK: - Shared: Edit pill button (light variant)

    private var editPillButton: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { viewModel.isEditing = true } }) {
            Text("Edit")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.45))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.05))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared: Block info line (type + time + duration)

    private var lightBlockInfo: some View {
        HStack(spacing: 6) {
            Circle().fill(blockTypeColor).frame(width: 7, height: 7)
            Text(viewModel.blockTypeLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(blockTypeColor)
                .tracking(0.8)
            Text("·")
                .foregroundColor(Color(white: 0.55))
            Text("\(viewModel.timeDisplay)  ·  \(viewModel.durationDisplay)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(white: 0.50))
            Spacer()
        }
    }

    // MARK: - Variant 2: "Ready to Focus" — warm greeting, accent bar left

    private var variant2_readyToFocus: some View {
        HStack(spacing: 0) {
            // Left accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(blockTypeColor.opacity(0.6))
                .frame(width: 4)
                .padding(.vertical, 20)

            VStack(alignment: .leading, spacing: 0) {
                Text("Ready to focus?")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(white: 0.50))
                    .padding(.bottom, 16)

                Text(viewModel.blockTitle)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(Color(white: 0.12))
                    .lineLimit(2)
                    .padding(.bottom, 6)

                if !viewModel.focusQuestion.isEmpty {
                    Text(viewModel.focusQuestion)
                        .font(.system(size: 15))
                        .foregroundColor(Color(white: 0.48))
                        .lineLimit(3)
                        .padding(.bottom, 4)
                }

                lightBlockInfo
                    .padding(.top, 10)

                Spacer().frame(height: 28)

                HStack(spacing: 12) {
                    Button(action: viewModel.onStart) {
                        Text("Start")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(colors: [goGreen, goGreenBright],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)

                    editPillButton
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 32)
            .padding(.vertical, 32)
        }
        .frame(maxWidth: 460)
        .background(airyCardBg())
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.05), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 40, x: 0, y: 10)
    }

    // MARK: - Variant 3: "Up Next" — casual compact header

    private var variant3_upNext: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Up next")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(white: 0.50))
                    .tracking(0.5)
                Spacer()
                Text(viewModel.durationDisplay)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(blockTypeColor)
            }
            .padding(.bottom, 18)

            Text(viewModel.blockTitle)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(Color(white: 0.10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .padding(.bottom, 6)

            if !viewModel.focusQuestion.isEmpty {
                Text(viewModel.focusQuestion)
                    .font(.system(size: 15))
                    .foregroundColor(Color(white: 0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
                    .padding(.bottom, 4)
            }

            lightBlockInfo
                .padding(.top, 8)

            Spacer().frame(height: 28)

            HStack(spacing: 12) {
                Button(action: viewModel.onStart) {
                    Text("Start")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(colors: [goGreen, goGreenBright],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)

                editPillButton
            }
        }
        .padding(32)
        .frame(maxWidth: 460)
        .background(airyCardBg())
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.05), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 40, x: 0, y: 10)
    }

    // MARK: - Variant 4: "Your Session" — centered greeting, spacious

    private var variant4_yourSession: some View {
        VStack(spacing: 0) {
            Text("Your next session")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(white: 0.50))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 20)

            Text(viewModel.blockTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Color(white: 0.10))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

            if !viewModel.focusQuestion.isEmpty {
                Text(viewModel.focusQuestion)
                    .font(.system(size: 15))
                    .foregroundColor(Color(white: 0.48))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 6) {
                Circle().fill(blockTypeColor).frame(width: 6, height: 6)
                Text("\(viewModel.blockTypeLabel)  ·  \(viewModel.timeDisplay)  ·  \(viewModel.durationDisplay)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.50))
            }
            .padding(.top, 4)

            Spacer().frame(height: 32)

            Button(action: viewModel.onStart) {
                Text("Start")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 56)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [goGreen, goGreenBright],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)

            editPillButton
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 36)
        .frame(maxWidth: 480)
        .background(airyCardBg())
        .cornerRadius(28)
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.black.opacity(0.04), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 45, x: 0, y: 12)
    }

    // MARK: - Variant 5: "Let's Go" — bold greeting, minimal detail

    private var variant5_letsGo: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(blockTypeColor).frame(width: 8, height: 8)
                Text(viewModel.blockTypeLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(blockTypeColor)
                    .tracking(1.0)
                Spacer()
                editPillButton
            }
            .padding(.bottom, 20)

            Text("Ready when you are.")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(white: 0.48))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 14)

            Text(viewModel.blockTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Color(white: 0.08))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .padding(.bottom, 6)

            if !viewModel.focusQuestion.isEmpty {
                Text(viewModel.focusQuestion)
                    .font(.system(size: 15))
                    .foregroundColor(Color(white: 0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }

            Text("\(viewModel.timeDisplay)  ·  \(viewModel.durationDisplay)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(white: 0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

            Spacer().frame(height: 28)

            Button(action: viewModel.onStart) {
                Text("Start")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [goGreen, goGreenBright],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
        .padding(32)
        .frame(maxWidth: 460)
        .background(airyCardBg(tint: Color(white: 0.94)))
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.05), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 40, x: 0, y: 10)
    }

    // MARK: - Variant 6: "Next Block" — quiet, understated, thin separator

    private var variant6_nextBlock: some View {
        VStack(spacing: 0) {
            lightBlockInfo
                .padding(.bottom, 16)

            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
                .padding(.bottom, 20)

            Text(viewModel.blockTitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Color(white: 0.10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .padding(.bottom, 6)

            if !viewModel.focusQuestion.isEmpty {
                Text(viewModel.focusQuestion)
                    .font(.system(size: 15))
                    .foregroundColor(Color(white: 0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }

            Spacer().frame(height: 28)

            HStack(spacing: 12) {
                Button(action: viewModel.onStart) {
                    Text("Start")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(colors: [goGreen, goGreenBright],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)

                editPillButton
            }
        }
        .padding(32)
        .frame(maxWidth: 440)
        .background(airyCardBg(tint: Color(white: 0.95)))
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.05), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 35, x: 0, y: 8)
    }

    // MARK: - Variant 7: "Up Next + Quiet" — Next Block design with "Up next" above title

    private var variant7_upNextQuiet: some View {
        VStack(spacing: 0) {
            lightBlockInfo
                .padding(.bottom, 16)

            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
                .padding(.bottom, 20)

            Text("Up next")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.50))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            Text(viewModel.blockTitle)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Color(white: 0.10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .padding(.bottom, 6)

            if !viewModel.focusQuestion.isEmpty {
                Text(viewModel.focusQuestion)
                    .font(.system(size: 15))
                    .foregroundColor(Color(white: 0.48))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }

            Spacer().frame(height: 28)

            HStack(spacing: 12) {
                Button(action: viewModel.onStart) {
                    Text("Start")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(colors: [goGreen, goGreenBright],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)

                editPillButton
            }
        }
        .padding(32)
        .frame(maxWidth: 440)
        .background(airyCardBg(tint: Color(white: 0.95)))
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.05), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 35, x: 0, y: 8)
    }

    // MARK: - Shared building blocks (dark variants)

    private var badge: some View {
        HStack(spacing: 6) {
            Circle().fill(blockTypeColor).frame(width: 8, height: 8)
            Text(viewModel.blockTypeLabel)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(blockTypeColor)
                .tracking(1.2)
            Spacer()
            Text(viewModel.durationDisplay)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(white: 0.58))
        }
    }

    private var timeRow: some View {
        Text(viewModel.timeDisplay)
            .font(.system(size: 13))
            .foregroundColor(Color(white: 0.40))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: some View {
        Text(viewModel.blockTitle)
            .font(.system(size: 24, weight: .bold))
            .foregroundColor(Color(white: 0.96))
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(2)
    }

    @ViewBuilder
    private var descriptionText: some View {
        if !viewModel.focusQuestion.isEmpty {
            Text(viewModel.focusQuestion)
                .font(.system(size: 15))
                .foregroundColor(Color(white: 0.58))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
    }

    private var greenStartButton: some View {
        Button(action: viewModel.onStart) {
            Text("Start")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(colors: [goGreen, goGreenBright],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(12)
                .shadow(color: goGreen.opacity(0.4), radius: 12, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
    }

    private var editLink: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { viewModel.isEditing = true } }) {
            Text("Edit block")
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.40))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared building blocks (light variants)

    private var lightStartButton: some View {
        Button(action: viewModel.onStart) {
            Text("Start")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(colors: [goGreen, goGreenBright],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
    }

    private var lightEditLink: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { viewModel.isEditing = true } }) {
            Text("Edit block")
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.55))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Free Time Card

    private var freeTimeCard: some View {
        VStack(spacing: 20) {
            HStack(spacing: 6) {
                Circle().fill(freeTimeColor).frame(width: 8, height: 8)
                Text("FREE TIME").font(.system(size: 11, weight: .bold)).foregroundColor(freeTimeColor).tracking(1.2)
                Text("·").foregroundColor(Color(white: 0.40))
                Text(viewModel.timeDisplay).font(.system(size: 12, weight: .medium)).foregroundColor(Color(white: 0.40))
                Spacer()
            }
            VStack(spacing: 6) {
                Text("Enjoy your break.")
                    .font(.system(size: 20, weight: .semibold)).foregroundColor(Color(white: 0.96))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if viewModel.availableMinutes > 0 {
                    Text("\(Int(viewModel.availableMinutes)) min of recharge time available.")
                        .font(.system(size: 14)).foregroundColor(Color(white: 0.58))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button(action: viewModel.onStart) {
                Text("Start Break").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(freeTimeColor.opacity(0.9)).cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
        .padding(32).frame(maxWidth: 420)
        .background(ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
            Color(red: 0.10, green: 0.10, blue: 0.14).opacity(0.50)
        })
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 12)
    }

    // MARK: - Edit Card (shared across all variants)

    private var editCard: some View {
        let fieldBg = Color.white.opacity(0.07)
        let fieldBorder = Color.white.opacity(0.12)
        let textTertiary = Color(white: 0.40)
        let textPrimary = Color(white: 0.96)

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(blockTypeColor).frame(width: 8, height: 8)
                    Text(viewModel.blockTypeLabel).font(.system(size: 11, weight: .bold))
                        .foregroundColor(blockTypeColor).tracking(1.2)
                }
                Spacer()
                Text(viewModel.timeDisplay).font(.system(size: 13)).foregroundColor(textTertiary)
            }
            .padding(.bottom, 20)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.bottom, 18)

            Text("Title").font(.system(size: 12, weight: .medium)).foregroundColor(textTertiary).padding(.bottom, 6)
            TextField("What are you working on?", text: $viewModel.blockTitle)
                .textFieldStyle(.plain).font(.system(size: 16, weight: .semibold)).foregroundColor(textPrimary)
                .padding(12).background(fieldBg).cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(fieldBorder, lineWidth: 1))
                .padding(.bottom, 14)

            Text("Description").font(.system(size: 12, weight: .medium)).foregroundColor(textTertiary).padding(.bottom, 6)
            TextField("What will you accomplish?", text: $viewModel.focusQuestion)
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundColor(textPrimary)
                .padding(12).background(fieldBg).cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(fieldBorder, lineWidth: 1))
                .padding(.bottom, 18)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.bottom, 18)

            Text("Block type").font(.system(size: 12, weight: .medium)).foregroundColor(textTertiary).padding(.bottom, 8)
            HStack(spacing: 8) {
                typePill(.deepWork, label: "Deep Work", color: deepWorkColor)
                typePill(.focusHours, label: "Focus Hours", color: accentStart)
            }
            .padding(.bottom, 24)

            HStack {
                Spacer()
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { viewModel.isEditing = false } }) {
                    Text("Done").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 24).padding(.vertical, 11)
                        .background(LinearGradient(colors: [goGreen, goGreenBright], startPoint: .leading, endPoint: .trailing))
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(32).frame(maxWidth: 480)
        .background(ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
            Color(red: 0.10, green: 0.10, blue: 0.14).opacity(0.55)
        })
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 12)
    }

    private func typePill(_ type: ScheduleManager.BlockType, label: String, color: Color) -> some View {
        let selected = viewModel.blockType == type
        return Button(action: { viewModel.blockType = type }) {
            HStack(spacing: 5) {
                Circle().fill(selected ? color : Color.clear)
                    .overlay(Circle().stroke(selected ? Color.clear : Color(white: 0.40), lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                Text(label).font(.system(size: 12, weight: .medium))
                    .foregroundColor(selected ? Color(white: 0.96) : Color(white: 0.58))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? color.opacity(0.15) : Color.white.opacity(0.04))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? color.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

import Cocoa
import SwiftUI

/// Manages the block end ritual overlay shown when a focus block ends.
///
/// Full-screen overlay with centered card showing session stats and optional reflection.
/// Uses `KeyableWindow` (from FocusOverlayWindow.swift) so text fields accept keyboard input.
class BlockEndRitualController {

    private var ritualWindow: NSWindow?
    private var autoDismissTimer: Timer?
    private var viewModel: BlockEndRitualViewModel?

    var isShowing: Bool { ritualWindow != nil }

    func show(
        block: ScheduleManager.FocusBlock,
        stats: EarnedBrowseManager.BlockFocusStats,
        nextBlock: ScheduleManager.FocusBlock?,
        onDone: @escaping (Int?, String) -> Void
    ) {
        dismiss()

        let isFreeTime = block.blockType == .freeTime

        // Skip trivial free time blocks (0 ticks)
        if isFreeTime && stats.totalTicks == 0 { return }

        let vm = BlockEndRitualViewModel(
            blockTitle: block.title,
            blockType: block.blockType,
            startHour: block.startHour,
            startMinute: block.startMinute,
            endHour: block.endHour,
            endMinute: block.endMinute,
            focusScore: stats.focusScore,
            earnedMinutes: stats.earnedMinutes,
            totalTicks: stats.totalTicks,
            nextBlock: nextBlock,
            onDone: { [weak self] in
                let rating = self?.viewModel?.selfRating
                let reflection = self?.viewModel?.reflection ?? ""
                self?.dismiss()
                onDone(rating, reflection)
            }
        )

        self.viewModel = vm

        let view = BlockEndRitualView(viewModel: vm, isFreeTime: isFreeTime)
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

        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: false) { [weak self] _ in
            guard self?.isShowing == true else { return }
            let rating = self?.viewModel?.selfRating
            let reflection = self?.viewModel?.reflection ?? ""
            self?.dismiss()
            onDone(rating, reflection)
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

class BlockEndRitualViewModel: ObservableObject {
    let blockTitle: String
    let blockType: ScheduleManager.BlockType
    let startHour: Int
    let startMinute: Int
    let endHour: Int
    let endMinute: Int
    let focusScore: Int
    let earnedMinutes: Double
    let totalTicks: Int
    let nextBlockTitle: String?
    let nextBlockType: ScheduleManager.BlockType?
    let nextBlockStartsIn: String?
    let onDone: () -> Void

    @Published var selfRating: Int? = nil
    @Published var reflection: String = ""

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

    var earnedDisplay: String {
        if earnedMinutes < 1 {
            return "less than a minute"
        }
        return "\(Int(round(earnedMinutes))) min"
    }

    init(blockTitle: String, blockType: ScheduleManager.BlockType,
         startHour: Int, startMinute: Int, endHour: Int, endMinute: Int,
         focusScore: Int, earnedMinutes: Double, totalTicks: Int,
         nextBlock: ScheduleManager.FocusBlock?,
         onDone: @escaping () -> Void) {
        self.blockTitle = blockTitle
        self.blockType = blockType
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.focusScore = focusScore
        self.earnedMinutes = earnedMinutes
        self.totalTicks = totalTicks
        self.onDone = onDone

        // Next block info
        if let next = nextBlock {
            self.nextBlockTitle = next.title
            self.nextBlockType = next.blockType
            let now = Calendar.current.component(.hour, from: Date()) * 60
                    + Calendar.current.component(.minute, from: Date())
            let diff = next.startMinutes - now
            if diff <= 0 {
                self.nextBlockStartsIn = "now"
            } else if diff < 60 {
                self.nextBlockStartsIn = "in \(diff) min"
            } else {
                let h = diff / 60, m = diff % 60
                self.nextBlockStartsIn = m > 0 ? "in \(h)h \(m)m" : "in \(h)h"
            }
        } else {
            self.nextBlockTitle = nil
            self.nextBlockType = nil
            self.nextBlockStartsIn = nil
        }
    }

    private func formatTime(hour: Int, minute: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return minute == 0 ? "\(h12) \(ampm)" : "\(h12):\(String(format: "%02d", minute)) \(ampm)"
    }
}

// MARK: - SwiftUI View

struct BlockEndRitualView: View {
    @ObservedObject var viewModel: BlockEndRitualViewModel
    let isFreeTime: Bool

    private let goGreen = Color(red: 0.25, green: 0.78, blue: 0.45)
    private let goGreenBright = Color(red: 0.30, green: 0.88, blue: 0.52)
    private let deepWorkColor = Color(red: 0.95, green: 0.35, blue: 0.35)
    private let focusHoursColor = Color(red: 0.45, green: 0.46, blue: 1.0)
    private let freeTimeColor = Color(red: 0.35, green: 0.85, blue: 0.55)

    private var blockTypeColor: Color {
        switch viewModel.blockType {
        case .deepWork: return deepWorkColor
        case .focusHours: return focusHoursColor
        case .freeTime: return freeTimeColor
        }
    }

    private var focusBarColor: Color {
        if viewModel.focusScore >= 80 { return goGreen }
        if viewModel.focusScore >= 50 { return Color(red: 0.95, green: 0.75, blue: 0.25) }
        return Color(red: 0.95, green: 0.35, blue: 0.35)
    }

    private let ratingEmojis = ["😤", "😕", "😐", "🙂", "🔥"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                if isFreeTime {
                    freeTimeEndCard
                } else {
                    workBlockEndCard
                }

                Spacer()
            }
        }
    }

    // MARK: - Work Block End Card

    private var workBlockEndCard: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Session complete")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(white: 0.50))
                    .tracking(0.5)
                Spacer()
                Text(viewModel.durationDisplay)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(blockTypeColor)
            }
            .padding(.bottom, 18)

            // Block title
            Text(viewModel.blockTitle)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(Color(white: 0.10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .padding(.bottom, 6)

            // Block type + time
            HStack(spacing: 6) {
                Circle().fill(blockTypeColor).frame(width: 7, height: 7)
                Text(viewModel.blockTypeLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(blockTypeColor)
                    .tracking(0.8)
                Text("·")
                    .foregroundColor(Color(white: 0.55))
                Text(viewModel.timeDisplay)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.50))
                Spacer()
            }
            .padding(.bottom, 20)

            // Divider
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
                .padding(.bottom, 20)

            // Earned minutes
            Text("You earned \(viewModel.earnedDisplay) of recharge time.")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(white: 0.30))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)

            // Focus bar
            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.06))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(focusBarColor)
                            .frame(width: geo.size.width * CGFloat(viewModel.focusScore) / 100.0, height: 8)
                    }
                }
                .frame(height: 8)

                HStack {
                    Spacer()
                    Text("\(viewModel.focusScore)% focused")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(focusBarColor)
                }
            }
            .padding(.bottom, 20)

            // Divider
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
                .padding(.bottom, 20)

            // Self-assessment
            Text("How focused did you feel?")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(white: 0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)

            HStack(spacing: 12) {
                ForEach(0..<ratingEmojis.count, id: \.self) { index in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.selfRating = index
                        }
                    }) {
                        Text(ratingEmojis[index])
                            .font(.system(size: 24))
                            .frame(width: 44, height: 44)
                            .background(
                                viewModel.selfRating == index
                                    ? focusBarColor.opacity(0.15)
                                    : Color.black.opacity(0.03)
                            )
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        viewModel.selfRating == index
                                            ? focusBarColor.opacity(0.4)
                                            : Color.black.opacity(0.06),
                                        lineWidth: 1.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.bottom, 16)

            // Reflection text field
            Text("What went well?")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(white: 0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

            TextField("", text: $viewModel.reflection)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(Color(white: 0.15))
                .padding(12)
                .background(Color.black.opacity(0.03))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .padding(.bottom, 20)

            // Next block preview (if any)
            if let nextTitle = viewModel.nextBlockTitle, let startsIn = viewModel.nextBlockStartsIn {
                Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .frame(height: 1)
                    .padding(.bottom, 16)

                nextBlockPreview(title: nextTitle, startsIn: startsIn, blockType: viewModel.nextBlockType)
                    .padding(.bottom, 20)
            }

            // Done button
            Button(action: viewModel.onDone) {
                Text("Done")
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
        .background(
            ZStack {
                VisualEffectBlur(material: .sidebar, blendingMode: .withinWindow)
                Color(white: 0.93)
            }
        )
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.05), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 40, x: 0, y: 10)
    }

    // MARK: - Free Time End Card

    private var freeTimeEndCard: some View {
        VStack(spacing: 0) {
            Text("Break over")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(white: 0.50))
                .tracking(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 18)

            // Block type + time
            HStack(spacing: 6) {
                Circle().fill(freeTimeColor).frame(width: 7, height: 7)
                Text("FREE TIME")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(freeTimeColor)
                    .tracking(0.8)
                Text("·")
                    .foregroundColor(Color(white: 0.55))
                Text(viewModel.timeDisplay)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(white: 0.50))
                Spacer()
            }
            .padding(.bottom, 20)

            // Next block preview (if any)
            if let nextTitle = viewModel.nextBlockTitle, let startsIn = viewModel.nextBlockStartsIn {
                nextBlockPreview(title: nextTitle, startsIn: startsIn, blockType: viewModel.nextBlockType)
                    .padding(.bottom, 20)
            }

            // Done button
            Button(action: viewModel.onDone) {
                Text("Done")
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
        .background(
            ZStack {
                VisualEffectBlur(material: .sidebar, blendingMode: .withinWindow)
                Color(white: 0.93)
            }
        )
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.black.opacity(0.05), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 40, x: 0, y: 10)
    }

    // MARK: - Next Block Preview

    private func nextBlockPreview(title: String, startsIn: String, blockType: ScheduleManager.BlockType?) -> some View {
        let color: Color = {
            switch blockType {
            case .deepWork: return deepWorkColor
            case .focusHours: return focusHoursColor
            case .freeTime: return freeTimeColor
            case .none: return Color(white: 0.50)
            }
        }()

        let typeLabel: String = {
            switch blockType {
            case .deepWork: return "Deep Work"
            case .focusHours: return "Focus Hours"
            case .freeTime: return "Free Time"
            case .none: return ""
            }
        }()

        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("Next: \(typeLabel) — \(title)")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(white: 0.40))
                .lineLimit(1)
            Spacer()
            Text(startsIn)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(white: 0.55))
        }
    }
}

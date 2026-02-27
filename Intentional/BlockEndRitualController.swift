import Cocoa
import SwiftUI

/// Manages the block end celebration overlay shown when a focus block ends.
///
/// Work blocks: 3-card carousel (Session Complete → Focus Score → App Breakdown).
/// Free time blocks: Single "Break over" card.
/// Full-screen overlay with centered card. Uses `KeyableWindow` (from FocusOverlayWindow.swift).
class BlockEndRitualController {

    private var ritualWindow: NSWindow?
    private var autoDismissTimer: Timer?
    private var viewModel: BlockEndRitualViewModel?

    var isShowing: Bool { ritualWindow != nil }

    func show(
        block: ScheduleManager.FocusBlock,
        stats: EarnedBrowseManager.BlockFocusStats,
        nextBlock: ScheduleManager.FocusBlock?,
        onDone: @escaping () -> Void
    ) {
        dismiss()

        let isFreeTime = block.blockType == .freeTime

        // Skip trivial free time blocks (0 ticks)
        if isFreeTime && stats.totalTicks == 0 { return }

        // Load app breakdown for work blocks
        var appBreakdown: [(appName: String, seconds: Int)] = []
        if !isFreeTime {
            appBreakdown = Self.loadAppBreakdown(
                startHour: block.startHour, startMinute: block.startMinute,
                endHour: block.endHour, endMinute: block.endMinute
            )
        }

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
            appBreakdown: appBreakdown,
            isFreeTime: isFreeTime,
            onDone: { [weak self] in
                self?.dismiss()
                onDone()
            }
        )

        self.viewModel = vm

        let view = BlockEndRitualView(viewModel: vm)
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

        // Auto-dismiss: 30s after reaching last card, or 120s total
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: false) { [weak self] _ in
            guard self?.isShowing == true else { return }
            self?.dismiss()
            onDone()
        }
    }

    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        viewModel?.stopAutoAdvance()
        ritualWindow?.close()
        ritualWindow = nil
    }

    deinit { dismiss() }

    // MARK: - App Breakdown from relevance_log.jsonl

    /// Load per-app time breakdown for a block's time window.
    /// Groups entries by appName, counts ticks × 10 seconds, returns top 6 sorted by time.
    static func loadAppBreakdown(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) -> [(appName: String, seconds: Int)] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logURL = appSupport.appendingPathComponent("Intentional").appendingPathComponent("relevance_log.jsonl")

        guard FileManager.default.fileExists(atPath: logURL.path),
              let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return []
        }

        // Compute block start/end as Date objects (today)
        let cal = Calendar.current
        let now = Date()
        var startComps = cal.dateComponents([.year, .month, .day], from: now)
        startComps.hour = startHour
        startComps.minute = startMinute
        startComps.second = 0
        var endComps = cal.dateComponents([.year, .month, .day], from: now)
        endComps.hour = endHour
        endComps.minute = endMinute
        endComps.second = 0

        guard let startDate = cal.date(from: startComps),
              let endDate = cal.date(from: endComps) else { return [] }

        let isoFormatter = ISO8601DateFormatter()
        var appTicks: [String: Int] = [:]

        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = isoFormatter.date(from: tsStr),
                  ts >= startDate, ts <= endDate else { continue }

            // Skip neutral entries (loginwindow, etc.) and event entries (nudge/block markers)
            if let neutral = obj["neutral"] as? Bool, neutral { continue }
            if let isEvent = obj["isEvent"] as? Bool, isEvent { continue }

            let appName = obj["appName"] as? String ?? obj["title"] as? String ?? "Unknown"
            appTicks[appName, default: 0] += 1
        }

        // Convert ticks to seconds (10s per tick) and sort descending
        return appTicks
            .map { (appName: $0.key, seconds: $0.value * 10) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(6)
            .map { $0 }
    }
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
    let appBreakdown: [(appName: String, seconds: Int)]
    let isFreeTime: Bool
    let onDone: () -> Void

    @Published var currentCard: Int = 0
    var cardCount: Int { isFreeTime ? 1 : 3 }

    private var autoAdvanceTimer: Timer?

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

    var focusMessage: String {
        if focusScore >= 80 { return ["Great session!", "Crushed it!", "Nailed it!"].randomElement()! }
        if focusScore >= 50 { return "Good effort — next one's yours." }
        return "We'll get there. Keep showing up."
    }

    init(blockTitle: String, blockType: ScheduleManager.BlockType,
         startHour: Int, startMinute: Int, endHour: Int, endMinute: Int,
         focusScore: Int, earnedMinutes: Double, totalTicks: Int,
         nextBlock: ScheduleManager.FocusBlock?,
         appBreakdown: [(appName: String, seconds: Int)],
         isFreeTime: Bool,
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
        self.appBreakdown = appBreakdown
        self.isFreeTime = isFreeTime
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

        startAutoAdvance()
    }

    func nextCard() {
        if currentCard < cardCount - 1 {
            currentCard += 1
            restartAutoAdvance()
        } else {
            onDone()
        }
    }

    func startAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.nextCard()
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

    private func formatTime(hour: Int, minute: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "AM" : "PM"
        return minute == 0 ? "\(h12) \(ampm)" : "\(h12):\(String(format: "%02d", minute)) \(ampm)"
    }

    /// Format seconds as human-readable duration (e.g. "1h 22m", "28m", "45s").
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

struct BlockEndRitualView: View {
    @ObservedObject var viewModel: BlockEndRitualViewModel

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

    var body: some View {
        ZStack {
            Color.black.opacity(0.08)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                if viewModel.isFreeTime {
                    freeTimeEndCard
                } else {
                    workBlockCarousel
                }

                Spacer()
            }
        }
    }

    // MARK: - Work Block Carousel

    private var workBlockCarousel: some View {
        ZStack {
            // Card 1: Session Complete
            if viewModel.currentCard == 0 {
                sessionCompleteCard
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
            }

            // Card 2: Focus Score
            if viewModel.currentCard == 1 {
                focusScoreCard
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
            }

            // Card 3: App Breakdown
            if viewModel.currentCard == 2 {
                appBreakdownCard
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: viewModel.currentCard)
    }

    // MARK: - Card 1: Session Complete

    private var sessionCompleteCard: some View {
        cardContainer {
            VStack(spacing: 0) {
                // Header
                Text("Session complete")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(white: 0.50))
                    .tracking(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)

                // Block title + duration
                HStack(alignment: .top) {
                    Text(viewModel.blockTitle)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(Color(white: 0.10))
                        .lineLimit(2)
                    Spacer()
                    Text(viewModel.durationDisplay)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(white: 0.35))
                }
                .padding(.bottom, 8)

                // Block type + time
                HStack(spacing: 6) {
                    Circle().fill(blockTypeColor).frame(width: 7, height: 7)
                    Text(viewModel.blockTypeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(blockTypeColor)
                        .tracking(0.8)
                    Text("\u{00B7}")
                        .foregroundColor(Color(white: 0.55))
                    Text(viewModel.timeDisplay)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(white: 0.50))
                    Spacer()
                }
                .padding(.bottom, 28)

                // Divider
                Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .frame(height: 1)
                    .padding(.bottom, 24)

                // Earned minutes
                Text("You earned \(viewModel.earnedDisplay) of recharge time.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(white: 0.30))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 28)

                // Next button
                nextButton(label: "Next")
            }
        }
    }

    // MARK: - Card 2: Focus Score

    private var focusScoreCard: some View {
        cardContainer {
            VStack(spacing: 0) {
                Spacer().frame(height: 8)

                // Big focus score
                Text("\(viewModel.focusScore)% focused")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(focusBarColor)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 20)

                // Focus bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.black.opacity(0.06))
                            .frame(height: 10)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(focusBarColor)
                            .frame(width: geo.size.width * CGFloat(viewModel.focusScore) / 100.0, height: 10)
                    }
                }
                .frame(height: 10)
                .padding(.bottom, 24)

                // Encouragement message
                Text(viewModel.focusMessage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(white: 0.35))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 28)

                // Next button
                nextButton(label: "Next")
            }
        }
    }

    // MARK: - Card 3: App Breakdown

    private var appBreakdownCard: some View {
        cardContainer {
            VStack(spacing: 0) {
                // Header
                Text("Where you spent your time")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(white: 0.50))
                    .tracking(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)

                // App list
                if viewModel.appBreakdown.isEmpty {
                    Text("No activity recorded for this block.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(white: 0.50))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 20)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(viewModel.appBreakdown.enumerated()), id: \.offset) { _, entry in
                            HStack {
                                Text(entry.appName)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(Color(white: 0.15))
                                    .lineLimit(1)
                                Spacer()
                                Text(viewModel.formatDuration(entry.seconds))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(white: 0.40))
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }

                // Divider
                Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .frame(height: 1)
                    .padding(.bottom, 16)

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
        }
    }

    // MARK: - Free Time End Card

    private var freeTimeEndCard: some View {
        cardContainer {
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
                    Text("\u{00B7}")
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
        }
    }

    // MARK: - Shared Components

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
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

    private func nextButton(label: String) -> some View {
        Button(action: {
            withAnimation {
                viewModel.nextCard()
            }
        }) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 16, weight: .bold))
                Text("\u{2192}")
                    .font(.system(size: 16, weight: .bold))
            }
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

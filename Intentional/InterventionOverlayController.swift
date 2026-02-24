import Cocoa
import SwiftUI

// MARK: - Intervention Type

enum InterventionType: String, CaseIterable {
    case scrambledWords = "scrambled_words"
    case reflectAndCommit = "reflect_and_commit"
    // Future: recallChallenge, mathPuzzle, breathingCircle, memoryGrid
}

// MARK: - Controller

/// Manages a full-screen intervention overlay that forces cognitive engagement.
///
/// Shown after 5 minutes of cumulative distraction during Focus Hours.
/// Picks a random game (Scrambled Words or Reflect & Commit) and requires
/// the user to complete it AND wait a mandatory duration before dismissing.
/// Duration escalates with repeated interventions (60s -> 90s -> 120s).
class InterventionOverlayController {

    weak var appDelegate: AppDelegate?
    private var overlayWindow: NSWindow?
    var onComplete: (() -> Void)?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    func showIntervention(intention: String, displayName: String,
                          distractionMinutes: Int, duration: Int = 60,
                          focusScore: Int = 0, type: InterventionType? = nil) {
        dismiss()

        let gameType = type ?? InterventionType.allCases.randomElement()!

        let viewModel = InterventionOverlayViewModel(
            intention: intention,
            displayName: displayName,
            distractionMinutes: distractionMinutes,
            duration: duration,
            focusScore: focusScore,
            gameType: gameType
        )

        viewModel.onComplete = { [weak self] in
            self?.onComplete?()
            self?.dismiss()
        }

        let view = InterventionOverlayView(viewModel: viewModel)
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
        overlayWindow = window

        viewModel.startTimer()

        appDelegate?.postLog("🧩 Intervention shown: \(gameType.rawValue) (\(distractionMinutes) min off-task, \(duration)s wait, focus \(focusScore)%)")
    }

    func dismiss() {
        overlayWindow?.close()
        overlayWindow = nil
    }

    var isShowing: Bool {
        overlayWindow != nil
    }
}

// MARK: - View Model

class InterventionOverlayViewModel: ObservableObject {
    let intention: String
    let displayName: String
    let distractionMinutes: Int
    let duration: Int
    let focusScore: Int
    let gameType: InterventionType

    @Published var timeRemaining: Int
    @Published var elapsedSeconds: Int = 0
    private var timer: Timer?
    var onComplete: (() -> Void)?

    /// Safety skip threshold (seconds)
    static let safetySkipThreshold = 180

    // Scrambled Words state
    @Published var shuffledWords: [(id: Int, word: String)] = []
    @Published var placedWords: [String] = []
    var targetWords: [String] = []
    @Published var wrongFlashIndex: Int? = nil
    @Published var gameCompleted: Bool = false

    // Reflect & Commit state
    @Published var planText: String = ""

    /// Whether the reflection text meets validation requirements (30+ chars, 2+ spaces)
    var isTextValid: Bool {
        let trimmed = planText.trimmingCharacters(in: .whitespacesAndNewlines)
        let spaceCount = trimmed.filter { $0 == " " }.count
        return trimmed.count >= 30 && spaceCount >= 2
    }

    /// Characters still needed for validation
    var charsNeeded: Int {
        max(0, 30 - planText.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    /// Whether dismiss is possible (both timer expired AND task completed)
    var canDismiss: Bool {
        guard timeRemaining <= 0 else { return false }
        switch gameType {
        case .scrambledWords:
            return gameCompleted
        case .reflectAndCommit:
            return isTextValid
        }
    }

    /// Whether the safety skip should be visible
    var showSafetySkip: Bool {
        elapsedSeconds >= Self.safetySkipThreshold
    }

    init(intention: String, displayName: String, distractionMinutes: Int,
         duration: Int, focusScore: Int, gameType: InterventionType) {
        self.intention = intention
        self.displayName = displayName
        self.distractionMinutes = distractionMinutes
        self.duration = duration
        self.focusScore = focusScore
        self.gameType = gameType
        self.timeRemaining = duration

        if gameType == .scrambledWords {
            setupScrambledWords()
        }
    }

    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.elapsedSeconds += 1
            if self.timeRemaining > 0 {
                self.timeRemaining -= 1
            }
            // No auto-dismiss — timer just stops counting down.
            // For scrambled words: auto-dismiss when game completed AND timer expired
            if self.timeRemaining <= 0 && self.gameCompleted && self.gameType == .scrambledWords {
                self.timer?.invalidate()
                self.timer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.onComplete?()
                }
            }
        }
    }

    // MARK: - Scrambled Words

    private func setupScrambledWords() {
        let words = intention.split(separator: " ").map(String.init)
        targetWords = words
        // Shuffle and assign stable IDs
        var shuffled = words.enumerated().map { (id: $0.offset, word: $0.element) }
        shuffled.shuffle()
        shuffledWords = shuffled
        placedWords = []
    }

    func placeWord(at index: Int) {
        guard index < shuffledWords.count else { return }
        let tappedWord = shuffledWords[index].word
        let nextExpectedIndex = placedWords.count

        guard nextExpectedIndex < targetWords.count else { return }

        if tappedWord == targetWords[nextExpectedIndex] {
            // Correct
            placedWords.append(tappedWord)
            shuffledWords.remove(at: index)

            if placedWords.count == targetWords.count {
                gameCompleted = true
                // If timer already expired, auto-dismiss is handled by the timer callback
                // If timer hasn't expired yet, the timer callback will catch it when it hits 0
            }
        } else {
            // Wrong — flash red
            wrongFlashIndex = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.wrongFlashIndex = nil
            }
        }
    }

    func dismissReflect() {
        guard canDismiss else { return }
        timer?.invalidate()
        timer = nil
        onComplete?()
    }

    func skip() {
        timer?.invalidate()
        timer = nil
        onComplete?()
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - Focus Context View (shared between games)

struct FocusContextView: View {
    let focusScore: Int
    let distractionMinutes: Int
    let displayName: String

    private let textSecondary = Color(white: 0.55)
    private let textTertiary = Color(white: 0.35)
    private let warningAmber = Color(red: 0.95, green: 0.65, blue: 0.15)
    private let errorRed = Color(red: 0.95, green: 0.25, blue: 0.25)

    private var scoreColor: Color {
        if focusScore >= 80 { return Color(red: 0.2, green: 0.78, blue: 0.35) }
        if focusScore >= 50 { return warningAmber }
        return errorRed
    }

    var body: some View {
        HStack(spacing: 16) {
            // Focus score ring
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 3)
                    .frame(width: 44, height: 44)
                Circle()
                    .trim(from: 0, to: CGFloat(focusScore) / 100.0)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(-90))
                Text("\(focusScore)%")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundColor(scoreColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("\(distractionMinutes) min off-task")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(warningAmber)

                Text(displayName)
                    .font(.system(size: 12))
                    .foregroundColor(textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Container View

struct InterventionOverlayView: View {
    @ObservedObject var viewModel: InterventionOverlayViewModel

    private let cardBg = Color(red: 0.08, green: 0.08, blue: 0.10)
    private let textPrimary = Color(white: 0.95)
    private let textTertiary = Color(white: 0.35)

    var body: some View {
        ZStack {
            // Full-screen blur + dark tint
            ZStack {
                VisualEffectBlur(material: .fullScreenUI, blendingMode: .behindWindow)
                Color.black.opacity(0.85)
            }
            .ignoresSafeArea()

            // Center card with game
            VStack(spacing: 0) {
                switch viewModel.gameType {
                case .scrambledWords:
                    ScrambledWordsGame(viewModel: viewModel)
                case .reflectAndCommit:
                    ReflectAndCommitGame(viewModel: viewModel)
                }
            }
            .padding(40)
            .frame(maxWidth: 520)
            .background(
                ZStack {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                    cardBg.opacity(0.7)
                }
            )
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 40, x: 0, y: 12)

            // Safety skip (bottom right corner, after 3 min)
            if viewModel.showSafetySkip {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: { viewModel.skip() }) {
                            Text("Skip")
                                .font(.system(size: 12))
                                .foregroundColor(textTertiary)
                        }
                        .buttonStyle(.plain)
                        .padding(24)
                    }
                }
            }
        }
    }
}

// MARK: - Scrambled Words Game

struct ScrambledWordsGame: View {
    @ObservedObject var viewModel: InterventionOverlayViewModel

    private let textPrimary = Color(white: 0.95)
    private let textSecondary = Color(white: 0.55)
    private let textTertiary = Color(white: 0.35)
    private let accentStart = Color(red: 0.39, green: 0.4, blue: 0.95)
    private let accentEnd = Color(red: 0.55, green: 0.36, blue: 0.96)
    private let successGreen = Color(red: 0.2, green: 0.78, blue: 0.35)
    private let errorRed = Color(red: 0.95, green: 0.25, blue: 0.25)

    var body: some View {
        VStack(spacing: 24) {
            // Header with timer
            HStack {
                Text("What was your intention?")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(textPrimary)
                Spacer()
                timerBadge
            }

            // Focus context
            FocusContextView(
                focusScore: viewModel.focusScore,
                distractionMinutes: viewModel.distractionMinutes,
                displayName: viewModel.displayName
            )

            if viewModel.gameCompleted {
                // Completion state
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(successGreen)

                    Text(viewModel.intention)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(textPrimary)
                        .multilineTextAlignment(.center)

                    if viewModel.timeRemaining > 0 {
                        Text("Waiting \(viewModel.timeRemaining)s...")
                            .font(.system(size: 14))
                            .foregroundColor(textSecondary)
                    } else {
                        Text("Now get back to it.")
                            .font(.system(size: 14))
                            .foregroundColor(textSecondary)
                    }
                }
                .padding(.vertical, 20)
            } else {
                // Instruction
                Text("Reconstruct it from memory:")
                    .font(.system(size: 13))
                    .foregroundColor(textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Slots — placed words + remaining blanks
                slotsView
                    .padding(.vertical, 4)

                // Shuffled word tiles
                wordTilesView
            }
        }
    }

    // MARK: - Subviews

    private var timerBadge: some View {
        Text("\(viewModel.timeRemaining)s")
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundColor(viewModel.timeRemaining <= 10 ? errorRed : textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)
    }

    private var slotsView: some View {
        HStack(spacing: 6) {
            ForEach(0..<viewModel.targetWords.count, id: \.self) { i in
                if i < viewModel.placedWords.count {
                    // Placed word — green highlight
                    Text(viewModel.placedWords[i])
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(successGreen.opacity(0.8))
                        .cornerRadius(8)
                } else {
                    // Empty slot
                    Text(String(repeating: "_", count: max(3, viewModel.targetWords[i].count)))
                        .font(.system(size: 15, weight: .medium).monospaced())
                        .foregroundColor(textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var wordTilesView: some View {
        // Wrap tiles in a flow layout
        FlowLayout(spacing: 8) {
            ForEach(0..<viewModel.shuffledWords.count, id: \.self) { i in
                let isWrong = viewModel.wrongFlashIndex == i
                Button(action: { viewModel.placeWord(at: i) }) {
                    Text(viewModel.shuffledWords[i].word)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: isWrong ? [errorRed, errorRed.opacity(0.8)] : [accentStart, accentEnd],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .cornerRadius(10)
                        .scaleEffect(isWrong ? 0.95 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: isWrong)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Reflect & Commit Game

struct ReflectAndCommitGame: View {
    @ObservedObject var viewModel: InterventionOverlayViewModel

    private let textPrimary = Color(white: 0.95)
    private let textSecondary = Color(white: 0.55)
    private let textTertiary = Color(white: 0.35)
    private let accentStart = Color(red: 0.39, green: 0.4, blue: 0.95)
    private let accentEnd = Color(red: 0.55, green: 0.36, blue: 0.96)
    private let errorRed = Color(red: 0.95, green: 0.25, blue: 0.25)
    private let cardBg = Color(red: 0.08, green: 0.08, blue: 0.10)

    var body: some View {
        VStack(spacing: 24) {
            // Header with timer
            HStack {
                Text("Remember your intention")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(textPrimary)
                Spacer()
                timerBadge
            }

            // Focus context
            FocusContextView(
                focusScore: viewModel.focusScore,
                distractionMinutes: viewModel.distractionMinutes,
                displayName: viewModel.displayName
            )

            // Intention card
            VStack(alignment: .leading, spacing: 8) {
                Text("You set out to:")
                    .font(.system(size: 13))
                    .foregroundColor(textSecondary)

                Text("\"\(viewModel.intention)\"")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(textPrimary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(colors: [accentStart.opacity(0.15), accentEnd.opacity(0.1)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(accentStart.opacity(0.3), lineWidth: 1)
                    )
            }

            // Commitment text field
            VStack(alignment: .leading, spacing: 8) {
                Text("What's your next step?")
                    .font(.system(size: 13))
                    .foregroundColor(textSecondary)

                TextField("Type your plan here...", text: $viewModel.planText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(textPrimary)
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }

            // Button with dynamic state
            Button(action: { viewModel.dismissReflect() }) {
                Text(buttonLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(viewModel.canDismiss ? .white : textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Group {
                            if viewModel.canDismiss {
                                LinearGradient(colors: [accentStart, accentEnd],
                                               startPoint: .leading, endPoint: .trailing)
                            } else {
                                Color.white.opacity(0.06)
                            }
                        }
                    )
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canDismiss)
        }
    }

    private var buttonLabel: String {
        if viewModel.timeRemaining > 0 {
            return "Wait \(viewModel.timeRemaining)s..."
        } else if !viewModel.isTextValid {
            if viewModel.charsNeeded > 0 {
                return "Type your plan (\(viewModel.charsNeeded) more chars)"
            } else {
                return "Use real words (need spaces)"
            }
        } else {
            return "Get back to work"
        }
    }

    private var timerBadge: some View {
        Text("\(viewModel.timeRemaining)s")
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundColor(viewModel.timeRemaining <= 10 ? errorRed : textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)
    }
}

// MARK: - Flow Layout (for word tiles)

/// Simple horizontal flow layout that wraps to the next line when width is exceeded.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            guard index < subviews.count else { break }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return (CGSize(width: totalWidth, height: currentY + lineHeight), positions)
    }
}

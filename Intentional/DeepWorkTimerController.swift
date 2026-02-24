import Cocoa
import SwiftUI

/// Manages a floating pill-shaped timer widget shown during Deep Work blocks.
///
/// Displays the block intention + countdown timer in the top-right corner.
/// A colored dot indicates focus state: indigo = focused, red = distracted.
///
/// - `show(intention:endsAt:)` — show the widget and start counting down
/// - `update(isDistracted:)` — change the dot color
/// - `dismiss()` — hide the widget
class DeepWorkTimerController {

    private var timerWindow: NSWindow?
    private var countdownTimer: Timer?
    private var viewModel: DeepWorkTimerViewModel?

    var isShowing: Bool { timerWindow != nil }

    // MARK: - Public API

    /// Show the floating timer widget.
    ///
    /// - Parameters:
    ///   - intention: The Deep Work block's intention text
    ///   - endsAt: When the block ends (for countdown)
    func show(intention: String, endsAt: Date) {
        dismiss()

        let vm = DeepWorkTimerViewModel(intention: intention, endsAt: endsAt)
        self.viewModel = vm

        let view = DeepWorkTimerView(viewModel: vm)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 36)
        let fittingSize = hostingView.fittingSize
        let windowWidth = min(max(fittingSize.width, 200), 400)
        let windowHeight = max(fittingSize.height, 36)
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
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

        // Start 1s countdown
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let vm = self.viewModel else { return }
            let remaining = vm.endsAt.timeIntervalSinceNow
            if remaining <= 0 {
                vm.timeDisplay = "0:00"
                self.dismiss()
            } else {
                let mins = Int(remaining) / 60
                let secs = Int(remaining) % 60
                vm.timeDisplay = String(format: "%d:%02d", mins, secs)
            }
        }
    }

    /// Update the distraction state (changes dot color).
    func update(isDistracted: Bool) {
        viewModel?.isDistracted = isDistracted
    }

    /// Hide the widget and stop the countdown.
    func dismiss() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        timerWindow?.close()
        timerWindow = nil
        viewModel = nil
    }

    deinit {
        dismiss()
    }
}

// MARK: - View Model

class DeepWorkTimerViewModel: ObservableObject {
    let intention: String
    let endsAt: Date

    @Published var timeDisplay: String
    @Published var isDistracted: Bool = false

    init(intention: String, endsAt: Date) {
        self.intention = intention
        self.endsAt = endsAt

        let remaining = max(0, endsAt.timeIntervalSinceNow)
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        self.timeDisplay = String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - SwiftUI View

struct DeepWorkTimerView: View {
    @ObservedObject var viewModel: DeepWorkTimerViewModel

    private let bgColor = Color(red: 0.09, green: 0.09, blue: 0.11)
    private let textPrimary = Color(red: 0.95, green: 0.95, blue: 0.95)
    private let textSecondary = Color(red: 0.70, green: 0.70, blue: 0.70)
    private let borderColor = Color.white.opacity(0.12)

    // Dot colors
    private let focusedStart = Color(red: 0.39, green: 0.4, blue: 0.95)   // indigo
    private let focusedEnd = Color(red: 0.55, green: 0.36, blue: 0.96)    // violet
    private let distractedColor = Color(red: 0.95, green: 0.25, blue: 0.25) // red

    var body: some View {
        HStack(spacing: 8) {
            // Status dot
            Circle()
                .fill(
                    viewModel.isDistracted
                        ? LinearGradient(colors: [distractedColor, distractedColor], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [focusedStart, focusedEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 8, height: 8)

            // Intention text
            Text(viewModel.intention)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            // Countdown timer
            Text(viewModel.timeDisplay)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(bgColor)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
    }
}

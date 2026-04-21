import Cocoa
import SwiftUI

/// Data handed to the overlay for display. Immutable.
struct SwitchOverlayPresentation {
    let taskTitle: String                 // currentBlock.title
    let timeRemainingInSession: String    // e.g. "38 min left"
    let targetDisplayName: String         // "Safari" or "youtube.com — Home"
    let countdownSeconds: Int
}

/// Callbacks the controller invokes based on user action.
protocol SwitchOverlayDelegate: AnyObject {
    func switchOverlayDidTapBackToWork()
    func switchOverlayDidTapContinue()
}

final class SwitchOverlayViewModel: ObservableObject {
    let presentation: SwitchOverlayPresentation
    @Published var secondsRemaining: Int
    @Published var continueEnabled: Bool = false
    weak var delegate: SwitchOverlayDelegate?
    private var timer: Timer?

    init(presentation: SwitchOverlayPresentation) {
        self.presentation = presentation
        self.secondsRemaining = presentation.countdownSeconds
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.secondsRemaining > 0 {
                self.secondsRemaining -= 1
            }
            if self.secondsRemaining <= 0 {
                self.continueEnabled = true
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }

    func backToWork() { delegate?.switchOverlayDidTapBackToWork() }

    func continueToTarget() {
        guard continueEnabled else { return }
        delegate?.switchOverlayDidTapContinue()
    }

    deinit { timer?.invalidate() }
}

// MARK: - View

struct SwitchOverlayView: View {
    @ObservedObject var viewModel: SwitchOverlayViewModel

    private let cardBg = Color(red: 0.08, green: 0.08, blue: 0.10)
    private let textPrimary = Color(white: 0.95)
    private let textSecondary = Color(white: 0.55)
    private let textTertiary = Color(white: 0.35)
    private let accentStart = Color(red: 0.39, green: 0.4, blue: 0.95)
    private let accentEnd = Color(red: 0.55, green: 0.36, blue: 0.96)
    private let disabledBg = Color.white.opacity(0.06)

    var body: some View {
        ZStack {
            // Full-screen blur + dark tint — same pattern as InterventionOverlayView.
            ZStack {
                VisualEffectBlur(material: .fullScreenUI, blendingMode: .behindWindow)
                Color.black.opacity(0.85)
            }
            .ignoresSafeArea()

            VStack(spacing: 22) {
                // Header: task title + time remaining in session
                VStack(spacing: 6) {
                    Text(viewModel.presentation.taskTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(viewModel.presentation.timeRemainingInSession)
                        .font(.system(size: 13))
                        .foregroundColor(textSecondary)
                }

                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                // Target info
                VStack(spacing: 4) {
                    Text("Opening")
                        .font(.system(size: 12))
                        .foregroundColor(textTertiary)
                    Text(viewModel.presentation.targetDisplayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(textPrimary)
                        .lineLimit(1)
                }

                // Countdown
                Text("\(viewModel.secondsRemaining)s")
                    .font(.system(size: 44, weight: .bold).monospacedDigit())
                    .foregroundColor(viewModel.continueEnabled ? textSecondary : textPrimary)

                // Buttons
                HStack(spacing: 12) {
                    Button(action: { viewModel.backToWork() }) {
                        Text("Back to work")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(colors: [accentStart, accentEnd],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)

                    Button(action: { viewModel.continueToTarget() }) {
                        Text("Continue")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(viewModel.continueEnabled ? textPrimary : textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(disabledBg)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.continueEnabled)
                }
            }
            .padding(32)
            .frame(maxWidth: 460)
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
        }
    }
}

// MARK: - Controller

/// Owns the overlay window. One window active at a time.
final class SwitchOverlayController {
    private var overlayWindow: NSWindow?
    private(set) var viewModel: SwitchOverlayViewModel?

    func show(presentation: SwitchOverlayPresentation, delegate: SwitchOverlayDelegate) {
        dismiss()
        let vm = SwitchOverlayViewModel(presentation: presentation)
        vm.delegate = delegate
        self.viewModel = vm

        let view = SwitchOverlayView(viewModel: vm)
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
        vm.startTimer()
    }

    func dismiss() {
        overlayWindow?.close()
        overlayWindow = nil
        viewModel = nil
    }

    var isShowing: Bool { overlayWindow != nil }
}

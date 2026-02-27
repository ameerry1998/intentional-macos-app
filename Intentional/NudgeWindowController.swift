import Cocoa
import SwiftUI

/// Manages a compact nudge toast that appears below the floating pill timer.
///
/// Shows a dark, minimal toast (300px wide, matching pill width) below the pill
/// when the user is on irrelevant content during a work block.
///
/// Two modes:
/// - **Level 1** (default): Auto-dismisses after 8s. Used for initial distraction detection.
/// - **Level 2** (escalated): Stays until user interacts. Used after sustained distraction.
///
/// Actions:
/// - "Got it" — button on the right, acknowledges the nudge
/// - "This is relevant" — secondary text link, opens inline justification field
class NudgeWindowController {

    weak var appDelegate: AppDelegate?
    private var nudgeWindow: NSWindow?
    private var autoDismissTimer: Timer?

    /// Frame of the pill window — used to position nudge below it
    var pillWindowFrame: NSRect?

    /// Called when the user clicks "Got it" (or nudge auto-dismisses)
    var onGotIt: (() -> Void)?
    /// Called when the user submits a "This is relevant" justification
    var onThisIsRelevant: ((String) -> Void)?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    /// Show a nudge toast below the pill (or top-right fallback).
    ///
    /// - Parameters:
    ///   - intention: The current block's intention
    ///   - appOrPage: The name of the off-task app or page title
    ///   - escalated: If true, nudge stays until user interacts (level 2)
    ///   - distractionMinutes: Cumulative distraction time (shown in level 2)
    ///   - warning: If true, shows red warning style (pre-intervention)
    func showNudge(intention: String, appOrPage: String, escalated: Bool = false,
                   distractionMinutes: Int = 0, warning: Bool = false) {
        // Close any existing nudge first
        dismiss()

        let viewModel = NudgeViewModel(
            intention: intention,
            appOrPage: appOrPage,
            escalated: escalated,
            distractionMinutes: distractionMinutes,
            warning: warning,
            onGotIt: { [weak self] in
                self?.onGotIt?()
                self?.dismiss()
            },
            onThisIsRelevant: { [weak self] justification in
                self?.onThisIsRelevant?(justification)
                self?.dismiss()
            }
        )

        let view = NudgeView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        let windowWidth: CGFloat = 300
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: 10)
        let fittingSize = hostingView.fittingSize
        let windowHeight = max(fittingSize.height, 40)
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
        window.isMovableByWindowBackground = false
        window.animationBehavior = .utilityWindow
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Position below pill (right-aligned), or top-right fallback
        if let pillFrame = pillWindowFrame {
            let newOrigin = NSPoint(
                x: pillFrame.maxX - windowWidth,
                y: pillFrame.minY - windowHeight - 6
            )
            window.setFrameOrigin(newOrigin)
        } else if let screenFrame = NSScreen.main?.visibleFrame {
            let newOrigin = NSPoint(
                x: screenFrame.maxX - windowWidth - 20,
                y: screenFrame.maxY - windowHeight - 20
            )
            window.setFrameOrigin(newOrigin)
        }

        // Wire up resize callback: when justification field appears, grow downward from top-right
        viewModel.onNeedsResize = { [weak hostingView, weak window, weak self] in
            guard let hv = hostingView, let w = window else { return }
            DispatchQueue.main.async {
                let newSize = hv.fittingSize
                let oldFrame = w.frame
                // Keep top-right corner fixed (grow downward)
                let newOrigin = NSPoint(
                    x: oldFrame.maxX - newSize.width,
                    y: oldFrame.maxY - newSize.height
                )
                w.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: true)
                _ = self // prevent unused capture warning
            }
        }

        // Wire up auto-dismiss cancellation: stop timer when user clicks "This is relevant"
        viewModel.onCancelAutoDismiss = { [weak self] in
            self?.autoDismissTimer?.invalidate()
            self?.autoDismissTimer = nil
        }

        window.orderFrontRegardless()
        nudgeWindow = window

        // Level 1: auto-dismiss after 8s. Level 2: stays until user interacts.
        if !escalated {
            autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
                self?.onGotIt?()
                self?.dismiss()
            }
        }

        appDelegate?.postLog("💬 Nudge shown: \"\(appOrPage)\" vs \"\(intention)\" (escalated: \(escalated))")
    }

    /// Dismiss the nudge window if showing.
    func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        nudgeWindow?.close()
        nudgeWindow = nil
    }

    /// Whether a nudge is currently visible.
    var isShowing: Bool {
        nudgeWindow != nil
    }
}

// MARK: - View Model

class NudgeViewModel: ObservableObject {
    let intention: String
    let appOrPage: String
    let escalated: Bool
    let distractionMinutes: Int
    let warning: Bool
    let onGotIt: () -> Void
    let onThisIsRelevant: (String) -> Void

    /// Called when the view needs to resize (e.g., justification field appears)
    var onNeedsResize: (() -> Void)?
    /// Called when the auto-dismiss timer should be cancelled (user is interacting)
    var onCancelAutoDismiss: (() -> Void)?

    @Published var showJustificationField: Bool = false {
        didSet {
            if showJustificationField {
                onCancelAutoDismiss?()
            }
            onNeedsResize?()
        }
    }
    @Published var justificationText: String = ""
    @Published var isChecking: Bool = false

    var canSubmit: Bool {
        justificationText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
    }

    init(intention: String, appOrPage: String, escalated: Bool, distractionMinutes: Int,
         warning: Bool = false,
         onGotIt: @escaping () -> Void, onThisIsRelevant: @escaping (String) -> Void) {
        self.intention = intention
        self.appOrPage = appOrPage
        self.escalated = escalated
        self.distractionMinutes = distractionMinutes
        self.warning = warning
        self.onGotIt = onGotIt
        self.onThisIsRelevant = onThisIsRelevant
    }

    func submitJustification() {
        guard canSubmit else { return }
        isChecking = true
        onThisIsRelevant(justificationText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Compact Toast View

struct NudgeView: View {
    @ObservedObject var viewModel: NudgeViewModel

    // Translucent red palette (matches reference toast)
    private let redBg = Color(red: 0.85, green: 0.18, blue: 0.18)
    private let textPrimary = Color.white
    private let textSecondary = Color.white.opacity(0.85)
    private let textTertiary = Color.white.opacity(0.55)

    // Warning: deeper red
    private let warningBg = Color(red: 0.70, green: 0.10, blue: 0.10)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row: message + Got it button
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if viewModel.warning {
                        Text("Off-task \(viewModel.distractionMinutes) min")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(textPrimary)
                        Text("Intervention in 60s")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(textSecondary)
                    } else if viewModel.escalated {
                        Text("Off-task \(viewModel.distractionMinutes) min")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(textPrimary)
                    } else {
                        Text("Not related to your task")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(textPrimary)
                    }
                }
                .lineLimit(1)

                Spacer(minLength: 4)

                Button(action: viewModel.onGotIt) {
                    Text("Got it")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // "This is relevant" secondary link (below main row)
            if !viewModel.showJustificationField {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.showJustificationField = true
                    }
                }) {
                    Text("This is relevant")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(textTertiary)
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            // Justification field (expanded when "This is relevant" tapped)
            if viewModel.showJustificationField {
                VStack(spacing: 6) {
                    TextField("Why is this relevant?", text: $viewModel.justificationText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(textPrimary)
                        .padding(8)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .onSubmit { viewModel.submitJustification() }

                    HStack {
                        Spacer()
                        Button(action: { viewModel.submitJustification() }) {
                            if viewModel.isChecking {
                                Text("Checking...")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(textTertiary)
                            } else {
                                Text("Submit")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(viewModel.canSubmit ? textPrimary : textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canSubmit || viewModel.isChecking)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 300)
        .background(
            (viewModel.warning ? warningBg : redBg).opacity(0.92)
        )
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 3)
    }
}

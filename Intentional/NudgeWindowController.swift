import Cocoa
import SwiftUI

/// Manages a floating nudge notification window.
///
/// Shows a dark, minimal card in the top-right corner of the screen when the user
/// is on irrelevant content during a work block.
///
/// Two modes:
/// - **Level 1** (default): Auto-dismisses after 8s. Used for initial distraction detection.
/// - **Level 2** (escalated): Stays until user interacts. Used after sustained distraction.
///
/// Two action buttons:
/// - "Got it" — acknowledges the nudge
/// - "This is relevant" — opens inline justification text field for AI re-evaluation
class NudgeWindowController {

    weak var appDelegate: AppDelegate?
    private var nudgeWindow: NSWindow?
    private var autoDismissTimer: Timer?

    /// Called when the user clicks "Got it" (or nudge auto-dismisses)
    var onGotIt: (() -> Void)?
    /// Called when the user submits a "This is relevant" justification
    var onThisIsRelevant: ((String) -> Void)?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    /// Show a nudge notification in the top-right corner.
    ///
    /// - Parameters:
    ///   - intention: The current block's intention
    ///   - appOrPage: The name of the off-task app or page title
    ///   - escalated: If true, nudge stays until user interacts (level 2)
    ///   - distractionMinutes: Cumulative distraction time (shown in level 2)
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 10)
        let fittingSize = hostingView.fittingSize
        let windowWidth: CGFloat = 340
        let windowHeight = max(fittingSize.height, 120)
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

        if let screenFrame = NSScreen.main?.visibleFrame {
            let windowFrame = window.frame
            let newOrigin = NSPoint(
                x: screenFrame.maxX - windowFrame.width - 20,
                y: screenFrame.maxY - windowFrame.height - 20
            )
            window.setFrameOrigin(newOrigin)
        }

        // Wire up resize callback: when justification field appears, resize window from top-right
        viewModel.onNeedsResize = { [weak hostingView, weak window] in
            guard let hv = hostingView, let w = window else { return }
            DispatchQueue.main.async {
                let newSize = hv.fittingSize
                let oldFrame = w.frame
                // Keep top-right corner fixed
                let newOrigin = NSPoint(
                    x: oldFrame.maxX - newSize.width,
                    y: oldFrame.maxY - newSize.height
                )
                w.setFrame(NSRect(origin: newOrigin, size: newSize), display: true, animate: true)
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

// MARK: - SwiftUI Nudge View

struct NudgeView: View {
    @ObservedObject var viewModel: NudgeViewModel

    // Colors (matching dark theme)
    private let bgColor = Color(red: 0.09, green: 0.09, blue: 0.11)
    private let borderColor = Color(red: 0.23, green: 0.23, blue: 0.26)
    private let textPrimary = Color(red: 0.95, green: 0.95, blue: 0.95)
    private let textSecondary = Color(red: 0.70, green: 0.70, blue: 0.70)
    private let textTertiary = Color(red: 0.50, green: 0.50, blue: 0.50)
    private let accentStart = Color(red: 0.39, green: 0.4, blue: 0.95)   // indigo
    private let accentEnd = Color(red: 0.55, green: 0.36, blue: 0.96)    // violet

    // Warning colors (red scheme for 4-min warning)
    private let warningStart = Color(red: 0.95, green: 0.25, blue: 0.25)  // red-500
    private let warningEnd = Color(red: 0.85, green: 0.15, blue: 0.15)    // red-700
    private let warningBorder = Color(red: 0.4, green: 0.1, blue: 0.1)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Block intention with accent dot
            HStack(spacing: 6) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: viewModel.warning ? [warningStart, warningEnd] : [accentStart, accentEnd],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 8, height: 8)

                Text(viewModel.intention)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Message — different for warning vs level 2 vs level 1
            if viewModel.warning {
                Text("You've been off-task for \(viewModel.distractionMinutes) min. A focus intervention starts in 60s if you don't get back on task.")
                    .font(.system(size: 12))
                    .foregroundColor(textSecondary)
            } else if viewModel.escalated {
                Text("You've been off-task for \(viewModel.distractionMinutes) min. You're not earning browse time.")
                    .font(.system(size: 12))
                    .foregroundColor(textSecondary)
            } else {
                Text("This doesn't seem related to your intention.")
                    .font(.system(size: 12))
                    .foregroundColor(textSecondary)
            }

            // App/page name
            Text(viewModel.appOrPage)
                .font(.system(size: 11))
                .foregroundColor(textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            // Justification text field (shown when "This is relevant" is clicked)
            if viewModel.showJustificationField {
                VStack(spacing: 6) {
                    TextField("Why is this relevant?", text: $viewModel.justificationText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(textPrimary)
                        .padding(8)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
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
            }

            // Action buttons
            HStack(spacing: 8) {
                Spacer()

                // "Got it" — secondary
                Button(action: viewModel.onGotIt) {
                    Text("Got it")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundColor(textSecondary)
                        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1))
                }
                .buttonStyle(.plain)

                // "This is relevant" — primary
                if !viewModel.showJustificationField {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.showJustificationField = true
                        }
                    }) {
                        Text("This is relevant")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .foregroundColor(bgColor)
                            .background(
                                LinearGradient(
                                    colors: viewModel.warning ? [warningStart, warningEnd] : [accentStart, accentEnd],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(bgColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(viewModel.warning ? warningBorder : borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
    }
}

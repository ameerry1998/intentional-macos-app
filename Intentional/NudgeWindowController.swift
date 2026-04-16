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
    private var nudgeWindow: KeyablePanel?
    private var autoDismissTimer: Timer?
    /// The current NudgeViewModel — stored so FocusMonitor can update override state after creation.
    private(set) var viewModel: NudgeViewModel?

    /// The pill window — nudge is added as a child so it moves with dragging
    weak var pillWindow: NSWindow?

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
                   distractionMinutes: Int = 0, warning: Bool = false,
                   showJustificationExpanded: Bool = false) {
        // Close any existing nudge first
        dismiss()

        let vm = NudgeViewModel(
            intention: intention,
            appOrPage: appOrPage,
            escalated: escalated,
            distractionMinutes: distractionMinutes,
            warning: warning,
            showJustificationExpanded: showJustificationExpanded,
            onGotIt: { [weak self] in
                self?.onGotIt?()
                self?.dismiss()
            },
            onThisIsRelevant: { [weak self] justification in
                self?.onThisIsRelevant?(justification)
                self?.dismiss()
            }
        )
        self.viewModel = vm

        let view = NudgeView(viewModel: vm)
        let hostingView = NSHostingView(rootView: view)
        let windowWidth: CGFloat = 300
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: 10)
        let fittingSize = hostingView.fittingSize
        let windowHeight = max(fittingSize.height, 40)
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let window = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Enable keyboard input if justification field is pre-expanded
        window.allowKeyboardInput = showJustificationExpanded

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
        if let pill = pillWindow {
            let pillFrame = pill.frame
            let newOrigin = NSPoint(
                x: pillFrame.maxX - windowWidth,
                y: pillFrame.minY - windowHeight - 6
            )
            window.setFrameOrigin(newOrigin)
            // Add as child window so it moves with the pill when dragged
            pill.addChildWindow(window, ordered: .below)
        } else if let screenFrame = NSScreen.main?.visibleFrame {
            let newOrigin = NSPoint(
                x: screenFrame.maxX - windowWidth - 20,
                y: screenFrame.maxY - windowHeight - 20
            )
            window.setFrameOrigin(newOrigin)
        }

        // Wire up resize callback: when justification field appears, grow downward from top-right
        vm.onNeedsResize = { [weak hostingView, weak window, weak self] in
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
        vm.onCancelAutoDismiss = { [weak self, weak window] in
            self?.autoDismissTimer?.invalidate()
            self?.autoDismissTimer = nil
            // Enable keyboard input for the justification text field
            window?.allowKeyboardInput = true
        }

        print("🚨 ACTIVATE: NudgeWindowController.showNudge — orderFrontRegardless")
        window.orderFrontRegardless()
        nudgeWindow = window

        // If justification is pre-expanded, trigger a resize now that callbacks are wired
        if showJustificationExpanded {
            vm.onNeedsResize?()
        }

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
        if let nw = nudgeWindow {
            nw.parent?.removeChildWindow(nw)
            nw.close()
        }
        nudgeWindow = nil
        viewModel = nil
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

    // AI Override
    var onOverrideAI: (() -> Void)?
    @Published var overridesRemaining: Int = 2
    @Published var partnerApprovalRequired: Bool = false
    @Published var showOverrideCodeEntry: Bool = false {
        didSet {
            if showOverrideCodeEntry {
                onCancelAutoDismiss?()
            }
            onNeedsResize?()
        }
    }
    @Published var overrideRequestId: String = ""
    @Published var overridePartnerName: String = ""
    @Published var overrideCodeDigits: [String] = Array(repeating: "", count: 6)
    @Published var overrideCodeError: String = ""
    var onVerifyOverrideCode: ((String, String) -> Void)?  // (code, requestId)

    var overridesAvailable: Bool { partnerApprovalRequired || overridesRemaining > 0 }

    var overrideLabel: String {
        if partnerApprovalRequired { return "Override AI" }
        if overridesRemaining > 0 { return "Override AI (\(overridesRemaining) left)" }
        return "Override AI (none left)"
    }

    var canSubmit: Bool {
        justificationText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 5
    }

    var canSubmitOverrideCode: Bool {
        overrideCodeDigits.allSatisfy { $0.count == 1 }
    }

    func submitOverrideCode() {
        let code = overrideCodeDigits.joined()
        guard code.count == 6 else { return }
        onVerifyOverrideCode?(code, overrideRequestId)
    }

    init(intention: String, appOrPage: String, escalated: Bool, distractionMinutes: Int,
         warning: Bool = false, showJustificationExpanded: Bool = false,
         onGotIt: @escaping () -> Void, onThisIsRelevant: @escaping (String) -> Void) {
        self.intention = intention
        self.appOrPage = appOrPage
        self.escalated = escalated
        self.distractionMinutes = distractionMinutes
        self.warning = warning
        self.onGotIt = onGotIt
        self.onThisIsRelevant = onThisIsRelevant
        // Pre-expand justification field if requested (e.g., from pill "This is relevant" link)
        if showJustificationExpanded {
            self.showJustificationField = true
        }
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

    // Translucent red palette (matches reference toast — frosted glass + red tint)
    private let redTint = Color(red: 0.75, green: 0.12, blue: 0.12)
    private let textPrimary = Color.white
    private let textSecondary = Color.white.opacity(0.85)
    private let textTertiary = Color.white.opacity(0.55)

    // Warning: deeper red tint
    private let warningTint = Color(red: 0.60, green: 0.08, blue: 0.08)

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

            // "This is relevant" + "Override AI" links (below main row)
            if !viewModel.showJustificationField && !viewModel.showOverrideCodeEntry {
                VStack(spacing: 4) {
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

                    // "Override AI" link
                    Button(action: { viewModel.onOverrideAI?() }) {
                        Text(viewModel.overrideLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(viewModel.overridesAvailable ? textTertiary : textTertiary.opacity(0.4))
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.overridesAvailable)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            // Partner override code entry (shown when partner approval required)
            if viewModel.showOverrideCodeEntry {
                VStack(spacing: 8) {
                    Text("Code sent to \(viewModel.overridePartnerName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(textSecondary)

                    HStack(spacing: 4) {
                        ForEach(0..<6, id: \.self) { i in
                            TextField("", text: Binding(
                                get: { viewModel.overrideCodeDigits[i] },
                                set: { newVal in
                                    let filtered = String(newVal.filter { $0.isNumber }.prefix(1))
                                    viewModel.overrideCodeDigits[i] = filtered
                                }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(textPrimary)
                            .multilineTextAlignment(.center)
                            .frame(width: 28, height: 32)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.2), lineWidth: 1))
                        }
                    }

                    if !viewModel.overrideCodeError.isEmpty {
                        Text(viewModel.overrideCodeError)
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.9))
                    }

                    Button(action: { viewModel.submitOverrideCode() }) {
                        Text("Verify")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(viewModel.canSubmitOverrideCode ? textPrimary : textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canSubmitOverrideCode)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
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
            ZStack {
                // Frosted glass blur layer
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                // Semi-translucent red tint overlay
                (viewModel.warning ? warningTint : redTint).opacity(0.72)
            }
        )
        .cornerRadius(18)
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 3)
    }
}

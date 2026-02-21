import Cocoa
import SwiftUI

/// Manages a floating nudge notification window.
///
/// Shows a dark, minimal card in the top-right corner of the screen when the user
/// has been on irrelevant content for too long during a work block. Styled after
/// FocusAssistant's distraction notification — dark card, borderless, floating.
class NudgeWindowController {

    weak var appDelegate: AppDelegate?
    private var nudgeWindow: NSWindow?
    private var autoDismissTimer: Timer?

    /// Called when the user clicks "Got it" (or nudge auto-dismisses)
    var onGotIt: (() -> Void)?
    /// Called when the user clicks "5 more min"
    var onFiveMoreMinutes: (() -> Void)?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    /// Show a nudge notification in the top-right corner.
    ///
    /// - Parameters:
    ///   - intention: The current block's intention (e.g., "Finish the strict mode PR")
    ///   - appOrPage: The name of the off-task app or page title
    ///   - timeOnTarget: How long the user has been on this content
    func showNudge(intention: String, appOrPage: String, timeOnTarget: TimeInterval) {
        // Close any existing nudge first
        dismiss()

        let view = NudgeView(
            intention: intention,
            appOrPage: appOrPage,
            timeOnTarget: timeOnTarget,
            onGotIt: { [weak self] in
                self?.onGotIt?()
                self?.dismiss()
            },
            onFiveMoreMin: { [weak self] in
                self?.onFiveMoreMinutes?()
                self?.dismiss()
            }
        )

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 10) // initial; sized below
        let fittingSize = hostingView.fittingSize
        let windowWidth: CGFloat = 340
        let windowHeight = max(fittingSize.height, 120) // minimum 120 to avoid tiny windows
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

        // Position top-right corner, 20px from edges
        if let screenFrame = NSScreen.main?.visibleFrame {
            let windowFrame = window.frame
            let newOrigin = NSPoint(
                x: screenFrame.maxX - windowFrame.width - 20,
                y: screenFrame.maxY - windowFrame.height - 20
            )
            window.setFrameOrigin(newOrigin)
        }

        window.orderFrontRegardless()
        nudgeWindow = window

        // Auto-dismiss after 10 seconds — treat like "Got it" (restarts linger timer)
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.onGotIt?()
            self?.dismiss()
        }

        appDelegate?.postLog("💬 Nudge shown: \"\(appOrPage)\" vs \"\(intention)\"")
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

// MARK: - SwiftUI Nudge View

/// The floating nudge card — dark theme, minimal, with two action buttons.
/// Matches FocusAssistant's design language: dark background, subtle border,
/// teal-emerald gradient accent for the primary action.
struct NudgeView: View {
    let intention: String
    let appOrPage: String
    let timeOnTarget: TimeInterval
    let onGotIt: () -> Void
    let onFiveMoreMin: () -> Void

    // Colors (matching FocusAssistant's dark theme)
    private let bgColor = Color(red: 0.09, green: 0.09, blue: 0.11)        // zinc-900
    private let borderColor = Color(red: 0.23, green: 0.23, blue: 0.26)    // zinc-700
    private let textPrimary = Color(red: 0.95, green: 0.95, blue: 0.95)    // zinc-100
    private let textSecondary = Color(red: 0.70, green: 0.70, blue: 0.70)  // zinc-400
    private let textTertiary = Color(red: 0.50, green: 0.50, blue: 0.50)   // zinc-500
    private let cardBg = Color(red: 0.12, green: 0.12, blue: 0.13)         // zinc-800
    private let accentStart = Color(hue: 165.0 / 360.0, saturation: 0.8, brightness: 0.7)  // teal
    private let accentEnd = Color(hue: 142.0 / 360.0, saturation: 0.8, brightness: 0.7)    // emerald

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Block intention with accent dot
            HStack(spacing: 6) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accentStart, accentEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 8, height: 8)

                Text(intention)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Message
            Text("This doesn't seem related.")
                .font(.system(size: 12))
                .foregroundColor(textSecondary)

            // Time on target
            Text("\(appOrPage) · \(formatTime(timeOnTarget))")
                .font(.system(size: 11))
                .foregroundColor(textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            // Action buttons
            HStack(spacing: 8) {
                Spacer()

                // "Got it" — secondary action
                Button(action: onGotIt) {
                    Text("Got it")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundColor(textSecondary)
                        .background(cardBg)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(borderColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                // "5 more min" — primary action with gradient
                Button(action: onFiveMoreMin) {
                    Text("5 more min")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundColor(bgColor)
                        .background(
                            LinearGradient(
                                colors: [accentStart, accentEnd],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(bgColor)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return String(format: "%d:%02d", mins, secs)
        } else {
            return "\(secs)s"
        }
    }
}

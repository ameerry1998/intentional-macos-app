import Cocoa
import SwiftUI

// MARK: - View Model

class MorningPlanViewModel: ObservableObject {
    let yesterdayBlockCount: Int
    let yesterdayFocusedTime: String      // "4h 30m"
    let yesterdayAvgFocusScore: Int        // 0-100
    let yesterdayHadSchedule: Bool
    var onPlan: () -> Void
    var onSnooze: () -> Void

    init(
        yesterdayBlockCount: Int,
        yesterdayFocusedTime: String,
        yesterdayAvgFocusScore: Int,
        yesterdayHadSchedule: Bool,
        onPlan: @escaping () -> Void,
        onSnooze: @escaping () -> Void
    ) {
        self.yesterdayBlockCount = yesterdayBlockCount
        self.yesterdayFocusedTime = yesterdayFocusedTime
        self.yesterdayAvgFocusScore = yesterdayAvgFocusScore
        self.yesterdayHadSchedule = yesterdayHadSchedule
        self.onPlan = onPlan
        self.onSnooze = onSnooze
    }
}

// MARK: - View

struct MorningPlanView: View {
    @ObservedObject var viewModel: MorningPlanViewModel

    private let textPrimary = Color(red: 0.95, green: 0.95, blue: 0.95)
    private let textSecondary = Color(red: 0.70, green: 0.70, blue: 0.70)
    private let cardBg = Color(red: 0.09, green: 0.09, blue: 0.11)
    private let purpleStart = Color(red: 0.45, green: 0.30, blue: 0.90)
    private let purpleEnd = Color(red: 0.55, green: 0.36, blue: 0.96)
    private let statBg = Color.white.opacity(0.06)

    var body: some View {
        ZStack {
            // Full-screen dark backdrop
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            // Centered card
            VStack(spacing: 0) {
                // Sun icon + greeting
                Text("\u{2600}\u{FE0F}")
                    .font(.system(size: 32))
                    .padding(.top, 28)
                    .padding(.bottom, 4)

                Text("Good Morning")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(textPrimary)
                    .padding(.bottom, 20)

                // Yesterday section (if data exists)
                if viewModel.yesterdayHadSchedule && viewModel.yesterdayBlockCount > 0 {
                    Text("YESTERDAY")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(textSecondary)
                        .tracking(1.2)
                        .padding(.bottom, 10)

                    // Stats boxes
                    HStack(spacing: 12) {
                        statBox(value: "\(viewModel.yesterdayBlockCount)", label: "blocks")
                        statBox(value: "\(viewModel.yesterdayAvgFocusScore)%", label: "focus")
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 8)

                    Text("\(viewModel.yesterdayFocusedTime) focused")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textSecondary)
                        .padding(.bottom, 20)
                } else {
                    Text("Ready to plan your day?")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(textSecondary)
                        .padding(.bottom, 20)
                }

                // Plan Your Day button
                Button(action: { viewModel.onPlan() }) {
                    HStack(spacing: 6) {
                        Text("Plan Your Day")
                            .font(.system(size: 15, weight: .semibold))
                        Text("\u{2192}")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [purpleStart, purpleEnd],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)

                // Snooze link
                Button(action: { viewModel.onSnooze() }) {
                    Text("Snooze 1 hour")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
            .frame(width: 380)
            .background(cardBg.opacity(0.95))
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 10)
        }
    }

    private func statBox(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(textPrimary)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(statBg)
        .cornerRadius(10)
    }
}

// MARK: - Controller

/// Full-screen morning planning overlay shown when no plan is set.
/// Follows the BlockRitualController pattern: KeyableWindow at .screenSaver level.
class MorningPlanOverlayController {

    private var overlayWindow: NSWindow?

    var isShowing: Bool { overlayWindow != nil }

    func show(data: MorningPlanViewModel) {
        dismiss()

        let view = MorningPlanView(viewModel: data)
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
    }

    func dismiss() {
        overlayWindow?.close()
        overlayWindow = nil
    }

    deinit { dismiss() }
}

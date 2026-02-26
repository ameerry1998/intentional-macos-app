import Cocoa
import SwiftUI

/// Borderless NSWindow subclass that can become key (required for text field input and button interaction).
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Manages a full-screen blocking overlay window (Deep Work only).
///
/// Shown after a nudge timeout during deep work blocks. No progressive darkening —
/// appears at full opacity immediately. Only action is "Back to work".
class FocusOverlayWindowController {

    weak var appDelegate: AppDelegate?
    private var overlayWindow: NSWindow?

    /// Called when the user clicks "Back to work" or "Open Intentional"
    var onBackToWork: (() -> Void)?
    /// Called when the user clicks "Snooze for 30 min" (noPlan overlay only)
    var onSnooze: (() -> Void)?
    /// Called when the user creates a quick block from the unplanned overlay (title, durationMinutes, isFree)
    var onStartQuickBlock: ((String, Int, Bool) -> Void)?
    /// Called when the user clicks "Plan My Day" to open the full dashboard
    var onPlanDay: (() -> Void)?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    /// Show the blocking overlay.
    func showOverlay(
        intention: String,
        reason: String,
        focusDurationMinutes: Int,
        isNoPlan: Bool = false,
        canSnooze: Bool = false,
        nextBlockTitle: String? = nil,
        nextBlockTime: String? = nil,
        minutesUntilNextBlock: Int? = nil,
        displayName: String? = nil
    ) {
        // Close any existing overlay
        dismiss()

        let viewModel = FocusOverlayViewModel(
            intention: intention,
            reason: reason,
            focusDurationMinutes: focusDurationMinutes,
            isNoPlan: isNoPlan,
            canSnooze: canSnooze,
            nextBlockTitle: nextBlockTitle,
            nextBlockTime: nextBlockTime,
            minutesUntilNextBlock: minutesUntilNextBlock,
            displayName: displayName
        )

        viewModel.onBackToWork = { [weak self] in
            self?.onBackToWork?()
            self?.dismiss()
        }

        viewModel.onSnooze = { [weak self] in
            self?.onSnooze?()
            self?.dismiss()
        }

        viewModel.onStartQuickBlock = { [weak self] title, duration, isFree in
            self?.onStartQuickBlock?(title, duration, isFree)
            self?.dismiss()
        }

        viewModel.onPlanDay = { [weak self] in
            self?.onPlanDay?()
            self?.dismiss()
        }

        let view = FocusOverlayView(viewModel: viewModel)
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

        appDelegate?.postLog("🌑 Native focus overlay shown: \"\(intention)\" (isNoPlan: \(isNoPlan))")
    }

    /// Dismiss the overlay window.
    func dismiss() {
        overlayWindow?.close()
        overlayWindow = nil
    }

    var isShowing: Bool {
        overlayWindow != nil
    }
}

// MARK: - View Model

struct DurationOption: Identifiable {
    let minutes: Int
    let label: String
    var id: Int { minutes }
}

class FocusOverlayViewModel: ObservableObject {
    let intention: String
    let reason: String
    let focusDurationMinutes: Int
    let isNoPlan: Bool
    let canSnooze: Bool

    // What triggered the overlay (page title or app name)
    let displayName: String?

    // Next block context (for unplanned overlay)
    let nextBlockTitle: String?
    let nextBlockTime: String?
    let minutesUntilNextBlock: Int?

    // Quick block creation (unplanned overlay)
    @Published var quickBlockTitle: String = ""
    @Published var selectedDuration: Int = 60
    @Published var showQuickSession: Bool = false

    var onBackToWork: (() -> Void)?
    var onSnooze: (() -> Void)?
    var onStartQuickBlock: ((String, Int, Bool) -> Void)?
    var onPlanDay: (() -> Void)?

    var durationOptions: [DurationOption] {
        var options = [
            DurationOption(minutes: 30, label: "30 min"),
            DurationOption(minutes: 60, label: "1 hr"),
            DurationOption(minutes: 120, label: "2 hr"),
        ]
        if let untilNext = minutesUntilNextBlock, untilNext > 0 && untilNext != 30 && untilNext != 60 && untilNext != 120 {
            let label = "Until \(nextBlockTime ?? "")"
            options.append(DurationOption(minutes: untilNext, label: label))
        }
        return options
    }

    func startQuickBlock(isFree: Bool) {
        let title = isFree ? "Free time" : quickBlockTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFree || !title.isEmpty else { return }
        onStartQuickBlock?(title, selectedDuration, isFree)
    }

    init(intention: String, reason: String, focusDurationMinutes: Int,
         isNoPlan: Bool = false, canSnooze: Bool = false,
         nextBlockTitle: String? = nil, nextBlockTime: String? = nil, minutesUntilNextBlock: Int? = nil,
         displayName: String? = nil) {
        self.intention = intention
        self.reason = reason
        self.focusDurationMinutes = focusDurationMinutes
        self.isNoPlan = isNoPlan
        self.canSnooze = canSnooze
        self.displayName = displayName
        self.nextBlockTitle = nextBlockTitle
        self.nextBlockTime = nextBlockTime
        self.minutesUntilNextBlock = minutesUntilNextBlock
    }
}

// MARK: - Glassmorphic Blur Background

/// NSViewRepresentable that wraps NSVisualEffectView for real behind-window blur.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - SwiftUI View

struct FocusOverlayView: View {
    @ObservedObject var viewModel: FocusOverlayViewModel

    // Colors matching the existing design language
    private let cardBg = Color(red: 0.06, green: 0.06, blue: 0.08)
    private let textPrimary = Color(white: 0.95)
    private let textSecondary = Color(white: 0.5)
    private let textTertiary = Color(white: 0.35)
    private let accentStart = Color(red: 0.39, green: 0.4, blue: 0.95)   // indigo-500
    private let accentEnd = Color(red: 0.55, green: 0.36, blue: 0.96)    // violet-500

    // Green accent for noPlan card
    private let goGreen = Color(red: 0.25, green: 0.78, blue: 0.45)
    private let goGreenBright = Color(red: 0.30, green: 0.88, blue: 0.52)

    var body: some View {
        ZStack {
            if viewModel.isNoPlan {
                // Light backdrop for noPlan
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
            } else {
                // Full-screen glassmorphic blur + dark tint for deep work
                ZStack {
                    VisualEffectBlur(material: .fullScreenUI, blendingMode: .behindWindow)
                    Color.black.opacity(0.80)
                }
                .ignoresSafeArea()
            }

            VStack {
                Spacer()

                // Center card
                VStack(spacing: 0) {
                    if viewModel.isNoPlan {
                        noPlanOverlay
                    } else {
                        deepWorkOverlay
                    }
                }
                .padding(viewModel.isNoPlan ? 32 : 40)
                .frame(maxWidth: 460)
                .background(
                    viewModel.isNoPlan
                        ? AnyView(ZStack {
                            VisualEffectBlur(material: .sidebar, blendingMode: .withinWindow)
                            Color(white: 0.93)
                        })
                        : AnyView(ZStack {
                            VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                            cardBg.opacity(0.7)
                        })
                )
                .cornerRadius(viewModel.isNoPlan ? 24 : 20)
                .overlay(
                    RoundedRectangle(cornerRadius: viewModel.isNoPlan ? 24 : 20)
                        .stroke(viewModel.isNoPlan ? Color.black.opacity(0.05) : Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(viewModel.isNoPlan ? 0.10 : 0.6), radius: 40, x: 0, y: 12)

                Spacer()
            }
        }
    }

    // MARK: - No Plan / Unplanned Overlay

    // Light-mode text colors for noPlan
    private let lightTextPrimary = Color(white: 0.10)
    private let lightTextSecondary = Color(white: 0.48)
    private let lightTextTertiary = Color(white: 0.55)

    @ViewBuilder
    private var noPlanOverlay: some View {
        Text("Unscheduled time")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(lightTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 16)

        Text("Plan your day to stay focused")
            .font(.system(size: 24, weight: .bold))
            .foregroundColor(lightTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(2)
            .padding(.bottom, 6)

        Text("Set up your schedule so Intentional can help you stay on track.")
            .font(.system(size: 15))
            .foregroundColor(lightTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(2)
            .padding(.bottom, 4)

        if let nextTitle = viewModel.nextBlockTitle, let nextTime = viewModel.nextBlockTime {
            HStack(spacing: 6) {
                Circle().fill(accentStart).frame(width: 6, height: 6)
                Text("Next: \"\(nextTitle)\" at \(nextTime)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(lightTextTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }

        Spacer().frame(height: 28)

        HStack(spacing: 12) {
            Button(action: { viewModel.onPlanDay?() }) {
                Text("Plan My Day")
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

            if !viewModel.showQuickSession {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.showQuickSession = true
                    }
                }) {
                    Text("Quick session")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(lightTextSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }

        if viewModel.showQuickSession {
            quickSessionForm
                .padding(.top, 12)
        }

        if viewModel.canSnooze {
            Button(action: { viewModel.onSnooze?() }) {
                Text("Snooze 30 min")
                    .font(.system(size: 12))
                    .foregroundColor(lightTextTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var quickSessionForm: some View {
        let isLight = viewModel.isNoPlan
        let fieldBg = isLight ? Color.black.opacity(0.04) : Color.white.opacity(0.06)
        let fieldBorder = isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.1)
        let fieldText = isLight ? lightTextPrimary : textPrimary
        let labelColor = isLight ? lightTextSecondary : textSecondary

        VStack(spacing: 10) {
            TextField("What are you working on?", text: $viewModel.quickBlockTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(fieldText)
                .padding(12)
                .background(fieldBg)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(fieldBorder, lineWidth: 1))
                .frame(maxWidth: 340)

            HStack(spacing: 8) {
                ForEach(viewModel.durationOptions) { option in
                    Button(action: { viewModel.selectedDuration = option.minutes }) {
                        Text(option.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(
                                viewModel.selectedDuration == option.minutes
                                    ? .white
                                    : labelColor
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                viewModel.selectedDuration == option.minutes
                                    ? AnyShapeStyle(LinearGradient(colors: [goGreen, goGreenBright], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(fieldBg)
                            )
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Button(action: { viewModel.startQuickBlock(isFree: false) }) {
                    Text("Start Focus Block")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(colors: [goGreen, goGreenBright], startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.quickBlockTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(viewModel.quickBlockTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1.0)

                Button(action: { viewModel.startQuickBlock(isFree: true) }) {
                    Text("Free Time")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(labelColor)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(fieldBg)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(fieldBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Deep Work Blocking Overlay

    @ViewBuilder
    private var deepWorkOverlay: some View {
        if viewModel.focusDurationMinutes > 0 {
            Text("FOCUSED FOR \(viewModel.focusDurationMinutes) MIN")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(textTertiary)
                .padding(.bottom, 20)
        }

        Text("You're working on")
            .font(.system(size: 13))
            .foregroundColor(textSecondary)
            .padding(.bottom, 6)

        Text(viewModel.intention)
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(textPrimary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 12)

        if let name = viewModel.displayName, !name.isEmpty {
            Text("You were on: \(name)")
                .font(.system(size: 13))
                .foregroundColor(textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
        }

        if !viewModel.reason.isEmpty {
            Text(viewModel.reason)
                .font(.system(size: 14))
                .foregroundColor(textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.bottom, 24)
        }

        Button(action: { viewModel.onBackToWork?() }) {
            Text("Back to work")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 13)
                .background(
                    LinearGradient(colors: [accentStart, accentEnd], startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

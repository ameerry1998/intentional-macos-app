import Cocoa
import SwiftUI

/// Borderless NSWindow subclass that can become key (required for text field input and button interaction).
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Manages a full-screen progressive overlay window for all apps.
///
/// When the user is on irrelevant content during a work block (or any app during
/// unscheduled time), this overlay covers the entire screen with a glassmorphic
/// blur effect that progressively intensifies.
class FocusOverlayWindowController {

    weak var appDelegate: AppDelegate?
    private var overlayWindow: NSWindow?
    private var progressTimer: Timer?
    private var holdTimer: Timer?

    /// Called when the user clicks "Back to work" or "Open Intentional"
    var onBackToWork: (() -> Void)?
    /// Called when the user types a reason and clicks "Grant 5 minutes"
    var onFiveMoreMinutes: ((String) -> Void)?
    /// Called when the user clicks "Snooze for 30 min" (noPlan overlay only)
    var onSnooze: (() -> Void)?
    /// Called when the user clicks "Snooze 5 min" (simple snooze, no reason needed)
    var onSnooze5Min: (() -> Void)?
    /// Called when the user creates a quick block from the unplanned overlay (title, durationMinutes, isFree)
    var onStartQuickBlock: ((String, Int, Bool) -> Void)?
    /// Called when the user clicks "Plan My Day" to open the full dashboard
    var onPlanDay: (() -> Void)?

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate
    }

    /// Show the progressive overlay.
    func showOverlay(
        intention: String,
        reason: String,
        enforcement: String,
        isRevisit: Bool,
        focusDurationMinutes: Int,
        isNoPlan: Bool = false,
        canSnooze: Bool = false,
        canSnooze5Min: Bool = true,
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
            enforcement: enforcement,
            isRevisit: isRevisit,
            focusDurationMinutes: focusDurationMinutes,
            isNoPlan: isNoPlan,
            canSnooze: canSnooze,
            canSnooze5Min: canSnooze5Min,
            nextBlockTitle: nextBlockTitle,
            nextBlockTime: nextBlockTime,
            minutesUntilNextBlock: minutesUntilNextBlock,
            displayName: displayName
        )

        viewModel.onBackToWork = { [weak self] in
            self?.onBackToWork?()
            self?.dismiss()
        }

        viewModel.onFiveMoreMinutes = { [weak self] reason in
            self?.onFiveMoreMinutes?(reason)
            self?.dismiss()
        }

        viewModel.onSnooze = { [weak self] in
            self?.onSnooze?()
            self?.dismiss()
        }

        viewModel.onSnooze5Min = { [weak self] in
            self?.onSnooze5Min?()
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

        appDelegate?.postLog("🌑 Native focus overlay shown: \"\(intention)\" (enforcement: \(enforcement), revisit: \(isRevisit))")
    }

    /// Dismiss the overlay window.
    func dismiss() {
        progressTimer?.invalidate()
        progressTimer = nil
        holdTimer?.invalidate()
        holdTimer = nil
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
    let enforcement: String
    let isRevisit: Bool
    let focusDurationMinutes: Int
    let isNoPlan: Bool
    let canSnooze: Bool
    let canSnooze5Min: Bool

    // What triggered the overlay (page title or app name)
    let displayName: String?

    // Next block context (for unplanned overlay)
    let nextBlockTitle: String?
    let nextBlockTime: String?
    let minutesUntilNextBlock: Int?

    @Published var overlayOpacity: Double
    @Published var countdownSeconds: Int
    @Published var bypassText: String = ""
    @Published var showBypassForm: Bool = false

    // Quick block creation (unplanned overlay)
    @Published var quickBlockTitle: String = ""
    @Published var selectedDuration: Int = 60
    @Published var showQuickSession: Bool = false

    var onBackToWork: (() -> Void)?
    var onFiveMoreMinutes: ((String) -> Void)?
    var onSnooze: (() -> Void)?
    var onSnooze5Min: (() -> Void)?
    var onStartQuickBlock: ((String, Int, Bool) -> Void)?
    var onPlanDay: (() -> Void)?

    private var progressTimer: Timer?
    private var holdTimer: Timer?
    private let targetOpacity: Double
    private let rampDurationSeconds: Double

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

    init(intention: String, reason: String, enforcement: String, isRevisit: Bool, focusDurationMinutes: Int,
         isNoPlan: Bool = false, canSnooze: Bool = false, canSnooze5Min: Bool = true,
         nextBlockTitle: String? = nil, nextBlockTime: String? = nil, minutesUntilNextBlock: Int? = nil,
         displayName: String? = nil) {
        self.intention = intention
        self.reason = reason
        self.enforcement = enforcement
        self.isRevisit = isRevisit
        self.focusDurationMinutes = focusDurationMinutes
        self.isNoPlan = isNoPlan
        self.canSnooze = canSnooze
        self.canSnooze5Min = canSnooze5Min
        self.displayName = displayName
        self.nextBlockTitle = nextBlockTitle
        self.nextBlockTime = nextBlockTime
        self.minutesUntilNextBlock = minutesUntilNextBlock

        let startOpacity = isRevisit ? 0.6 : 0.0
        self.overlayOpacity = startOpacity
        self.targetOpacity = isNoPlan ? 0.8 : (enforcement == "block" ? 0.95 : 0.7)
        self.rampDurationSeconds = isNoPlan ? 2.0 : 30.0
        self.countdownSeconds = isNoPlan ? 0 : (isRevisit ? 0 : 30)

        startProgressiveDarkening(from: startOpacity)
    }

    deinit {
        progressTimer?.invalidate()
        holdTimer?.invalidate()
    }

    private func startProgressiveDarkening(from startOpacity: Double) {
        // Quick initial ramp to 0.2 if starting from 0
        let rampFrom = max(startOpacity, 0.2)

        if startOpacity < 0.2 {
            // Ramp to 0.2 (1s for noPlan gentle fade, 0.5s for work block)
            let initialRampDuration = isNoPlan ? 1.0 : 0.5
            let steps = initialRampDuration / 0.016
            let increment = (0.2 - startOpacity) / steps
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                DispatchQueue.main.async {
                    self.overlayOpacity = min(self.overlayOpacity + increment, 0.2)
                    if self.overlayOpacity >= 0.2 {
                        timer.invalidate()
                        self.startMainRamp(from: 0.2)
                    }
                }
            }
        } else {
            startMainRamp(from: rampFrom)
        }
    }

    private func startMainRamp(from opacity: Double) {
        let stepInterval: TimeInterval = 0.1
        let steps = rampDurationSeconds / stepInterval
        let increment = (targetOpacity - opacity) / steps

        if increment <= 0 {
            overlayOpacity = targetOpacity
            if enforcement == "nudge" {
                scheduleNudgeFadeOut()
            }
            return
        }

        // Countdown timer (every 1s)
        if enforcement == "block" && countdownSeconds > 0 {
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                DispatchQueue.main.async {
                    self.countdownSeconds -= 1
                    if self.countdownSeconds <= 0 {
                        timer.invalidate()
                    }
                }
            }
        }

        progressTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            DispatchQueue.main.async {
                self.overlayOpacity = min(self.overlayOpacity + increment, self.targetOpacity)
                if self.overlayOpacity >= self.targetOpacity {
                    timer.invalidate()
                    if self.enforcement == "nudge" {
                        self.scheduleNudgeFadeOut()
                    }
                }
            }
        }
    }

    private func scheduleNudgeFadeOut() {
        // Hold for 3 seconds, then fade out over 2 seconds
        holdTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let fadeSteps = 2.0 / 0.05
            let fadeDecrement = self.overlayOpacity / fadeSteps

            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                DispatchQueue.main.async {
                    self.overlayOpacity = max(self.overlayOpacity - fadeDecrement, 0)
                    if self.overlayOpacity <= 0 {
                        timer.invalidate()
                        self.onBackToWork?()  // Auto-dismiss
                    }
                }
            }
        }
    }

    var canSubmitBypass: Bool {
        bypassText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
    }

    func submitBypass() {
        guard canSubmitBypass else { return }
        onFiveMoreMinutes?(bypassText.trimmingCharacters(in: .whitespacesAndNewlines))
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
    private let cardBorder = Color(white: 1, opacity: 0.08)
    private let textPrimary = Color(white: 0.95)
    private let textSecondary = Color(white: 0.5)
    private let textTertiary = Color(white: 0.35)
    private let accentStart = Color(red: 0.39, green: 0.4, blue: 0.95)   // indigo-500
    private let accentEnd = Color(red: 0.55, green: 0.36, blue: 0.96)    // violet-500

    var body: some View {
        ZStack {
            // Full-screen glassmorphic blur + dark tint
            ZStack {
                // Behind-window blur (frosted glass effect)
                VisualEffectBlur(material: .fullScreenUI, blendingMode: .behindWindow)
                    .opacity(min(1.0, viewModel.overlayOpacity * 3))  // Blur fades in quickly

                // Dark tint that progressively increases
                Color.black
                    .opacity(viewModel.overlayOpacity * 0.85)
            }
            .ignoresSafeArea()

            // Center card
            VStack(spacing: 0) {
                if viewModel.isNoPlan {
                    // --- UNPLANNED OVERLAY ---

                    Text("Unscheduled Time")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(textPrimary)
                        .padding(.bottom, 8)

                    Text("Plan your day to stay focused")
                        .font(.system(size: 14))
                        .foregroundColor(textSecondary)
                        .padding(.bottom, 16)

                    // Next block context
                    if let nextTitle = viewModel.nextBlockTitle, let nextTime = viewModel.nextBlockTime {
                        Text("Next up: \"\(nextTitle)\" at \(nextTime)")
                            .font(.system(size: 12))
                            .foregroundColor(textTertiary)
                            .padding(.bottom, 16)
                    }

                    // Primary: Plan My Day
                    Button(action: { viewModel.onPlanDay?() }) {
                        Text("Plan My Day")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 13)
                            .background(
                                LinearGradient(
                                    colors: [accentStart, accentEnd],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 16)

                    // Expandable quick session
                    if !viewModel.showQuickSession {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.showQuickSession = true
                            }
                        }) {
                            Text("+ Quick session instead")
                                .font(.system(size: 13))
                                .foregroundColor(textSecondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 12)
                    } else {
                        VStack(spacing: 10) {
                            // Title input
                            TextField("What are you working on?", text: $viewModel.quickBlockTitle)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .foregroundColor(textPrimary)
                                .padding(12)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                                .frame(maxWidth: 340)

                            // Duration pills
                            HStack(spacing: 8) {
                                ForEach(viewModel.durationOptions) { option in
                                    Button(action: { viewModel.selectedDuration = option.minutes }) {
                                        Text(option.label)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(viewModel.selectedDuration == option.minutes ? .white : textSecondary)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 7)
                                            .background(
                                                Group {
                                                    if viewModel.selectedDuration == option.minutes {
                                                        LinearGradient(
                                                            colors: [accentStart, accentEnd],
                                                            startPoint: .leading,
                                                            endPoint: .trailing
                                                        )
                                                    } else {
                                                        LinearGradient(
                                                            colors: [Color.white.opacity(0.06), Color.white.opacity(0.06)],
                                                            startPoint: .leading,
                                                            endPoint: .trailing
                                                        )
                                                    }
                                                }
                                            )
                                            .cornerRadius(8)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // Start buttons
                            HStack(spacing: 10) {
                                Button(action: { viewModel.startQuickBlock(isFree: false) }) {
                                    Text("Start Work Block")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(
                                            LinearGradient(
                                                colors: [accentStart, accentEnd],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                                .disabled(viewModel.quickBlockTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .opacity(viewModel.quickBlockTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1.0)

                                Button(action: { viewModel.startQuickBlock(isFree: true) }) {
                                    Text("Free Block")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(textSecondary)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.white.opacity(0.06))
                                        .cornerRadius(10)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 12)
                    }

                    // Snooze (subtle, one-time)
                    if viewModel.canSnooze5Min {
                        Button(action: { viewModel.onSnooze5Min?() }) {
                            Text("Snooze 5 min")
                                .font(.system(size: 12))
                                .foregroundColor(textTertiary)
                        }
                        .buttonStyle(.plain)
                    }

                } else {
                    // --- WORK BLOCK OVERLAY ---

                    // Focus streak
                    if viewModel.focusDurationMinutes > 0 {
                        Text("FOCUSED FOR \(viewModel.focusDurationMinutes) MIN")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(textTertiary)
                            .padding(.bottom, 20)
                    }

                    // Task label
                    Text("You're working on")
                        .font(.system(size: 13))
                        .foregroundColor(textSecondary)
                        .padding(.bottom, 6)

                    // Intention
                    Text(viewModel.intention)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 12)

                    // What triggered this overlay
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

                    // AI reason
                    if !viewModel.reason.isEmpty {
                        Text(viewModel.reason)
                            .font(.system(size: 14))
                            .foregroundColor(textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.bottom, 24)
                    }

                    // Countdown (block mode only)
                    if viewModel.enforcement == "block" && viewModel.countdownSeconds > 0 {
                        Text("Screen will be hidden in \(viewModel.countdownSeconds)s")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundColor(textTertiary)
                            .padding(.bottom, 28)
                    }

                    // Primary action button
                    Button(action: { viewModel.onBackToWork?() }) {
                        Text("Back to work")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 13)
                            .background(
                                LinearGradient(
                                    colors: [accentStart, accentEnd],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)

                    // Snooze 5 min button
                    if viewModel.canSnooze5Min {
                        Button(action: { viewModel.onSnooze5Min?() }) {
                            Text("Snooze 5 min")
                                .font(.system(size: 13))
                                .foregroundColor(textTertiary)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 4)
                    }

                    // Work block mode: show bypass toggle / form
                    if !viewModel.showBypassForm {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.showBypassForm = true
                            }
                        }) {
                            Text("I need this page...")
                                .font(.system(size: 13))
                                .foregroundColor(textTertiary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        VStack(spacing: 8) {
                            TextField("Why do you need this? (min 10 characters)", text: $viewModel.bypassText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundColor(textPrimary)
                                .padding(10)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                                .frame(maxWidth: 340)
                                .onSubmit {
                                    viewModel.submitBypass()
                                }

                            let remaining = max(0, 10 - viewModel.bypassText.trimmingCharacters(in: .whitespacesAndNewlines).count)
                            if remaining > 0 {
                                Text("\(remaining) more character\(remaining == 1 ? "" : "s") needed")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.white.opacity(0.2))
                            }

                            Button(action: { viewModel.submitBypass() }) {
                                Text("Grant 5 minutes")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(viewModel.canSubmitBypass ? textSecondary : textTertiary)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 9)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(!viewModel.canSubmitBypass)
                            .opacity(viewModel.canSubmitBypass ? 1.0 : 0.3)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: 460)
            .background(
                ZStack {
                    // Glassmorphic card background
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
            .opacity(min(1.0, viewModel.overlayOpacity * 5))  // Card fades in faster than background
        }
    }
}

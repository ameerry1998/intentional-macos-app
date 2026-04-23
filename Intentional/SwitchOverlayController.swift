import Cocoa
import SwiftUI

/// Data handed to the overlay for display. Immutable.
///
/// Maps to the V9E-A design handoff (SwitchOverlay.jsx) — see docs/CONTEXT_SWITCHING_OVERLAY.md.
struct SwitchOverlayPresentation {
    /// Active block/project name — coral eyebrow line ("Deep Work · 23 min left").
    let project: String
    /// Specific task/outcome text under the eyebrow. Empty string hides the row.
    let task: String
    /// Human-readable remaining session text, e.g. "23 min left".
    let sessionLeft: String
    /// Display name of the app/tab being opened, e.g. "Google Chrome" or "Safari — youtube.com".
    let targetName: String
    /// Countdown length in seconds (10 / 15 / 20 by tier).
    let countdownSeconds: Int
    /// Monotonically-increasing index used to pick a rotating reminder; stable for this interception.
    let interceptIndex: Int
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

// MARK: - Design tokens

private enum SO {
    static let coral1 = Color(red: 232.0 / 255.0, green: 116.0 / 255.0, blue: 97.0 / 255.0)
    static let coral2 = Color(red: 240.0 / 255.0, green: 176.0 / 255.0, blue: 96.0 / 255.0)
    static let coralGradient = LinearGradient(
        colors: [coral1, coral2],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let coralGlow = Color(red: 232.0 / 255.0, green: 116.0 / 255.0, blue: 97.0 / 255.0).opacity(0.5)

    static let text1 = Color(red: 247.0 / 255.0, green: 248.0 / 255.0, blue: 248.0 / 255.0)
    static let text2 = Color.white.opacity(0.65)
    static let text3 = Color.white.opacity(0.40)

    static let backdrop = Color(red: 6.0 / 255.0, green: 6.0 / 255.0, blue: 8.0 / 255.0).opacity(0.82)
    static let underlineTrack = Color.white.opacity(0.08)

    /// #1a0a05 — dark brown for contrast on the coral gradient button.
    static let buttonTextOnCoral = Color(red: 26.0 / 255.0, green: 10.0 / 255.0, blue: 5.0 / 255.0)

    static let rotatingReminders: [String] = [
        "Each switch costs ~23 min of deep focus.",
        "Deep work is built one uninterrupted block at a time.",
        "The urge to switch will pass. Your work won't.",
        "You chose this hour. Honor the choice.",
    ]

    static func reminder(for index: Int) -> String {
        let count = rotatingReminders.count
        guard count > 0 else { return "" }
        let i = ((index % count) + count) % count
        return rotatingReminders[i]
    }
}

// MARK: - View

struct SwitchOverlayView: View {
    @ObservedObject var viewModel: SwitchOverlayViewModel
    @State private var breathing = false

    var body: some View {
        ZStack {
            // Full-bleed blur + 82% black backdrop. No entrance animation — feel final/immediate.
            ZStack {
                VisualEffectBlur(material: .fullScreenUI, blendingMode: .behindWindow)
                SO.backdrop
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topContext
                Spacer(minLength: 24)
                phrase
                Spacer(minLength: 24)
                bottomBlock
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Top — coral eyebrow + task

    private var topContext: some View {
        VStack(spacing: 8) {
            Text(eyebrowText)
                .font(.system(size: 10, weight: .semibold))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundColor(SO.coral1)
                .lineLimit(1)

            if !viewModel.presentation.task.isEmpty {
                Text(viewModel.presentation.task)
                    .font(.system(size: 14))
                    .foregroundColor(SO.text3)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var eyebrowText: String {
        let p = viewModel.presentation.project
        let s = viewModel.presentation.sessionLeft
        if p.isEmpty { return s }
        if s.isEmpty { return p }
        return "\(p) · \(s)"
    }

    // MARK: Phrase — "Opening {target} in {N}s" on one line with underline depletion under target

    private var phrase: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text("Opening ")
                .foregroundColor(SO.text3)

            targetWithUnderline

            Text(" in ")
                .foregroundColor(SO.text3)

            Text("\(viewModel.secondsRemaining)s")
                .font(.system(size: 42, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(SO.coral1)
                .kerning(-0.84)  // -0.02em at 42pt ≈ -0.84pt
                .opacity(breathing ? 0.82 : 1.0)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: breathing)
        }
        .font(.system(size: 42, weight: .light))
        .tracking(-0.5)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { breathing = true }
    }

    private var targetWithUnderline: some View {
        Text(viewModel.presentation.targetName)
            .font(.system(size: 42, weight: .medium))
            .foregroundColor(SO.text1)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(SO.underlineTrack)
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(SO.coralGradient)
                            .frame(width: max(0, geo.size.width * fillFraction), height: 3)
                            .shadow(color: SO.coralGlow, radius: 5)
                            .animation(.linear(duration: 1.0), value: viewModel.secondsRemaining)
                    }
                }
                .frame(height: 3)
            }
    }

    private var fillFraction: CGFloat {
        let total = max(1, viewModel.presentation.countdownSeconds)
        let remaining = max(0, min(total, viewModel.secondsRemaining))
        return CGFloat(remaining) / CGFloat(total)
    }

    // MARK: Bottom — rotating reminder + buttons

    private var bottomBlock: some View {
        VStack(spacing: 32) {
            Text(SO.reminder(for: viewModel.presentation.interceptIndex))
                .font(.system(size: 13))
                .italic()
                .foregroundColor(SO.text2)
                .lineSpacing(13 * 0.55)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            HStack(spacing: 10) {
                Button(action: { viewModel.backToWork() }) {
                    Text("Back to work")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.1)
                        .foregroundColor(SO.buttonTextOnCoral)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 13)
                        .background(SO.coralGradient)
                        .cornerRadius(8)
                        .shadow(color: SO.coral1.opacity(0.25), radius: 10, x: 0, y: 6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Button(action: { viewModel.continueToTarget() }) {
                    Text("Continue")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.1)
                        .foregroundColor(viewModel.continueEnabled ? SO.text1 : SO.text3)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 13)
                        .background(Color.white.opacity(viewModel.continueEnabled ? 0.08 : 0.04))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(viewModel.continueEnabled ? 0.12 : 0.06), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.continueEnabled)
            }
        }
    }
}

// MARK: - Controller

/// Owns overlay windows — one per screen so the intervention is unescapable on multi-display setups.
/// All windows share a single view model so the countdown is in sync across screens.
final class SwitchOverlayController {
    private var overlayWindows: [NSWindow] = []
    private(set) var viewModel: SwitchOverlayViewModel?
    /// Local keyDown monitor — Esc routes to "Back to work" (matches design spec).
    private var escapeMonitor: Any?
    /// Activation observer — re-key the overlay if another app steals focus while the overlay is up.
    private var activationObserver: NSObjectProtocol?
    /// Last time the observer pulled focus back. Used to damp rapid cascades (each NSApp.activate
    /// fires a didActivate that we filter out, but a real activation storm from macOS could still
    /// trigger us repeatedly — 100ms cooldown caps that to 10 Hz).
    private var lastFocusPullback: Date?

    func show(presentation: SwitchOverlayPresentation, delegate: SwitchOverlayDelegate) {
        dismiss()
        let vm = SwitchOverlayViewModel(presentation: presentation)
        vm.delegate = delegate
        self.viewModel = vm

        // Create one window per screen so the overlay can't be dodged by moving to another display
        // or by Mission-Control-ing to a different space. Same pattern as FocusOverlayWindow.
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        for (index, screen) in screens.enumerated() {
            let view = SwitchOverlayView(viewModel: vm)
            let hostingView = NSHostingView(rootView: view)
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
            // .canJoinAllSpaces — window appears on every Space.
            // .fullScreenAuxiliary — window can float over apps running in fullScreen mode.
            // .ignoresCycle — keeps the overlay out of Cmd-` window cycling.
            // .stationary — overlay does not animate away when user swipes between Spaces.
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            window.animationBehavior = .none

            window.setFrame(screenFrame, display: true)
            // Only the main-screen window becomes key (holds keyboard focus + Esc handler);
            // others just orderFront to be visible. Having multiple key windows on multi-display
            // would compete for keyboard input.
            if index == 0 {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
            overlayWindows.append(window)
        }

        // Force Intentional to the front so the overlay has app-level focus.
        // Without this, on some configurations the overlay renders above but the
        // app below keeps keyboard focus, so typing goes to the wrong app.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        vm.startTimer()

        // Esc = "okay, back to work" (design spec). .defaultAction on the primary button
        // already handles Enter, so we only need an explicit monitor for Escape.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 = kVK_Escape
            if event.keyCode == 53, !(self?.overlayWindows.isEmpty ?? true) {
                self?.viewModel?.backToWork()
                return nil
            }
            return event
        }

        // If another app activates while the overlay is visible (e.g. via Cmd-Tab, Mission Control
        // pick, or Dock click), pull focus back so the overlay keeps the keyboard. We only snap
        // back to Intentional — we don't try to prevent the app switch itself (macOS owns that).
        //
        // Filters:
        //   - Intentional itself: no-op (would otherwise spin when our own NSApp.activate fires).
        //   - Accessory / prohibited activation policy: skip. Menu-bar apps, Spotlight, Control
        //     Center, etc. briefly "activate" without becoming foreground; chasing those causes
        //     flicker and can fight with the system.
        //   - 100ms cooldown: caps pullback rate so we can't enter a tight loop if macOS fires
        //     a burst of didActivate events during an overlay show or system transition.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self, !self.overlayWindows.isEmpty else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != "com.arayan.intentional" else { return }
            if app.activationPolicy != .regular { return }
            let now = Date()
            if let last = self.lastFocusPullback, now.timeIntervalSince(last) < 0.1 { return }
            self.lastFocusPullback = now
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            self.overlayWindows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func dismiss() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        for window in overlayWindows {
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()
        viewModel = nil
        lastFocusPullback = nil
    }

    var isShowing: Bool { !overlayWindows.isEmpty }
}

//
//  ContentSafetyMonitor.swift
//  Intentional
//
//  On-device screen monitoring for explicit content. Captures all screens,
//  classifies via Apple's SensitiveContentAnalysis framework, and on detection:
//  blocks all screens with an overlay, blurs the screenshot, and sends it to the
//  accountability partner via email (base64 inline).
//
//  Independent of FocusMonitor and the focus schedule — always-on when enabled.
//

import Cocoa
import SwiftUI
import CoreImage
import SensitiveContentAnalysis

class ContentSafetyMonitor {

    weak var appDelegate: AppDelegate?

    // MARK: - State

    /// Whether the feature is enabled in settings
    private(set) var isEnabled: Bool = false

    /// Whether the monitor is actively polling (enabled + permission granted)
    private(set) var isMonitoring: Bool = false

    /// Whether screen recording permission has been granted
    private(set) var hasScreenRecordingPermission: Bool = false

    // MARK: - Polling

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 2.0

    /// Permission recheck timer (when permission not yet granted)
    private var permissionCheckTimer: Timer?
    private let permissionCheckInterval: TimeInterval = 30.0

    // MARK: - Cooldowns & Grace

    /// Last time an email was sent to the partner
    private var lastEmailTime: Date?
    /// Minimum time between partner emails
    private let emailCooldown: TimeInterval = 300  // 5 minutes

    /// Grace period end — no scanning until this time (after overlay dismiss)
    private var graceUntil: Date?
    /// Duration of grace period after overlay dismiss
    private let gracePeriod: TimeInterval = 30

    // MARK: - Analysis Guard

    /// Prevents concurrent analysis runs
    private var isAnalyzing: Bool = false

    // MARK: - Analyzer

    private var analyzer: SCSensitivityAnalyzer?

    // MARK: - Overlay

    private var overlayWindows: [NSWindow] = []
    private var overlayViewModel: ContentSafetyOverlayViewModel?

    // MARK: - Local Log

    private let logFileURL: URL

    // MARK: - CoreImage context (reuse for performance)

    private let ciContext = CIContext()

    // MARK: - Init

    init(appDelegate: AppDelegate?) {
        self.appDelegate = appDelegate

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logFileURL = dir.appendingPathComponent("content_safety_log.jsonl")

        self.analyzer = SCSensitivityAnalyzer()
    }

    /// Whether the system-level Sensitive Content Warning setting is enabled.
    /// Users must enable this in System Settings > Privacy & Security > Sensitive Content Warning.
    var isAnalysisAvailable: Bool {
        analyzer?.analysisPolicy != .disabled
    }

    // MARK: - Public API

    /// Called from MainWindow.handleSaveSettings when contentSafety.enabled changes
    func onSettingsChanged(enabled: Bool) {
        if enabled && !isEnabled {
            isEnabled = true
            start()
        } else if !enabled && isEnabled {
            isEnabled = false
            stop()
        }
    }

    /// Trigger a test detection — captures screen, blurs it, shows overlay.
    /// Skips the SensitiveContentAnalysis check. Used from dashboard "Test" button.
    func triggerTestDetection() {
        appDelegate?.postLog("🛡️ Content Safety: TEST detection triggered")
        Task { @MainActor in
            // Capture and blur
            guard let screenshot = captureAllScreens() else {
                appDelegate?.postLog("⚠️ Content Safety TEST: screenshot capture failed")
                return
            }
            let downscaled = downscale(screenshot, maxDimension: 1920)
            let blurredData = blurImage(downscaled, radius: 40)

            // Show overlay
            showBlockingOverlay()

            // Report to partner if we have blurred data
            if let data = blurredData {
                let emailSent = await reportToPartner(blurredImageData: data)
                logDetection(emailSent: emailSent)
                appDelegate?.postLog("🛡️ Content Safety TEST: overlay shown, emailSent=\(emailSent), blurSize=\(data.count) bytes")
            } else {
                logDetection(emailSent: false)
                appDelegate?.postLog("🛡️ Content Safety TEST: overlay shown, blur failed")
            }
        }
    }

    /// Begin monitoring (checks permission first)
    func start() {
        guard isEnabled else { return }

        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()

        // Check if Sensitive Content Warning is enabled in System Settings
        if !isAnalysisAvailable {
            appDelegate?.postLog("🛡️ Content Safety: Sensitive Content Warning not enabled in System Settings")
        }

        if hasScreenRecordingPermission {
            startPolling()
        } else {
            // Request permission (shows system dialog once)
            CGRequestScreenCaptureAccess()
            appDelegate?.postLog("🛡️ Content Safety: requesting Screen Recording permission")

            // Start checking for permission grant
            startPermissionCheckTimer()
        }

        // Always push status so dashboard shows current state
        pushPermissionStatus()
    }

    /// Stop monitoring
    func stop() {
        stopPolling()
        stopPermissionCheckTimer()
        dismissOverlay()
        isMonitoring = false
        appDelegate?.postLog("🛡️ Content Safety: stopped")
    }

    // MARK: - Sleep/Wake

    /// Called when computer sleeps — pause polling
    func onSleep() {
        guard isMonitoring else { return }
        stopPolling()
        appDelegate?.postLog("🛡️ Content Safety: paused (sleep)")
    }

    /// Called when computer wakes — resume polling
    func onWake() {
        guard isEnabled, hasScreenRecordingPermission else { return }
        startPolling()
        appDelegate?.postLog("🛡️ Content Safety: resumed (wake)")
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTimer == nil else { return }

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { await self?.pollAndAnalyze() }
        }
        isMonitoring = true
        appDelegate?.postLog("🛡️ Content Safety: monitoring active (every \(Int(pollInterval))s)")
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Permission Check

    private func startPermissionCheckTimer() {
        guard permissionCheckTimer == nil else { return }

        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: permissionCheckInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            if CGPreflightScreenCaptureAccess() {
                self.hasScreenRecordingPermission = true
                self.stopPermissionCheckTimer()
                self.startPolling()
                self.appDelegate?.postLog("🛡️ Content Safety: Screen Recording permission granted")
                // Notify dashboard of permission status change
                self.pushPermissionStatus()
            }
        }
    }

    private func stopPermissionCheckTimer() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    /// Push permission status to dashboard
    func pushPermissionStatus() {
        let status: [String: Any] = [
            "hasPermission": hasScreenRecordingPermission,
            "isMonitoring": isMonitoring,
            "isAnalysisAvailable": isAnalysisAvailable,
            "isEnabled": isEnabled
        ]
        DispatchQueue.main.async { [weak self] in
            self?.appDelegate?.mainWindowController?.pushContentSafetyStatus(status)
        }
    }

    // MARK: - Core Pipeline

    @MainActor
    private func pollAndAnalyze() async {
        // Skip if already analyzing (guard against concurrent runs)
        guard !isAnalyzing else { return }

        // Skip during grace period
        if let graceEnd = graceUntil, Date() < graceEnd { return }

        // Skip if overlay is currently showing
        guard overlayWindows.isEmpty else { return }

        isAnalyzing = true
        defer { isAnalyzing = false }

        // 1. Capture all screens
        guard let screenshot = captureAllScreens() else {
            appDelegate?.postLog("⚠️ Content Safety: screenshot capture failed")
            return
        }

        // 2. Downscale for memory efficiency
        let downscaled = downscale(screenshot, maxDimension: 1920)

        // 3. Classify
        let isSensitive = await analyzeImage(downscaled)

        guard isSensitive else { return }

        // 4. Detection! Blur the screenshot
        appDelegate?.postLog("🛡️ Content Safety: explicit content detected")

        guard let blurredData = blurImage(downscaled, radius: 40) else {
            appDelegate?.postLog("⚠️ Content Safety: blur failed")
            // Still show overlay even if blur fails
            showBlockingOverlay()
            logDetection(emailSent: false)
            return
        }

        // 5. Show blocking overlay on all screens
        showBlockingOverlay()

        // 6. Report to partner (respects email cooldown)
        let emailSent = await reportToPartner(blurredImageData: blurredData)

        // 7. Log locally
        logDetection(emailSent: emailSent)
    }

    // MARK: - Screenshot Capture

    /// Captures a composite image of all connected screens (all visible windows)
    private func captureAllScreens() -> CGImage? {
        return CGWindowListCreateImage(
            CGRect.null,              // all screens composited
            .optionOnScreenOnly,      // only visible windows
            kCGNullWindowID,          // no specific window
            [.bestResolution]
        )
    }

    // MARK: - Downscale

    /// Downscale image so the longest edge is at most `maxDimension` pixels.
    /// Uses CILanczosScaleTransform for GPU-accelerated high-quality downscaling.
    private func downscale(_ image: CGImage, maxDimension: Int) -> CGImage {
        let width = image.width
        let height = image.height
        let longestEdge = max(width, height)

        guard longestEdge > maxDimension else { return image }

        let scale = Double(maxDimension) / Double(longestEdge)

        let ciImage = CIImage(cgImage: image)

        guard let scaleFilter = CIFilter(name: "CILanczosScaleTransform") else { return image }
        scaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let outputImage = scaleFilter.outputImage else { return image }

        let outputRect = CGRect(origin: .zero, size: CGSize(
            width: Int(Double(width) * scale),
            height: Int(Double(height) * scale)
        ))

        guard let result = ciContext.createCGImage(outputImage, from: outputRect) else { return image }
        return result
    }

    // MARK: - SensitiveContentAnalysis

    /// Classifies an image using Apple's on-device SensitiveContentAnalysis framework.
    /// Returns true if the image is flagged as sensitive (explicit/nude content).
    /// Uses completion handler API wrapped in async continuation.
    private func analyzeImage(_ image: CGImage) async -> Bool {
        guard let analyzer = self.analyzer else {
            appDelegate?.postLog("⚠️ Content Safety: analyzer is nil")
            return false
        }

        // Log policy but don't bail — try analysis anyway (debug builds may report .disabled incorrectly)
        if analyzer.analysisPolicy == .disabled {
            appDelegate?.postLog("⚠️ Content Safety: analysisPolicy=disabled, attempting analysis anyway")
        }

        do {
            let result: SCSensitivityAnalysis = try await withCheckedThrowingContinuation { continuation in
                analyzer.analyzeImage(image) { analysis, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let analysis = analysis {
                        continuation.resume(returning: analysis)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "ContentSafetyMonitor",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No analysis result returned"]
                        ))
                    }
                }
            }
            if result.isSensitive {
                appDelegate?.postLog("🛡️ Content Safety: SENSITIVE content detected!")
            }
            return result.isSensitive
        } catch {
            appDelegate?.postLog("⚠️ Content Safety: analysis error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Blur

    /// Applies CIGaussianBlur to the image and returns PNG data.
    /// Radius 40 renders details as vague color blobs while preserving screen layout context.
    private func blurImage(_ image: CGImage, radius: Double) -> Data? {
        let ciImage = CIImage(cgImage: image)

        // Apply blur
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)

        guard let blurredImage = blurFilter.outputImage else { return nil }

        // Clamp to original extent (blur extends edges)
        let clampedImage = blurredImage.cropped(to: ciImage.extent)

        // Render to CGImage
        guard let cgResult = ciContext.createCGImage(clampedImage, from: ciImage.extent) else { return nil }

        // Convert to PNG data (compressed for email embedding)
        let bitmapRep = NSBitmapImageRep(cgImage: cgResult)

        // Use JPEG for smaller size (target <200KB for email)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) else {
            return nil
        }

        return jpegData
    }

    // MARK: - Blocking Overlay

    /// Shows a full-screen blocking overlay on ALL connected screens.
    private func showBlockingOverlay() {
        guard overlayWindows.isEmpty else { return }

        let viewModel = ContentSafetyOverlayViewModel()
        viewModel.onDismiss = { [weak self] in
            self?.dismissOverlay()
            // Start grace period — don't scan for 30s so user can close content
            self?.graceUntil = Date().addingTimeInterval(self?.gracePeriod ?? 30)
        }
        self.overlayViewModel = viewModel

        for screen in NSScreen.screens {
            let view = ContentSafetyOverlayView(viewModel: viewModel)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = screen.frame

            let window = KeyableWindow(
                contentRect: screen.frame,
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

            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }

        viewModel.startTimer()
        appDelegate?.postLog("🛡️ Content Safety: blocking overlay shown on \(NSScreen.screens.count) screen(s)")
    }

    /// Dismiss all overlay windows
    private func dismissOverlay() {
        for window in overlayWindows {
            window.close()
        }
        overlayWindows.removeAll()
        overlayViewModel = nil
    }

    var isShowingOverlay: Bool {
        !overlayWindows.isEmpty
    }

    // MARK: - Partner Report

    /// Sends blurred screenshot to accountability partner via backend.
    /// Returns true if email was sent, false if skipped (cooldown, no partner, error).
    private func reportToPartner(blurredImageData: Data) async -> Bool {
        // Check email cooldown
        if let lastEmail = lastEmailTime,
           Date().timeIntervalSince(lastEmail) < emailCooldown {
            appDelegate?.postLog("🛡️ Content Safety: email skipped (cooldown, \(Int(emailCooldown - Date().timeIntervalSince(lastEmail)))s remaining)")
            return false
        }

        guard let backendClient = appDelegate?.backendClient else {
            appDelegate?.postLog("⚠️ Content Safety: no backend client available")
            return false
        }

        let base64String = blurredImageData.base64EncodedString()
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let success = await backendClient.reportContentSafety(
            blurredImageBase64: base64String,
            timestamp: timestamp
        )

        if success {
            lastEmailTime = Date()
            appDelegate?.postLog("🛡️ Content Safety: report sent to partner")
        }

        return success
    }

    // MARK: - Local Logging

    /// Append detection event to content_safety_log.jsonl
    private func logDetection(emailSent: Bool) {
        let entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "emailSent": emailSent,
            "screenCount": NSScreen.screens.count
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else { return }

        let lineData = (line + "\n").data(using: .utf8)!

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(lineData)
                handle.closeFile()
            }
        } else {
            try? lineData.write(to: logFileURL)
        }
    }
}

// MARK: - Overlay View Model

class ContentSafetyOverlayViewModel: ObservableObject {

    @Published var timeRemaining: Int = 10
    @Published var canDismiss: Bool = false

    private var timer: Timer?
    var onDismiss: (() -> Void)?

    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.timeRemaining > 0 {
                self.timeRemaining -= 1
            }
            if self.timeRemaining <= 0 {
                self.canDismiss = true
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        onDismiss?()
    }
}

// MARK: - Overlay View

struct ContentSafetyOverlayView: View {

    @ObservedObject var viewModel: ContentSafetyOverlayViewModel

    var body: some View {
        ZStack {
            // Full-screen dark background
            Color.black.opacity(0.95)

            VStack(spacing: 24) {
                Spacer()

                // Shield icon
                Image(systemName: "shield.trianglebadge.exclamationmark.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.red)

                // Title
                Text("Explicit Content Detected")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                // Subtitle
                Text("Your accountability partner has been notified.")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.7))

                Spacer().frame(height: 20)

                // Countdown or dismiss button
                if viewModel.canDismiss {
                    Button(action: { viewModel.dismiss() }) {
                        Text("I Understand")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.red.opacity(0.8))
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("You can dismiss in \(viewModel.timeRemaining)s")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()
            }
        }
        .ignoresSafeArea()
    }
}

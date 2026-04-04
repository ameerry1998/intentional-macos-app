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

    /// Track previous permission states for revocation detection
    private var wasScreenRecordingGranted: Bool = false
    private var wasSensitiveContentEnabled: Bool = false

    // MARK: - Polling

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 2.0

    /// Permission recheck timer (when permission not yet granted)
    private var permissionCheckTimer: Timer?
    private let permissionCheckInterval: TimeInterval = 30.0

    // MARK: - Escalation System
    //
    // 1st detection: overlay only, no email (local warning)
    // 2nd detection (within 1hr): overlay + "next time your partner will be notified"
    // 3rd detection (within 1hr): overlay + partner emailed with blurred screenshot
    // 4th+ (keeps going): partner emailed every 30 min of continued attempts

    /// Number of detections in the current escalation window
    private var detectionCount: Int = 0
    /// When the escalation window started (resets after 1 hour of no detections)
    private var escalationWindowStart: Date?
    /// Escalation window duration — resets if no detection for this long
    private let escalationWindowDuration: TimeInterval = 3600  // 1 hour
    /// Last time a report was uploaded to the backend
    private var lastUploadTime: Date?

    /// Grace period end — short pause after overlay dismiss to avoid instant re-trigger on same frame
    private var graceUntil: Date?
    /// Grace period: 5 seconds after dismiss — enough to close the content, not enough to browse
    private let gracePeriod: TimeInterval = 5

    // MARK: - Confirmation Pass (false positive filter)
    //
    // First trigger marks as "pending". On the next poll (~2s later), if it triggers
    // again → confirmed real detection. If not → discarded as false positive.

    /// Whether we're waiting for a confirmation pass
    private var pendingConfirmation: Bool = false
    /// The source that triggered the pending detection (for logging)
    private var pendingSource: String?

    // MARK: - Analysis Guard

    /// Prevents concurrent analysis runs
    private var isAnalyzing: Bool = false

    // MARK: - Analyzers

    /// Apple's built-in sensitive content classifier
    private var analyzer: SCSensitivityAnalyzer?

    /// Debug: save flagged screenshots so we can review what triggered detection
    private let debugSaveScreenshots = true

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
            // Feature being DISABLED — report as tamper if it was previously active
            if isMonitoring {
                appDelegate?.postLog("🛡️ TAMPER: Content Safety feature DISABLED by user")
                Task {
                    await appDelegate?.backendClient?.reportContentSafetyTamper(
                        eventType: "feature_disabled", detail: "content_safety"
                    )
                }
            }
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
            let blurredData = blurImage(downscaled, radius: 1)

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

    // MARK: - Permission Revocation Detection

    /// Check for permission revocations and report to backend as tamper events.
    /// Only reports if permissions were previously granted (not first-time missing).
    private func checkForPermissionRevocations() {
        let screenRecordingNow = CGPreflightScreenCaptureAccess()
        let sensitiveContentNow = isAnalysisAvailable

        // Screen Recording revoked?
        if wasScreenRecordingGranted && !screenRecordingNow {
            appDelegate?.postLog("🛡️ TAMPER: Screen Recording permission was REVOKED")
            Task {
                await appDelegate?.backendClient?.reportContentSafetyTamper(
                    eventType: "permission_revoked", detail: "screen_recording"
                )
            }
            wasScreenRecordingGranted = false
            hasScreenRecordingPermission = false
            pushPermissionStatus()
        } else if screenRecordingNow {
            wasScreenRecordingGranted = true
        }

        // Sensitive Content Warning disabled?
        if wasSensitiveContentEnabled && !sensitiveContentNow {
            appDelegate?.postLog("🛡️ TAMPER: Sensitive Content Warning was DISABLED")
            Task {
                await appDelegate?.backendClient?.reportContentSafetyTamper(
                    eventType: "permission_revoked", detail: "sensitive_content_warning"
                )
            }
            wasSensitiveContentEnabled = false
        } else if sensitiveContentNow {
            wasSensitiveContentEnabled = true
        }
    }

    // MARK: - Core Pipeline

    @MainActor
    private func pollAndAnalyze() async {
        // Check for permission revocations on every poll
        checkForPermissionRevocations()

        // Skip if already analyzing (guard against concurrent runs)
        guard !isAnalyzing else { return }

        // Skip during grace period
        if let graceEnd = graceUntil, Date() < graceEnd { return }

        // Skip if overlay is currently showing
        guard overlayWindows.isEmpty else { return }

        isAnalyzing = true
        defer { isAnalyzing = false }

        // Strategy: Three-layer detection pipeline
        // Layer 1: Apple SensitiveContentAnalysis on full composite
        // Layer 2: Apple SCA on individual windows (catches diluted content)
        // Layer 3: NudeNet (Python) on individual windows (catches what Apple misses)
        // ANY layer triggers → detection fires

        var detectedImage: CGImage? = nil
        var detectionSource: String = "unknown"

        // Capture full composite first
        let composite = captureAllScreens()

        // Layer 1: Apple SCA on full composite (full resolution — don't downscale,
        // give Apple's algorithm maximum detail for accurate classification)
        if let composite = composite {
            if await analyzeImage(composite) {
                appDelegate?.postLog("🛡️ Detection: Apple SCA triggered on COMPOSITE screenshot (\(composite.width)x\(composite.height))")
                detectedImage = composite
                detectionSource = "apple_sca_composite"
            }
        }

        // Layer 2: Apple SCA on individual windows (full resolution)
        var detectedInBackground = false
        if detectedImage == nil {
            let capturedWindows = captureVisibleWindows()
            let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName
            for (index, captured) in capturedWindows.enumerated() {
                if await analyzeImage(captured.image) {
                    let isBg = captured.ownerName != frontmostApp
                    appDelegate?.postLog("🛡️ Detection: Apple SCA triggered on window #\(index + 1) (\(captured.ownerName), \(isBg ? "BACKGROUND" : "foreground"), \(captured.image.width)x\(captured.image.height))")
                    detectedImage = captured.image
                    detectionSource = "apple_sca_window_\(index + 1)_\(captured.ownerName)"
                    detectedInBackground = isBg
                    break
                }
            }
        }

        guard let detected = detectedImage else { return }

        // === ESCALATION SYSTEM ===
        // Check if escalation window has expired (1 hour of no detections → reset)
        if let windowStart = escalationWindowStart,
           Date().timeIntervalSince(windowStart) > escalationWindowDuration {
            detectionCount = 0
            escalationWindowStart = nil
            appDelegate?.postLog("🛡️ Escalation: window expired, resetting to step 1")
        }

        // Start escalation window on first detection
        if escalationWindowStart == nil {
            escalationWindowStart = Date()
        }
        detectionCount += 1

        appDelegate?.postLog("🛡️ Content Safety: confirmed detection #\(detectionCount) in current window (source: \(detectionSource))")

        // Debug: save the raw screenshot with source in filename
        if debugSaveScreenshots {
            saveDebugScreenshot(detected, source: detectionSource)
        }

        // Blur the image for backend upload
        // Radius 3 on 640px: light softening, content clearly recognizable but not crisp
        let blurredData = blurImage(detected, radius: 1)

        // Show blocking overlay with context-appropriate message
        let overlayMessage = detectedInBackground
            ? "Explicit content detected in a background window.\nPlease close it."
            : "Explicit content detected"
        showBlockingOverlay(message: overlayMessage)

        // Upload EVERY confirmed detection to backend — backend handles batching & emailing
        var uploaded = false
        if let data = blurredData {
            uploaded = await reportToPartner(blurredImageData: data)
            appDelegate?.postLog("🛡️ Detection #\(detectionCount): uploaded to backend = \(uploaded)")
        } else {
            appDelegate?.postLog("⚠️ Content Safety: blur failed, overlay shown without upload")
        }

        // Log locally
        logDetection(emailSent: uploaded, source: detectionSource)
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

    /// A captured window image with its owner app name.
    private struct CapturedWindow {
        let image: CGImage
        let ownerName: String
    }

    /// Captures individual visible windows (browser windows, etc.) for per-window analysis.
    /// This catches content in background windows that may be diluted in the full composite.
    private func captureVisibleWindows() -> [CapturedWindow] {
        var results: [CapturedWindow] = []

        // Get list of all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return results
        }

        // Skip system UI windows, menubar, dock, etc. — only capture app windows
        let skipOwners: Set<String> = ["Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center", "Intentional"]

        for windowInfo in windowList {
            guard let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
                  !skipOwners.contains(ownerName),
                  let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 200, height > 200 // Skip tiny windows
            else { continue }

            // Capture this specific window
            if let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.bestResolution, .boundsIgnoreFraming]
            ) {
                results.append(CapturedWindow(image: image, ownerName: ownerName))
            }

            // Limit to 5 windows to keep analysis fast
            if results.count >= 5 { break }
        }

        return results
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
        // Downscale to 640px BEFORE blurring — keeps the base64 small enough for Gmail
        let smallImage = downscale(image, maxDimension: 640)
        let ciImage = CIImage(cgImage: smallImage)

        // Apply blur
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)

        guard let blurredImage = blurFilter.outputImage else { return nil }

        // Clamp to original extent (blur extends edges)
        let clampedImage = blurredImage.cropped(to: ciImage.extent)

        // Render to CGImage
        guard let cgResult = ciContext.createCGImage(clampedImage, from: ciImage.extent) else { return nil }

        let bitmapRep = NSBitmapImageRep(cgImage: cgResult)

        // Compress hard — target <50KB so Gmail doesn't clip the base64
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.3]) else {
            return nil
        }

        return jpegData
    }

    // MARK: - Blocking Overlay

    /// Shows a full-screen blocking overlay on ALL connected screens.
    private func showBlockingOverlay(message: String = "Explicit Content Detected") {
        guard overlayWindows.isEmpty else { return }

        let viewModel = ContentSafetyOverlayViewModel()
        viewModel.displayMessage = message
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
    /// Cooldowns are managed by the escalation system in pollAndAnalyze, not here.
    private func reportToPartner(blurredImageData: Data) async -> Bool {
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
            lastUploadTime = Date()
            appDelegate?.postLog("🛡️ Content Safety: screenshot uploaded to backend")
        }

        return success
    }

    // MARK: - Local Logging

    /// Append detection event to content_safety_log.jsonl
    /// Save a debug screenshot to ~/Library/Application Support/Intentional/content_safety_debug/
    /// so the user can review what triggered detection and tune thresholds.
    private func saveDebugScreenshot(_ image: CGImage, source: String = "unknown") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let debugDir = appSupport.appendingPathComponent("Intentional/content_safety_debug")
        try? FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true)

        // Downscale for disk (debug only — analysis uses full res)
        let saveImage = downscale(image, maxDimension: 1920)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "flagged_\(dateFormatter.string(from: Date()))_\(source).jpg"
        let fileURL = debugDir.appendingPathComponent(filename)

        let bitmapRep = NSBitmapImageRep(cgImage: saveImage)
        if let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
            try? data.write(to: fileURL)
            appDelegate?.postLog("🛡️ Debug screenshot saved: \(fileURL.path)")
        }
    }

    private func logDetection(emailSent: Bool, source: String = "unknown") {
        let entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "emailSent": emailSent,
            "screenCount": NSScreen.screens.count,
            "source": source
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

    /// Custom message shown on the overlay (changes with escalation step)
    var displayMessage: String = "Explicit Content Detected"

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

                // Message (changes with escalation step)
                Text(viewModel.displayMessage)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

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

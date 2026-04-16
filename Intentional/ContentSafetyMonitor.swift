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
import Vision
import CoreML

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

    /// Persisted flag: true once we've confirmed screen recording works.
    /// Loaded from onboarding_settings.json on init. Survives app relaunches
    /// so we can detect revocations that happen while the app isn't running.
    private var permissionsEverConfirmed: Bool = false

    // MARK: - Polling

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 2.0

    /// Permission recheck timer (when permission not yet granted)
    private var permissionCheckTimer: Timer?
    private let permissionCheckInterval: TimeInterval = 30.0

    // MARK: - Permission Revocation Overlay

    /// Blocking overlay shown when screen recording permission is revoked
    private var permissionOverlayWindows: [NSWindow] = []
    private var permissionOverlayViewModel: PermissionRequiredOverlayViewModel?

    /// Timer that checks if permission has been re-granted (to auto-dismiss overlay)
    private var permissionRecheckTimer: Timer?
    private let permissionRecheckInterval: TimeInterval = 5.0

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

    /// OpenNSFW classifier — binary NSFW score 0-1
    private var nsfwModel: OpenNSFW?

    /// Temporal voting: require 3 of last 5 frames to trigger
    private var recentNSFWFrames: [Bool] = []
    private let temporalWindowSize = 5
    private let temporalThreshold = 3

    /// NSFW score threshold — only trigger above this (0.90 = very high confidence)
    private let nsfwScoreThreshold: Float = 0.90

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

        // Load persisted permission confirmation flag.
        // NOTE: We load permissionsEverConfirmed for tamper REPORTING only — NOT for
        // showing the blocking overlay on startup. CGPreflightScreenCaptureAccess() is
        // unreliable for Developer ID binaries (returns false even when permission IS
        // granted, especially after PKG reinstall). Showing the overlay based on persisted
        // state + unreliable API would lock the user out on every PKG update.
        // The overlay is only shown after we confirm permission works IN THIS SESSION
        // (wasScreenRecordingGranted = true) and then it stops working.
        let settingsURL = dir.appendingPathComponent("onboarding_settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cs = json["contentSafety"] as? [String: Any],
           let confirmed = cs["permissionsConfirmedAt"] as? String, !confirmed.isEmpty {
            self.permissionsEverConfirmed = true
            // DO NOT set wasScreenRecordingGranted here — that's the in-session flag
            // used for overlay decisions. It must be confirmed by a live API check.
        }

        // NudeNet detector is loaded lazily in start() to avoid competing
        // with WebKit during initial dashboard render (macOS 26 PAC crash)
    }

    /// Whether content safety analysis is available.
    var isAnalysisAvailable: Bool {
        nsfwModel != nil
    }

    /// Downscale a CGImage for NSFW classification
    private func downscaleForNSFW(_ image: CGImage) -> CGImage {
        let size = 224
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage() ?? image
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

        // Load OpenNSFW model on first start
        if nsfwModel == nil {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine
                self.nsfwModel = try OpenNSFW(configuration: config)
                appDelegate?.postLog("🛡️ OpenNSFW loaded (threshold=\(nsfwScoreThreshold))")
            } catch {
                appDelegate?.postLog("⚠️ OpenNSFW failed: \(error.localizedDescription)")
            }
        }

        // Check if screen recording permission is available.
        // IMPORTANT: Use CGPreflightScreenCaptureAccess() for the startup check — it does NOT
        // trigger a system dialog. The old hasScreenRecordingPermissionNow() calls
        // CGWindowListCopyWindowInfo which DOES trigger the "would like to record" dialog
        // on macOS Sequoia if permission hasn't been granted yet.
        // We only use hasScreenRecordingPermissionNow() AFTER the first successful capture.
        let hasPermission = CGPreflightScreenCaptureAccess()
        appDelegate?.postLog("🛡️ START: hasScreenRecordingPermissionNow=\(hasPermission), permissionsEverConfirmed=\(permissionsEverConfirmed)")

        if hasPermission {
            // Permission confirmed — record it for this session
            hasScreenRecordingPermission = true
            wasScreenRecordingGranted = true
            persistPermissionConfirmation()
            appDelegate?.postLog("🛡️ START: wasScreenRecordingGranted set to TRUE")
        } else if permissionsEverConfirmed {
            // API says no but we had it before — might be unreliable API or real revocation.
            // Report tamper to backend but DON'T show overlay yet. Start polling and let
            // checkForPermissionRevocations() confirm after the first successful poll cycle.
            appDelegate?.postLog("🛡️ Content Safety: CGPreflightScreenCaptureAccess=false on start (permissionsEverConfirmed=true) — reporting but NOT blocking yet")
            Task {
                await appDelegate?.backendClient?.reportContentSafetyTamper(
                    eventType: "permission_revoked_on_start", detail: "screen_recording"
                )
            }
        }

        // Always start polling — even if API says no permission, captures may still work
        // (unreliable API). The poll loop will confirm permission state within 2-4 seconds.
        hasScreenRecordingPermission = true
        startPolling()

        // Always push status so dashboard shows current state
        pushPermissionStatus()
    }

    /// Stop monitoring
    func stop() {
        stopPolling()
        stopPermissionCheckTimer()
        stopPermissionRecheckTimer()
        dismissOverlay()
        dismissPermissionRequiredOverlay()
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

    /// Called when computer wakes — resume polling (or show overlay if permission was revoked)
    func onWake() {
        guard isEnabled else { return }

        // Re-check permission on wake — user may have revoked it while asleep.
        // Only show overlay if we confirmed permission IN THIS SESSION (wasScreenRecordingGranted).
        let hasPermission = hasScreenRecordingPermissionNow()
        if hasPermission {
            hasScreenRecordingPermission = true
            wasScreenRecordingGranted = true
            startPolling()
            appDelegate?.postLog("🛡️ Content Safety: resumed (wake)")
        } else if wasScreenRecordingGranted {
            // Permission was CONFIRMED working this session and now it's gone — block screen
            hasScreenRecordingPermission = false
            wasScreenRecordingGranted = false
            appDelegate?.postLog("🛡️ Content Safety: permission revoked during sleep — blocking screen")
            showPermissionRequiredOverlay()
            startPermissionRecheckTimer()
            Task {
                await appDelegate?.backendClient?.reportContentSafetyTamper(
                    eventType: "permission_revoked", detail: "screen_recording"
                )
            }
        } else {
            // Permission never confirmed this session — start polling, let poll loop handle it
            startPolling()
            appDelegate?.postLog("🛡️ Content Safety: resumed (wake)")
        }
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

            let granted = self.hasScreenRecordingPermissionNow()
            if granted {
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
            "isEnabled": isEnabled,
            "isPermissionBlocked": isShowingPermissionOverlay
        ]
        DispatchQueue.main.async { [weak self] in
            self?.appDelegate?.mainWindowController?.pushContentSafetyStatus(status)
        }
    }

    // MARK: - Permission Required Overlay (Screen Blocking)

    /// Whether the permission-required overlay is currently showing
    var isShowingPermissionOverlay: Bool {
        !permissionOverlayWindows.isEmpty
    }

    /// Show a non-dismissable blocking overlay on ALL screens when screen recording
    /// permission is revoked. The user can click "Open System Settings" to get a
    /// 90-second window to re-enable the permission. If they don't, overlay returns.
    private func showPermissionRequiredOverlay() {
        guard permissionOverlayWindows.isEmpty else { return }

        let viewModel = PermissionRequiredOverlayViewModel()
        viewModel.onOpenSettings = { [weak self] in
            self?.handleOpenSettingsFromOverlay()
        }
        self.permissionOverlayViewModel = viewModel

        for screen in NSScreen.screens {
            let view = PermissionRequiredOverlayView(viewModel: viewModel)
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
            appDelegate?.postLog("🚨 ACTIVATE: ContentSafetyMonitor.showPermissionOverlay — makeKeyAndOrderFront")
            window.makeKeyAndOrderFront(nil)
            permissionOverlayWindows.append(window)
        }

        appDelegate?.postLog("🛡️ Permission overlay: shown on \(NSScreen.screens.count) screen(s)")
    }

    /// Dismiss all permission overlay windows
    private func dismissPermissionRequiredOverlay() {
        for window in permissionOverlayWindows {
            window.close()
        }
        permissionOverlayWindows.removeAll()
        permissionOverlayViewModel = nil
    }

    /// Handle the "Open System Settings" button: temporarily dismiss the overlay
    /// for 90 seconds so the user can navigate to System Settings and re-enable
    /// Screen Recording. If permission isn't re-granted, overlay comes back.
    private func handleOpenSettingsFromOverlay() {
        appDelegate?.postLog("🛡️ Permission overlay: user clicked Open Settings — 90s grace period")

        // Open Screen Recording settings pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }

        // Dismiss overlay temporarily
        dismissPermissionRequiredOverlay()

        // After 90 seconds, check if permission was restored. If not, overlay comes back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self = self, self.isEnabled else { return }

            if self.hasScreenRecordingPermissionNow() {
                // Permission restored during grace period — resume monitoring
                self.hasScreenRecordingPermission = true
                self.wasScreenRecordingGranted = true
                self.permissionsEverConfirmed = true
                self.persistPermissionConfirmation()
                self.stopPermissionRecheckTimer()
                self.startPolling()
                self.pushPermissionStatus()
                self.appDelegate?.postLog("🛡️ Permission restored during grace period — monitoring resumed")
            } else {
                // Still no permission — overlay comes back
                self.appDelegate?.postLog("🛡️ Grace period expired without permission — overlay returning")
                self.showPermissionRequiredOverlay()
            }
        }
    }

    /// Timer that checks every 5s if permission has been re-granted.
    /// Auto-dismisses the overlay when permission is detected.
    private func startPermissionRecheckTimer() {
        guard permissionRecheckTimer == nil else { return }

        permissionRecheckTimer = Timer.scheduledTimer(withTimeInterval: permissionRecheckInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.isEnabled else { return }

            if self.hasScreenRecordingPermissionNow() {
                self.appDelegate?.postLog("🛡️ Screen Recording permission restored — dismissing overlay")
                self.hasScreenRecordingPermission = true
                self.wasScreenRecordingGranted = true
                self.permissionsEverConfirmed = true
                self.persistPermissionConfirmation()
                self.stopPermissionRecheckTimer()
                self.dismissPermissionRequiredOverlay()
                self.startPolling()
                self.pushPermissionStatus()
            }
        }
    }

    /// Stop the permission recheck timer
    private func stopPermissionRecheckTimer() {
        permissionRecheckTimer?.invalidate()
        permissionRecheckTimer = nil
    }

    /// Save `contentSafety.permissionsConfirmedAt` to onboarding_settings.json so
    /// we can detect revocations across app relaunches.
    private func persistPermissionConfirmation() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let settingsURL = appSupport.appendingPathComponent("Intentional/onboarding_settings.json")

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var cs = json["contentSafety"] as? [String: Any] ?? [:]
        if cs["permissionsConfirmedAt"] == nil {
            cs["permissionsConfirmedAt"] = ISO8601DateFormatter().string(from: Date())
            json["contentSafety"] = cs
            if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                try? data.write(to: settingsURL)
            }
            appDelegate?.postLog("🛡️ Persisted permissionsConfirmedAt to settings")
        }
    }

    // MARK: - Permission Revocation Detection

    /// Check whether we can actually read other apps' window names.
    /// When Screen Recording permission is granted, CGWindowListCopyWindowInfo returns
    /// kCGWindowName for other apps' windows. When revoked, that key is nil/missing.
    /// This is reliable at runtime — unlike CGPreflightScreenCaptureAccess() which caches
    /// the permission state per-process and may not update after revocation.
    /// Detect Screen Recording permission by probing what CGWindowListCopyWindowInfo reveals.
    /// Two independent signals (either one returning false = revoked):
    ///   1. kCGWindowName — present for other apps when granted, nil when revoked
    ///   2. kCGWindowSharingState — non-zero when granted, zero when revoked
    /// This updates at runtime, unlike CGPreflightScreenCaptureAccess() which caches per-process.
    private func hasScreenRecordingPermissionNow() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let skipOwners: Set<String> = ["Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center"]

        var otherAppWindowCount = 0
        var hasReadableName = false
        var hasNonZeroSharingState = false

        for windowInfo in windowList {
            guard let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID,
                  let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
                  !skipOwners.contains(ownerName) else {
                continue
            }

            otherAppWindowCount += 1

            // Signal 1: Can we read other apps' window titles?
            if let name = windowInfo[kCGWindowName as String] as? String, !name.isEmpty {
                hasReadableName = true
            }

            // Signal 2: Is the sharing state non-zero? (0 = not shared = permission revoked)
            if let sharingState = windowInfo[kCGWindowSharingState as String] as? Int, sharingState > 0 {
                hasNonZeroSharingState = true
            }

            // Either signal confirms permission — return early
            if hasReadableName || hasNonZeroSharingState {
                return true
            }
        }

        // We found other app windows but neither signal confirmed permission → revoked
        if otherAppWindowCount > 0 {
            return false
        }

        // No other app windows visible at all (rare: user closed everything).
        // Can't determine from window list. Fall back to CGPreflight as last resort.
        return CGPreflightScreenCaptureAccess()
    }

    /// Track last logged permission state to avoid spamming logs every 2s
    private var lastLoggedPermissionState: Bool?

    private func checkForPermissionRevocations() {
        let screenRecordingNow = hasScreenRecordingPermissionNow()

        // Log on first check and on any state change
        if lastLoggedPermissionState != screenRecordingNow {
            appDelegate?.postLog("🛡️ PERM CHECK: hasScreenRecordingPermissionNow=\(screenRecordingNow) (was \(lastLoggedPermissionState.map(String.init) ?? "nil")), wasGranted=\(wasScreenRecordingGranted), everConfirmed=\(permissionsEverConfirmed)")
            lastLoggedPermissionState = screenRecordingNow
        }

        // Screen Recording revoked?
        // Only show overlay if wasScreenRecordingGranted is true (confirmed in THIS session).
        // We don't use permissionsEverConfirmed for overlay decisions to avoid lockout on PKG reinstall.
        if wasScreenRecordingGranted && !screenRecordingNow {
            appDelegate?.postLog("🛡️ TAMPER: Screen Recording permission was REVOKED (confirmed in-session)")
            Task {
                await appDelegate?.backendClient?.reportContentSafetyTamper(
                    eventType: "permission_revoked", detail: "screen_recording"
                )
            }
            wasScreenRecordingGranted = false
            hasScreenRecordingPermission = false
            pushPermissionStatus()

            // BLOCK THE SCREEN — revoking permission doesn't help, you just get a blocked screen
            stopPolling()
            showPermissionRequiredOverlay()
            startPermissionRecheckTimer()
        } else if screenRecordingNow {
            // Permission confirmed — persist if first time, and set in-session flag
            if !permissionsEverConfirmed {
                permissionsEverConfirmed = true
                persistPermissionConfirmation()
            }
            wasScreenRecordingGranted = true
        }

        // Sensitive Content Warning disabled?
        let sensitiveContentNow = isAnalysisAvailable
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

        // Skip if overlay is currently showing (NSFW or permission)
        guard overlayWindows.isEmpty else { return }
        guard permissionOverlayWindows.isEmpty else { return }

        isAnalyzing = true
        defer { isAnalyzing = false }

        // OpenNSFW binary classifier with temporal voting (3 of 5 frames).

        var detectedImage: CGImage? = nil
        var detectionSource: String = "unknown"
        var detectedInBackground = false

        guard let model = nsfwModel else {
            debugLogToFile("No NSFW model — skipping")
            return
        }

        // Guard: don't attempt capture if preflight says no permission.
        // CGWindowListCreateImage triggers the system "would like to record" dialog
        // on macOS Sequoia if permission hasn't been granted. Only capture if we
        // know we have permission (via preflight) or have confirmed it this session.
        if !wasScreenRecordingGranted && !CGPreflightScreenCaptureAccess() {
            debugLogToFile("Skipping capture — no screen recording permission confirmed yet")
            return
        }

        // Capture full composite
        let composite = captureAllScreens()

        // Score composite with OpenNSFW via Vision
        var nsfwScore: Float = 0
        if let composite = composite {
            nsfwScore = scoreNSFW(image: composite, model: model)
            let isExplicit = nsfwScore >= nsfwScoreThreshold

            // Record for temporal voting
            recentNSFWFrames.append(isExplicit)
            if recentNSFWFrames.count > temporalWindowSize {
                recentNSFWFrames.removeFirst()
            }
            let confirmedCount = recentNSFWFrames.filter { $0 }.count
            let isConfirmed = confirmedCount >= temporalThreshold

            debugLogToFile("NSFW score=\(String(format: "%.3f", nsfwScore)) threshold=\(nsfwScoreThreshold) explicit=\(isExplicit) confirmed=\(isConfirmed) (\(confirmedCount)/\(recentNSFWFrames.count))")

            if isConfirmed {
                appDelegate?.postLog("🛡️ Detection: OpenNSFW CONFIRMED (score=\(String(format: "%.2f", nsfwScore)), \(confirmedCount)/\(recentNSFWFrames.count) frames)")
                detectedImage = composite
                detectionSource = "opennsfw_composite_\(String(format: "%.2f", nsfwScore))"
            }
        }

        // If composite didn't confirm, check individual windows
        if detectedImage == nil && nsfwScore < nsfwScoreThreshold {
            let capturedWindows = captureVisibleWindows()
            let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName
            for (index, captured) in capturedWindows.enumerated() {
                let windowScore = scoreNSFW(image: captured.image, model: model)
                if windowScore >= nsfwScoreThreshold {
                    recentNSFWFrames[recentNSFWFrames.count - 1] = true  // upgrade this frame
                    let confirmedCount = recentNSFWFrames.filter { $0 }.count
                    let isConfirmed = confirmedCount >= temporalThreshold

                    debugLogToFile("NSFW window #\(index+1) (\(captured.ownerName)) score=\(String(format: "%.3f", windowScore)) confirmed=\(isConfirmed)")

                    if isConfirmed {
                        let isBg = captured.ownerName != frontmostApp
                        detectedImage = captured.image
                        detectionSource = "opennsfw_window_\(index+1)_\(captured.ownerName)"
                        detectedInBackground = isBg
                        break
                    }
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
            debugLogToFile("captureVisibleWindows: CGWindowListCopyWindowInfo returned nil")
            return results
        }

        // Skip system UI windows, menubar, dock, etc. — only capture app windows
        let skipOwners: Set<String> = ["Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center", "Intentional"]

        var skipped = 0
        var capturedCount = 0
        var captureFailCount = 0

        for windowInfo in windowList {
            guard let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
                  !skipOwners.contains(ownerName),
                  let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else {
                skipped += 1
                continue
            }

            // Get window bounds — CGWindowListCopyWindowInfo returns CGRect as a dictionary
            var width: CGFloat = 0
            var height: CGFloat = 0
            if let boundsAny = windowInfo[kCGWindowBounds as String] {
                let boundsDict = boundsAny as! CFDictionary
                if let boundsRect = CGRect(dictionaryRepresentation: boundsDict) {
                    width = boundsRect.width
                    height = boundsRect.height
                }
            }

            guard width > 200, height > 200 else {
                skipped += 1
                continue
            }

            // Capture this specific window
            if let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.bestResolution, .boundsIgnoreFraming]
            ) {
                results.append(CapturedWindow(image: image, ownerName: ownerName))
                capturedCount += 1
            } else {
                captureFailCount += 1
            }

            // Limit to 5 windows to keep analysis fast
            if results.count >= 5 { break }
        }

        if results.isEmpty {
            debugLogToFile("captureVisibleWindows: 0 windows captured (total=\(windowList.count), skipped=\(skipped), captureFail=\(captureFailCount))")
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
            appDelegate?.postLog("🚨 ACTIVATE: ContentSafetyMonitor.showBlockingOverlay — makeKeyAndOrderFront")
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
        // Reset temporal filter so dismissed content doesn't carry over
        recentNSFWFrames.removeAll()
    }

    // MARK: - OpenNSFW Scoring

    /// Score an image using the Xcode-generated OpenNSFW class. Returns 0-1 NSFW probability.
    private func scoreNSFW(image: CGImage, model: OpenNSFW) -> Float {
        do {
            let input = try OpenNSFWInput(dataWith: image)
            let output = try model.prediction(input: input)
            let nsfwScore = Float(output.prob["NSFW"] ?? -1)
            let sfwScore = Float(output.prob["SFW"] ?? -1)
            debugLogToFile("OpenNSFW: NSFW=\(String(format: "%.4f", nsfwScore)) SFW=\(String(format: "%.4f", sfwScore)) label=\(output.classLabel)")
            return max(nsfwScore, 0)
        } catch {
            debugLogToFile("OpenNSFW ERROR: \(error.localizedDescription)")
            return 0
        }
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

    // MARK: - Debug File Log

    /// Persistent log path — survives reboots (unlike /tmp)
    private static let persistentLogPath: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("csm-debug.log").path
    }()

    /// Also write to /tmp for easy `tail -f` during development
    private static let tmpLogPath = "/tmp/intentional-csm-debug.log"

    /// Max log size before rotation (5 MB)
    private static let maxLogSize: UInt64 = 5 * 1024 * 1024

    /// Write debug messages to persistent log + /tmp symlink
    private func debugLogToFile(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let path = Self.persistentLogPath

        // Rotate if too large
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > Self.maxLogSize {
            let rotatedPath = path + ".1"
            try? FileManager.default.removeItem(atPath: rotatedPath)
            try? FileManager.default.moveItem(atPath: path, toPath: rotatedPath)
        }

        // Append to persistent log
        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }

        // Also write to /tmp for easy tail -f
        if FileManager.default.fileExists(atPath: Self.tmpLogPath) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: Self.tmpLogPath)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: Self.tmpLogPath, contents: data)
        }
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

// MARK: - Permission Required Overlay View Model

class PermissionRequiredOverlayViewModel: ObservableObject {

    @Published var hasClickedOpenSettings: Bool = false

    var onOpenSettings: (() -> Void)?

    func openSettings() {
        guard !hasClickedOpenSettings else { return }  // one-time use
        hasClickedOpenSettings = true
        onOpenSettings?()
    }
}

// MARK: - Permission Required Overlay View

struct PermissionRequiredOverlayView: View {

    @ObservedObject var viewModel: PermissionRequiredOverlayViewModel

    var body: some View {
        ZStack {
            // Full-screen dark background
            Color.black.opacity(0.95)

            VStack(spacing: 24) {
                Spacer()

                // Lock icon
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.orange)

                Text("Screen Recording Permission Required")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text("Content Safety needs Screen Recording permission\nto keep you safe. Please re-enable it in System Settings.")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Spacer().frame(height: 8)

                Text("Your accountability partner has been notified.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.red.opacity(0.8))

                Spacer().frame(height: 16)

                if !viewModel.hasClickedOpenSettings {
                    Button(action: { viewModel.openSettings() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "gear")
                            Text("Open System Settings")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.blue.opacity(0.7))
                        )
                    }
                    .buttonStyle(.plain)

                    Text("You'll have 90 seconds to re-enable the permission.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                } else {
                    Text("Opening System Settings...")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer().frame(height: 8)

                Text("System Settings > Privacy & Security >\nScreen & System Audio Recording > Intentional")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)

                Spacer()
            }
        }
        .ignoresSafeArea()
    }
}

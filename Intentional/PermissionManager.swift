//
//  PermissionManager.swift
//  Intentional
//
//  Manages and checks required system permissions
//

import Foundation
import Cocoa
import UserNotifications

class PermissionManager: NSObject {

    private weak var appDelegate: AppDelegate?
    private var permissionCheckTimer: Timer?

    // Permission status
    struct PermissionStatus {
        var accessibility: Bool = false
        var notifications: Bool = false
        var screenRecording: Bool = false
        var sensitiveContentWarning: Bool = false
        var appleEvents: [String: Bool] = [:] // bundleID -> granted
    }

    /// Track whether content safety permissions were previously fully granted (for revocation detection)
    private var contentSafetyWasFullyGranted: Bool = false

    private(set) var status = PermissionStatus()

    // Known browsers to check permissions for (only if installed)
    private let knownBrowserBundleIds = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser"
    ]

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    // MARK: - Start Monitoring

    func startMonitoring() {
        // Check immediately
        checkAllPermissions()

        // Check accessibility silently — NEVER auto-prompt.
        // The system dialog is disruptive and confusing on every launch.
        // If missing, we log it and show status in the UI. User can grant manually.
        if !AXIsProcessTrusted() {
            appDelegate?.postLog("⚠️ Accessibility permission not granted — features like the red-shift screen tint and AppleScript require it")
        }

        // Check every 30 seconds
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkAllPermissions()
        }

        // Also check when app becomes active (user returns from System Settings)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAllPermissions()
        }

        appDelegate?.postLog("✅ Permission monitoring started")
    }

    func stopMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    // MARK: - Permission Checking

    func checkAllPermissions() {
        checkAccessibilityPermission()
        checkNotificationPermissions()
        checkAppleEventsPermissions()
        checkContentSafetyPermissions()

        // Post notification about permission status
        postPermissionStatusUpdate()
    }

    private func postPermissionStatusUpdate() {
        let missing = getMissingPermissions()
        NotificationCenter.default.post(
            name: NSNotification.Name("PermissionStatusUpdated"),
            object: nil,
            userInfo: ["missing": missing]
        )
    }

    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        let changed = status.accessibility != trusted
        status.accessibility = trusted

        if changed {
            if trusted {
                appDelegate?.postLog("✅ Accessibility permission granted")
            } else {
                appDelegate?.postLog("⚠️ Accessibility permission missing — red-shift screen tint and AppleScript will not work")
            }
        }
    }

    // MARK: - Content Safety Permissions

    /// Check Screen Recording + Sensitive Content Warning permissions.
    /// Detects revocation and notifies partner if content safety was previously active.
    private func checkContentSafetyPermissions() {
        let hasScreenRecording = CGPreflightScreenCaptureAccess()
        let hasSensitiveContent = appDelegate?.contentSafetyMonitor?.isAnalysisAvailable ?? false
        let contentSafetyEnabled = appDelegate?.contentSafetyMonitor?.isEnabled ?? false

        let prevScreen = status.screenRecording
        let prevSensitive = status.sensitiveContentWarning

        status.screenRecording = hasScreenRecording
        status.sensitiveContentWarning = hasSensitiveContent

        // Check if both permissions are now granted (for tracking revocation)
        let fullyGranted = hasScreenRecording && hasSensitiveContent && contentSafetyEnabled
        if fullyGranted && !contentSafetyWasFullyGranted {
            contentSafetyWasFullyGranted = true
            appDelegate?.postLog("🛡️ Content Safety: all permissions granted")
        }

        // Detect revocation: was fully granted, now something is missing
        if contentSafetyWasFullyGranted && contentSafetyEnabled {
            if prevScreen && !hasScreenRecording {
                appDelegate?.postLog("🛡️ TAMPER: Screen Recording permission REVOKED")
                Task {
                    await appDelegate?.backendClient?.reportContentSafetyTamper(
                        eventType: "permission_revoked", detail: "screen_recording"
                    )
                }
            }
            if prevSensitive && !hasSensitiveContent {
                appDelegate?.postLog("🛡️ TAMPER: Sensitive Content Warning DISABLED")
                Task {
                    await appDelegate?.backendClient?.reportContentSafetyTamper(
                        eventType: "permission_revoked", detail: "sensitive_content_warning"
                    )
                }
            }
        }

        // Push updated status to dashboard
        appDelegate?.contentSafetyMonitor?.pushPermissionStatus()
    }

    /// Prompt the user to grant Accessibility permission. Opens System Settings with the prompt.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func checkNotificationPermissions() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { [weak self] in
                self?.status.notifications = settings.authorizationStatus == .authorized
            }
        }
    }

    private func checkAppleEventsPermissions() {
        // Only check permissions for browsers that are CURRENTLY RUNNING
        // Sending an AppleEvent to a non-running app causes macOS to LAUNCH it
        let installedBrowsers = getInstalledBrowsers()
        let runningApps = NSWorkspace.shared.runningApplications
        let runningBundleIds = Set(runningApps.compactMap { $0.bundleIdentifier })

        for bundleId in installedBrowsers {
            guard runningBundleIds.contains(bundleId) else {
                // Skip — don't want to accidentally launch the browser
                continue
            }

            let hasPermission = checkAppleEventsPermission(for: bundleId)
            let changed = status.appleEvents[bundleId] != hasPermission
            status.appleEvents[bundleId] = hasPermission

            // Only log on state change
            if changed {
                let browserName = getBrowserName(for: bundleId)
                if hasPermission {
                    appDelegate?.postLog("✅ AppleEvents permission granted for \(browserName)")
                } else {
                    appDelegate?.postLog("⚠️ AppleEvents permission missing for \(browserName)")
                }
            }
        }
    }

    private func checkAppleEventsPermission(for bundleId: String) -> Bool {
        // Use AEDeterminePermissionToAutomateTarget to check permission SILENTLY.
        // This does NOT trigger any system dialog — it just returns the current state.
        // The old approach (executing AppleScript) would trigger the "wants to control" dialog.
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return false
        }

        var addressDesc = AEAddressDesc()
        let bundleIDData = bundleId.data(using: .utf8)!
        let _ = bundleIDData.withUnsafeBytes { ptr in
            AECreateDesc(
                keyAddressAttr,
                ptr.baseAddress!,
                bundleIDData.count,
                &addressDesc
            )
        }
        defer { AEDisposeDesc(&addressDesc) }

        let result = AEDeterminePermissionToAutomateTarget(
            &addressDesc,
            typeWildCard,
            typeWildCard,
            false  // false = don't prompt, just check
        )

        // 0 = permitted, -1744 = not permitted, -600 = app not running (treat as unknown/ok)
        return result == 0 || result == -600
    }

    // MARK: - Get Installed Browsers

    func getInstalledBrowsers() -> [String] {
        var installed: [String] = []

        for bundleId in knownBrowserBundleIds {
            if isApplicationInstalled(bundleId: bundleId) {
                installed.append(bundleId)
            }
        }

        return installed
    }

    private func isApplicationInstalled(bundleId: String) -> Bool {
        // Use NSWorkspace to find the app path
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return false
        }

        // Verify the app actually exists at that path
        return FileManager.default.fileExists(atPath: appURL.path)
    }

    // MARK: - Get Missing Permissions

    func getMissingPermissions() -> [String] {
        var missing: [String] = []

        if !status.accessibility {
            missing.append("Accessibility")
        }

        if !status.notifications {
            missing.append("Notifications")
        }

        let installedBrowsers = getInstalledBrowsers()
        for bundleId in installedBrowsers {
            if status.appleEvents[bundleId] != true {
                let browserName = getBrowserName(for: bundleId)
                missing.append("AppleEvents for \(browserName)")
            }
        }

        return missing
    }

    private func getBrowserName(for bundleId: String) -> String {
        let names = [
            "com.google.Chrome": "Chrome",
            "com.apple.Safari": "Safari",
            "org.mozilla.firefox": "Firefox",
            "com.microsoft.edgemac": "Edge",
            "com.brave.Browser": "Brave",
            "company.thebrowser.Browser": "Arc"
        ]
        return names[bundleId] ?? bundleId
    }

    // MARK: - Request Permissions

    func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                self.appDelegate?.postLog("✅ Notification permissions granted")
            } else if let error = error {
                self.appDelegate?.postLog("❌ Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    func openSystemPreferences() {
        // Open System Settings to Privacy & Security
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    deinit {
        stopMonitoring()
    }
}

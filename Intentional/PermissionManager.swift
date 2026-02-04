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
        var notifications: Bool = false
        var appleEvents: [String: Bool] = [:] // bundleID -> granted
    }

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
        checkNotificationPermissions()
        checkAppleEventsPermissions()

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

    private func checkNotificationPermissions() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { [weak self] in
                self?.status.notifications = settings.authorizationStatus == .authorized
            }
        }
    }

    private func checkAppleEventsPermissions() {
        // Only check permissions for installed browsers
        let installedBrowsers = getInstalledBrowsers()

        for bundleId in installedBrowsers {
            let hasPermission = checkAppleEventsPermission(for: bundleId)
            status.appleEvents[bundleId] = hasPermission

            let browserName = getBrowserName(for: bundleId)
            if hasPermission {
                appDelegate?.postLog("✅ AppleEvents permission granted for \(browserName)")
            } else {
                appDelegate?.postLog("⚠️ AppleEvents permission missing for \(browserName)")
            }
        }
    }

    private func checkAppleEventsPermission(for bundleId: String) -> Bool {
        // Get the app path
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return false
        }

        // Try to execute a simple AppleScript that doesn't require the app to be running
        let appPath = appURL.path
        let testScript = """
        tell application "\(appPath)"
            if it is running then
                return true
            else
                return false
            end if
        end tell
        """

        guard let appleScript = NSAppleScript(source: testScript) else {
            return false
        }

        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)

        // If there's no error, we have permission
        // If there's an error code -1743, it means permission denied
        if let errorDict = error {
            if let errorNumber = errorDict["NSAppleScriptErrorNumber"] as? Int {
                return errorNumber != -1743 && errorNumber != -1728
            }
            return false
        }

        return true
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

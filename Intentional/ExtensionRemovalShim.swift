// EXTENSION-REMOVAL-TODO: temporary shim. Stub types so the build compiles
// while subsequent dispatches strip the remaining callers (MainWindow,
// AppDelegate, FocusMonitor, WebsiteBlocker, EarnedBrowseManager,
// BrowserMonitor, LegacyMonitorView).
// Delete this file once every caller is gone (final dispatch).

import Foundation

// MARK: - SocketRelayServer (deleted)

final class SocketRelayServer {
    init() {}
    init(appDelegate: AppDelegate) {}

    @discardableResult
    func start() -> Bool { false }
    func stop() {}

    /// Live connection count. Always 0 in shim.
    var connectionCount: Int { 0 }

    // Targeted broadcasts. All no-ops in shim.
    func broadcastScheduleSync() {}
    func broadcastEarnedMinutesUpdate(_ manager: EarnedBrowseManager) {}
    func broadcastSessionSync() {}
    func broadcastFocusModeUpdate() {}
    func broadcastHideFocusOverlay() {}
    func broadcastMuteBackgroundTab(platform: String) {}

    /// Generic typed broadcast (settings sync, onboarding sync, reset, lock sync, …).
    func broadcastToAll(_ message: [String: Any]) {}

    /// Connected browser bundle ids — used by FocusMonitor + BrowserMonitor.
    /// Empty in shim — no extensions are connected because the extension is gone.
    func getConnectedBrowserBundleIds() -> [String] { [] }
}

// MARK: - NativeMessagingHost (deleted)

final class NativeMessagingHost {
    init() {}
    init(appDelegate: AppDelegate) {}

    // Properties wired by AppDelegate's init path. Writable so existing
    // assignments compile until the AppDelegate strip dispatch removes them.
    var timeTracker: TimeTracker?
    var scheduleManager: ScheduleManager?
    var relevanceScorer: RelevanceScorer?
    var earnedBrowseManager: EarnedBrowseManager?

    func start() {}
    func stop() {}
}

// MARK: - NativeMessagingSetup (deleted)

final class NativeMessagingSetup {
    static let shared = NativeMessagingSetup()
    private init() {}

    /// Treated as "we've never scanned, but also never will" — callers should
    /// fall through their `hasCompletedInitialScan == false` waiting branch
    /// immediately. We set this to `true` so BrowserMonitor doesn't sit in a
    /// permanent wait state.
    var hasCompletedInitialScan: Bool { true }
    var initialScanCompletedAt: Date? { nil }

    /// Return how many extensions were discovered. Always 0 in shim.
    @discardableResult
    func autoDiscoverExtensions() -> Int { 0 }

    func installManifestsIfNeeded() {}

    /// All extension ids registered with the host. Empty in shim.
    func getAllExtensionIds() -> [String] { [] }

    /// Extension ids registered specifically (LegacyMonitorView UI).
    func getRegisteredIds() -> [String] { [] }

    /// Per-browser status snapshot. Empty in shim — no browsers managed.
    func getBrowserStatus() -> [BrowserExtensionStatus] { [] }

    /// User clicked "Open extensions page" for a specific bundle id. No-op.
    func openExtensionsPage(bundleId: String) {}

    /// Manual extension-id registration (LegacyMonitorView UI). Always reports
    /// failure in the shim so the UI shows "couldn't register" instead of a
    /// fake success.
    @discardableResult
    func registerExtensionId(_ id: String) -> Bool { false }
}

// MARK: - BrowserExtensionStatus (deleted)

/// Snapshot of an installed browser + its extension state. All fields zeroed
/// out in shim because no extension surface exists.
struct BrowserExtensionStatus: Identifiable {
    let id: String
    let name: String
    let bundleId: String
    let extensionId: String?
    let hasExtension: Bool
    let isEnabled: Bool
    let lastDetected: Date
    let extensionPageUrl: String
}

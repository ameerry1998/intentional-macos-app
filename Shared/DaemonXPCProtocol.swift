//
//  DaemonXPCProtocol.swift
//  Shared between Intentional app and IntentionalDaemon
//
//  Defines the XPC interface the GUI app uses to communicate with the root daemon.
//  The daemon is the source of truth for strict mode, partner lock state, and config.
//

import Foundation

/// Mach service name registered by the daemon's LaunchDaemon plist.
let kDaemonMachServiceName = "com.intentional.daemon.xpc"

/// XPC protocol: app → daemon requests.
@objc protocol DaemonXPCProtocol {

    /// Query whether strict mode (app persistence) is currently enabled.
    func isStrictModeEnabled(reply: @escaping (Bool) -> Void)

    /// Enable or disable strict mode.
    /// The daemon enforces rules: strict mode can only be disabled if partner lock is off
    /// or a valid unlock token has been provided.
    /// Reply: (success, errorMessage)
    func setStrictMode(enabled: Bool, reply: @escaping (Bool, String?) -> Void)

    /// Update the partner lock state. Called by the app when lock mode changes.
    /// The daemon stores this in its root-owned config so the app can't fake it.
    func updatePartnerLockState(isLocked: Bool, partnerEmail: String?, deviceId: String?, reply: @escaping (Bool) -> Void)

    /// Verify an uninstall/disable code. The app or uninstaller passes a code
    /// that the daemon verifies against the backend.
    /// Reply: (success)
    func verifyUnlockCode(_ code: String, reply: @escaping (Bool) -> Void)

    /// Report that the app is alive. Called periodically by the app so the daemon
    /// knows the app is running (in addition to process monitoring).
    func appHeartbeat(reply: @escaping (Bool) -> Void)

    /// Get the full daemon config (for the app to sync state on launch).
    /// Reply: JSON data of the config.
    func getConfig(reply: @escaping (Data?) -> Void)
}

//
//  DaemonXPCClient.swift
//  Intentional
//
//  XPC client for communicating with the root daemon (syspolicyd_helper).
//  Provides graceful degradation: if the daemon isn't running (e.g., during
//  development or DMG install), falls back to UserDefaults for strict mode state.
//

import Foundation

class DaemonXPCClient {

    private var connection: NSXPCConnection?
    private var isConnected = false

    /// Whether the daemon is available (PKG installed and daemon running).
    var isDaemonAvailable: Bool { isConnected }

    // MARK: - Connection

    /// Establish connection to the daemon. Call once on app launch.
    func connect() {
        let conn = NSXPCConnection(machServiceName: kDaemonMachServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: DaemonXPCProtocol.self)

        conn.invalidationHandler = { [weak self] in
            self?.isConnected = false
            self?.connection = nil
            NSLog("[DaemonXPC] Connection invalidated — daemon may not be running")
        }

        conn.interruptionHandler = { [weak self] in
            self?.isConnected = false
            NSLog("[DaemonXPC] Connection interrupted — will retry on next call")
        }

        conn.resume()
        self.connection = conn
        self.isConnected = true
        NSLog("[DaemonXPC] Connection established to \(kDaemonMachServiceName)")
    }

    /// Get the proxy object for making XPC calls.
    private var proxy: DaemonXPCProtocol? {
        guard let conn = connection else {
            // Try to reconnect
            connect()
            guard let conn = connection else { return nil }
            return conn.remoteObjectProxyWithErrorHandler { error in
                NSLog("[DaemonXPC] Proxy error: \(error.localizedDescription)")
            } as? DaemonXPCProtocol
        }
        return conn.remoteObjectProxyWithErrorHandler { error in
            NSLog("[DaemonXPC] Proxy error: \(error.localizedDescription)")
        } as? DaemonXPCProtocol
    }

    // MARK: - Strict Mode (with fallback)

    /// Check if strict mode is enabled.
    /// Tries daemon first, falls back to UserDefaults.
    func isStrictModeEnabled(completion: @escaping (Bool) -> Void) {
        guard let proxy = proxy else {
            // Daemon not available — fall back to UserDefaults
            let fallback = UserDefaults.standard.bool(forKey: "strictModeEnabled")
            NSLog("[DaemonXPC] Daemon unavailable, using UserDefaults: strictMode=\(fallback)")
            completion(fallback)
            return
        }

        proxy.isStrictModeEnabled { enabled in
            NSLog("[DaemonXPC] Daemon reports strictMode=\(enabled)")
            completion(enabled)
        }
    }

    /// Synchronous check — tries daemon, falls back to UserDefaults.
    /// Use sparingly (blocks the calling thread briefly).
    func isStrictModeEnabledSync() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = UserDefaults.standard.bool(forKey: "strictModeEnabled")

        guard let proxy = proxy else { return result }

        proxy.isStrictModeEnabled { enabled in
            result = enabled
            semaphore.signal()
        }

        // Wait up to 500ms for daemon response
        let timeout = semaphore.wait(timeout: .now() + 0.5)
        if timeout == .timedOut {
            NSLog("[DaemonXPC] Timeout waiting for daemon — using UserDefaults fallback")
            return UserDefaults.standard.bool(forKey: "strictModeEnabled")
        }

        return result
    }

    /// Set strict mode. Tries daemon first, falls back to UserDefaults.
    func setStrictMode(enabled: Bool, completion: @escaping (Bool, String?) -> Void) {
        // Always update UserDefaults as fallback/cache
        UserDefaults.standard.set(enabled, forKey: "strictModeEnabled")

        guard let proxy = proxy else {
            NSLog("[DaemonXPC] Daemon unavailable, saved to UserDefaults only")
            completion(true, nil)
            return
        }

        proxy.setStrictMode(enabled: enabled) { success, error in
            NSLog("[DaemonXPC] setStrictMode(\(enabled)): success=\(success), error=\(error ?? "nil")")
            completion(success, error)
        }
    }

    // MARK: - Partner Lock State

    /// Sync partner lock state to daemon.
    func updatePartnerLockState(isLocked: Bool, partnerEmail: String?, deviceId: String?) {
        guard let proxy = proxy else {
            NSLog("[DaemonXPC] Daemon unavailable — cannot sync partner lock state")
            return
        }

        proxy.updatePartnerLockState(isLocked: isLocked, partnerEmail: partnerEmail, deviceId: deviceId) { success in
            NSLog("[DaemonXPC] updatePartnerLockState: locked=\(isLocked), success=\(success)")
        }
    }

    // MARK: - Unlock Code

    /// Verify an unlock code via the daemon (daemon checks with backend).
    func verifyUnlockCode(_ code: String, completion: @escaping (Bool) -> Void) {
        guard let proxy = proxy else {
            NSLog("[DaemonXPC] Daemon unavailable — cannot verify unlock code")
            completion(false)
            return
        }

        proxy.verifyUnlockCode(code) { valid in
            NSLog("[DaemonXPC] verifyUnlockCode: valid=\(valid)")
            completion(valid)
        }
    }

    // MARK: - App Heartbeat

    /// Send a heartbeat to the daemon so it knows the app is alive.
    func sendHeartbeat() {
        proxy?.appHeartbeat { _ in }
    }

    // MARK: - Config

    /// Get the full daemon config.
    func getConfig(completion: @escaping (Data?) -> Void) {
        guard let proxy = proxy else {
            completion(nil)
            return
        }
        proxy.getConfig { data in
            completion(data)
        }
    }
}

//
//  main.swift
//  syspolicyd_helper
//
//  Root-level daemon that provides tamper-resistant app persistence.
//  Installed via PKG to /usr/local/libexec/intentional-daemon.
//  Runs as root with KeepAlive — launchd restarts it instantly if killed.
//
//  Responsibilities:
//  - XPC server for GUI app communication
//  - App watchdog (restarts app if killed while strict mode is ON)
//  - Independent heartbeat to backend (survives app kill)
//  - /etc/hosts tamper detection
//  - Root-owned config (strict mode state, partner lock)
//

import Foundation

// MARK: - XPC Delegate

/// Handles incoming XPC connections from the GUI app.
class DaemonDelegate: NSObject, NSXPCListenerDelegate {

    let config: ConfigManager
    let heartbeat: HeartbeatService

    init(config: ConfigManager, heartbeat: HeartbeatService) {
        self.config = config
        self.heartbeat = heartbeat
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Set the exported interface (what the app can call on us)
        connection.exportedInterface = NSXPCInterface(with: DaemonXPCProtocol.self)
        connection.exportedObject = XPCHandler(config: config, heartbeat: heartbeat)

        // Record the connecting user's UID as the configured user (first connection wins)
        let connectingUID = connection.effectiveUserIdentifier
        config.setConfiguredUserUID(connectingUID)

        connection.invalidationHandler = {
            log("XPC connection invalidated")
        }

        connection.resume()
        log("XPC connection accepted (pid=\(connection.processIdentifier), uid=\(connectingUID))")
        return true
    }
}

// MARK: - XPC Handler (implements the protocol)

class XPCHandler: NSObject, DaemonXPCProtocol {

    let config: ConfigManager
    let heartbeat: HeartbeatService

    init(config: ConfigManager, heartbeat: HeartbeatService) {
        self.config = config
        self.heartbeat = heartbeat
    }

    func isStrictModeEnabled(reply: @escaping (Bool) -> Void) {
        reply(config.strictModeEnabled)
    }

    func setStrictMode(enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        let (success, error) = config.setStrictMode(enabled: enabled)
        if success {
            log("Strict mode \(enabled ? "enabled" : "disabled") via XPC")
        }
        reply(success, error)
    }

    func updatePartnerLockState(isLocked: Bool, partnerEmail: String?, deviceId: String?, reply: @escaping (Bool) -> Void) {
        config.updatePartnerLockState(isLocked: isLocked, partnerEmail: partnerEmail, deviceId: deviceId)
        reply(true)
    }

    func verifyUnlockCode(_ code: String, reply: @escaping (Bool) -> Void) {
        // Verify code against the backend
        guard let deviceId = config.deviceId else {
            reply(false)
            return
        }

        let endpoint = "https://api.intentional.social/unlock/verify"
        guard let url = URL(string: endpoint) else {
            reply(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        request.timeoutInterval = 10

        let payload: [String: Any] = ["code": code]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            reply(false)
            return
        }
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let valid = json["valid"] as? Bool, valid else {
                reply(false)
                return
            }
            log("Unlock code verified successfully")
            reply(true)
        }.resume()
    }

    func appHeartbeat(reply: @escaping (Bool) -> Void) {
        config.recordAppHeartbeat()
        reply(true)
    }

    func getConfig(reply: @escaping (Data?) -> Void) {
        reply(config.getConfigData())
    }
}

// MARK: - Main

log("syspolicyd_helper starting (pid=\(ProcessInfo.processInfo.processIdentifier))")

// Initialize components
let config = ConfigManager()
let heartbeat = HeartbeatService(config: config)
let watchdog = AppWatchdog(config: config, heartbeat: heartbeat)
let hostsWatcher = HostsWatcher(heartbeat: heartbeat)

// Start services
heartbeat.start()
watchdog.start()
hostsWatcher.start()

// Set up XPC listener (Mach service registered in LaunchDaemon plist)
let delegate = DaemonDelegate(config: config, heartbeat: heartbeat)
let listener = NSXPCListener(machServiceName: kDaemonMachServiceName)
listener.delegate = delegate
listener.resume()

log("syspolicyd_helper ready — XPC listener active on \(kDaemonMachServiceName)")

// Handle SIGTERM gracefully (report to backend before dying)
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    log("SIGTERM received — reporting to backend and exiting")
    heartbeat.reportTamper(eventType: "daemon_killed", detail: "Daemon received SIGTERM")
    // Give the network request a moment to send
    Thread.sleep(forTimeInterval: 1.0)
    exit(0)
}
sigtermSource.resume()

// Run forever
dispatchMain()

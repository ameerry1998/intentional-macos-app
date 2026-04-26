//
//  ConfigManager.swift
//  IntentionalDaemon
//
//  Manages the root-owned config at /private/var/intentional/config.json.
//  This file is owned by root:wheel with mode 700, so standard users cannot
//  read or modify it. The daemon is the sole accessor.
//

import Foundation

struct DaemonConfig: Codable {
    var strictModeEnabled: Bool = false
    var partnerLocked: Bool = false
    var partnerEmail: String?
    var deviceId: String?
    var installedAt: String?
    var daemonVersion: String = "1.0"
    var lastHeartbeatToBackend: String?
    var lastAppHeartbeat: String?
    var configuredUserUID: uid_t?  // UID of the user who set up Intentional
}

class ConfigManager {

    static let configDir = "/private/var/intentional"
    static let configPath = "/private/var/intentional/config.json"

    private var config: DaemonConfig
    private let queue = DispatchQueue(label: "com.intentional.daemon.config")

    init() {
        // Ensure config directory exists (root-owned)
        let fm = FileManager.default
        if !fm.fileExists(atPath: ConfigManager.configDir) {
            try? fm.createDirectory(atPath: ConfigManager.configDir, withIntermediateDirectories: true)
            // Set ownership: root:wheel, mode 700
            let attrs: [FileAttributeKey: Any] = [
                .posixPermissions: 0o700,
                .ownerAccountName: "root",
                .groupOwnerAccountName: "wheel"
            ]
            try? fm.setAttributes(attrs, ofItemAtPath: ConfigManager.configDir)
        }

        // Load existing config or create default
        if let data = fm.contents(atPath: ConfigManager.configPath),
           let loaded = try? JSONDecoder().decode(DaemonConfig.self, from: data) {
            self.config = loaded
            log("Config loaded: strictMode=\(loaded.strictModeEnabled), partnerLocked=\(loaded.partnerLocked)")
        } else {
            self.config = DaemonConfig(installedAt: ISO8601DateFormatter().string(from: Date()))
            save()
            log("Config created with defaults")
        }
    }

    // MARK: - Accessors

    var strictModeEnabled: Bool {
        queue.sync { config.strictModeEnabled }
    }

    var partnerLocked: Bool {
        queue.sync { config.partnerLocked }
    }

    var partnerEmail: String? {
        queue.sync { config.partnerEmail }
    }

    var deviceId: String? {
        queue.sync { config.deviceId }
    }

    var configuredUserUID: uid_t? {
        queue.sync { config.configuredUserUID }
    }

    // MARK: - Mutators

    func setStrictMode(enabled: Bool) -> (Bool, String?) {
        return queue.sync {
            // Can't disable strict mode if partner has it locked
            if !enabled && config.partnerLocked {
                return (false, "Cannot disable strict mode while partner lock is active")
            }
            config.strictModeEnabled = enabled
            save()
            log("Strict mode set to \(enabled)")
            return (true, nil)
        }
    }

    func updatePartnerLockState(isLocked: Bool, partnerEmail: String?, deviceId: String?) {
        queue.sync {
            config.partnerLocked = isLocked
            if let email = partnerEmail { config.partnerEmail = email }
            if let id = deviceId { config.deviceId = id }
            save()
            log("Partner lock updated: locked=\(isLocked), email=\(partnerEmail ?? "nil")")
        }
    }

    func setConfiguredUserUID(_ uid: uid_t) {
        queue.sync {
            if config.configuredUserUID == nil {
                config.configuredUserUID = uid
                save()
                log("Configured user UID set to \(uid)")
            }
        }
    }

    func recordAppHeartbeat() {
        queue.sync {
            config.lastAppHeartbeat = ISO8601DateFormatter().string(from: Date())
            save()
        }
    }

    func recordBackendHeartbeat() {
        queue.sync {
            config.lastHeartbeatToBackend = ISO8601DateFormatter().string(from: Date())
            save()
        }
    }

    func getConfigData() -> Data? {
        queue.sync {
            try? JSONEncoder().encode(config)
        }
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(config) else { return }
        FileManager.default.createFile(atPath: ConfigManager.configPath, contents: data)

        // Ensure file permissions stay locked down
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: ConfigManager.configPath
        )
    }
}

// MARK: - Logging

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)"
    print(line)

    // Also append to log file
    let logPath = "/var/log/intentional-daemon.log"
    if let data = (line + "\n").data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
}

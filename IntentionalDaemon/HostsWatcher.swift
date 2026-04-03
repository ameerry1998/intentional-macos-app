//
//  HostsWatcher.swift
//  IntentionalDaemon
//
//  Monitors /etc/hosts for DNS tampering. If someone adds entries to block
//  api.intentional.social, the daemon detects and reports it.
//

import Foundation

class HostsWatcher {

    private let hostsPath = "/etc/hosts"
    private let blockedDomains = ["api.intentional.social", "intentional.social"]
    private var fileSource: DispatchSourceFileSystemObject?
    private let heartbeat: HeartbeatService
    private var lastReportedTamper: Date?

    init(heartbeat: HeartbeatService) {
        self.heartbeat = heartbeat
    }

    func start() {
        // Initial check
        checkHosts()

        // Watch for changes
        let fd = open(hostsPath, O_EVTONLY)
        guard fd >= 0 else {
            log("HostsWatcher: cannot open /etc/hosts for monitoring")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.checkHosts()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.fileSource = source
        log("HostsWatcher: monitoring /etc/hosts")
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
    }

    /// Called by the daemon when launchd wakes it due to WatchPaths trigger.
    func onWatchPathTriggered() {
        checkHosts()
    }

    private func checkHosts() {
        guard let contents = try? String(contentsOfFile: hostsPath, encoding: .utf8) else { return }

        let lines = contents.components(separatedBy: .newlines)
        var tamperedDomains: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            for domain in blockedDomains {
                if trimmed.contains(domain) {
                    tamperedDomains.append(domain)
                }
            }
        }

        if !tamperedDomains.isEmpty {
            // Rate limit: only report once per 5 minutes
            if let last = lastReportedTamper, Date().timeIntervalSince(last) < 300 { return }
            lastReportedTamper = Date()

            let detail = "Blocked domains found in /etc/hosts: \(tamperedDomains.joined(separator: ", "))"
            log("TAMPER: \(detail)")
            heartbeat.reportTamper(eventType: "hosts_tamper", detail: detail)
        }
    }
}

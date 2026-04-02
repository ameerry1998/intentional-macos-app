//
//  FilterDataProvider.swift
//  FilterExtension
//
//  System-level website blocker using NEFilterDataProvider.
//  Blocks distracting domains across ALL browsers and apps — no extension needed.
//  Communicates with main app via App Group shared container.
//

import NetworkExtension
import os.log

class FilterDataProvider: NEFilterDataProvider {

    private let logger = Logger(subsystem: "com.arayan.intentional.filter", category: "Filter")

    /// Blocked domains loaded from shared App Group container
    private var blockedDomains: Set<String> = []

    /// Whether blocking is currently active (focus session in progress)
    private var blockingEnabled = true

    /// File monitor for blocklist changes
    private var blocklistMonitor: DispatchSourceFileSystemObject?

    // MARK: - Lifecycle

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        logger.info("Filter starting")

        // Load initial blocklist
        loadBlocklist()

        // Watch for blocklist file changes from main app
        startWatchingBlocklist()

        // Filter all outbound TCP/UDP — we decide per-flow in handleNewFlow
        let filterSettings = NEFilterSettings(rules: [], defaultAction: .filterData)
        apply(filterSettings) { error in
            if let error {
                self.logger.error("Failed to apply filter settings: \(error.localizedDescription)")
            }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("Filter stopping, reason: \(String(describing: reason))")
        blocklistMonitor?.cancel()
        completionHandler()
    }

    // MARK: - Flow Handling

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // If blocking is disabled (earned brain rot time), allow everything
        guard blockingEnabled else {
            return .allow()
        }

        // Get the hostname from the flow
        guard let hostname = extractHostname(from: flow) else {
            return .allow()
        }

        let normalizedHost = hostname.lowercased()

        // Check if this domain is blocked
        if isDomainBlocked(normalizedHost) {
            logger.info("Blocked: \(normalizedHost)")
            return .drop()
        }

        return .allow()
    }

    // MARK: - Domain Matching

    /// Check if a hostname matches any blocked domain (exact or subdomain)
    private func isDomainBlocked(_ hostname: String) -> Bool {
        // Exact match
        if blockedDomains.contains(hostname) {
            return true
        }

        // Subdomain match: if "youtube.com" is blocked, "m.youtube.com" should also be blocked
        for domain in blockedDomains {
            if hostname.hasSuffix(".\(domain)") {
                return true
            }
        }

        return false
    }

    /// Extract hostname from a filter flow
    private func extractHostname(from flow: NEFilterFlow) -> String? {
        // Preferred: get hostname from flow URL (works for browser/HTTP flows)
        if let url = flow.url, let host = url.host {
            return host
        }

        // Fallback: get from socket flow's remote hostname
        if let socketFlow = flow as? NEFilterSocketFlow,
           let hostname = socketFlow.remoteHostname {
            return hostname
        }

        return nil
    }

    // MARK: - Blocklist Management

    /// Path to shared blocklist in App Group container
    private var blocklistURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.arayan.intentional")?
            .appendingPathComponent("blocklist.json")
    }

    /// Path to shared state file (blocking enabled/disabled)
    private var stateURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.arayan.intentional")?
            .appendingPathComponent("filter_state.json")
    }

    /// Load blocked domains from shared container
    private func loadBlocklist() {
        // Load domains
        if let url = blocklistURL,
           let data = try? Data(contentsOf: url),
           let domains = try? JSONDecoder().decode([String].self, from: data) {
            blockedDomains = Set(domains)
            logger.info("Loaded \(self.blockedDomains.count) blocked domains")
        } else {
            // Default blocklist if no shared file exists yet
            blockedDomains = Set([
                "youtube.com", "instagram.com", "facebook.com",
                "twitter.com", "x.com", "tiktok.com",
                "reddit.com", "snapchat.com"
            ])
            logger.info("Using default blocklist (\(self.blockedDomains.count) domains)")
        }

        // Load state (blocking enabled/disabled)
        if let url = stateURL,
           let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(FilterState.self, from: data) {
            blockingEnabled = state.blockingEnabled
            logger.info("Blocking enabled: \(self.blockingEnabled)")
        }
    }

    /// Watch the blocklist file for changes from main app
    private func startWatchingBlocklist() {
        guard let url = blocklistURL else { return }

        // Ensure the file exists
        if !FileManager.default.fileExists(atPath: url.path) {
            // Write default blocklist so we have something to watch
            let defaultDomains = Array(blockedDomains)
            if let data = try? JSONEncoder().encode(defaultDomains) {
                try? data.write(to: url)
            }
        }

        // Also watch state file
        if let stateURL = stateURL, !FileManager.default.fileExists(atPath: stateURL.path) {
            let state = FilterState(blockingEnabled: true)
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: stateURL)
            }
        }

        // Watch the App Group container directory for any changes
        let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.arayan.intentional")!

        let fd = open(containerURL.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.error("Failed to open container for watching")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.logger.info("Blocklist changed, reloading")
            self?.loadBlocklist()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        blocklistMonitor = source
    }
}

// MARK: - Shared Types

/// Shared state between main app and filter extension
struct FilterState: Codable {
    let blockingEnabled: Bool
}

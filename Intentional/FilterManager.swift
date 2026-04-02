//
//  FilterManager.swift
//  Intentional
//
//  Manages the NEFilterDataProvider System Extension.
//  Handles enabling/disabling the filter and updating the blocklist
//  via the App Group shared container.
//

import Foundation
import NetworkExtension
import SystemExtensions
import os.log

/// Shared state between main app and filter extension
struct FilterState: Codable {
    let blockingEnabled: Bool
}

class FilterManager: NSObject, OSSystemExtensionRequestDelegate {

    private let logger = Logger(subsystem: "com.arayan.intentional", category: "FilterManager")
    private let extensionBundleID = "com.arayan.intentional.filter"
    private let appGroupID = "group.com.arayan.intentional"

    /// Current status of the filter
    private(set) var isFilterEnabled = false

    /// Callback when filter status changes
    var onStatusChanged: ((Bool) -> Void)?

    weak var appDelegate: AppDelegate?

    // MARK: - Public API

    /// Install and activate the System Extension + Network Extension filter
    func activateFilter() {
        logger.info("Requesting System Extension activation")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Deactivate the System Extension
    func deactivateFilter() {
        logger.info("Requesting System Extension deactivation")
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Enable the NEFilterManager (turns on filtering after extension is installed)
    func enableFilter() {
        NEFilterManager.shared().loadFromPreferences { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("Failed to load filter preferences: \(error.localizedDescription)")
                return
            }

            let config = NEFilterProviderConfiguration()
            config.filterSockets = true
            config.organization = "Intentional"

            NEFilterManager.shared().providerConfiguration = config
            NEFilterManager.shared().isEnabled = true

            NEFilterManager.shared().saveToPreferences { error in
                if let error {
                    self.logger.error("Failed to save filter preferences: \(error.localizedDescription)")
                } else {
                    self.logger.info("Filter enabled successfully")
                    self.isFilterEnabled = true
                    self.onStatusChanged?(true)
                }
            }
        }
    }

    /// Disable filtering (during earned brain rot time)
    func disableFilter() {
        NEFilterManager.shared().loadFromPreferences { [weak self] error in
            guard let self else { return }
            if let error {
                self.logger.error("Failed to load filter preferences: \(error.localizedDescription)")
                return
            }

            NEFilterManager.shared().isEnabled = false
            NEFilterManager.shared().saveToPreferences { error in
                if let error {
                    self.logger.error("Failed to disable filter: \(error.localizedDescription)")
                } else {
                    self.logger.info("Filter disabled")
                    self.isFilterEnabled = false
                    self.onStatusChanged?(false)
                }
            }
        }
    }

    /// Check current filter status
    func checkFilterStatus() {
        NEFilterManager.shared().loadFromPreferences { [weak self] _ in
            let enabled = NEFilterManager.shared().isEnabled
            self?.isFilterEnabled = enabled
            self?.logger.info("Filter status: \(enabled ? "enabled" : "disabled")")
            self?.onStatusChanged?(enabled)
        }
    }

    // MARK: - Blocklist Management

    /// Update the blocklist in the shared App Group container.
    /// The FilterDataProvider watches this file and reloads automatically.
    func updateBlocklist(_ domains: [String]) {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.error("App Group container not available")
            return
        }

        let url = containerURL.appendingPathComponent("blocklist.json")

        do {
            let data = try JSONEncoder().encode(domains)
            try data.write(to: url, options: .atomic)
            logger.info("Updated blocklist with \(domains.count) domains")
        } catch {
            logger.error("Failed to write blocklist: \(error.localizedDescription)")
        }
    }

    /// Update the filter state (blocking enabled/disabled).
    /// Used for toggling during earned brain rot time without fully disabling the NE.
    func updateFilterState(blockingEnabled: Bool) {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            logger.error("App Group container not available")
            return
        }

        let url = containerURL.appendingPathComponent("filter_state.json")
        let state = FilterState(blockingEnabled: blockingEnabled)

        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
            logger.info("Updated filter state: blockingEnabled=\(blockingEnabled)")
        } catch {
            logger.error("Failed to write filter state: \(error.localizedDescription)")
        }
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            logger.info("System Extension request completed")
            // After successful activation, enable the filter
            enableFilter()
        case .willCompleteAfterReboot:
            logger.info("System Extension will complete after reboot")
        @unknown default:
            logger.warning("Unknown System Extension result: \(String(describing: result))")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        logger.error("System Extension request failed: \(error.localizedDescription)")
        appDelegate?.postLog("Filter extension failed: \(error.localizedDescription)")
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        logger.info("System Extension needs user approval — check System Settings > General > Login Items & Extensions")
        appDelegate?.postLog("Filter needs approval: System Settings > General > Login Items & Extensions")
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        logger.info("Replacing existing extension (v\(existing.bundleShortVersion)) with v\(ext.bundleShortVersion)")
        return .replace
    }
}

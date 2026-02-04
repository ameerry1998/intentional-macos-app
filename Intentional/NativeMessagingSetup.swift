import Foundation
import Cocoa

/// Handles installation and management of Native Messaging manifests for all Chromium browsers
/// This allows the extension to communicate with the native app for cross-browser time tracking
class NativeMessagingSetup {

    static let shared = NativeMessagingSetup()

    private let manifestName = "com.intentional.social.json"
    private let hostName = "com.intentional.social"

    // File to persist registered extension IDs
    private let registeredIdsFile: URL

    // Known extension IDs (add production ID here when published)
    private var registeredExtensionIds: [String] = []

    // Map bundle ID → Application Support data directory (relative to ~/Library/Application Support/)
    // This is the canonical mapping - used for both extensions and Native Messaging manifests
    private let browserDataPaths: [String: (name: String, dataPath: String)] = [
        // Chrome variants
        "com.google.Chrome": ("Google Chrome", "Google/Chrome"),
        "com.google.Chrome.beta": ("Chrome Beta", "Google/Chrome Beta"),
        "com.google.Chrome.dev": ("Chrome Dev", "Google/Chrome Dev"),
        "com.google.Chrome.canary": ("Chrome Canary", "Google/Chrome Canary"),

        // Chromium
        "org.chromium.Chromium": ("Chromium", "Chromium"),

        // Microsoft Edge variants
        "com.microsoft.edgemac": ("Microsoft Edge", "Microsoft Edge"),
        "com.microsoft.edgemac.Beta": ("Edge Beta", "Microsoft Edge Beta"),
        "com.microsoft.edgemac.Dev": ("Edge Dev", "Microsoft Edge Dev"),
        "com.microsoft.edgemac.Canary": ("Edge Canary", "Microsoft Edge Canary"),

        // Brave variants
        "com.brave.Browser": ("Brave", "BraveSoftware/Brave-Browser"),
        "com.brave.Browser.beta": ("Brave Beta", "BraveSoftware/Brave-Browser-Beta"),
        "com.brave.Browser.nightly": ("Brave Nightly", "BraveSoftware/Brave-Browser-Nightly"),

        // Arc
        "company.thebrowser.Browser": ("Arc", "Arc/User Data"),

        // Opera variants
        "com.operasoftware.Opera": ("Opera", "com.operasoftware.Opera"),
        "com.operasoftware.OperaGX": ("Opera GX", "com.operasoftware.OperaGX"),

        // Vivaldi
        "com.vivaldi.Vivaldi": ("Vivaldi", "Vivaldi"),

        // Other Chromium-based
        "com.nickvision.sigmaos": ("SigmaOS", "SigmaOS"),
        "io.nickvision.nickvision.nickvision.desktop": ("Wavebox", "WaveboxApp"),
        "nickvision.nickvision.nickvision": ("Sidekick", "Sidekick"),
    ]

    // Cache of discovered installed browsers
    private var installedBrowsers: [(bundleId: String, name: String, dataPath: String)] = []

    // Auto-discovered extension IDs (separate from manually registered)
    private var autoDiscoveredIds: [String] = []

    private init() {
        // Store registered IDs in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let intentionalDir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: intentionalDir, withIntermediateDirectories: true)
        registeredIdsFile = intentionalDir.appendingPathComponent("registered_extension_ids.json")

        loadRegisteredIds()
        discoverInstalledBrowsers()
    }

    // MARK: - Browser Discovery

    /// Discover which Chromium-based browsers are installed on this system
    private func discoverInstalledBrowsers() {
        installedBrowsers = []

        for (bundleId, info) in browserDataPaths {
            // Check if the browser is installed using NSWorkspace
            if let _ = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                // Also verify the data directory exists
                let dataPath = NSHomeDirectory() + "/Library/Application Support/" + info.dataPath
                if FileManager.default.fileExists(atPath: dataPath) {
                    installedBrowsers.append((bundleId: bundleId, name: info.name, dataPath: info.dataPath))
                    print("[NativeMessagingSetup] ✅ Found installed browser: \(info.name)")
                }
            }
        }

        print("[NativeMessagingSetup] 📊 Discovered \(installedBrowsers.count) Chromium-based browsers")
    }

    /// Re-scan for installed browsers (call if user installs new browser)
    func refreshInstalledBrowsers() {
        discoverInstalledBrowsers()
    }

    /// Get list of installed browsers
    func getInstalledBrowsers() -> [(name: String, bundleId: String)] {
        return installedBrowsers.map { ($0.name, $0.bundleId) }
    }

    // MARK: - Public API

    /// Scan browsers for installed Intentional extensions and auto-register them
    /// Returns the number of newly discovered extensions
    @discardableResult
    func autoDiscoverExtensions() -> Int {
        // Refresh browser list in case new browsers were installed
        discoverInstalledBrowsers()

        var discoveredIds: [String] = []
        var browsersScanned: [String] = []

        for browser in installedBrowsers {
            let browserDir = NSHomeDirectory() + "/Library/Application Support/" + browser.dataPath

            // Look in Default profile and any numbered profiles (Profile 1, Profile 2, etc.)
            let profileDirs = ["Default"] + (1...10).map { "Profile \($0)" }

            for profile in profileDirs {
                let extensionsDir = browserDir + "/" + profile + "/Extensions"

                guard FileManager.default.fileExists(atPath: extensionsDir) else { continue }

                // Track that we scanned this browser
                if !browsersScanned.contains(browser.name) {
                    browsersScanned.append(browser.name)
                }

                // Each subfolder in Extensions/ is an extension ID
                guard let extensionFolders = try? FileManager.default.contentsOfDirectory(atPath: extensionsDir) else { continue }

                for extensionId in extensionFolders {
                    // Skip if already discovered or registered
                    if discoveredIds.contains(extensionId) || registeredExtensionIds.contains(extensionId) {
                        continue
                    }

                    // Validate extension ID format (32 lowercase letters a-p)
                    let pattern = "^[a-p]{32}$"
                    guard extensionId.range(of: pattern, options: .regularExpression) != nil else { continue }

                    let extensionPath = extensionsDir + "/" + extensionId

                    // Look for version subfolders
                    guard let versionFolders = try? FileManager.default.contentsOfDirectory(atPath: extensionPath) else { continue }

                    for version in versionFolders {
                        let manifestPath = extensionPath + "/" + version + "/manifest.json"

                        if isIntentionalExtension(manifestPath: manifestPath) {
                            discoveredIds.append(extensionId)
                            print("[NativeMessagingSetup] 🔍 Auto-discovered Intentional extension: \(extensionId) in \(browser.name) (\(profile))")
                            break
                        }
                    }
                }
            }
        }

        print("[NativeMessagingSetup] 📋 Scanned \(browsersScanned.count) browsers: \(browsersScanned.joined(separator: ", "))")

        // Update auto-discovered list
        let newlyDiscovered = discoveredIds.filter { !autoDiscoveredIds.contains($0) }
        autoDiscoveredIds = discoveredIds

        if !newlyDiscovered.isEmpty {
            print("[NativeMessagingSetup] ✅ Found \(newlyDiscovered.count) new Intentional extension(s)")
            installManifestsIfNeeded()
        }

        return newlyDiscovered.count
    }

    /// Check if a manifest.json belongs to the Intentional extension
    private func isIntentionalExtension(manifestPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: manifestPath) else { return false }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String {
                // Check for our extension name
                return name == "Intentional"
            }
        } catch {
            // Ignore parse errors
        }

        return false
    }

    /// Install manifests for all detected browsers
    /// Call this on app startup
    func installManifestsIfNeeded() {
        let allIds = getAllExtensionIds()

        guard !allIds.isEmpty else {
            print("[NativeMessagingSetup] No extension IDs registered yet")
            return
        }

        let appPath = Bundle.main.executablePath ?? "/Applications/Intentional.app/Contents/MacOS/Intentional"
        var installedCount = 0

        for browser in installedBrowsers {
            // Native Messaging manifests go in <dataPath>/NativeMessagingHosts/
            let manifestDir = NSHomeDirectory() + "/Library/Application Support/" + browser.dataPath + "/NativeMessagingHosts"
            installManifest(for: browser.name, at: manifestDir, appPath: appPath)
            installedCount += 1
        }

        print("[NativeMessagingSetup] 📦 Installed manifests for \(installedCount) browsers")
    }

    /// Get all extension IDs (both auto-discovered and manually registered)
    func getAllExtensionIds() -> [String] {
        return Array(Set(autoDiscoveredIds + registeredExtensionIds))
    }

    /// Get only auto-discovered extension IDs
    func getAutoDiscoveredIds() -> [String] {
        return autoDiscoveredIds
    }

    /// Register a new extension ID and reinstall manifests
    func registerExtensionId(_ extensionId: String) -> Bool {
        // Validate extension ID format (32 lowercase letters)
        let pattern = "^[a-p]{32}$"
        guard extensionId.range(of: pattern, options: .regularExpression) != nil else {
            print("[NativeMessagingSetup] Invalid extension ID format: \(extensionId)")
            return false
        }

        if !registeredExtensionIds.contains(extensionId) {
            registeredExtensionIds.append(extensionId)
            saveRegisteredIds()
            installManifestsIfNeeded()
            print("[NativeMessagingSetup] Registered extension ID: \(extensionId)")
            return true
        }

        return true // Already registered
    }

    /// Remove an extension ID
    func unregisterExtensionId(_ extensionId: String) {
        registeredExtensionIds.removeAll { $0 == extensionId }
        saveRegisteredIds()
        installManifestsIfNeeded()
    }

    /// Get manually registered extension IDs (not auto-discovered)
    func getRegisteredIds() -> [String] {
        return registeredExtensionIds
    }

    /// Check if any extension IDs are available (auto-discovered or manually registered)
    func hasRegisteredExtensions() -> Bool {
        return !getAllExtensionIds().isEmpty
    }

    // MARK: - Private

    private func loadRegisteredIds() {
        guard FileManager.default.fileExists(atPath: registeredIdsFile.path) else {
            // Start with empty list - user needs to add their extension ID
            registeredExtensionIds = []
            return
        }

        do {
            let data = try Data(contentsOf: registeredIdsFile)
            registeredExtensionIds = try JSONDecoder().decode([String].self, from: data)
            print("[NativeMessagingSetup] Loaded \(registeredExtensionIds.count) registered extension IDs")
        } catch {
            print("[NativeMessagingSetup] Failed to load registered IDs: \(error)")
            registeredExtensionIds = []
        }
    }

    private func saveRegisteredIds() {
        do {
            let data = try JSONEncoder().encode(registeredExtensionIds)
            try data.write(to: registeredIdsFile)
        } catch {
            print("[NativeMessagingSetup] Failed to save registered IDs: \(error)")
        }
    }

    private func installManifest(for browserName: String, at directoryPath: String, appPath: String) {
        // Create directory if needed
        do {
            try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        } catch {
            print("[NativeMessagingSetup] Failed to create directory for \(browserName): \(error)")
            return
        }

        // Build allowed_origins list from ALL extension IDs (auto-discovered + manually registered)
        let allowedOrigins = getAllExtensionIds().map { "chrome-extension://\($0)/" }

        // Create manifest
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Intentional - Cross-browser time tracking and accountability",
            "path": appPath,
            "type": "stdio",
            "allowed_origins": allowedOrigins
        ]

        // Write manifest
        let manifestPath = (directoryPath as NSString).appendingPathComponent(manifestName)

        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: manifestPath))
            print("[NativeMessagingSetup] ✅ Installed manifest for \(browserName)")
        } catch {
            print("[NativeMessagingSetup] Failed to write manifest for \(browserName): \(error)")
        }
    }

    /// Remove all installed manifests (for uninstall)
    func removeAllManifests() {
        // Remove from all known browser data paths (even if browser was uninstalled)
        for (_, info) in browserDataPaths {
            let manifestPath = NSHomeDirectory() + "/Library/Application Support/" + info.dataPath + "/NativeMessagingHosts/" + manifestName

            if FileManager.default.fileExists(atPath: manifestPath) {
                do {
                    try FileManager.default.removeItem(atPath: manifestPath)
                    print("[NativeMessagingSetup] Removed manifest for \(info.name)")
                } catch {
                    print("[NativeMessagingSetup] Failed to remove manifest for \(info.name): \(error)")
                }
            }
        }
    }
}

import Foundation

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

    // Browser manifest directories (for installing Native Messaging manifests)
    private let browserPaths: [(name: String, path: String)] = [
        ("Google Chrome", "Google/Chrome/NativeMessagingHosts"),
        ("Google Chrome Canary", "Google/Chrome Canary/NativeMessagingHosts"),
        ("Chromium", "Chromium/NativeMessagingHosts"),
        ("Brave", "BraveSoftware/Brave-Browser/NativeMessagingHosts"),
        ("Microsoft Edge", "Microsoft Edge/NativeMessagingHosts"),
        ("Arc", "Arc/User Data/NativeMessagingHosts"),
        ("Vivaldi", "Vivaldi/NativeMessagingHosts"),
        ("Opera", "com.operasoftware.Opera/NativeMessagingHosts")
    ]

    // Browser extension directories (for auto-discovering installed Intentional extensions)
    private let browserExtensionPaths: [(name: String, basePath: String)] = [
        ("Google Chrome", "Google/Chrome"),
        ("Google Chrome Canary", "Google/Chrome Canary"),
        ("Chromium", "Chromium"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "Microsoft Edge"),
        ("Arc", "Arc/User Data"),
        ("Vivaldi", "Vivaldi"),
        ("Opera", "com.operasoftware.Opera")
    ]

    // Auto-discovered extension IDs (separate from manually registered)
    private var autoDiscoveredIds: [String] = []

    private init() {
        // Store registered IDs in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let intentionalDir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: intentionalDir, withIntermediateDirectories: true)
        registeredIdsFile = intentionalDir.appendingPathComponent("registered_extension_ids.json")

        loadRegisteredIds()
    }

    // MARK: - Public API

    /// Scan browsers for installed Intentional extensions and auto-register them
    /// Returns the number of newly discovered extensions
    @discardableResult
    func autoDiscoverExtensions() -> Int {
        var discoveredIds: [String] = []

        for (browserName, basePath) in browserExtensionPaths {
            let browserDir = NSHomeDirectory() + "/Library/Application Support/" + basePath

            // Look in Default profile and any numbered profiles (Profile 1, Profile 2, etc.)
            let profileDirs = ["Default"] + (1...10).map { "Profile \($0)" }

            for profile in profileDirs {
                let extensionsDir = browserDir + "/" + profile + "/Extensions"

                guard FileManager.default.fileExists(atPath: extensionsDir) else { continue }

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
                            print("[NativeMessagingSetup] 🔍 Auto-discovered Intentional extension: \(extensionId) in \(browserName) (\(profile))")
                            break
                        }
                    }
                }
            }
        }

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

        for (browserName, relativePath) in browserPaths {
            let fullPath = NSHomeDirectory() + "/Library/Application Support/" + relativePath

            // Only install if browser directory exists (browser is installed)
            let browserBaseDir = (fullPath as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: browserBaseDir) {
                installManifest(for: browserName, at: fullPath, appPath: appPath)
            }
        }
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
        for (browserName, relativePath) in browserPaths {
            let manifestPath = NSHomeDirectory() + "/Library/Application Support/" + relativePath + "/" + manifestName

            if FileManager.default.fileExists(atPath: manifestPath) {
                do {
                    try FileManager.default.removeItem(atPath: manifestPath)
                    print("[NativeMessagingSetup] Removed manifest for \(browserName)")
                } catch {
                    print("[NativeMessagingSetup] Failed to remove manifest for \(browserName): \(error)")
                }
            }
        }
    }
}

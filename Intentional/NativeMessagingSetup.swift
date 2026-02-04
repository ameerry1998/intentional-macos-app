import Foundation
import Cocoa

/// Represents the extension status for a single browser
struct BrowserExtensionStatus: Identifiable {
    let name: String
    let bundleId: String
    let hasExtension: Bool
    let isEnabled: Bool  // Only meaningful if hasExtension is true
    let extensionId: String?
    let extensionPageUrl: String

    var id: String { bundleId }
}

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

    // Cache of discovered installed browsers (using new BrowserDiscovery)
    private var installedBrowsers: [InstalledBrowser] = []

    // Auto-discovered extension IDs (separate from manually registered)
    private var autoDiscoveredIds: [String] = []

    // Track which browsers have the extension installed (browser name -> extension ID)
    private var browserExtensionMap: [String: String] = [:]

    // Track whether the extension is enabled in each browser (browser name -> isEnabled)
    private var browserExtensionEnabledMap: [String: Bool] = [:]

    private init() {
        // Store registered IDs in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let intentionalDir = appSupport.appendingPathComponent("Intentional")
        try? FileManager.default.createDirectory(at: intentionalDir, withIntermediateDirectories: true)
        registeredIdsFile = intentionalDir.appendingPathComponent("registered_extension_ids.json")

        loadRegisteredIds()
        discoverInstalledBrowsers()
    }

    // MARK: - Logging Helper

    /// Log to both stdout and debug file
    private func log(_ message: String) {
        print(message)  // Still print to stdout for debugging

        // Also write to debug log file
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.postLog(message)
        }
    }

    // MARK: - Browser Discovery

    /// Discover which browsers are installed on this system
    /// Uses the new BrowserDatabase + BrowserDiscovery architecture
    private func discoverInstalledBrowsers() {
        log("[NativeMessagingSetup] 🔍 Starting browser discovery...")

        // Use the new BrowserDiscovery to find all installed browsers
        installedBrowsers = BrowserDiscovery.findInstalledBrowsers()

        // Log what we found
        for browser in installedBrowsers {
            log("[NativeMessagingSetup] ✅ Found browser: \(browser.info.name) (\(browser.info.bundleId))")
            if let dataPath = browser.dataPath {
                log("[NativeMessagingSetup]    Data path: \(dataPath.path)")
                log("[NativeMessagingSetup]    Profiles: \(browser.profiles.count)")
            }
        }

        log("[NativeMessagingSetup] 📊 Total browsers found: \(installedBrowsers.count)")
    }

    /// Re-scan for installed browsers (call if user installs new browser)
    func refreshInstalledBrowsers() {
        discoverInstalledBrowsers()
        detectExtensions()  // Re-detect extensions after refresh
    }

    /// Get list of installed browsers
    func getInstalledBrowsers() -> [(name: String, bundleId: String)] {
        return installedBrowsers.map { ($0.info.name, $0.info.bundleId) }
    }

    /// Get browser status with extension info for UI display
    /// Returns list of browsers with: name, bundleId, hasExtension, isEnabled, extensionId (if any), extensionPageUrl
    func getBrowserStatus() -> [BrowserExtensionStatus] {
        return installedBrowsers.map { browser in
            let extensionId = browserExtensionMap[browser.info.name]
            let isEnabled = browserExtensionEnabledMap[browser.info.name] ?? false

            return BrowserExtensionStatus(
                name: browser.info.name,
                bundleId: browser.info.bundleId,
                hasExtension: extensionId != nil,
                isEnabled: isEnabled,
                extensionId: extensionId,
                extensionPageUrl: browser.info.extensionPageUrl
            )
        }
    }

    /// Open the extensions page in the specified browser
    func openExtensionsPage(bundleId: String) {
        guard let browser = installedBrowsers.first(where: { $0.info.bundleId == bundleId }),
              let browserUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return
        }

        // Create a URL with the extensions:// scheme
        // Note: We can't directly open chrome:// URLs, so we launch the browser
        // and it will open to its default page. User needs to navigate to extensions manually.
        // However, we can try using NSWorkspace to open the URL in the specific browser.

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // For internal browser URLs (chrome://, brave://, etc.), we need to launch the browser directly
        // These URLs can't be opened via NSWorkspace.shared.open(URL)
        NSWorkspace.shared.openApplication(at: browserUrl, configuration: configuration) { _, error in
            if let error = error {
                self.log("[NativeMessagingSetup] Failed to open browser: \(error)")
            } else {
                self.log("[NativeMessagingSetup] Opened \(bundleId) - user should navigate to \(browser.info.extensionPageUrl)")
            }
        }
    }

    // MARK: - Public API

    // MARK: - Extension Detection

    /// Detect extensions in all installed browsers
    private func detectExtensions() {
        autoDiscoverExtensions()
    }

    /// Scan browsers for installed Intentional extensions and auto-register them
    /// Returns the number of newly discovered extensions
    @discardableResult
    func autoDiscoverExtensions() -> Int {
        // Refresh browser list in case new browsers were installed
        discoverInstalledBrowsers()

        var discoveredIds: [String] = []
        var browsersScanned: [String] = []

        // Reset browser-extension mapping
        browserExtensionMap = [:]
        browserExtensionEnabledMap = [:]

        log("[NativeMessagingSetup] 🔍 Starting extension discovery for \(installedBrowsers.count) browsers...")

        for browser in installedBrowsers {
            guard browser.info.supportsWebExtensions else {
                log("[NativeMessagingSetup] ⏭️ Skipping \(browser.info.name) - doesn't support web extensions")
                continue
            }

            log("[NativeMessagingSetup] 📂 Scanning browser: \(browser.info.name) (engine: \(browser.info.engine))")

            // Route to appropriate detection method based on browser engine
            switch browser.info.engine {
            case .chromium:
                // Chromium-based browsers: Chrome, Arc, Edge, Brave, Electron apps, etc.
                if let found = scanChromiumBrowser(browser, discoveredIds: &discoveredIds, browsersScanned: &browsersScanned) {
                    if !discoveredIds.contains(found) {
                        discoveredIds.append(found)
                    }
                }

            case .gecko:
                // Firefox-based browsers: Firefox, Tor Browser, etc.
                log("[NativeMessagingSetup]   🦊 Using Firefox/Gecko detection method")
                if let found = scanFirefoxBrowser(browser, discoveredIds: &discoveredIds, browsersScanned: &browsersScanned) {
                    if !discoveredIds.contains(found) {
                        discoveredIds.append(found)
                    }
                }

            case .webkit:
                // Safari-based browsers
                log("[NativeMessagingSetup]   🧭 Using Safari/WebKit detection method")
                if let found = scanSafariBrowser(browser, discoveredIds: &discoveredIds, browsersScanned: &browsersScanned) {
                    if !discoveredIds.contains(found) {
                        discoveredIds.append(found)
                    }
                }

            default:
                // Unknown engine - try Chromium method as fallback
                log("[NativeMessagingSetup]   ⚠️ Unknown engine, trying Chromium detection as fallback")
                if let found = scanChromiumBrowser(browser, discoveredIds: &discoveredIds, browsersScanned: &browsersScanned) {
                    if !discoveredIds.contains(found) {
                        discoveredIds.append(found)
                    }
                }
            }
        }

        log("[NativeMessagingSetup] 📋 Scanned \(browsersScanned.count) browsers: \(browsersScanned.joined(separator: ", "))")

        // Update auto-discovered list
        let newlyDiscovered = discoveredIds.filter { !autoDiscoveredIds.contains($0) }
        autoDiscoveredIds = discoveredIds

        if discoveredIds.isEmpty {
            log("[NativeMessagingSetup] ⚠️ No Intentional extensions found in any browser")
        } else {
            log("[NativeMessagingSetup] ✅ Found \(discoveredIds.count) Intentional extension(s): \(discoveredIds.joined(separator: ", "))")
            if !newlyDiscovered.isEmpty {
                log("[NativeMessagingSetup] 🆕 \(newlyDiscovered.count) newly discovered")
            }
            installManifestsIfNeeded()
        }

        return newlyDiscovered.count
    }

    /// Scan Extensions folder for installed Intentional extension
    private func scanExtensionsFolder(_ extensionsDir: String, browserName: String, profile: String) -> String? {
        guard let extensionFolders = try? FileManager.default.contentsOfDirectory(atPath: extensionsDir) else {
            return nil
        }

        log("[NativeMessagingSetup]   🔍 Extensions folder has \(extensionFolders.count) extensions")

        for extensionId in extensionFolders {
            // Validate extension ID format (32 lowercase letters a-p)
            let pattern = "^[a-p]{32}$"
            guard extensionId.range(of: pattern, options: .regularExpression) != nil else { continue }

            let extensionPath = extensionsDir + "/" + extensionId

            // Look for version subfolders
            guard let versionFolders = try? FileManager.default.contentsOfDirectory(atPath: extensionPath) else { continue }

            for version in versionFolders {
                let manifestPath = extensionPath + "/" + version + "/manifest.json"

                if isIntentionalExtension(manifestPath: manifestPath) {
                    browserExtensionMap[browserName] = extensionId
                    // Extensions in the Extensions folder are typically enabled (assume enabled if not in Preferences)
                    browserExtensionEnabledMap[browserName] = true
                    log("[NativeMessagingSetup]   ✅ Found Intentional in Extensions folder: \(extensionId)")
                    return extensionId
                }
            }
        }

        return nil
    }

    /// Scan Preferences file for unpacked extensions loaded in developer mode
    private func scanPreferencesForUnpackedExtensions(_ prefsPath: String, browserName: String, profile: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: prefsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extensions = json["extensions"] as? [String: Any],
              let settings = extensions["settings"] as? [String: Any] else {
            return nil
        }

        log("[NativeMessagingSetup]   🔍 Preferences has \(settings.count) extension entries")

        for (extensionId, extData) in settings {
            guard let extDict = extData as? [String: Any] else { continue }

            let location = extDict["location"] as? Int ?? -1
            let path = extDict["path"] as? String
            let blacklisted = extDict["blacklist"] as? Bool ?? false

            // Chromium uses disable_reasons field as an ARRAY of integers
            // Empty array = enabled, non-empty array = disabled
            // Reason codes: 1=user, 2=permissions, 4=reload, 8=unsupported, 16=sideload
            let disableReasonsArray = extDict["disable_reasons"] as? [Int] ?? []
            let isEnabled = disableReasonsArray.isEmpty

            let stateDescription: String
            if blacklisted {
                stateDescription = "blocklisted 🚫"
            } else if isEnabled {
                stateDescription = "enabled ✅"
            } else {
                // Extension is disabled - decode the reason codes from the array
                var reasonParts: [String] = []
                for code in disableReasonsArray {
                    switch code {
                    case 1: reasonParts.append("user")
                    case 2: reasonParts.append("permissions")
                    case 4: reasonParts.append("reload")
                    case 8: reasonParts.append("unsupported")
                    case 16: reasonParts.append("sideload")
                    default: reasonParts.append("\(code)")
                    }
                }
                let reasonStr = reasonParts.isEmpty ? "unknown" : reasonParts.joined(separator: ", ")
                stateDescription = "disabled ⏸️ (reason: \(reasonStr))"
            }

            // Method 1: Check embedded manifest (some browsers embed it)
            if let manifest = extDict["manifest"] as? [String: Any],
               let name = manifest["name"] as? String,
               name == "Intentional" {
                let isUnpacked = location == 4
                let locationType = isUnpacked ? "unpacked (dev mode)" : "location=\(location)"

                browserExtensionMap[browserName] = extensionId
                browserExtensionEnabledMap[browserName] = isEnabled
                log("[NativeMessagingSetup]   ✅ Found Intentional (embedded manifest): \(extensionId)")
                log("[NativeMessagingSetup]      Type: \(locationType)")
                log("[NativeMessagingSetup]      State: \(stateDescription)")
                log("[NativeMessagingSetup]      Path: \(path ?? "unknown")")
                return extensionId
            }

            // Method 2: For unpacked extensions (location=4), read manifest from path
            if location == 4, let extPath = path {
                let manifestPath = extPath + "/manifest.json"
                if isIntentionalExtension(manifestPath: manifestPath) {
                    browserExtensionMap[browserName] = extensionId
                    browserExtensionEnabledMap[browserName] = isEnabled
                    log("[NativeMessagingSetup]   ✅ Found Intentional (unpacked extension): \(extensionId)")
                    log("[NativeMessagingSetup]      Type: unpacked (dev mode)")
                    log("[NativeMessagingSetup]      State: \(stateDescription)")
                    log("[NativeMessagingSetup]      Path: \(extPath)")
                    return extensionId
                }
            }
        }

        return nil
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
            log("[NativeMessagingSetup] No extension IDs registered yet")
            return
        }

        let appPath = Bundle.main.executablePath ?? "/Applications/Intentional.app/Contents/MacOS/Intentional"
        var installedCount = 0

        for browser in installedBrowsers {
            // Only install for browsers that support Native Messaging
            guard browser.info.supportsNativeMessaging else {
                log("[NativeMessagingSetup] ⏭️ Skipping \(browser.info.name) - doesn't support Native Messaging")
                continue
            }

            // Get the Native Messaging path for this browser
            if let manifestPath = BrowserDiscovery.getNativeMessagingPath(for: browser.info, dataPath: browser.dataPath) {
                installManifest(for: browser.info.name, at: manifestPath.path, appPath: appPath)
                installedCount += 1
            } else {
                log("[NativeMessagingSetup] ⚠️ Could not determine Native Messaging path for \(browser.info.name)")
            }
        }

        log("[NativeMessagingSetup] 📦 Installed manifests for \(installedCount) browsers")
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
            log("[NativeMessagingSetup] Invalid extension ID format: \(extensionId)")
            return false
        }

        if !registeredExtensionIds.contains(extensionId) {
            registeredExtensionIds.append(extensionId)
            saveRegisteredIds()
            installManifestsIfNeeded()
            log("[NativeMessagingSetup] Registered extension ID: \(extensionId)")
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
            log("[NativeMessagingSetup] Loaded \(registeredExtensionIds.count) registered extension IDs")
        } catch {
            log("[NativeMessagingSetup] Failed to load registered IDs: \(error)")
            registeredExtensionIds = []
        }
    }

    private func saveRegisteredIds() {
        do {
            let data = try JSONEncoder().encode(registeredExtensionIds)
            try data.write(to: registeredIdsFile)
        } catch {
            log("[NativeMessagingSetup] Failed to save registered IDs: \(error)")
        }
    }

    private func installManifest(for browserName: String, at directoryPath: String, appPath: String) {
        // Create directory if needed
        do {
            try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        } catch {
            log("[NativeMessagingSetup] Failed to create directory for \(browserName): \(error)")
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
            log("[NativeMessagingSetup] ✅ Installed manifest for \(browserName)")
        } catch {
            log("[NativeMessagingSetup] Failed to write manifest for \(browserName): \(error)")
        }
    }

    // MARK: - Browser-Specific Scanning Methods

    /// Scan Chromium-based browser for Intentional extension
    private func scanChromiumBrowser(_ browser: InstalledBrowser, discoveredIds: inout [String], browsersScanned: inout [String]) -> String? {
        for profilePath in browser.profiles {
            let profileName = profilePath.lastPathComponent

            // Track that we scanned this browser
            if !browsersScanned.contains(browser.info.name) {
                browsersScanned.append(browser.info.name)
                log("[NativeMessagingSetup]   📁 Found profile: \(profileName)")
            }

            // Method 1: Scan Extensions folder
            let extensionsDir = profilePath.appendingPathComponent("Extensions")
            if FileManager.default.fileExists(atPath: extensionsDir.path) {
                if let found = scanExtensionsFolder(extensionsDir.path, browserName: browser.info.name, profile: profileName) {
                    return found
                }
            }

            // Method 2: Check Preferences file for unpacked extensions
            let prefsPath = profilePath.appendingPathComponent("Preferences")
            if FileManager.default.fileExists(atPath: prefsPath.path) {
                if let found = scanPreferencesForUnpackedExtensions(prefsPath.path, browserName: browser.info.name, profile: profileName) {
                    return found
                }
            }

            // Method 3: Check Secure Preferences
            let securePrefsPath = profilePath.appendingPathComponent("Secure Preferences")
            if FileManager.default.fileExists(atPath: securePrefsPath.path) {
                if let found = scanPreferencesForUnpackedExtensions(securePrefsPath.path, browserName: browser.info.name, profile: profileName) {
                    return found
                }
            }
        }
        return nil
    }

    /// Scan Firefox/Gecko-based browser for Intentional extension
    private func scanFirefoxBrowser(_ browser: InstalledBrowser, discoveredIds: inout [String], browsersScanned: inout [String]) -> String? {
        for profilePath in browser.profiles {
            let profileName = profilePath.lastPathComponent

            if !browsersScanned.contains(browser.info.name) {
                browsersScanned.append(browser.info.name)
                log("[NativeMessagingSetup]   📁 Found profile: \(profileName)")
            }

            // Firefox stores extensions in extensions.json and prefs.js
            let extensionsJson = profilePath.appendingPathComponent("extensions.json")
            let prefsJs = profilePath.appendingPathComponent("prefs.js")
            let addonsJson = profilePath.appendingPathComponent("addons.json")

            log("[NativeMessagingSetup]   🔍 Checking Firefox extension files:")
            log("[NativeMessagingSetup]      extensions.json: \(FileManager.default.fileExists(atPath: extensionsJson.path) ? "✅ exists" : "❌ missing")")
            log("[NativeMessagingSetup]      prefs.js: \(FileManager.default.fileExists(atPath: prefsJs.path) ? "✅ exists" : "❌ missing")")
            log("[NativeMessagingSetup]      addons.json: \(FileManager.default.fileExists(atPath: addonsJson.path) ? "✅ exists" : "❌ missing")")

            // Try to parse extensions.json
            if FileManager.default.fileExists(atPath: extensionsJson.path) {
                if let found = scanFirefoxExtensionsJson(extensionsJson.path, browserName: browser.info.name) {
                    return found
                }
            }

            // Try to parse addons.json  (newer Firefox versions)
            if FileManager.default.fileExists(atPath: addonsJson.path) {
                if let found = scanFirefoxAddonsJson(addonsJson.path, browserName: browser.info.name) {
                    return found
                }
            }

            log("[NativeMessagingSetup]   ⚠️ No Intentional extension found in Firefox profile")
        }
        return nil
    }

    /// Scan Safari/WebKit-based browser for Intentional extension
    private func scanSafariBrowser(_ browser: InstalledBrowser, discoveredIds: inout [String], browsersScanned: inout [String]) -> String? {
        for profilePath in browser.profiles {
            let profileName = profilePath.lastPathComponent

            if !browsersScanned.contains(browser.info.name) {
                browsersScanned.append(browser.info.name)
                log("[NativeMessagingSetup]   📁 Found profile: \(profileName)")
            }

            // Safari stores extensions in different locations
            let extensionsPath = profilePath.appendingPathComponent("Extensions")
            let safariExtensions = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari/Extensions")

            log("[NativeMessagingSetup]   🔍 Checking Safari extension paths:")
            log("[NativeMessagingSetup]      ~/Library/Safari/Extensions: \(FileManager.default.fileExists(atPath: safariExtensions.path) ? "✅ exists" : "❌ missing")")
            log("[NativeMessagingSetup]      Profile Extensions: \(FileManager.default.fileExists(atPath: extensionsPath.path) ? "✅ exists" : "❌ missing")")

            // Check Safari Web Extensions database
            let webExtensionsDb = profilePath.appendingPathComponent("WebExtensions/WebExtensions.db")
            if FileManager.default.fileExists(atPath: webExtensionsDb.path) {
                log("[NativeMessagingSetup]   📊 Found WebExtensions.db (SQLite database)")
                log("[NativeMessagingSetup]   ⚠️ Safari extension detection not yet implemented")
                // TODO: Parse SQLite database to find installed extensions
            }

            // Check for extension bundles in Extensions folder
            if FileManager.default.fileExists(atPath: safariExtensions.path) {
                if let extensionBundles = try? FileManager.default.contentsOfDirectory(atPath: safariExtensions.path) {
                    log("[NativeMessagingSetup]   📦 Found \(extensionBundles.count) Safari extension bundles")
                    for bundle in extensionBundles {
                        log("[NativeMessagingSetup]      - \(bundle)")
                    }
                }
            }

            log("[NativeMessagingSetup]   ⚠️ Safari extension scanning requires additional implementation")
        }
        return nil
    }

    /// Parse Firefox extensions.json file
    private func scanFirefoxExtensionsJson(_ jsonPath: String, browserName: String) -> String? {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let addons = json["addons"] as? [[String: Any]] {
                log("[NativeMessagingSetup]   📋 Found \(addons.count) Firefox extensions")

                for addon in addons {
                    if let name = addon["name"] as? String,
                       let id = addon["id"] as? String,
                       name == "Intentional" {
                        let userDisabled = addon["userDisabled"] as? Bool ?? false
                        let appDisabled = addon["appDisabled"] as? Bool ?? false
                        let state = !userDisabled && !appDisabled ? "enabled ✅" : "disabled ⏸️"

                        log("[NativeMessagingSetup]   ✅ Found Intentional: \(id)")
                        log("[NativeMessagingSetup]      State: \(state)")
                        log("[NativeMessagingSetup]      userDisabled: \(userDisabled), appDisabled: \(appDisabled)")
                        return id
                    }
                }
            }
        } catch {
            log("[NativeMessagingSetup]   ❌ Failed to parse extensions.json: \(error)")
        }
        return nil
    }

    /// Parse Firefox addons.json file (newer Firefox versions)
    private func scanFirefoxAddonsJson(_ jsonPath: String, browserName: String) -> String? {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let addons = json["addons"] as? [[String: Any]] {
                log("[NativeMessagingSetup]   📋 Found \(addons.count) Firefox addons")

                for addon in addons {
                    if let name = addon["name"] as? String,
                       let id = addon["id"] as? String,
                       name == "Intentional" {
                        let active = addon["active"] as? Bool ?? false
                        let userDisabled = addon["userDisabled"] as? Bool ?? false
                        let state = active && !userDisabled ? "enabled ✅" : "disabled ⏸️"

                        log("[NativeMessagingSetup]   ✅ Found Intentional: \(id)")
                        log("[NativeMessagingSetup]      State: \(state)")
                        log("[NativeMessagingSetup]      active: \(active), userDisabled: \(userDisabled)")
                        return id
                    }
                }
            }
        } catch {
            log("[NativeMessagingSetup]   ❌ Failed to parse addons.json: \(error)")
        }
        return nil
    }

    // MARK: - Manifest Management

    /// Remove all installed manifests (for uninstall)
    func removeAllManifests() {
        // Remove from all known browser data paths (even if browser was uninstalled)
        for browserInfo in BrowserDatabase.allBrowsers {
            // Only process browsers that support Native Messaging
            guard browserInfo.supportsNativeMessaging else { continue }

            // Try to find the browser's data path
            if let dataPath = BrowserDiscovery.discoverDataPath(for: browserInfo),
               let manifestPath = BrowserDiscovery.getNativeMessagingPath(for: browserInfo, dataPath: dataPath) {
                let fullManifestPath = manifestPath.appendingPathComponent(manifestName)

                if FileManager.default.fileExists(atPath: fullManifestPath.path) {
                    do {
                        try FileManager.default.removeItem(at: fullManifestPath)
                        log("[NativeMessagingSetup] Removed manifest for \(browserInfo.name)")
                    } catch {
                        log("[NativeMessagingSetup] Failed to remove manifest for \(browserInfo.name): \(error)")
                    }
                }
            }
        }
    }
}

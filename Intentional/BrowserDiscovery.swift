import Foundation
import Cocoa

// MARK: - Installed Browser

struct InstalledBrowser {
    let info: BrowserInfo
    let appPath: URL           // Where .app is installed
    let dataPath: URL?         // Where user data is stored
    let profiles: [URL]        // All discovered profiles
    var hasExtensionInstalled: Bool
    var extensionId: String?   // If extension is installed
}

// MARK: - Browser Discovery

struct BrowserDiscovery {

    // MARK: - Main Discovery Method

    /// Discovers all installed browsers from our known browser database
    static func findInstalledBrowsers() -> [InstalledBrowser] {
        var installedBrowsers: [InstalledBrowser] = []

        print("[BrowserDiscovery] 🔍 Checking \(BrowserDatabase.allBrowsers.count) known browsers...")

        // Only check browsers we KNOW about (prevents iTerm2 false positive)
        for knownBrowser in BrowserDatabase.allBrowsers {
            // Use Launch Services to find if this browser is installed
            if let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: knownBrowser.bundleId
            ) {
                print("[BrowserDiscovery] ✅ \(knownBrowser.name) is installed at: \(appURL.path)")

                // Browser is installed! Now discover its data path dynamically
                let dataPath = discoverDataPath(for: knownBrowser)

                if let dataPath = dataPath {
                    print("[BrowserDiscovery]    📁 Data path found: \(dataPath.path)")
                } else {
                    print("[BrowserDiscovery]    ⚠️ No data path found for \(knownBrowser.name)")
                }

                let profiles = dataPath != nil ? findProfiles(in: dataPath!, for: knownBrowser) : []

                if !profiles.isEmpty {
                    print("[BrowserDiscovery]    👤 Found \(profiles.count) profile(s)")
                    for profile in profiles {
                        print("[BrowserDiscovery]       - \(profile.lastPathComponent)")
                    }
                }

                let installedBrowser = InstalledBrowser(
                    info: knownBrowser,
                    appPath: appURL,
                    dataPath: dataPath,
                    profiles: profiles,
                    hasExtensionInstalled: false,
                    extensionId: nil
                )

                installedBrowsers.append(installedBrowser)
            }
        }

        print("[BrowserDiscovery] 📊 Total installed browsers found: \(installedBrowsers.count)")
        return installedBrowsers
    }

    // MARK: - Data Path Discovery

    /// Dynamically discovers where browser stores its user data
    /// Does NOT rely on hardcoded paths - checks multiple possible locations
    static func discoverDataPath(for browser: BrowserInfo) -> URL? {
        let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")

        // Build list of candidate paths to check
        var candidates: [URL] = []

        // Primary data folder name
        candidates.append(appSupportDir.appendingPathComponent(browser.dataFolderName))

        // Company name + browser name (e.g., "Microsoft Edge")
        if !browser.companyName.isEmpty {
            candidates.append(
                appSupportDir
                    .appendingPathComponent(browser.companyName)
                    .appendingPathComponent(browser.name)
            )
        }

        // Just browser name
        candidates.append(appSupportDir.appendingPathComponent(browser.name))

        // Alternative folder names
        for altFolder in browser.alternativeDataFolders {
            candidates.append(appSupportDir.appendingPathComponent(altFolder))
        }

        // Safari special case - uses ~/Library/Safari
        if browser.bundleId.contains("Safari") {
            let safariDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Safari")
            candidates.insert(safariDir, at: 0)
        }

        print("[BrowserDiscovery]    🔎 Checking \(candidates.count) candidate paths for \(browser.name):")
        for candidate in candidates {
            let exists = directoryExists(at: candidate)
            print("[BrowserDiscovery]       \(exists ? "✅" : "❌") \(candidate.path)")
            if exists {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Profile Discovery

    /// Finds all user profiles within a browser's data directory
    static func findProfiles(in dataPath: URL, for browser: BrowserInfo) -> [URL] {
        var profiles: [URL] = []

        // Firefox uses a different structure
        if browser.engine == .gecko {
            return findFirefoxProfiles(in: dataPath)
        }

        // Safari doesn't have profiles like Chromium
        if browser.engine == .webkit && browser.bundleId.contains("Safari") {
            return [dataPath] // Safari data dir itself is the "profile"
        }

        // Chromium-style profiles
        // Check for "Default" profile (most common)
        let defaultProfile = dataPath.appendingPathComponent("Default")
        if directoryExists(at: defaultProfile) {
            profiles.append(defaultProfile)
        }

        // Check for numbered profiles ("Profile 1", "Profile 2", etc.)
        for i in 1...20 {
            let profile = dataPath.appendingPathComponent("Profile \(i)")
            if directoryExists(at: profile) {
                profiles.append(profile)
            } else {
                // Stop checking after first missing profile
                break
            }
        }

        return profiles
    }

    /// Special handling for Firefox profiles (uses profiles.ini)
    static func findFirefoxProfiles(in firefoxDataPath: URL) -> [URL] {
        var profiles: [URL] = []

        let profilesIni = firefoxDataPath.appendingPathComponent("Profiles/profiles.ini")

        guard let contents = try? String(contentsOf: profilesIni, encoding: .utf8) else {
            // Fallback: look for any profile directories
            let profilesDir = firefoxDataPath.appendingPathComponent("Profiles")
            if let profileFolders = try? FileManager.default.contentsOfDirectory(
                at: profilesDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                return profileFolders.filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
            }
            return profiles
        }

        // Parse profiles.ini to find profile paths
        let lines = contents.components(separatedBy: .newlines)
        var currentPath: String?

        for line in lines {
            if line.hasPrefix("Path=") {
                currentPath = line.replacingOccurrences(of: "Path=", with: "")
            } else if line.hasPrefix("IsRelative=1"), let path = currentPath {
                // Relative path
                let profileURL = firefoxDataPath
                    .appendingPathComponent("Profiles")
                    .appendingPathComponent(path)
                if directoryExists(at: profileURL) {
                    profiles.append(profileURL)
                }
                currentPath = nil
            } else if line.hasPrefix("IsRelative=0"), let path = currentPath {
                // Absolute path
                let profileURL = URL(fileURLWithPath: path)
                if directoryExists(at: profileURL) {
                    profiles.append(profileURL)
                }
                currentPath = nil
            }
        }

        return profiles
    }

    // MARK: - Extension Detection

    /// Searches for extension in all browsers and returns list with extension info
    static func findExtension(
        extensionId: String,
        in browsers: [InstalledBrowser]
    ) -> [InstalledBrowser] {
        return browsers.map { browser in
            var updatedBrowser = browser

            // Check all profiles for this extension
            for profile in browser.profiles {
                if let _ = findExtensionInProfile(extensionId: extensionId, profilePath: profile, browserInfo: browser.info) {
                    updatedBrowser.hasExtensionInstalled = true
                    updatedBrowser.extensionId = extensionId
                    break
                }
            }

            return updatedBrowser
        }
    }

    /// Searches for extension by name (useful when ID is unknown)
    static func findExtensionByName(
        name: String,
        in browsers: [InstalledBrowser]
    ) -> [InstalledBrowser] {
        return browsers.map { browser in
            var updatedBrowser = browser

            for profile in browser.profiles {
                if let foundId = searchForExtensionByName(name: name, profilePath: profile, browserInfo: browser.info) {
                    updatedBrowser.hasExtensionInstalled = true
                    updatedBrowser.extensionId = foundId
                    break
                }
            }

            return updatedBrowser
        }
    }

    /// Finds extension in a specific profile (Chromium-style)
    private static func findExtensionInProfile(
        extensionId: String,
        profilePath: URL,
        browserInfo: BrowserInfo
    ) -> URL? {
        if browserInfo.engine == .chromium || (browserInfo.engine == .webkit && browserInfo.bundleId.contains("kagi")) {
            // Chromium-style extensions
            let extensionPath = profilePath
                .appendingPathComponent("Extensions")
                .appendingPathComponent(extensionId)

            return directoryExists(at: extensionPath) ? extensionPath : nil
        }

        return nil
    }

    /// Searches for extension by name in profile
    private static func searchForExtensionByName(
        name: String,
        profilePath: URL,
        browserInfo: BrowserInfo
    ) -> String? {
        if browserInfo.engine == .chromium || (browserInfo.engine == .webkit && browserInfo.bundleId.contains("kagi")) {
            let extensionsDir = profilePath.appendingPathComponent("Extensions")

            guard let extensionFolders = try? FileManager.default.contentsOfDirectory(
                at: extensionsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return nil
            }

            // Check each extension folder
            for extensionFolder in extensionFolders {
                let extensionId = extensionFolder.lastPathComponent

                // Validate extension ID format (32 lowercase letters a-p)
                let pattern = "^[a-p]{32}$"
                guard extensionId.range(of: pattern, options: .regularExpression) != nil else {
                    continue
                }

                // Look for manifest.json in version subfolders
                if let versionFolders = try? FileManager.default.contentsOfDirectory(
                    at: extensionFolder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    for versionFolder in versionFolders {
                        let manifestPath = versionFolder.appendingPathComponent("manifest.json")

                        if isExtensionWithName(name: name, manifestPath: manifestPath) {
                            return extensionId
                        }
                    }
                }
            }

            // Also check Preferences/Secure Preferences for unpacked extensions
            return searchUnpackedExtensions(name: name, profilePath: profilePath)
        }

        return nil
    }

    /// Search for unpacked extensions in Preferences files
    private static func searchUnpackedExtensions(
        name: String,
        profilePath: URL
    ) -> String? {
        // Check both Preferences and Secure Preferences
        let prefsPaths = [
            profilePath.appendingPathComponent("Preferences"),
            profilePath.appendingPathComponent("Secure Preferences")
        ]

        for prefsPath in prefsPaths {
            guard let data = try? Data(contentsOf: prefsPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let extensions = json["extensions"] as? [String: Any],
                  let settings = extensions["settings"] as? [String: Any] else {
                continue
            }

            for (extensionId, extData) in settings {
                guard let extDict = extData as? [String: Any] else { continue }

                // Method 1: Check embedded manifest
                if let manifest = extDict["manifest"] as? [String: Any],
                   let manifestName = manifest["name"] as? String,
                   manifestName == name {
                    return extensionId
                }

                // Method 2: For unpacked extensions, read manifest from path
                let location = extDict["location"] as? Int ?? -1
                if location == 4, // Unpacked extension
                   let extPath = extDict["path"] as? String {
                    let manifestPath = URL(fileURLWithPath: extPath)
                        .appendingPathComponent("manifest.json")

                    if isExtensionWithName(name: name, manifestPath: manifestPath) {
                        return extensionId
                    }
                }
            }
        }

        return nil
    }

    /// Checks if manifest.json has the specified name
    private static func isExtensionWithName(
        name: String,
        manifestPath: URL
    ) -> Bool {
        guard let data = try? Data(contentsOf: manifestPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manifestName = json["name"] as? String else {
            return false
        }

        return manifestName == name
    }

    // MARK: - Native Messaging Paths

    /// Gets the path where Native Messaging manifest should be installed
    static func getNativeMessagingPath(for browser: BrowserInfo, dataPath: URL?) -> URL? {
        switch browser.nativeMessagingType {
        case .chromium:
            // Chromium browsers use per-browser locations
            guard let dataPath = dataPath else { return nil }
            return dataPath.appendingPathComponent("NativeMessagingHosts")

        case .mozilla:
            // Firefox browsers share a common location
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts")

        case .safari:
            // Safari uses App Extensions (different mechanism)
            return nil

        case .none:
            return nil
        }
    }

    // MARK: - Helper Methods

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }
}

import Foundation

// MARK: - Data Models

struct BlockingProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var blockedDomains: [String]
    var blockedAppBundleIds: [String]
    var isDefault: Bool
}

struct MergedBlockList {
    let domains: [String]
    let appBundleIds: [String]
}

// MARK: - BlockingProfileManager

class BlockingProfileManager {

    // MARK: - Storage

    private let settingsDir: String
    private let filePath: String

    // MARK: - State

    private(set) var profiles: [BlockingProfile]

    // MARK: - Default profile contents

    private static let defaultDomains: [String] = [
        "reddit.com",
        "twitter.com",
        "x.com",
        "youtube.com",
        "instagram.com",
        "facebook.com",
        "tiktok.com",
        "twitch.tv",
        "discord.com",
        "snapchat.com"
    ]

    private static let defaultAppBundleIds: [String] = [
        "com.spotify.client",
        "tv.twitch.app",
        "com.hnc.Discord",
        "com.valvesoftware.steam"
    ]

    // MARK: - Init

    init(settingsDir: String? = nil) {
        let dir = settingsDir ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/Library/Application Support/Intentional"
        }()
        self.settingsDir = dir
        self.filePath = "\(dir)/blocking_profiles.json"

        // Try to load from disk first
        if let loaded = BlockingProfileManager.load(from: self.filePath) {
            self.profiles = loaded
        } else {
            // Create default profile
            let defaultProfile = BlockingProfile(
                id: UUID(),
                name: "Distracting Apps & Sites",
                blockedDomains: BlockingProfileManager.defaultDomains,
                blockedAppBundleIds: BlockingProfileManager.defaultAppBundleIds,
                isDefault: true
            )
            self.profiles = [defaultProfile]
            save()
        }
    }

    // MARK: - CRUD

    @discardableResult
    func createProfile(name: String, domains: [String], appBundleIds: [String]) -> BlockingProfile {
        let profile = BlockingProfile(
            id: UUID(),
            name: name,
            blockedDomains: domains,
            blockedAppBundleIds: appBundleIds,
            isDefault: false
        )
        profiles.append(profile)
        save()
        return profile
    }

    func deleteProfile(id: UUID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return false
        }
        // Cannot delete the default profile
        if profiles[index].isDefault {
            return false
        }
        profiles.remove(at: index)
        save()
        return true
    }

    func updateProfile(id: UUID, name: String? = nil, domains: [String]? = nil, appBundleIds: [String]? = nil) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let name = name {
            profiles[index].name = name
        }
        if let domains = domains {
            profiles[index].blockedDomains = domains
        }
        if let appBundleIds = appBundleIds {
            profiles[index].blockedAppBundleIds = appBundleIds
        }
        save()
    }

    func profile(for id: UUID) -> BlockingProfile? {
        return profiles.first(where: { $0.id == id })
    }

    // MARK: - Merging

    func mergedBlockList(profileIds: [UUID]) -> MergedBlockList {
        var domainSet = Set<String>()
        var appSet = Set<String>()
        var orderedDomains: [String] = []
        var orderedApps: [String] = []

        for id in profileIds {
            guard let profile = profile(for: id) else {
                continue  // Unknown UUID — skip gracefully
            }
            for domain in profile.blockedDomains {
                if domainSet.insert(domain).inserted {
                    orderedDomains.append(domain)
                }
            }
            for app in profile.blockedAppBundleIds {
                if appSet.insert(app).inserted {
                    orderedApps.append(app)
                }
            }
        }

        return MergedBlockList(domains: orderedDomains, appBundleIds: orderedApps)
    }

    // MARK: - Persistence

    private func save() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: settingsDir) {
            try? fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return }
        fm.createFile(atPath: filePath, contents: data)
    }

    private static func load(from path: String) -> [BlockingProfile]? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return try? JSONDecoder().decode([BlockingProfile].self, from: data)
    }
}

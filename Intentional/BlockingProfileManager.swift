import Foundation

// MARK: - Data Models

struct BlockingProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var blockedDomains: [String]
    var blockedAppBundleIds: [String]
    var isDefault: Bool
    var alwaysActive: Bool

    // May 2026 Opal-parity additions: each profile becomes a "block rule"
    // with an optional recurring schedule. Tolerant decoding ensures
    // pre-existing on-disk profiles continue to load without these fields.
    var enabled: Bool
    var startHour: Int?
    var startMinute: Int?
    var endHour: Int?
    var endMinute: Int?
    /// ISO weekday numbers: 1 = Monday … 7 = Sunday. Default = every day.
    var activeDays: [Int]

    init(
        id: UUID,
        name: String,
        blockedDomains: [String],
        blockedAppBundleIds: [String],
        isDefault: Bool,
        alwaysActive: Bool,
        enabled: Bool = true,
        startHour: Int? = nil,
        startMinute: Int? = nil,
        endHour: Int? = nil,
        endMinute: Int? = nil,
        activeDays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    ) {
        self.id = id
        self.name = name
        self.blockedDomains = blockedDomains
        self.blockedAppBundleIds = blockedAppBundleIds
        self.isDefault = isDefault
        self.alwaysActive = alwaysActive
        self.enabled = enabled
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.activeDays = activeDays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        blockedDomains = try c.decodeIfPresent([String].self, forKey: .blockedDomains) ?? []
        blockedAppBundleIds = try c.decodeIfPresent([String].self, forKey: .blockedAppBundleIds) ?? []
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        alwaysActive = try c.decodeIfPresent(Bool.self, forKey: .alwaysActive) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        startHour = try c.decodeIfPresent(Int.self, forKey: .startHour)
        startMinute = try c.decodeIfPresent(Int.self, forKey: .startMinute)
        endHour = try c.decodeIfPresent(Int.self, forKey: .endHour)
        endMinute = try c.decodeIfPresent(Int.self, forKey: .endMinute)
        activeDays = try c.decodeIfPresent([Int].self, forKey: .activeDays) ?? [1, 2, 3, 4, 5, 6, 7]
    }

    /// True when this rule is currently producing enforcement:
    /// `enabled == true` AND (no schedule set, OR current local time and ISO weekday
    /// fall inside the configured window).
    var isCurrentlyActive: Bool {
        return isCurrentlyActive(at: Date(), calendar: Calendar.current)
    }

    /// Testable variant — caller can inject `Date` + `Calendar` for unit tests.
    func isCurrentlyActive(at date: Date, calendar: Calendar) -> Bool {
        guard enabled else { return false }
        // No schedule = always-active rule
        guard let sh = startHour, let eh = endHour else { return true }
        let sm = startMinute ?? 0
        let em = endMinute ?? 0
        // ISO 8601 weekday: Mon=1 … Sun=7. Calendar.weekday is Sun=1 … Sat=7.
        let weekday = calendar.component(.weekday, from: date)
        let isoWeekday = weekday == 1 ? 7 : weekday - 1
        if !activeDays.contains(isoWeekday) { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let nowMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let startMin = sh * 60 + sm
        let endMin = eh * 60 + em
        return nowMin >= startMin && nowMin < endMin
    }

    enum CodingKeys: String, CodingKey {
        case id, name, blockedDomains, blockedAppBundleIds, isDefault, alwaysActive
        case enabled, startHour, startMinute, endHour, endMinute, activeDays
    }
}

struct MergedBlockList {
    let domains: [String]
    let appBundleIds: [String]
}

// MARK: - BlockingProfileManager

@available(*, deprecated, message: "Profile concept folded into Focus Mode app rules. Use FocusModeStore. Will be removed in slice 13.")
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
                isDefault: true,
                alwaysActive: false
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
            isDefault: false,
            alwaysActive: false
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

    func updateProfile(
        id: UUID,
        name: String? = nil,
        domains: [String]? = nil,
        appBundleIds: [String]? = nil,
        alwaysActive: Bool? = nil,
        enabled: Bool? = nil,
        startHour: Int?? = nil,
        startMinute: Int?? = nil,
        endHour: Int?? = nil,
        endMinute: Int?? = nil,
        activeDays: [Int]? = nil
    ) {
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
        if let alwaysActive = alwaysActive {
            profiles[index].alwaysActive = alwaysActive
        }
        if let enabled = enabled {
            profiles[index].enabled = enabled
        }
        // Double-optional: outer .some means "caller passed a value (possibly nil)".
        if let sh = startHour { profiles[index].startHour = sh }
        if let sm = startMinute { profiles[index].startMinute = sm }
        if let eh = endHour { profiles[index].endHour = eh }
        if let em = endMinute { profiles[index].endMinute = em }
        if let days = activeDays {
            profiles[index].activeDays = days
        }
        save()
    }

    /// Flip enabled flag on a profile and persist. Returns the updated profile.
    @discardableResult
    func setEnabled(id: UUID, enabled: Bool) -> BlockingProfile? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        profiles[index].enabled = enabled
        save()
        return profiles[index]
    }

    /// Returns merged block list of all profiles with alwaysActive == true
    func alwaysActiveBlockList() -> MergedBlockList {
        let activeIds = profiles.filter { $0.alwaysActive }.map { $0.id }
        return mergedBlockList(profileIds: activeIds)
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

    // MARK: - Close-the-noise sweep helpers

    /// Hosts blocked by a rule that is currently enforcing (enabled + inside
    /// its scheduled window, if any). Used by the sweep to stash a tab
    /// regardless of the AI verdict.
    func activeBlockedDomains() -> [String] {
        return profiles
            .filter { $0.isCurrentlyActive }
            .flatMap { $0.blockedDomains }
    }

    /// App bundle IDs blocked by a currently-enforcing rule. Used by the sweep
    /// to hide a native app regardless of the in-scope check.
    func activeBlockedBundleIds() -> [String] {
        return profiles
            .filter { $0.isCurrentlyActive }
            .flatMap { $0.blockedAppBundleIds }
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

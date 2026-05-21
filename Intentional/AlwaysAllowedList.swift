import Foundation

/// Per-user list of apps + websites the sweep at session-start NEVER touches.
/// Global (not per-Intention) — replaces the old per-Intention allowWebsites/allowBundleIds.
struct AlwaysAllowedList: Codable, Equatable {
    var bundleIds: Set<String>
    var domains: Set<String>

    static let defaults = AlwaysAllowedList(
        bundleIds: [
            "com.apple.systempreferences",
            "com.apple.iCal",                  // Calendar
            "com.apple.MobileSMS",             // Messages
            "com.apple.Music",                 // Apple Music
            "com.spotify.client",              // Spotify
            "com.1password.1password",         // 1Password
            "com.1password.1password-launcher",
            "com.apple.finder",
        ],
        domains: [
            "music.apple.com",
            "1password.com",
            "calendar.google.com",
            "icloud.com",
        ]
    )
}

/// Disk-backed store for the global Always-Allowed list. Lives at
/// <appSupport>/Intentional/always_allowed.json.
final class AlwaysAllowedStore {
    private(set) var list: AlwaysAllowedList
    private let fileURL: URL

    init(storageDir: String) {
        let dir = URL(fileURLWithPath: storageDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("always_allowed.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(AlwaysAllowedList.self, from: data) {
            self.list = loaded
        } else {
            self.list = AlwaysAllowedList.defaults
            persist()
        }
    }

    func addBundleId(_ bid: String) { list.bundleIds.insert(bid); persist() }
    func removeBundleId(_ bid: String) { list.bundleIds.remove(bid); persist() }
    func addDomain(_ domain: String) { list.domains.insert(domain.lowercased()); persist() }
    func removeDomain(_ domain: String) { list.domains.remove(domain.lowercased()); persist() }

    func isBundleIdAllowed(_ bid: String) -> Bool { list.bundleIds.contains(bid) }

    /// Suffix match — "example.com" matches "sub.example.com" but not "notexample.com".
    func isDomainAllowed(_ host: String) -> Bool {
        let h = host.lowercased()
        for d in list.domains {
            if h == d || h.hasSuffix("." + d) { return true }
        }
        return false
    }

    /// Replace the whole list (used by the migration runner + Settings save).
    func replace(_ newList: AlwaysAllowedList) {
        self.list = AlwaysAllowedList(
            bundleIds: newList.bundleIds,
            domains: Set(newList.domains.map { $0.lowercased() })
        )
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

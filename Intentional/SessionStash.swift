import Foundation

struct StashedTab: Codable, Equatable {
    let title: String
    let url: String
    let browserBundleId: String
    let originalWindow: Int
    let originalIndex: Int
}

struct SessionStash: Codable, Equatable {
    let sessionId: String
    let createdAt: Date
    let bookmarksFolderId: String?    // Browser-side identifier we wrote bookmarks into
    let hiddenBundleIds: [String]     // Apps that were Cmd+H'd
    let stashedTabs: [StashedTab]
}

/// File-per-session JSON store. Lives at <appSupport>/Intentional/session_stashes/.
final class SessionStashStore {
    private let dir: URL

    init(storageDir: String) {
        self.dir = URL(fileURLWithPath: storageDir)
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }

    func save(_ stash: SessionStash) {
        let url = dir.appendingPathComponent("\(stash.sessionId).json")
        guard let data = try? JSONEncoder().encode(stash) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func load(sessionId: String) -> SessionStash? {
        let url = dir.appendingPathComponent("\(sessionId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionStash.self, from: data)
    }

    func delete(sessionId: String) {
        let url = dir.appendingPathComponent("\(sessionId).json")
        try? FileManager.default.removeItem(at: url)
    }

    func listAll() -> [SessionStash] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let stashes = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionStash? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(SessionStash.self, from: data)
            }
        return stashes.sorted { $0.createdAt > $1.createdAt }
    }

    /// Deletes stashes whose createdAt is older than now - maxAgeSeconds. Returns count removed.
    @discardableResult
    func purgeOlderThan(maxAgeSeconds: TimeInterval) -> Int {
        let threshold = Date().addingTimeInterval(-maxAgeSeconds)
        var removed = 0
        for stash in listAll() where stash.createdAt < threshold {
            delete(sessionId: stash.sessionId)
            removed += 1
        }
        return removed
    }

    /// Used by AppDelegate to stamp the bookmark folder name at sweep time.
    static func timestampString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: Date())
    }
}

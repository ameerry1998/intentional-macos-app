import Foundation

struct FocusSession: Codable {
    let startedAt: Date
    let activeProfileIds: [UUID]
    let intention: String?
    let aiScoringEnabled: Bool
    let triggeredByPuck: Bool
}

class FocusSessionManager {
    private let settingsDir: String
    private let filePath: String

    private(set) var activeSession: FocusSession?

    var isActive: Bool { activeSession != nil }

    init(settingsDir: String? = nil) {
        let dir = settingsDir ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("Intentional").path
        }()
        self.settingsDir = dir
        self.filePath = (dir as NSString).appendingPathComponent("focus_session.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Restore session from disk if file exists
        if let data = FileManager.default.contents(atPath: filePath) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            activeSession = try? decoder.decode(FocusSession.self, from: data)
        }
    }

    func startSession(profileIds: [UUID], intention: String?, aiEnabled: Bool, triggeredByPuck: Bool) {
        let session = FocusSession(
            startedAt: Date(),
            activeProfileIds: profileIds,
            intention: intention,
            aiScoringEnabled: aiEnabled,
            triggeredByPuck: triggeredByPuck
        )
        activeSession = session
        persist(session)
    }

    func stopSession() {
        activeSession = nil
        try? FileManager.default.removeItem(atPath: filePath)
    }

    // MARK: - Private

    private func persist(_ session: FocusSession) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(session) else { return }
        FileManager.default.createFile(atPath: filePath, contents: data)
    }
}

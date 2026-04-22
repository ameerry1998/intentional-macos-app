import Foundation

// MARK: - Data Models

enum HostKind: String, Codable { case domain, appBundleId }

struct HostItem: Codable, Equatable, Identifiable {
    let id: UUID
    var kind: HostKind
    var value: String
    var note: String?
}

struct SessionEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?
    var durationSec: Int?
    var focusScore: Double?
    var blockId: UUID?
}

struct LearnedSite: Codable, Equatable, Identifiable {
    let id: UUID
    var host: String
    var hitCount: Int
    var lastSeenAt: Date
    var isPromoted: Bool
}

struct Project: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var intention: String
    var accent: String
    var allowed: [HostItem]
    var blocked: [HostItem]
    var learned: [LearnedSite]
    var blocklistIds: [UUID]
    var allowSearchEnginesForThisProject: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var sessions: [SessionEntry]
    var weekMinutes: [Int]
    var weeklyAnchor: Date?

    // Custom decode so existing `projects.json` files written before the
    // `blocked` field existed still load. Missing key → default to [].
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.intention = try c.decode(String.self, forKey: .intention)
        self.accent = try c.decode(String.self, forKey: .accent)
        self.allowed = try c.decode([HostItem].self, forKey: .allowed)
        self.blocked = try c.decodeIfPresent([HostItem].self, forKey: .blocked) ?? []
        self.learned = try c.decode([LearnedSite].self, forKey: .learned)
        self.blocklistIds = try c.decode([UUID].self, forKey: .blocklistIds)
        self.allowSearchEnginesForThisProject = try c.decode(Bool.self, forKey: .allowSearchEnginesForThisProject)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        self.sessions = try c.decode([SessionEntry].self, forKey: .sessions)
        self.weekMinutes = try c.decode([Int].self, forKey: .weekMinutes)
        self.weeklyAnchor = try c.decodeIfPresent(Date.self, forKey: .weeklyAnchor)
    }

    init(id: UUID, name: String, intention: String, accent: String,
         allowed: [HostItem], blocked: [HostItem], learned: [LearnedSite],
         blocklistIds: [UUID], allowSearchEnginesForThisProject: Bool,
         createdAt: Date, updatedAt: Date, lastUsedAt: Date?,
         sessions: [SessionEntry], weekMinutes: [Int], weeklyAnchor: Date?) {
        self.id = id
        self.name = name
        self.intention = intention
        self.accent = accent
        self.allowed = allowed
        self.blocked = blocked
        self.learned = learned
        self.blocklistIds = blocklistIds
        self.allowSearchEnginesForThisProject = allowSearchEnginesForThisProject
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.sessions = sessions
        self.weekMinutes = weekMinutes
        self.weeklyAnchor = weeklyAnchor
    }
}

struct ProjectSummary: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let intention: String
    let accent: String
    let lastUsedAt: Date?
    let humanLastUsed: String
    let weekMinutes: [Int]
    let totalHours: Double
    let blocklistCount: Int
    let allowedCount: Int
}

struct ProjectPatch {
    var name: String?
    var intention: String?
    var accent: String?
    var allowed: [HostItem]?
    var blocked: [HostItem]?
    var blocklistIds: [UUID]?
    var allowSearchEnginesForThisProject: Bool?
}

// MARK: - ProjectStore

/// Actor-isolated JSON-backed store for `Project` records.
/// Persists to `<settingsDir>/projects.json` (default:
/// `~/Library/Application Support/Intentional`).
actor ProjectStore {

    // MARK: - Constants

    static let accentPalette: [String] = ["#E87461", "#F0B060", "#8ea0b8", "#7fb39a"]
    static let sessionsCap = 20
    static let learnedCap = 200
    static let weekLength = 14
    static let intentionCap = 140

    // Shared encoder/decoder/calendar/formatter — constructing these per call
    // is measurable overhead in learned-hit and listSummary hot paths.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private static let calendar = Calendar.current
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    // MARK: - Storage

    private let fileURL: URL

    // MARK: - State

    private var projects: [Project] = []

    // MARK: - Init

    init(settingsDir: String? = nil) {
        let dirURL: URL
        if let settingsDir = settingsDir {
            dirURL = URL(fileURLWithPath: settingsDir)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dirURL = support.appendingPathComponent("Intentional", isDirectory: true)
        }
        self.fileURL = dirURL.appendingPathComponent("projects.json")

        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        } catch {
            print("⚠️ [ProjectStore] could not create settings dir: \(error)")
        }

        if let data = try? Data(contentsOf: fileURL) {
            do {
                self.projects = try Self.decoder.decode([Project].self, from: data)
            } catch {
                print("⚠️ [ProjectStore] decode failed, starting empty: \(error)")
                self.projects = []
            }
        }
    }

    // MARK: - Queries

    func list() -> [Project] {
        return projects
    }

    func listSummary() -> [ProjectSummary] {
        return projects.map { p in
            let totalSec = p.sessions.compactMap { $0.durationSec }.reduce(0, +)
            return ProjectSummary(
                id: p.id,
                name: p.name,
                intention: p.intention,
                accent: p.accent,
                lastUsedAt: p.lastUsedAt,
                humanLastUsed: Self.humanLastUsed(p.lastUsedAt),
                weekMinutes: p.weekMinutes,
                totalHours: Double(totalSec) / 3600.0,
                blocklistCount: p.blocklistIds.count,
                allowedCount: p.allowed.count
            )
        }
    }

    func get(id: UUID) -> Project? {
        return projects.first(where: { $0.id == id })
    }

    func projectsReferencing(blocklistId: UUID) -> [Project] {
        return projects.filter { $0.blocklistIds.contains(blocklistId) }
    }

    // MARK: - CRUD

    @discardableResult
    func create(name: String,
                intention: String,
                allowed: [HostItem],
                blocked: [HostItem] = [],
                blocklistIds: [UUID],
                allowSearchEngines: Bool) -> Project {
        let accent = Self.accentPalette[projects.count % Self.accentPalette.count]
        let truncated = String(intention.prefix(Self.intentionCap))
        let now = Date()
        let project = Project(
            id: UUID(),
            name: name,
            intention: truncated,
            accent: accent,
            allowed: allowed,
            blocked: blocked,
            learned: [],
            blocklistIds: Self.dedupe(blocklistIds),
            allowSearchEnginesForThisProject: allowSearchEngines,
            createdAt: now,
            updatedAt: now,
            lastUsedAt: nil,
            sessions: [],
            weekMinutes: Array(repeating: 0, count: Self.weekLength),
            weeklyAnchor: nil
        )
        projects.append(project)
        persist()
        return project
    }

    @discardableResult
    func update(id: UUID, patch: ProjectPatch) -> Project? {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return nil }
        if let name = patch.name { projects[idx].name = name }
        if let intention = patch.intention {
            projects[idx].intention = String(intention.prefix(Self.intentionCap))
        }
        if let accent = patch.accent { projects[idx].accent = accent }
        if let allowed = patch.allowed { projects[idx].allowed = allowed }
        if let blocked = patch.blocked { projects[idx].blocked = blocked }
        if let blocklistIds = patch.blocklistIds { projects[idx].blocklistIds = Self.dedupe(blocklistIds) }
        if let allowSearch = patch.allowSearchEnginesForThisProject {
            projects[idx].allowSearchEnginesForThisProject = allowSearch
        }
        projects[idx].updatedAt = Date()
        persist()
        return projects[idx]
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return false }
        projects.remove(at: idx)
        persist()
        return true
    }

    // MARK: - Sessions

    @discardableResult
    func recordSessionStart(projectId: UUID, blockId: UUID?) -> UUID? {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return nil }
        let now = Date()
        let entry = SessionEntry(
            id: UUID(),
            startedAt: now,
            endedAt: nil,
            durationSec: nil,
            focusScore: nil,
            blockId: blockId
        )
        projects[idx].sessions.append(entry)
        if projects[idx].sessions.count > Self.sessionsCap {
            projects[idx].sessions = Array(projects[idx].sessions.suffix(Self.sessionsCap))
        }
        projects[idx].lastUsedAt = now
        persist()
        return entry.id
    }

    @discardableResult
    func recordSessionEnd(projectId: UUID, sessionId: UUID, focusScore: Double?) -> SessionEntry? {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectId }) else { return nil }
        guard let sIdx = projects[pIdx].sessions.firstIndex(where: { $0.id == sessionId }) else { return nil }

        let now = Date()
        var entry = projects[pIdx].sessions[sIdx]
        entry.endedAt = now
        let durationSec = max(0, Int(now.timeIntervalSince(entry.startedAt)))
        entry.durationSec = durationSec
        entry.focusScore = focusScore
        projects[pIdx].sessions[sIdx] = entry

        let anchor = projects[pIdx].weeklyAnchor
        let shifted = Self.advanceWeekly(projects[pIdx].weekMinutes, from: anchor, to: now)
        // Only touch weeklyAnchor when the window actually moved — avoids
        // rewriting identical JSON back on every session end within a day.
        if shifted != projects[pIdx].weekMinutes || anchor == nil {
            projects[pIdx].weekMinutes = shifted
            projects[pIdx].weeklyAnchor = now
        }
        projects[pIdx].weekMinutes[Self.weekLength - 1] += durationSec / 60

        projects[pIdx].lastUsedAt = now
        projects[pIdx].updatedAt = now

        persist()
        return entry
    }

    /// Find the most-recent session for a project that matches a given block UUID.
    /// Used when the FocusBlock lifecycle (not our code) knows only the blockId and
    /// needs to finalize the session via recordSessionEnd.
    func findActiveSession(projectId: UUID, blockId: UUID) -> UUID? {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return nil }
        return projects[idx].sessions
            .reversed()
            .first(where: { $0.blockId == blockId && $0.endedAt == nil })?
            .id
    }

    // MARK: - Learned sites

    func recordLearnedHit(projectId: UUID, host: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let now = Date()
        if let sIdx = projects[idx].learned.firstIndex(where: { $0.host == host }) {
            projects[idx].learned[sIdx].hitCount += 1
            projects[idx].learned[sIdx].lastSeenAt = now
        } else {
            projects[idx].learned.append(LearnedSite(
                id: UUID(),
                host: host,
                hitCount: 1,
                lastSeenAt: now,
                isPromoted: false
            ))
            Self.evictLearnedIfNeeded(&projects[idx].learned)
        }
        persist()
    }

    @discardableResult
    func promoteLearnedSite(projectId: UUID, host: String) -> Bool {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectId }) else { return false }
        guard let sIdx = projects[pIdx].learned.firstIndex(where: { $0.host == host }) else { return false }

        projects[pIdx].learned[sIdx].isPromoted = true

        let alreadyAllowed = projects[pIdx].allowed.contains(where: {
            $0.value == host && $0.kind == .domain
        })
        if !alreadyAllowed {
            projects[pIdx].allowed.append(HostItem(
                id: UUID(),
                kind: .domain,
                value: host,
                note: nil
            ))
        }

        persist()
        return true
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try Self.encoder.encode(projects)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("⚠️ [ProjectStore] persist failed: \(error)")
        }
    }

    // MARK: - Helpers

    private static func dedupe(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var out: [UUID] = []
        for id in ids where seen.insert(id).inserted { out.append(id) }
        return out
    }

    /// LRU-ish eviction: drop unpromoted entries with lowest hitCount first,
    /// tiebreak by oldest `lastSeenAt`. Promoted entries are kept.
    private static func evictLearnedIfNeeded(_ sites: inout [LearnedSite]) {
        guard sites.count > Self.learnedCap else { return }
        let overflow = sites.count - Self.learnedCap
        let indexed = sites.enumerated().map { ($0.offset, $0.element) }
        let victims = indexed
            .filter { !$0.1.isPromoted }
            .sorted { a, b in
                if a.1.hitCount != b.1.hitCount { return a.1.hitCount < b.1.hitCount }
                return a.1.lastSeenAt < b.1.lastSeenAt
            }
            .prefix(overflow)
            .map { $0.0 }
        let dropSet = Set(victims)
        sites = sites.enumerated().compactMap { dropSet.contains($0.offset) ? nil : $0.element }
    }

    /// Shift the week window so that index 13 corresponds to the calendar day
    /// of `to`. No-op if `from` is nil or is already the same day.
    static func advanceWeekly(_ week: [Int], from: Date?, to: Date) -> [Int] {
        guard let from = from else { return week }
        let fromDay = Self.calendar.startOfDay(for: from)
        let toDay = Self.calendar.startOfDay(for: to)
        guard let dayDiff = Self.calendar.dateComponents([.day], from: fromDay, to: toDay).day, dayDiff > 0 else {
            return week
        }
        let shift = min(dayDiff, Self.weekLength)
        var shifted = Array(week.dropFirst(shift))
        shifted.append(contentsOf: Array(repeating: 0, count: shift))
        assert(shifted.count == Self.weekLength)
        return shifted
    }

    /// Humanize a "last used" date to a compact relative string.
    /// - nil → "new"
    /// - same calendar day → "today"
    /// - 1 day (calendar) → "yesterday"
    /// - ≥2 and <7 days → "Nd ago"
    /// - ≥7 and <28 days → "Nw ago" (N = days/7 rounded down)
    /// - ≥28 days → "MMM d"
    static func humanLastUsed(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "new" }
        let startNow = Self.calendar.startOfDay(for: now)
        let startThen = Self.calendar.startOfDay(for: date)
        guard let dayDiff = Self.calendar.dateComponents([.day], from: startThen, to: startNow).day else {
            return "new"
        }
        if dayDiff <= 0 { return "today" }
        if dayDiff == 1 { return "yesterday" }
        if dayDiff < 7 { return "\(dayDiff)d ago" }
        if dayDiff < 28 { return "\(dayDiff / 7)w ago" }
        return Self.monthDayFormatter.string(from: date)
    }
}

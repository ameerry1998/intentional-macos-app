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

/// A persisted Project — the user's durable intention container.
///
/// Fields with spec notes:
/// - `intention`: max 140 chars (truncated on create/update).
/// - `accent`: hex string from the 4-color palette, assigned at create time
///   by `projects.count % palette.count`.
/// - `weekMinutes`: exactly 14 entries, index 13 = today. Shifted lazily
///   on `recordSessionEnd` based on `weeklyAnchor`.
/// - `sessions`: capped at the last 20 entries.
struct Project: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var intention: String
    var accent: String
    var allowed: [HostItem]
    var learned: [LearnedSite]
    var blocklistIds: [UUID]
    var allowSearchEnginesForThisProject: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var sessions: [SessionEntry]
    var weekMinutes: [Int]

    /// Calendar day that `weekMinutes[13]` represents. Private-ish: used only
    /// for lazy weekly shifting in `recordSessionEnd`. JSON-encoded so the
    /// shift tracking survives process restarts.
    var weeklyAnchor: Date?
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
    var blocklistIds: [UUID]?
    var allowSearchEnginesForThisProject: Bool?
}

// MARK: - ProjectStore

/// Actor-isolated JSON-backed store for `Project` records.
///
/// Persists to `<settingsDir>/projects.json` (default:
/// `~/Library/Application Support/Intentional`). Uses `.iso8601` on both
/// encode and decode — changing only one side was the bug in the prior
/// revision; don't repeat it.
actor ProjectStore {

    // MARK: - Constants

    static let accentPalette: [String] = ["#E87461", "#F0B060", "#8ea0b8", "#7fb39a"]
    static let sessionsCap = 20
    static let weekLength = 14
    static let intentionCap = 140

    // MARK: - Storage

    private let settingsDir: String
    private let filePath: String

    // MARK: - State

    private var projects: [Project] = []

    // MARK: - Init

    init(settingsDir: String? = nil) {
        let dir = settingsDir ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/Library/Application Support/Intentional"
        }()
        self.settingsDir = dir
        self.filePath = "\(dir)/projects.json"

        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                print("⚠️ [ProjectStore] could not create settings dir: \(error)")
            }
        }

        if let data = fm.contents(atPath: self.filePath) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                self.projects = try decoder.decode([Project].self, from: data)
            } catch {
                print("⚠️ [ProjectStore] decode failed, starting empty: \(error)")
                self.projects = []
            }
        } else {
            self.projects = []
        }
    }

    // MARK: - Queries

    func list() -> [Project] {
        return projects
    }

    func listSummary() -> [ProjectSummary] {
        return projects.map { p in
            let totalSec = p.sessions.compactMap { $0.durationSec }.reduce(0, +)
            let hours = Double(totalSec) / 3600.0
            return ProjectSummary(
                id: p.id,
                name: p.name,
                intention: p.intention,
                accent: p.accent,
                lastUsedAt: p.lastUsedAt,
                humanLastUsed: Self.humanLastUsed(p.lastUsedAt),
                weekMinutes: p.weekMinutes,
                totalHours: hours,
                blocklistCount: p.blocklistIds.count,
                allowedCount: p.allowed.count
            )
        }
    }

    func get(id: UUID) -> Project? {
        return projects.first(where: { $0.id == id })
    }

    /// Returns full `Project`s that reference the given blocklist id in their
    /// `blocklistIds`. Used by BlockingProfileManager to refuse deletion of
    /// referenced profiles (or to warn the user).
    func projectsReferencing(blocklistId: UUID) -> [Project] {
        return projects.filter { $0.blocklistIds.contains(blocklistId) }
    }

    // MARK: - CRUD

    @discardableResult
    func create(name: String,
                intention: String,
                allowed: [HostItem],
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

    /// Start a session: append a `SessionEntry` with `startedAt = now` and
    /// return its id. Caps to last 20, bumps `lastUsedAt`, persists.
    @discardableResult
    func recordSessionStart(projectId: UUID, blockId: UUID?) -> UUID {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return UUID() }
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

    /// Finalize a session: set `endedAt`, `durationSec`, `focusScore`; shift
    /// the weekly window if days have passed; bucket minutes into today's slot.
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

        // Lazy weekly shift, then add this session's minutes.
        let anchor = projects[pIdx].weeklyAnchor
        projects[pIdx].weekMinutes = Self.advanceWeekly(projects[pIdx].weekMinutes, from: anchor, to: now)
        projects[pIdx].weeklyAnchor = now
        let minutes = durationSec / 60
        projects[pIdx].weekMinutes[Self.weekLength - 1] += minutes

        projects[pIdx].lastUsedAt = now
        projects[pIdx].updatedAt = now

        persist()
        return entry
    }

    // MARK: - Learned sites

    /// Upsert a learned-site hit: increment `hitCount` if present, otherwise
    /// append a new entry. No ordering.
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
        }
        persist()
    }

    /// Mark a learned site as promoted and add a domain `HostItem` to
    /// `allowed` if not already present. Returns false if no matching
    /// learned site exists.
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
        let fm = FileManager.default
        if !fm.fileExists(atPath: settingsDir) {
            do {
                try fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
            } catch {
                print("⚠️ [ProjectStore] persist mkdir failed: \(error)")
                return
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(projects)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            print("⚠️ [ProjectStore] persist failed: \(error)")
        }
    }

    // MARK: - Helpers

    /// Remove duplicate UUIDs while preserving first-seen order.
    private static func dedupe(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var out: [UUID] = []
        for id in ids where seen.insert(id).inserted { out.append(id) }
        return out
    }

    /// Shift the week window so that index 13 corresponds to the calendar day
    /// of `to`. No-op if `from` is nil or is already the same day. Shift count
    /// is clamped to `weekLength` (larger gaps zero the whole window).
    static func advanceWeekly(_ week: [Int], from: Date?, to: Date) -> [Int] {
        guard let from = from else { return week }
        let cal = Calendar.current
        let fromDay = cal.startOfDay(for: from)
        let toDay = cal.startOfDay(for: to)
        guard let dayDiff = cal.dateComponents([.day], from: fromDay, to: toDay).day, dayDiff > 0 else {
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
    /// - ≥28 days → "MMM d" via DateFormatter with locale en_US_POSIX
    static func humanLastUsed(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "new" }
        let cal = Calendar.current
        let startNow = cal.startOfDay(for: now)
        let startThen = cal.startOfDay(for: date)
        guard let dayDiff = cal.dateComponents([.day], from: startThen, to: startNow).day else {
            return "new"
        }
        if dayDiff <= 0 { return "today" }
        if dayDiff == 1 { return "yesterday" }
        if dayDiff < 7 { return "\(dayDiff)d ago" }
        if dayDiff < 28 { return "\(dayDiff / 7)w ago" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }
}

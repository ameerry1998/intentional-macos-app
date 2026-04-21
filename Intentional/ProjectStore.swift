import Foundation

// MARK: - Data Models

/// A persisted Project — the user's durable intention container.
///
/// Projects are the top-level unit above individual focus sessions: each
/// Project references a ``BlockingProfile`` by UUID (decoupled — this file
/// does NOT import `BlockingProfile`), carries its own allow-list overrides,
/// and accumulates session rollups (counts, minutes, weekly histogram,
/// recent history, learned-site corrections).
struct Project: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var desc: String
    var blocklistId: UUID
    var allowed: [HostItem]
    var accent: String
    var createdAt: Date

    // Rollups — maintained by ProjectStore, not client-editable.
    var lastGoal: String
    var sessions: Int
    var focusedMinutes: Int
    var lastUsedAt: Date?
    var weekly: [Int]
    var history: [SessionEntry]
    var learnedSites: [LearnedSite]

    /// The calendar day that `weekly[13]` corresponds to. Updated only when
    /// a session ends — `recordSessionStart` mustn't move this, or the
    /// day-gap shift in `recordSessionEnd` would lose its reference point.
    var weeklyAnchor: Date?
}

struct HostItem: Codable, Equatable {
    var value: String
    var sub: String?
    var kind: HostKind
}

enum HostKind: String, Codable {
    case app
    case site
}

struct SessionEntry: Codable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let goal: String
    let focusScore: Int
}

struct LearnedSite: Codable, Equatable {
    var value: String
    var hits: Int
    var kind: HostKind
    var lastSeen: Date
}

/// Cheap projection for the Projects list UI — omits per-project
/// `history` and `learnedSites`, which can be large and are only needed
/// on the detail screen.
struct ProjectSummary: Codable, Equatable {
    let id: UUID
    let title: String
    let desc: String
    let blocklistId: UUID
    let accent: String
    let sessions: Int
    let hours: Double
    let lastUsed: String
    let weekly: [Int]
}

struct ProjectPatch {
    var title: String?
    var desc: String?
    var blocklistId: UUID?
    var allowed: [HostItem]?
}

// MARK: - ProjectStore

/// Actor-isolated JSON-backed store for ``Project`` records.
///
/// Persists to `~/Library/Application Support/Intentional/projects.json`
/// (or a test-specific `settingsDir`). Load-on-init with graceful fallback
/// to an empty list if the file is missing or corrupt. All mutations write
/// synchronously from within the actor — actor isolation guarantees no
/// concurrent writers.
actor ProjectStore {

    // MARK: - Constants

    /// The accent palette. `create` rotates through this list based on the
    /// current project count when no explicit accent is given.
    static let accentPalette: [String] = ["#E87461", "#F0B060", "#8ea0b8", "#7fb39a"]

    /// Cap on `Project.history` — keep only the most recent N sessions.
    static let historyCap = 20

    /// `weekly` array length — rolling 14-day histogram, rightmost = today.
    static let weeklyLength = 14

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

        if let data = FileManager.default.contents(atPath: self.filePath) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode([Project].self, from: data) {
                self.projects = loaded
            } else {
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
            ProjectSummary(
                id: p.id,
                title: p.title,
                desc: p.desc,
                blocklistId: p.blocklistId,
                accent: p.accent,
                sessions: p.sessions,
                hours: Self.roundedHours(minutes: p.focusedMinutes),
                lastUsed: Self.humanLastUsed(p.lastUsedAt),
                weekly: p.weekly
            )
        }
    }

    func get(id: UUID) -> Project? {
        return projects.first(where: { $0.id == id })
    }

    /// Returns summaries for every project whose `blocklistId` matches.
    /// Used by BlockingProfileManager to refuse deletion of referenced profiles.
    func projectsReferencing(blocklistId: UUID) -> [ProjectSummary] {
        return listSummary().filter { $0.blocklistId == blocklistId }
    }

    // MARK: - CRUD

    @discardableResult
    func create(title: String, desc: String, blocklistId: UUID, allowed: [HostItem], accent: String? = nil) -> Project {
        let chosenAccent = accent ?? Self.accentPalette[projects.count % Self.accentPalette.count]
        let project = Project(
            id: UUID(),
            title: title,
            desc: desc,
            blocklistId: blocklistId,
            allowed: allowed,
            accent: chosenAccent,
            createdAt: Date(),
            lastGoal: "",
            sessions: 0,
            focusedMinutes: 0,
            lastUsedAt: nil,
            weekly: Array(repeating: 0, count: Self.weeklyLength),
            history: [],
            learnedSites: [],
            weeklyAnchor: nil
        )
        projects.append(project)
        persist()
        return project
    }

    @discardableResult
    func update(id: UUID, patch: ProjectPatch) -> Project? {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return nil }
        if let title = patch.title { projects[idx].title = title }
        if let desc = patch.desc { projects[idx].desc = desc }
        if let blocklistId = patch.blocklistId { projects[idx].blocklistId = blocklistId }
        if let allowed = patch.allowed { projects[idx].allowed = allowed }
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

    // MARK: - Rollups

    /// Seed the resume hero without incrementing session count (that happens on end).
    func recordSessionStart(projectId: UUID, goal: String, at: Date = Date()) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[idx].lastGoal = goal
        projects[idx].lastUsedAt = at
        persist()
    }

    /// Finalize a session: append to history (capped), bump counters, and
    /// bucket the minutes into today's slot in `weekly`, shifting old entries
    /// left if days have passed since the previous session.
    func recordSessionEnd(projectId: UUID, startedAt: Date, endedAt: Date, focusScore: Int) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }

        let minutes = max(0, Int((endedAt.timeIntervalSince(startedAt)) / 60.0))

        var updated = projects[idx]

        // Weekly: advance the window to `endedAt`'s calendar day before
        // bucketing, so that weekly[13] is always "today" (per endedAt).
        // Drives off `weeklyAnchor` — the day the rightmost slot represents —
        // rather than `lastUsedAt`, which `recordSessionStart` may have
        // already moved forward without shifting the window.
        updated.weekly = Self.advanceWeekly(updated.weekly, from: updated.weeklyAnchor, to: endedAt)
        updated.weekly[Self.weeklyLength - 1] += minutes
        updated.weeklyAnchor = endedAt

        updated.sessions += 1
        updated.focusedMinutes += minutes

        let entry = SessionEntry(
            id: UUID(),
            startedAt: startedAt,
            endedAt: endedAt,
            goal: updated.lastGoal,
            focusScore: focusScore
        )
        updated.history.append(entry)
        if updated.history.count > Self.historyCap {
            updated.history.removeFirst(updated.history.count - Self.historyCap)
        }

        updated.lastUsedAt = endedAt
        projects[idx] = updated
        persist()
    }

    /// Upsert a learned-site hit: increments `hits` if the host is already
    /// tracked, otherwise creates a new entry. Maintains `learnedSites`
    /// sorted by `hits` descending.
    func recordLearnedHit(projectId: UUID, host: String, kind: HostKind, at: Date = Date()) {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }

        var sites = projects[idx].learnedSites
        if let existing = sites.firstIndex(where: { $0.value == host }) {
            sites[existing].hits += 1
            sites[existing].lastSeen = at
        } else {
            sites.append(LearnedSite(value: host, hits: 1, kind: kind, lastSeen: at))
        }
        sites.sort { $0.hits > $1.hits }
        projects[idx].learnedSites = sites
        persist()
    }

    /// Promote a learned site to the permanent `allowed` list. Deduplicates:
    /// if the value already exists in `allowed`, only removes from
    /// `learnedSites`. Returns the updated project (or nil if not found).
    @discardableResult
    func promoteLearnedSite(projectId: UUID, value: String) -> Project? {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return nil }
        guard let siteIdx = projects[idx].learnedSites.firstIndex(where: { $0.value == value }) else {
            return projects[idx]
        }

        let site = projects[idx].learnedSites[siteIdx]
        projects[idx].learnedSites.remove(at: siteIdx)

        let alreadyAllowed = projects[idx].allowed.contains(where: { $0.value == value })
        if !alreadyAllowed {
            projects[idx].allowed.append(HostItem(value: site.value, sub: nil, kind: site.kind))
        }

        persist()
        return projects[idx]
    }

    // MARK: - Persistence

    private func persist() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: settingsDir) {
            do {
                try fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
            } catch {
                print("⚠️ [ProjectStore] persist failed: \(error)")
                return
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(projects)
            fm.createFile(atPath: filePath, contents: data)
        } catch {
            print("⚠️ [ProjectStore] persist failed: \(error)")
        }
    }

    // MARK: - Helpers

    /// Shift the `weekly` window so that index 13 corresponds to the calendar
    /// day of `to`. If `from` is nil, no shift is needed. If `from` and `to`
    /// are the same calendar day, no shift. Otherwise shift left by N days
    /// and pad with zeros on the right.
    static func advanceWeekly(_ weekly: [Int], from: Date?, to: Date) -> [Int] {
        guard let from = from else { return weekly }

        let cal = Calendar.current
        let fromDay = cal.startOfDay(for: from)
        let toDay = cal.startOfDay(for: to)
        guard let dayDiff = cal.dateComponents([.day], from: fromDay, to: toDay).day, dayDiff > 0 else {
            return weekly
        }

        let shift = min(dayDiff, Self.weeklyLength)
        var shifted = Array(weekly.dropFirst(shift))
        shifted.append(contentsOf: Array(repeating: 0, count: shift))
        // If shift >= weeklyLength, `shifted` is all zeros at this point.
        // Ensure length invariant regardless.
        if shifted.count < Self.weeklyLength {
            shifted.append(contentsOf: Array(repeating: 0, count: Self.weeklyLength - shifted.count))
        } else if shifted.count > Self.weeklyLength {
            shifted = Array(shifted.prefix(Self.weeklyLength))
        }
        return shifted
    }

    /// Humanize a "last used" date to a compact relative string.
    /// - nil → "new"
    /// - same calendar day → "today"
    /// - yesterday → "yesterday"
    /// - within 7 days → "Nd ago"
    /// - within 4 weeks → "Nw ago"
    /// - else → localized month + day ("Apr 3")
    static func humanLastUsed(_ date: Date?, now: Date = Date()) -> String {
        guard let date = date else { return "new" }
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        let startThen = cal.startOfDay(for: date)
        guard let dayDiff = cal.dateComponents([.day], from: startThen, to: startToday).day else {
            return "new"
        }
        if dayDiff <= 0 { return "today" }
        if dayDiff == 1 { return "yesterday" }
        if dayDiff < 7 { return "\(dayDiff)d ago" }
        if dayDiff < 28 { return "\(dayDiff / 7)w ago" }
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMM d")
        return fmt.string(from: date)
    }

    /// Round a minutes total to hours with 1-decimal precision (e.g. 75 → 1.3).
    static func roundedHours(minutes: Int) -> Double {
        return (Double(minutes) / 60.0 * 10).rounded() / 10
    }
}

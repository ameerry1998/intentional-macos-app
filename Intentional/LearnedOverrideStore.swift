import Foundation

/// Tracks hosts where the user has corrected a relevance assessment ("This was wrong").
///
/// Hosts accumulate correction timestamps. When the tally for a host reaches
/// ``promotionThreshold`` or more within the 30-day rolling window, the host is
/// "promoted" — the OCR verification pass will always run for it, even if the
/// metadata scorer said off-task and the host is not in containerAppDomains.
///
/// Persistence: a JSON-encoded `[host: [ISO8601 timestamp]]` dictionary stored
/// under the UserDefaults key ``UserDefaults.learnedOverrideSummaryKey``.
/// The JSONL file is the authoritative record; UserDefaults is a cache that
/// avoids rescanning on every app launch.
actor LearnedOverrideStore {

    // MARK: - Constants

    /// Number of user corrections within the 30-day window required to promote a host.
    static let promotionThreshold = 3

    /// Rolling window for counting corrections (30 days in seconds).
    static let windowSeconds: TimeInterval = 30 * 24 * 60 * 60

    // MARK: - State

    /// Per-host lists of correction timestamps (pruned to the last 30 days on every mutation).
    private var overrideDates: [String: [Date]] = [:]

    // MARK: - Query

    /// Returns true if this host has been promoted (3+ user corrections in the last 30 days).
    /// Computed dynamically so stale data can never produce a false positive.
    func isPromoted(host: String) -> Bool {
        let key = normalise(host)
        let dates = pruned(overrideDates[key] ?? [])
        return dates.count >= Self.promotionThreshold
    }

    /// Returns the set of currently-promoted hosts (for logging).
    func promotedHostsSnapshot() -> Set<String> {
        Set(overrideDates.filter { pruned($0.value).count >= Self.promotionThreshold }.keys)
    }

    // MARK: - Mutation

    /// Record a user correction for `host` at `date`.
    /// Prunes stale timestamps and persists to UserDefaults.
    func recordOverride(host: String, at date: Date = Date()) {
        let key = normalise(host)
        guard !key.isEmpty else { return }
        var dates = overrideDates[key] ?? []
        dates.append(date)
        overrideDates[key] = pruned(dates)
        persist()
    }

    // MARK: - Population

    /// Load state from UserDefaults. Call on app start before the first query.
    /// If the key is missing, falls back to a full JSONL scan via `reloadFromLog(at:)`.
    func loadFromUserDefaults(logPath: URL) {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: UserDefaults.learnedOverrideSummaryKey),
           let raw = try? JSONDecoder().decode([String: [Date]].self, from: data) {
            overrideDates = raw.mapValues { pruned($0) }
        } else {
            // First launch or key missing — scan JSONL once and populate.
            reloadFromLog(at: logPath)
        }
    }

    /// Scan the JSONL relevance log, extract every line with `userOverride == true`,
    /// rebuild `overrideDates`, and persist.
    func reloadFromLog(at logPath: URL) {
        guard let contents = try? String(contentsOf: logPath, encoding: .utf8) else {
            // File missing or unreadable — start empty.
            overrideDates = [:]
            persist()
            return
        }

        let formatter = ISO8601DateFormatter()
        var rebuilt: [String: [Date]] = [:]

        for line in contents.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let override = json["userOverride"] as? Bool, override,
                  let hostname = json["hostname"] as? String, !hostname.isEmpty,
                  let tsString = json["timestamp"] as? String,
                  let date = formatter.date(from: tsString)
            else { continue }

            let key = normalise(hostname)
            var dates = rebuilt[key] ?? []
            dates.append(date)
            rebuilt[key] = dates
        }

        overrideDates = rebuilt.mapValues { pruned($0) }
        persist()
    }

    // MARK: - Helpers

    /// Lowercase the host and strip any leading "www." for consistent keying.
    private func normalise(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }

    /// Remove dates older than the 30-day rolling window.
    private func pruned(_ dates: [Date]) -> [Date] {
        let cutoff = Date().addingTimeInterval(-Self.windowSeconds)
        return dates.filter { $0 >= cutoff }
    }

    /// Persist the current `overrideDates` to UserDefaults.
    private func persist() {
        if let data = try? JSONEncoder().encode(overrideDates) {
            UserDefaults.standard.set(data, forKey: UserDefaults.learnedOverrideSummaryKey)
        }
    }
}

// MARK: - UserDefaults Key

extension UserDefaults {
    static let learnedOverrideSummaryKey = "learnedOverrideSummary"
}

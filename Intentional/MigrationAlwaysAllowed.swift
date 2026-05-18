import Foundation

/// One-shot migration: collects per-Intention `allowWebsites` + `allowBundleIds`
/// from the on-disk intentions cache, unions them into the global
/// AlwaysAllowedStore, and writes a receipt so it never re-runs.
///
/// Intentionally lightweight — reads the cache JSON directly with no
/// IntentionStore dependency so it can run before the actor is wired in.
struct MigrationAlwaysAllowed {

    static func runIfNeeded(intentionsCachePath: String,
                            store: AlwaysAllowedStore,
                            receiptPath: String) {
        if FileManager.default.fileExists(atPath: receiptPath) { return }
        guard let data = FileManager.default.contents(atPath: intentionsCachePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let intentions = json["intentions"] as? [[String: Any]] else {
            // No cache yet (fresh install). Mark receipt anyway so we don't try again.
            writeReceipt(at: receiptPath, added: 0)
            return
        }

        var addedDomains = 0
        var addedBundleIds = 0
        for intention in intentions {
            if let sites = intention["allowWebsites"] as? [String] {
                for s in sites {
                    let host = normalizeHost(s)
                    if !host.isEmpty, !store.list.domains.contains(host) {
                        store.addDomain(host)
                        addedDomains += 1
                    }
                }
            }
            if let bids = intention["allowBundleIds"] as? [String] {
                for b in bids where !store.list.bundleIds.contains(b) {
                    store.addBundleId(b)
                    addedBundleIds += 1
                }
            }
        }

        writeReceipt(at: receiptPath, added: addedDomains + addedBundleIds)
    }

    private static func normalizeHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("https://") { s.removeFirst(8) }
        if s.hasPrefix("http://") { s.removeFirst(7) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s
    }

    private static func writeReceipt(at path: String, added: Int) {
        let payload = """
        { "completedAt": "\(ISO8601DateFormatter().string(from: Date()))", "added": \(added) }
        """
        try? payload.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

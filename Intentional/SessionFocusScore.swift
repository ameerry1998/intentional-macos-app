// SessionFocusScore.swift
//
// Projects-kill B2 (June 2026): derives the focus score the Mac sends on
// session stop (`POST /focus/toggle {action:"stop", focus_score}`).
//
// Why this source: the old per-block tick accountant (EarnedBrowseManager.
// blockFocusStats) was deleted in Rules R6 and had been producing all-zeros
// behind its feature flag long before that. The only live, honest signal of
// "how relevant was the user's screen during the session" is the relevance
// log — FocusMonitor.logAssessment appends one JSONL line per evaluation
// (~every 10s while a session is active) to
// `~/Library/Application Support/Intentional/relevance_log.jsonl`.
//
// Derivation: fraction of REAL relevance judgments inside the session window
// that came back `relevant == true`. Excluded so the score isn't inflated /
// polluted:
//   - `isEvent == true`  — red-shift / intervention / override EVENTS, not
//     assessments of what was on screen.
//   - `neutral == true`  — neutral-app entries are logged with
//     `relevant: true, confidence: 0` ("Neutral app", "AI override active");
//     they are explicitly NOT a judgment that the content matched the intent.
// Kept: `userOverride == true` lines — the user asserted relevance; honoring
// the override is the product contract.
//
// Fail-honest: fewer than `minimumSamples` qualifying assessments (session
// too short, monitor off, log unreadable) → nil. The caller sends no
// focus_score rather than a fabricated one.

import Foundation

enum SessionFocusScore {

    /// Max bytes read from the end of the log. Assessments are ~300 B at a
    /// 10s cadence (~2.6 MB/day of continuous sessions), so an 8 MB tail
    /// covers any plausible single session with a wide margin while keeping
    /// the read bounded (the full log grows unbounded — 26 MB+ in the wild).
    private static let tailReadBytes = 8 * 1024 * 1024

    /// Minimum qualifying assessments for a meaningful ratio (~30s of
    /// monitoring at the 10s cadence).
    static let minimumSamples = 3

    private static let isoFormatter = ISO8601DateFormatter()

    static func defaultLogURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Intentional")
            .appendingPathComponent("relevance_log.jsonl")
    }

    /// Returns the session's focus score in 0.0–1.0, or nil when no sound
    /// signal exists. Reads up to `tailReadBytes` from the end of the log —
    /// call off the main thread.
    static func compute(sessionStart: Date,
                        sessionEnd: Date = Date(),
                        logURL: URL? = nil) -> Double? {
        let url = logURL ?? defaultLogURL()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > UInt64(tailReadBytes) ? fileSize - UInt64(tailReadBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        // Seeking mid-file may land mid-line; the first fragment is garbage.
        if offset > 0 && !lines.isEmpty { lines.removeFirst() }

        var relevant = 0
        var total = 0
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let tsString = obj["timestamp"] as? String,
                  let ts = isoFormatter.date(from: tsString) else { continue }
            guard ts >= sessionStart && ts <= sessionEnd else { continue }
            if (obj["isEvent"] as? Bool) == true { continue }
            if (obj["neutral"] as? Bool) == true { continue }
            guard let isRelevant = obj["relevant"] as? Bool else { continue }
            total += 1
            if isRelevant { relevant += 1 }
        }

        guard total >= minimumSamples else { return nil }
        return Double(relevant) / Double(total)
    }
}

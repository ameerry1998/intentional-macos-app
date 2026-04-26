import Foundation

/// Describes which scoring path was taken to produce a relevance verdict.
/// Persisted into the assessments log for instrumentation — distinguishes
/// metadata-only verdicts from OCR-verified ones, and enforced off-task
/// from low-confidence-let-through.
enum ScoringPath: String, Codable {
    /// Metadata said relevant — no OCR was performed.
    case metadataRelevant
    /// Metadata said off-task; OCR not triggered (gate said no, PID drifted, or OCR unavailable).
    case metadataOffTask
    /// Metadata said off-task below the confidence threshold — consumer let it through
    /// rather than enforcing. Logged for instrumentation; no blocking occurred.
    case metadataOffTaskLowConf
    /// Metadata said off-task; OCR rescore overturned the verdict to relevant.
    case ocrVerifiedRelevant
    /// Metadata said off-task; OCR rescore confirmed off-task.
    case ocrVerifiedOffTask
}

/// One step in a scoring decision: which stage ran, how long after scoring-entry, and outcome.
/// Attached to `RelevanceScorer.Result.trace` and persisted per-assessment so the user can
/// see the full journey ("keyword miss → cache miss → metadata off-task → OCR relevant").
struct TraceStep: Codable {
    /// Step name: "keyword", "approval", "cache", "metadata", "ocr-gate",
    /// "ocr-capture", "ocr-ocr", "ocr-rescore", "final".
    let step: String
    /// Milliseconds since scoring entry when this step landed.
    let elapsedMs: Int
    /// Free-form outcome for the step (e.g. "miss", "hit (age=4s)", "off-task/40").
    let detail: String
}

/// Records timestamped scoring steps relative to a start instant.
/// Lives for one `scoreRelevance` call; Result.trace is populated via `finalize()`.
final class ScoringTracer {
    private let start = Date()
    private(set) var steps: [TraceStep] = []

    func record(_ step: String, _ detail: String = "") {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        steps.append(TraceStep(step: step, elapsedMs: ms, detail: detail))
    }

    /// One-line summary suitable for postLog. Each step rendered as `name:detail@Xms`,
    /// joined with " → " so the journey reads left-to-right.
    func summary(label: String) -> String {
        let chain = steps
            .map { $0.detail.isEmpty ? "\($0.step)@\($0.elapsedMs)ms" : "\($0.step):\($0.detail)@\($0.elapsedMs)ms" }
            .joined(separator: " → ")
        return "🧠 [Trace] \(label) \(chain)"
    }
}

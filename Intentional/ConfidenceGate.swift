import Foundation

/// Confidence-threshold gate for off-task verdicts.
///
/// The scorer emits a confidence value but historically the consumer treated every
/// `relevant == false` as equally actionable. Under the asymmetric-cost principle
/// (a wrong block is worse than a wrong pass), low-confidence off-task verdicts
/// should not trigger enforcement — the model gets to say "I don't know" instead
/// of being forced into a binary call.
///
/// OCR-verified off-task verdicts bypass the threshold: the OCR pass already ran
/// a second-chance check on actual on-screen content, so its verdict is trustworthy
/// regardless of the numeric confidence the model emitted.
enum ConfidenceGate {
    /// Off-task verdicts with confidence strictly below this value are passed through
    /// as "unsure" rather than enforced. Tune by measuring the low-conf hit rate in
    /// the assessments log before moving this.
    static let lowConfThreshold = 50

    /// Decide whether an off-task verdict should trigger enforcement.
    ///
    /// - Returns: `true` if the verdict should be enforced (block/red shift/overlay),
    ///            `false` if it should be logged and let through (no enforcement).
    static func shouldEnforceOffTask(relevant: Bool, confidence: Int, path: ScoringPath) -> Bool {
        guard !relevant else { return false }
        if path == .ocrVerifiedOffTask { return true }
        return confidence >= lowConfThreshold
    }
}

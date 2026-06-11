// BlockFocusStats.swift
//
// Rules Consolidation R6 (June 2026): extracted from EarnedBrowseManager when
// that engine was deleted (it had been feature-flagged OFF since the
// FOCUS_CONCEPTS simplification and was replaced by the shared daily
// allowance — backend /allowance/* via RuleStore, see docs/features/rules.md).
//
// This struct survives as the data carrier for the block-end celebration
// surfaces (FocusMonitor.showCelebration → CelebrationData, and
// BlockEndRitualController.show). NOTHING populates per-block tick counts
// today — the engine that did is gone, and at runtime it had been producing
// all-zeros since the feature flag went false — so celebration cards render
// their zero-state, exactly as they did before the deletion. If per-block
// focus stats come back, they should be derived from the relevance log /
// focus_sessions rather than a resurrected earned-browse accountant.

import Foundation

/// Focus stats for a single schedule block.
struct BlockFocusStats {
    var blockId: String
    var blockTitle: String
    var relevantTicks: Int = 0
    var totalTicks: Int = 0
    var earnedMinutes: Double = 0
    var nudgeCount: Int = 0
    var recoveryCount: Int = 0     // Distraction→focus transitions this block
    var overridesUsed: Int = 0     // AI overrides used this block
    /// Focus score: percentage of ticks that were relevant (0-100)
    var focusScore: Int { totalTicks > 0 ? Int(round(Double(relevantTicks) / Double(totalTicks) * 100)) : 0 }
}

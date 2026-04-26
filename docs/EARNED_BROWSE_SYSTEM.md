# Earned Browse System (EarnedBrowseManager)

## Earning Rates

| Condition | Rate | Meaning |
|-----------|------|---------|
| Standard work | 0.2 | 5 min work = 1 min browse |
| Deep work (25 min continuous focus) | 0.3 | ~3.33 min work = 1 min browse |
| Welcome credit | 5.0 min/day | Granted on first load of the day |

## Cost Multipliers

| Block Type | Multiplier | Effect |
|------------|-----------|--------|
| Deep Work | 0x | Social media blocked entirely — macOS app aggressively enforces (redirect at 20s), extension rejects sessions |
| Focus Hours | 2x | ALL browsing costs 2x from pool (intent and free browse alike) |
| Free Time | 1x | ALL browsing costs 1x. Setting an intent earns +10 min bonus (once per block) |

## Intent Bonus (Free Time Incentive)
- During Free Time blocks, starting a session with an intent (not free browse) grants +10 min to the earned pool
- One bonus per block, tracked by `intentBonusGrantedBlockIds` (set of block IDs)
- Granted in `NativeMessagingHost.handleSessionStart()` when `!freeBrowse && blockType == .freeTime`
- `intentBonusAvailable` computed property: true when current block is Free Time and bonus hasn't been claimed
- Broadcast to extension via `EARNED_MINUTES_UPDATE` after granting; fields: `intentBonusAvailable`, `intentBonusAmount`
- Reset daily in `ensureToday()`, persisted in `earned_browse.json`

## Delay Escalation (per work block, resets on block change)
Steps: 30s → 60s → 120s → 300s. Increases with each social media visit during a work block.

## Per-Block Tracking
```swift
struct BlockFocusStats {
    var relevantTicks: Int     // Ticks where user was on-task
    var totalTicks: Int        // Total ticks in the block
    var earnedMinutes: Double  // Minutes earned this block
    var focusScore: Double     // relevantTicks / totalTicks
    var recoveryCount: Int     // Distraction→focus transitions this block
    var selfRating: Int?       // 0-4 emoji scale from end ritual (nil = not rated)
    var reflection: String     // "What went well?" text from end ritual
}
```

## Pool State (synced to extension)
```swift
earnedMinutes          // Total earned today
usedMinutes            // Total consumed today
availableMinutes       // earnedMinutes - usedMinutes
isPoolExhausted        // availableMinutes <= 0
costMultiplier         // 0x deep work, 2x focus hours, 1x free time
effectiveBrowseTime    // Available minutes / costMultiplier
intentBonusAvailable   // True if +10 min bonus available for current block
intentBonusAmount      // Bonus amount (10.0)
```

## Related Docs
- [EARN_YOUR_BROWSE_IMPLEMENTATION.md](EARN_YOUR_BROWSE_IMPLEMENTATION.md) — Full implementation spec with UI mockups and message protocol
- [UNIFIED_BUDGET_DESIGN.md](UNIFIED_BUDGET_DESIGN.md) — Product rationale and design decisions

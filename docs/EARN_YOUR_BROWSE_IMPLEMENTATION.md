# Earn Your Browse — Implementation Specification

This document is the implementation guide for the unified budget system. It covers every UI screen (with ASCII mockups), every code change across the macOS app, Chrome extension, and backend, and every message type and data structure.

Reference: `UNIFIED_BUDGET_DESIGN.md` for product rationale and design decisions.

---

## Table of Contents

1. [UI Mockups](#ui-mockups)
2. [macOS App Changes](#macos-app-changes)
3. [Chrome Extension Changes](#chrome-extension-changes)
4. [Backend Changes](#backend-changes)
5. [Data Structures](#data-structures)
6. [Message Protocol](#message-protocol)
7. [Migration Plan](#migration-plan)

---

## UI Mockups

### 1. Justification Screen (Work Block, Has Earned Minutes)

Replaces the current intent prompt. ONLY shown during work blocks. Communicates upfront that work-time social media costs 2x. Shows what they were just working on. Visual scarcity bar.

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│           ┌─────────────────────────────────────────┐           │
│           │  ⏱  WORK TIME · Social media costs 2x   │           │
│           └─────────────────────────────────────────┘           │
│                                                                 │
│                  You're working on: Taxes                        │
│                  Last active: TurboTax (2 min ago)              │
│                                                                 │
│              ┌──────────────────────────────┐                   │
│              │         12 min               │                   │
│              │       available              │                   │
│              │                              │                   │
│              │  ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░  │                   │
│              │  earned 45  ·  used 33       │                   │
│              └──────────────────────────────┘                   │
│                                                                 │
│           Why do you need YouTube right now?                     │
│                                                                 │
│    ┌───────────────────────────────────────────────────┐        │
│    │                                                   │        │
│    │                                                   │        │
│    └───────────────────────────────────────────────────┘        │
│                                                                 │
│         You can continue after a brief pause.                   │
│                                                                 │
│    ┌────────────────────┐    ┌─────────────────────────┐       │
│    │  Back to TurboTax  │    │   Continue (0:27)       │       │
│    │  (indigo, active)  │    │   (disabled, gray)      │       │
│    └────────────────────┘    └─────────────────────────┘       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**States:**
- Countdown active: "Continue (0:27)" button is disabled/gray, ticks down
- Countdown done + text entered: "Continue" button enabled (indigo)
- Countdown done + no text: "Continue" stays disabled
- Escalated delay: countdown starts at 60s / 2m / 5m instead of 30s
- "Back to [app]" uses `lastActiveApp` from WORK_BLOCK_STATE. Falls back to "Stay Focused" if unavailable.

**After Continue is clicked** → screen shows "Checking..." spinner while AI assesses justification.

### 2. AI Result — Relevant (Cost Reduced to 1x)

Shown after AI determines the justification IS related to the work block. This is the reward.

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│              ┌──────────────────────────────────┐               │
│              │  ✓  Related to: Taxes             │               │
│              │                                    │               │
│              │  "1099-NEC filing procedures are   │               │
│              │   directly related to tax prep."   │               │
│              │                                    │               │
│              │  Since this is work-related,       │               │
│              │  you'll get the full 12 minutes.   │               │
│              └──────────────────────────────────┘               │
│                                                                 │
│    ┌────────────────────┐    ┌─────────────────────────┐       │
│    │  Back to TurboTax  │    │  Continue to            │       │
│    │  (outline)         │    │  YouTube →  (indigo)    │       │
│    └────────────────────┘    └─────────────────────────┘       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3. AI Result — Not Relevant (Cost Stays at 2x)

Shown after AI determines the justification is NOT related. Default cost stays.

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│              ┌──────────────────────────────────┐               │
│              │  ✗  Not related to: Taxes          │               │
│              │                                    │               │
│              │  "Checking sports scores is not    │               │
│              │   related to tax preparation."     │               │
│              │                                    │               │
│              │  Your time will burn at 2x.        │               │
│              │  12 min available → 6 min of       │               │
│              │  browsing time.                    │               │
│              └──────────────────────────────────┘               │
│                                                                 │
│    ┌────────────────────┐    ┌─────────────────────────┐       │
│    │  Back to TurboTax  │    │   Continue at 2x        │       │
│    │  (indigo)          │    │   (amber)               │       │
│    └────────────────────┘    └─────────────────────────┘       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4. Blocked Screen (Work Block, Zero Earned Minutes)

User has 0 earned minutes. They cannot proceed.

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│                                                                 │
│                        ╭─────────────╮                          │
│                        │  ○  ◉  ○    │                          │
│                        ╰─────────────╯                          │
│                                                                 │
│                  You have 0 earned minutes                       │
│                                                                 │
│          Earn more by focusing on: Taxes                         │
│                                                                 │
│          ┌─────────────────────────────────────┐                │
│          │                                     │                │
│          │   25 min focused work = 5 min       │                │
│          │   earned browsing time              │                │
│          │                                     │                │
│          └─────────────────────────────────────┘                │
│                                                                 │
│    ┌──────────────────────┐  ┌──────────────────────┐          │
│    │  Request More Time   │  │    Back to Work      │          │
│    │  (if has partner)    │  │    (indigo)          │          │
│    └──────────────────────┘  └──────────────────────┘          │
│                                                                 │
│    (if no partner:)                                             │
│    Set up an accountability partner in the                      │
│    Intentional app to request more time.                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5. Time's Up Overlay (Earned Minutes Hit 0 Mid-Session)

Appears when earned minutes deplete while user is actively browsing.

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ (blurred bg) │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░               │
│ ░░░░     ┌───────────────────────────────────┐ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │         ⏱️  Time's Up              │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │  You've used all your browsing    │ ░░░░             │
│ ░░░░     │  time for today.                  │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │  Earned today: 45 min             │ ░░░░             │
│ ░░░░     │  Used today:   45 min             │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │  Focus on your next work block    │ ░░░░             │
│ ░░░░     │  to earn more browsing time.      │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │  ┌─────────────────────────────┐  │ ░░░░             │
│ ░░░░     │  │    Request More Time        │  │ ░░░░             │
│ ░░░░     │  │    (if hasPartner)          │  │ ░░░░             │
│ ░░░░     │  └─────────────────────────────┘  │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │  ┌─────────────────────────────┐  │ ░░░░             │
│ ░░░░     │  │    Back to Work             │  │ ░░░░             │
│ ░░░░     │  └─────────────────────────────┘  │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     └───────────────────────────────────┘ ░░░░             │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6. Partner Extra Time Flow (Within Time's Up Overlay)

After clicking "Request More Time":

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│ ░░░░     ┌───────────────────────────────────┐ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │      📱 Request Sent               │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │  Your accountability partner      │ ░░░░             │
│ ░░░░     │  (alex@example.com) has been      │ ░░░░             │
│ ░░░░     │  notified.                        │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │  Ask them for the 6-digit code    │ ░░░░             │
│ ░░░░     │  to add 30 min to your budget.    │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │   ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐ ┌──┐  │ ░░░░             │
│ ░░░░     │   │  │ │  │ │  │ │  │ │  │ │  │  │ ░░░░             │
│ ░░░░     │   └──┘ └──┘ └──┘ └──┘ └──┘ └──┘  │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │  ┌─────────────────────────────┐  │ ░░░░             │
│ ░░░░     │  │      Verify Code            │  │ ░░░░             │
│ ░░░░     │  └─────────────────────────────┘  │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │  Requests remaining today: 2      │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │       ┌──────────────┐            │ ░░░░             │
│ ░░░░     │       │  Cancel      │            │ ░░░░             │
│ ░░░░     │       └──────────────┘            │ ░░░░             │
│ ░░░░     └───────────────────────────────────┘ ░░░░             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 7. Session Bar Variants

```
Work Block — Filtered (AI relevant, 1x):
┌─────────────────────────────────────────────────────────────────┐
│  🎯 Taxes (filtered · 1x)  |  12 min remaining         [End]  │
│  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░                     │
└─────────────────────────────────────────────────────────────────┘

Work Block — Unfiltered (AI not relevant, 2x):
┌─────────────────────────────────────────────────────────────────┐
│  ⚡ Unfiltered · 2x  |  6 min remaining                 [End]  │
│  ▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  (amber)            │
└─────────────────────────────────────────────────────────────────┘

Free Block:
┌─────────────────────────────────────────────────────────────────┐
│  🌟 Free Time  |  25 min remaining                             │
│  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░  (indigo)          │
└─────────────────────────────────────────────────────────────────┘

Warning (≤ 3 min remaining):
┌─────────────────────────────────────────────────────────────────┐
│  🎯 Taxes (filtered · 1x)  |  2 min remaining          [End]  │
│  ▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  (pulsing red)     │
└─────────────────────────────────────────────────────────────────┘
```

**Session bar state fields:**
```
intent: string              — Work block intention (or "Free Time")
isFiltered: boolean         — True if AI said relevant
costMultiplier: 1 | 2      — 1x (filtered/free) or 2x (unfiltered work block)
earnedMinutes: number       — Current daily earned pool
warningActive: boolean      — True when ≤ 3 min
isWorkBlock: boolean        — Work vs free block
```

### 8. Popup (New Design)

```
┌──────────────────────────────────┐
│  ○ Intentional          ● ▸ YT  │  (logo, connection dot, platform)
├──────────────────────────────────┤
│                                  │
│  ┌────────────────────────────┐  │
│  │  CURRENT BLOCK             │  │
│  │  📋 Taxes (work)           │  │
│  │  9:00 AM — 12:00 PM       │  │
│  └────────────────────────────┘  │
│                                  │
│  ┌────────────────────────────┐  │
│  │  EARNED MINUTES            │  │
│  │                            │  │
│  │     ╭──────────╮           │  │
│  │     │    12    │           │  │
│  │     │   min    │           │  │
│  │     ╰──────────╯           │  │
│  │                            │  │
│  │  ▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░  │  │
│  │  Earned: 45   Used: 33    │  │
│  └────────────────────────────┘  │
│                                  │
│  ┌────────────────────────────┐  │
│  │  📊 Open Dashboard         │  │
│  └────────────────────────────┘  │
│                                  │
└──────────────────────────────────┘
```

### 9. Dashboard — Earned Minutes Widget

```
┌────────────────────────────────────────────────────────────────────┐
│                                                                    │
│   ┌──────────────────────────┐  ┌────────────────────────────────┐ │
│   │  EARNED MINUTES           │  │  TODAY                        │ │
│   │                           │  │                               │ │
│   │      ╭────╮               │  │  Earned: 45 min               │ │
│   │      │ 12 │               │  │  Used:   33 min               │ │
│   │      │min │               │  │  Rate: standard focus         │ │
│   │      ╰────╯               │  │                               │ │
│   │                           │  │  Deep work:   15 min today    │ │
│   │  ▓▓▓▓▓▓▓░░░░░░░░░░░░░░  │  │  Standard:    30 min today   │ │
│   │                           │  │                               │ │
│   └──────────────────────────┘  └────────────────────────────────┘ │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### 10. Free Block — Zero Earned Minutes Overlay

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░               │
│ ░░░░     ┌───────────────────────────────────┐ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │     You've used all your earned   │ ░░░░             │
│ ░░░░     │     time for today.               │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │     Earn more during your next    │ ░░░░             │
│ ░░░░     │     work block.                   │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │     Next work block: 1:00 PM      │ ░░░░             │
│ ░░░░     │     "Client project"              │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     │  ┌─────────────────────────────┐  │ ░░░░             │
│ ░░░░     │  │  Request More Time          │  │ ░░░░             │
│ ░░░░     │  │  (if hasPartner)            │  │ ░░░░             │
│ ░░░░     │  └─────────────────────────────┘  │ ░░░░             │
│ ░░░░     │                                   │ ░░░░             │
│ ░░░░     └───────────────────────────────────┘ ░░░░             │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## macOS App Changes

### New: EarnedBrowseManager

New component owned by AppDelegate. Source of truth for the daily earned pool.

**File**: `Intentional/EarnedBrowseManager.swift` (new)

```swift
class EarnedBrowseManager {
    // --- State ---
    private(set) var earnedMinutes: Double = 0.0       // Current pool (earned - used)
    private(set) var earnedToday: Double = 0.0         // Total earned today (never decrements)
    private(set) var usedToday: Double = 0.0           // Total used today
    private(set) var dailyRequestCount: Int = 0         // Partner extra time requests used today
    private(set) var currentDate: String = ""          // "yyyy-MM-dd", for reset detection
    private(set) var isFirstDay: Bool = false          // Welcome credit flag

    // --- Earning ---
    private var isCurrentlyEarning: Bool = false
    private var isDeepWork: Bool = false
    private var lastEarnTick: Date?

    // --- Spending ---
    private(set) var isCurrentlySpending: Bool = false
    private var currentCostMultiplier: Int = 1         // 1 or 2
    private var currentPlatform: String?
    private var lastSpendTick: Date?

    // --- Escalating Delays ---
    private var visitCountThisBlock: Int = 0

    // --- Callbacks ---
    var onEarnedMinutesChanged: ((Double) -> Void)?    // (earnedMinutes)
    var onEarnedMinutesDepleted: (() -> Void)?         // Fires when pool hits 0 while spending

    // --- Configurable Constants ---
    static let standardEarnRate: Double = 1.0 / 5.0       // 1 min per 5 min work (0.2)
    static let deepWorkEarnRate: Double = 1.0 / 3.33      // 1 min per 3.33 min work (0.3)
    static let workBlockCostMultiplier: Int = 2            // Default 2x during work blocks
    static let welcomeCredit: Double = 15.0
    static let partnerExtraTimeAmount: Double = 30.0    // Configurable
    static let maxDailyPartnerRequests: Int = 2          // Configurable

    // --- Methods ---
    func tickEarning(seconds: Double, isDeepWork: Bool)    // Called by FocusMonitor
    func tickSpending(seconds: Double, costMultiplier: Int) // Called on heartbeat
    func startSpending(platform: String, costMultiplier: Int)
    func stopSpending()
    func getDelaySeconds() -> Int                          // Based on visitCountThisBlock
    func recordVisit()                                     // Increment visit count
    func onBlockChanged()                                  // Reset visit count
    func onDayChanged()                                    // Reset daily pool
    func applyPartnerExtraTime() -> Bool                    // Add time to budget, check cap
    func getState() -> EarnedBrowseState                   // For native messaging
}
```

**Earning rates:**
- Standard focus: 0.2 earned min per real min (25 min → 5 min)
- Deep work: 0.3 earned min per real min (25 min → 7.5 min) — 1.5x

**Work block cost:**
- Default: `workBlockCostMultiplier = 2` (configurable)
- AI-relevant: drops to 1x
- Free block: always 1x

**Persistence:** `~/Library/Application Support/Intentional/earned_browse.json`
```json
{
    "date": "2026-02-21",
    "earnedMinutes": 12.5,
    "earnedToday": 45.0,
    "usedToday": 32.5,
    "dailyRequestCount": 0,
    "isFirstDay": false
}
```

### Modified: FocusMonitor.swift

**Changes:**
1. When foreground is relevant during a work block → call `earnedBrowseManager.tickEarning()`
2. Detect deep work: maintain a rolling 25-minute window of all assessments. If all relevant → deep work
3. When foreground is a social media platform → do NOT earn (earning pauses on social media)
4. New property: `isOnSocialMedia: Bool` — true when foreground is YouTube/Instagram/Facebook/etc.
5. Track `lastActiveApp` — the last non-social-media app the user was in (for "Back to [app]" button)
6. **Skip overlay for extension-connected browsers on social media.** When the foreground app is a browser with an active extension connection (check via `BrowserMonitor`) AND the active tab URL matches a social media hostname, FocusMonitor does NOT show its own overlay. The extension owns enforcement for those sites. Browsers without the extension still get FocusMonitor's standard progressive overlay.

**New logic in the 10s polling cycle:**
```
if currentBlock.isFree || currentBlock == nil {
    // Don't earn during free blocks or no-plan
} else if isOnSocialMedia {
    // Don't earn while on social media, even if "relevant"
} else if lastAssessment.relevant {
    let isDeep = checkDeepWorkWindow()
    earnedBrowseManager.tickEarning(seconds: 10, isDeepWork: isDeep)
    lastActiveApp = currentAppName  // Track for "Back to [app]"
}
```

**Deep work detection:**
```swift
private var assessmentWindow: [(Date, Bool)] = []  // (timestamp, relevant)

func checkDeepWorkWindow() -> Bool {
    let cutoff = Date().addingTimeInterval(-25 * 60)  // 25 minutes ago
    let windowAssessments = assessmentWindow.filter { $0.0 >= cutoff }
    guard let oldest = windowAssessments.first,
          Date().timeIntervalSince(oldest.0) >= 25 * 60 else { return false }
    return windowAssessments.allSatisfy { $0.1 }
}
```

**Social media detection:**
```swift
static let socialMediaHostnames: Set<String> = [
    "youtube.com", "www.youtube.com", "m.youtube.com",
    "instagram.com", "www.instagram.com",
    "facebook.com", "www.facebook.com",
    "twitter.com", "x.com",
    "reddit.com", "www.reddit.com",
    "tiktok.com", "www.tiktok.com"
]
```

### Modified: RelevanceScorer.swift

**New method** to assess social media justification text:

```swift
func assessJustification(
    justificationText: String,
    intention: String,
    intentionDescription: String = "",
    profile: String,
    dailyPlan: String
) async -> Result
```

**New method** to generate ML categories from work block intention:

```swift
func generateCategories(
    intention: String,
    intentionDescription: String = ""
) async -> [String]
// e.g., "taxes" → ["tax preparation", "financial documents", "IRS forms", "accounting"]
```

### Modified: NativeMessagingHost.swift

**New inbound message types:**

| Message | Payload | Handler |
|---------|---------|---------|
| `GET_WORK_BLOCK_STATE` | `{ platform }` | Return block state + earned minutes + delay + lastActiveApp |
| `JUSTIFY_SOCIAL_MEDIA` | `{ platform, justificationText }` | Score justification via RelevanceScorer |
| `SOCIAL_MEDIA_HEARTBEAT` | `{ platform, secondsSpent, costMultiplier }` | TimeTracker records time, then notifies EarnedBrowseManager to decrement |
| `REQUEST_EXTRA_TIME` | `{}` | Send extra time request to partner via backend |
| `VERIFY_EXTRA_TIME_CODE` | `{ code }` | Verify partner's 6-digit code |
| `SOCIAL_MEDIA_SESSION_END` | `{ platform }` | User clicked "End" or navigated away |

**New outbound message types:**

| Message | Payload | When |
|---------|---------|------|
| `WORK_BLOCK_STATE` | `{ isWorkBlock, intention, intentionDescription, earnedMinutes, earnedToday, usedToday, delaySeconds, hasPartner, workBlockCostMultiplier, lastActiveApp }` | Response to GET_WORK_BLOCK_STATE |
| `JUSTIFICATION_RESULT` | `{ relevant, costMultiplier, reason, earnedMinutes, categories }` | After AI assessment |
| `EARNED_MINUTES_UPDATE` | `{ earnedMinutes, earnedToday, usedToday }` | Pushed to ALL connected browsers on any heartbeat received, or on earn tick |
| `SESSION_EXPIRED` | `{ reason: "earned_minutes_depleted" }` | When pool hits 0 during active session |
| `EXTRA_TIME_RESULT` | `{ success, earnedMinutes, requestsRemaining, error? }` | After partner extra time attempt |

**Removed/deprecated outbound messages:**
- `STATE_SYNC` budget fields (`dailyUsage`, `freeBrowseUsage`, `freeBrowseBudgets`, `freeBrowseExceeded`) removed
- `FREE_BROWSE_EXCEEDED` — Replaced by `SESSION_EXPIRED`
- `BUDGET_EXCEEDED` — Replaced by `SESSION_EXPIRED`

### Modified: AppDelegate.swift

**Architecture: TimeTracker is the clock, EarnedBrowseManager is the accountant.**

TimeTracker remains the single entry point for all heartbeats (deduplication, usage analytics, crash recovery). After recording social media time, it notifies EarnedBrowseManager via callback. EarnedBrowseManager applies cost multipliers and manages the earned pool. Two components, clear ownership.

**New initialization (after TimeTracker, before ScheduleManager):**
```swift
earnedBrowseManager = EarnedBrowseManager()

// TimeTracker → EarnedBrowseManager: "time was spent on social media"
timeTracker.onSocialMediaTimeRecorded = { [weak self] platform, seconds, isActive in
    guard let mgr = self?.earnedBrowseManager, mgr.isCurrentlySpending else { return }
    mgr.tickSpending(seconds: Double(seconds), costMultiplier: mgr.currentCostMultiplier)
}

// EarnedBrowseManager → All browsers: pool depleted
earnedBrowseManager.onEarnedMinutesDepleted = { [weak self] in
    self?.socketRelayServer?.broadcast([
        "type": "SESSION_EXPIRED",
        "reason": "earned_minutes_depleted"
    ])
}

// EarnedBrowseManager → All browsers: pool changed (push to ALL connected browsers)
earnedBrowseManager.onEarnedMinutesChanged = { [weak self] minutes in
    self?.socketRelayServer?.broadcast([
        "type": "EARNED_MINUTES_UPDATE",
        "earnedMinutes": minutes
    ])
}
```

**Modified `onBlockChanged` callback chain:**
```
scheduleManager.onBlockChanged → {
    relevanceScorer.clearCache()
    focusMonitor.onBlockChanged()
    earnedBrowseManager.onBlockChanged()  // Reset visit count
    broadcast SCHEDULE_SYNC to all browsers
}
```

### Modified: dashboard.html

**New earned minutes widget** at top of the dashboard (above schedule). Shows:
- Current earned minutes (large number)
- Earned today / used today
- Current earning rate (standard / deep work / paused)
- Progress bar

---

## Chrome Extension Changes

### Modified: background.js

#### Removed
- `DEFAULT_SETTINGS.dailyBudgetMinutes` and all daily budget logic
- `DEFAULT_SETTINGS.maxPerPeriod` and period limit logic
- `freeBrowseBudgets` and `freeBrowseUsage` tracking
- `recordTimeSpent()` — replaced by `SOCIAL_MEDIA_HEARTBEAT`
- `handleStateSync()` — budget fields removed
- Free browse session management (session.freeBrowse flag)
- `GET_FREE_BROWSE_REMAINING` handler
- `UPDATE_SESSION_TIMER` handler
- `START_SESSION` handler (sessions driven by justification flow)

#### New Message Handlers

```javascript
case 'GET_WORK_BLOCK_STATE':
    const state = await queryNativeApp({ type: 'GET_WORK_BLOCK_STATE', platform });
    sendResponse(state);
    break;

case 'JUSTIFY_SOCIAL_MEDIA':
    const result = await queryNativeApp({
        type: 'JUSTIFY_SOCIAL_MEDIA',
        platform: message.platform,
        justificationText: message.justificationText
    });
    sendResponse(result);
    break;

case 'SOCIAL_MEDIA_HEARTBEAT':
    queryNativeApp({
        type: 'SOCIAL_MEDIA_HEARTBEAT',
        platform: message.platform,
        secondsSpent: message.secondsSpent,
        costMultiplier: message.costMultiplier
    });
    break;

case 'REQUEST_EXTRA_TIME':
    const extraTimeResult = await queryNativeApp({ type: 'REQUEST_EXTRA_TIME' });
    sendResponse(extraTimeResult);
    break;

case 'VERIFY_EXTRA_TIME_CODE':
    const verifyResult = await queryNativeApp({
        type: 'VERIFY_EXTRA_TIME_CODE',
        code: message.code
    });
    sendResponse(verifyResult);
    break;
```

#### Simplified Session State

```javascript
// OLD:
sessionState[platform] = {
    active, startedAt, endsAt, intent, durationMinutes, primaryTabId, strictSingleTab, freeBrowse
};

// NEW:
sessionState[platform] = {
    active: false,
    isFiltered: false,          // Content filtering active
    costMultiplier: 1,          // 1x or 2x
    intention: '',              // From work block
    justification: '',          // User's justification text
    primaryTabId: null
};
```

### Modified: platforms/youtube/content.js

#### Removed
- `showIntentPrompt()` (~500 lines) — replaced by `showJustificationScreen()`
- Intent categories/presets UI
- Duration picker
- Free browse button and free browse session logic
- Session timer management
- Budget display in intent prompt
- `showZenLoading()` — delay countdown replaces it

#### New: showJustificationScreen()

```javascript
async function showJustificationScreen() {
    const state = await chrome.runtime.sendMessage({
        type: 'GET_WORK_BLOCK_STATE', platform: 'youtube'
    });

    if (!state.isWorkBlock) {
        if (state.earnedMinutes <= 0) {
            showZeroMinutesOverlay(state);
        } else {
            startFreeSession(state);
        }
        return;
    }

    if (state.earnedMinutes <= 0) {
        showZeroMinutesOverlay(state);
        return;
    }

    // Show justification overlay with:
    // - "WORK TIME · Social media costs 2x" banner
    // - "You're working on: [intention]"
    // - "Last active: [lastActiveApp]"
    // - Budget display with progress bar
    // - Text field + delay countdown
    // - [Back to {lastActiveApp}] [Continue (0:xx)]
    const overlay = createJustificationOverlay(state);
    document.body.appendChild(overlay);
    startDelayCountdown(state.delaySeconds, overlay);

    overlay.querySelector('#justify-submit').addEventListener('click', async () => {
        const text = overlay.querySelector('#justify-input').value;
        showAssessingSpinner(overlay);

        const result = await chrome.runtime.sendMessage({
            type: 'JUSTIFY_SOCIAL_MEDIA',
            platform: 'youtube',
            justificationText: text
        });

        if (result.relevant) {
            showRelevantResult(overlay, result);   // "You'll get the full 12 min"
        } else {
            showNotRelevantResult(overlay, result); // "Cost stays at 2x"
        }
    });
}
```

#### New: Heartbeat + Local Decrement

```javascript
let heartbeatInterval = null;
let localEarnedMinutes = 0;
let localDecrementInterval = null;

function startHeartbeat(costMultiplier) {
    heartbeatInterval = setInterval(() => {
        if (document.visibilityState === 'visible') {
            chrome.runtime.sendMessage({
                type: 'SOCIAL_MEDIA_HEARTBEAT',
                platform: 'youtube',
                secondsSpent: 30,
                costMultiplier
            });
        }
    }, 30000);
}

function startLocalDecrement(costMultiplier) {
    localDecrementInterval = setInterval(() => {
        if (document.visibilityState === 'visible') {
            localEarnedMinutes -= (1/60) * costMultiplier;
            if (localEarnedMinutes < 0) localEarnedMinutes = 0;
            updateSessionBarTime(localEarnedMinutes);
        }
    }, 1000);
}

// Sync from native app (authoritative)
chrome.runtime.onMessage.addListener((message) => {
    if (message.type === 'EARNED_MINUTES_UPDATE') {
        localEarnedMinutes = message.earnedMinutes;
        updateSessionBarTime(localEarnedMinutes);
    }
    if (message.type === 'SESSION_EXPIRED') {
        showTimesUpOverlay();
    }
});
```

#### Modified: Content Filtering

```javascript
function startFilteredSession(result) {
    chrome.runtime.sendMessage({
        type: 'UPDATE_CATEGORIES',
        categories: result.categories
    });
    document.body.classList.add('yt-focus-active');
    startHeartbeat(1);
    startLocalDecrement(1);
    localEarnedMinutes = result.earnedMinutes;
    createSessionBar({
        intent: result.intention + ' (filtered · 1x)',
        isFiltered: true,
        costMultiplier: 1,
        earnedMinutes: result.earnedMinutes,
        isWorkBlock: true
    });
}

function startUnfilteredSession(result) {
    document.body.classList.remove('yt-focus-active');
    startHeartbeat(2);
    startLocalDecrement(2);
    localEarnedMinutes = result.earnedMinutes;
    createSessionBar({
        intent: 'Unfiltered · 2x',
        isFiltered: false,
        costMultiplier: 2,
        earnedMinutes: result.earnedMinutes,
        isWorkBlock: true
    });
}

function startFreeSession(state) {
    startHeartbeat(1);
    startLocalDecrement(1);
    localEarnedMinutes = state.earnedMinutes;
    createSessionBar({
        intent: 'Free Time',
        isFiltered: false,
        costMultiplier: 1,
        earnedMinutes: state.earnedMinutes,
        isWorkBlock: false
    });
}
```

### Modified: platforms/instagram/content.js & facebook/content.js

Same pattern as YouTube:
- Remove intent prompt (category picker, duration, free browse)
- Add `showJustificationScreen()` for work blocks
- Add heartbeat loop + local decrement
- Content filtering activates only after AI says relevant (1x)
- Free block: no overlay, just session bar + heartbeat

### Modified: platforms/shared/session-bar.js

**New `createSessionBar` / `updateSessionBar`:**
```javascript
createSessionBar({
    platform: 'youtube',
    intent: 'Taxes (filtered · 1x)',
    isFiltered: true,
    costMultiplier: 1,
    earnedMinutes: 12,
    isWorkBlock: true
});

updateSessionBar({
    earnedMinutes: 11.5,
    warningActive: false,
    costMultiplier: 1
});
```

**Removed:** `timeDisplay`, `isFreeBrowse`, `showExtendButton`, `progressPct`, `budgetUsedMinutes`, `budgetTotalMinutes`, `isCountingUp`, `streakCount`, `intentional-extend-session` event

**New:** Cost multiplier badge, earned minutes progress bar

### Modified: popup.html / popup.js

**Removed:** Session timer, free browse card, end session button, duration info, streak display
**New:** Current block (name, time range, work/free), earned minutes (number + bar), earned/used stats

### Modified: options.html / options.js

**Remove:** Daily budget setting, per-platform free browse budgets, period limits

---

## Backend Changes (Concept — Not Implementing Now)

### New Table: `earned_browse`

```sql
CREATE TABLE earned_browse (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id),
    date DATE NOT NULL,
    earned_minutes FLOAT DEFAULT 0,
    used_minutes FLOAT DEFAULT 0,
    daily_request_count INT DEFAULT 0,
    deep_work_minutes FLOAT DEFAULT 0,
    standard_work_minutes FLOAT DEFAULT 0,
    updated_at TIMESTAMP DEFAULT now(),
    UNIQUE(user_id, date)
);
```

### New Endpoints

- **POST `/earned-browse/sync`** — Native app syncs state (every 60s)
- **GET `/earned-browse/history`** — Dashboard history
- **POST `/earned-browse/request-extra-time`** — Request extra time from partner (adds to budget)
- **POST `/earned-browse/verify-extra-time`** — Verify partner's 6-digit code, add time to budget

### Partner Alert Emails

Extra time request emails include: user name, how many requests today, total earned vs used.

---

## Data Structures

### EarnedBrowseState (native app → extension)

```json
{
    "isWorkBlock": true,
    "intention": "Taxes",
    "intentionDescription": "Preparing 2025 tax returns",
    "earnedMinutes": 12.5,
    "earnedToday": 45.0,
    "usedToday": 32.5,
    "delaySeconds": 30,
    "hasPartner": true,
    "partnerEmail": "alex@example.com",
    "workBlockCostMultiplier": 2,
    "lastActiveApp": "TurboTax",
    "visitCount": 2,
    "dailyRequestCount": 0,
    "maxDailyRequests": 2
}
```

### JustificationResult (native app → extension)

```json
{
    "relevant": true,
    "costMultiplier": 1,
    "reason": "1099-NEC filing is directly related to tax preparation.",
    "earnedMinutes": 12.5,
    "categories": ["tax preparation", "financial documents", "IRS forms"]
}
```

---

## Message Protocol

```
Content Script                Background.js              Native App
     │                             │                         │
     │  GET_WORK_BLOCK_STATE       │  GET_WORK_BLOCK_STATE   │
     │ ─────────────────────────>  │ ─────────────────────>  │
     │                             │                         │
     │  WORK_BLOCK_STATE           │  WORK_BLOCK_STATE       │
     │ <─────────────────────────  │ <─────────────────────  │
     │                             │                         │
     │  [Justification screen +    │                         │
     │   delay countdown]          │                         │
     │                             │                         │
     │  JUSTIFY_SOCIAL_MEDIA       │  JUSTIFY_SOCIAL_MEDIA   │
     │ ─────────────────────────>  │ ─────────────────────>  │
     │                             │                         │
     │  JUSTIFICATION_RESULT       │  JUSTIFICATION_RESULT   │
     │ <─────────────────────────  │ <─────────────────────  │
     │                             │                         │
     │  [Session active]           │                         │
     │                             │                         │
     │  SOCIAL_MEDIA_HEARTBEAT     │  SOCIAL_MEDIA_HEARTBEAT │
     │ ─────────────────────────>  │ ─────────────────────>  │
     │  (every 30s)                │                         │
     │                             │                         │
     │  EARNED_MINUTES_UPDATE      │  EARNED_MINUTES_UPDATE  │
     │ <─────────────────────────  │ <─────────────────────  │
     │                             │                         │
     │  SESSION_EXPIRED            │  SESSION_EXPIRED        │
     │ <─────────────────────────  │ <─────────────────────  │
     │                             │                         │
     │  [Time's Up overlay]        │                         │
```

---

## Migration Plan

### Phase 1: macOS App (Do First)
1. Create `EarnedBrowseManager.swift`
2. Wire into `AppDelegate` initialization chain
3. Modify `FocusMonitor` to call `tickEarning()` + track `lastActiveApp`
4. Add `assessJustification()` to `RelevanceScorer`
5. Add `generateCategories()` to `RelevanceScorer`
6. Add new message handlers to `NativeMessagingHost`
7. Update `dashboard.html` with earned minutes widget
8. Test: verify earning accumulates during work blocks

### Phase 2: Chrome Extension (Do Second)
1. Add new message types to `background.js`
2. Remove old budget/timer code from `background.js`
3. Replace `showIntentPrompt()` with `showJustificationScreen()` in YouTube
4. Add heartbeat loop and local decrement to YouTube
5. Update session bar with new state structure
6. Repeat for Instagram and Facebook
7. Update popup
8. Update options page (remove budget settings)
9. Test: end-to-end justification → filtered session → time's up

### Phase 3: Backend (Do Later)
1. Create `earned_browse` table
2. Add sync endpoint
3. Add extra time request/verify endpoints
4. Update partner notification emails

### What Gets Deleted

**Extension code to remove:**
- All `freeBrowseBudgets` / `freeBrowseUsage` logic
- `dailyBudgetMinutes` / `dailyUsage` / `periodUsage` tracking
- `recordTimeSpent()` function
- Free browse session type
- Duration picker + category picker in all platform content scripts
- Zen loading screens
- `+5 min` extend button in session bar
- `GET_FREE_BROWSE_REMAINING`, `UPDATE_SESSION_TIMER`, `START_SESSION` handlers
- `FREE_BROWSE_EXCEEDED` / `BUDGET_EXCEEDED` broadcast handlers

**Settings to remove from `DEFAULT_SETTINGS`:**
- `dailyBudgetMinutes`, `maxPerPeriod`, `freeBrowseBudgets`, `freeBrowseUsage`, `dailyUsage`, `periodUsage`

---

## Resolved Questions

1. **Deep work rate**: 1.5x. 25 min → 7.5 min earned. Rate: 0.3 min/min.
2. **Earning while spending**: No. Earning pauses on social media.
3. **Visit definition**: Each justification screen = a visit. 5+ min away = session expired.
4. **ML categories**: AI-generated from intention, sent with JUSTIFICATION_RESULT.
5. **Display sync**: Extension decrements locally every 1s, syncs with app every 30s.
6. **Platform settings in free blocks**: Permanent prefs (block Shorts, hide ads) stay active.
7. **Session persistence**: 5 min away = expired. Block change = expired.
8. **Work block cost**: Default 2x (configurable). AI-relevant = reward drops to 1x.
9. **Streaks**: Deferred for v1. May revisit as daily streaks later.
10. **Only deducted for actual use**: Users are only charged for actual time spent. Ending a session, closing the tab, or navigating away keeps the remaining balance. No pre-commitment, no "use it or lose it."
11. **FocusMonitor vs extension enforcement**: FocusMonitor skips its overlay when the browser has an active extension connection AND URL is social media (checked via BrowserMonitor). Extension owns the justification flow. Browsers without extension get FocusMonitor's standard progressive overlay.
12. **Multi-browser sync**: Native app pushes `EARNED_MINUTES_UPDATE` to ALL connected browsers whenever any browser sends a heartbeat. Keeps all browsers in sync within ~15s when two are active.
13. **TimeTracker/EarnedBrowseManager ownership**: TimeTracker is the clock (heartbeat dedup, usage analytics, persistence). EarnedBrowseManager is the accountant (earned pool, cost multipliers, limits). TimeTracker notifies EarnedBrowseManager via `onSocialMediaTimeRecorded` callback. No duplicated logic.
14. **No protocol versioning**: Not launched yet. Build the new system directly. Add version handshake later if needed.

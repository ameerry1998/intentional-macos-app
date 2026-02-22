# Unified Budget & Incentive System: Earn Your Browse

## The Core Idea

Focused work earns social media time. One number goes up when you work, goes down when you browse. That's the entire system.

There is **one daily pool** of earned minutes. You build it up by working, you spend it by browsing social media. It works the same during work blocks and free blocks — the only difference is whether you see justification screens and content filtering.

---

## Two Modes

Your schedule has two types of blocks. The app requires a schedule — every hour is either work or free.

### Work Blocks
- Social media requires justification
- Justification screen appears on YouTube/Instagram/Facebook (delay + text field)
- Social media costs **2x** by default during work time (configurable)
- AI assesses justification — if relevant, cost drops to **1x** (reward for legitimate need)
- Content is filtered to match your work block intention when AI says relevant
- Earned minutes tick down while browsing

### Free Blocks
- Social media is unrestricted — no justification screens, no filtering, no delays
- Earned minutes tick down at **1x** rate
- When earned minutes hit 0, social media closes
- This is the reward for focused work — enjoy it guilt-free

**Key simplification**: Justification screens, content filtering, and AI assessment ONLY exist during work blocks. During free time, the extension gets out of the way completely — but you're still spending from the same earned pool.

### No Schedule / Unplanned Time
- Treated as a work block (justification required, filtering active, 2x default cost)
- This prevents users from gaming the system by not setting a schedule
- Incentivizes actually planning your day

---

## The Daily Earned Pool

### How It Works
- **One number for the whole day**: `earnedMinutes`
- Resets to 0 at midnight local time
- Accumulates during focused work (work blocks only)
- Decreases while browsing social media (any block type)
- Carries across all blocks throughout the day
- New users get **15 welcome minutes** on their first day only

### The Math
- Standard focus: ~5 min earned per 25 min of focus = ~12 min/hour
- Deep work: ~7.5 min earned per 25 min of deep focus = ~18 min/hour
- Realistic daily earnings for 6 hours of standard work: **~60 minutes** of social media
- A deep-work power user doing 6 hours: **~90 minutes**
- Realistic mix (2hr deep + 4hr standard): **~84 minutes**

### What Happens at 0 Earned Minutes

**During a work block**: User sees the justification screen but it says "You have 0 earned minutes. Earn more by focusing on your work." The Continue button is disabled. They cannot proceed.

**During a free block**: User sees a gentle overlay: "You've used all your earned time for today. Earn more during your next work block." Social media is blocked.

**The escape hatch**: Request extra time from your accountability partner (see Accountability section).

---

## Earning: How Focused Work Is Defined

The macOS app (FocusMonitor + RelevanceScorer) already monitors your foreground app and browser tab, scoring relevance against your work block intention. Earning ONLY happens during work blocks — free blocks don't earn.

### Standard Focus (earns at 1x rate)
- You're on apps/tabs the AI deems relevant to your work block
- You can have multiple tabs open
- 25 minutes of standard focus → 5 minutes earned
- Example: Working on "taxes" with TurboTax, IRS.gov, and Google Sheets all open

### Deep Work (earns at 1.5x rate)
- The foreground app/tab is relevant to your task for 25 straight minutes
- No switches to irrelevant foreground content during the entire 25-minute window
- 25 minutes of deep work → 7.5 minutes earned
- Example: Working in TurboTax for 25 uninterrupted minutes
- This incentivizes sustained focus and mono-tasking
- The reward (50% more browse time) is meaningful but doesn't blow the ceiling off

### Detection
The AI is already scoring every foreground app/tab switch. Focus state is derived from those scores:
- **Standard focus**: Most recent AI assessment = relevant → earning at 1x
- **Deep work**: All AI assessments for the last 25 minutes = relevant, AND no irrelevant app/tab appeared in the foreground at any point → earning at 1.5x
- **Not focused**: Current foreground is irrelevant → earning pauses (doesn't reset, just pauses)

### Earning Is Continuous, Not Cyclic
Earned minutes accumulate continuously — there's no "complete a 25-minute cycle" requirement. Think of it as a rate:
- Standard focus: 1 earned minute per 5 real minutes (0.2 min/min)
- Deep work: 1 earned minute per 3.33 real minutes (0.3 min/min)
- The 25→5 and 25→7.5 ratios just describe the rate in human-friendly terms

### Earning Pauses on Social Media
You cannot earn and spend at the same time. Even if you're watching a "relevant" YouTube tutorial during a work block, earning pauses while you're on any social media platform. You're either working or browsing — never both.

---

## Spending: The Social Media Threshold

### During a Work Block — User Opens YouTube

**The default cost is 2x.** Social media during work time is expensive. The AI assessment is the opportunity to earn the lower 1x rate by having a legitimate reason.

**Step 1: The Delay + Justification**

A screen appears with a work-time cost banner, context about what they were just doing, their available budget, and a mandatory pause:

- Top banner: "WORK TIME · Social media costs 2x"
- Shows what they're working on and what app they just left
- Visual budget display: available minutes with progress bar (earned vs used)
- Text field: "Why do you need YouTube right now?"
- Countdown timer (mandatory pause before Continue is enabled)
- Two buttons side by side: "Back to [last app]" (always active, indigo) and "Continue (0:27)" (disabled during countdown, gray)

The delay kills most impulses. The user has to wait regardless. The delay escalates with repeated visits within the same work block.

**Step 2: AI Assessment**

The user types their justification. When the countdown ends and they click Continue, the macOS app's AI (RelevanceScorer) assesses their justification against their work block intention.

- User types: "need to look up how to file a 1099-NEC" → AI says relevant to "taxes"
- User types: "just bored" → AI says not relevant
- User types: "research for work" (vague) → AI judges based on the work block context

**Step 3: Cost Determination**

- **AI says relevant** → Cost drops to **1x** (reward). Filtered session starts. Content filtered to work block intention. Screen shows: "Related to Taxes — since this is work-related, you'll get the full 12 minutes." User clicks "Continue to YouTube."
- **AI says not relevant** → Cost stays at **2x** (default). Screen shows: "Not related to Taxes — your time will burn at 2x. 12 minutes available → 6 min of browsing time." User can "Continue at 2x" or go back.

**Step 4: Session Runs**

Earned minutes tick down at the determined rate **only while the user is actively browsing**. Users are only charged for actual time spent — they can end their session or navigate away at any time and keep their remaining balance. When earned minutes hit 0, the session ends and the user sees a "Time's up" overlay. They have to go earn more or request extra time from their accountability partner.

### During a Free Block — User Opens YouTube

No justification screen. No delay. No filtering. Just opens normally.

Earned minutes tick down at 1x rate. Session bar shows remaining earned minutes. Users keep whatever they don't use — ending a session early or closing the tab preserves the remaining balance. When earned minutes hit 0, social media closes with a gentle overlay.

### Escalating Delays (Work Blocks Only)

Within a single work block, each social media visit increases the delay:
- 1st visit: 30 seconds
- 2nd visit: 60 seconds
- 3rd visit: 2 minutes
- 4th+: 5 minutes

Resets when the work block ends. Does not apply during free blocks.

### Zero Earned Minutes — The Hard Wall

When earned minutes reach 0:
1. Any active social media session ends immediately (overlay)
2. Justification screens show "0 minutes available" with Continue button disabled
3. Free block browsing is blocked with a gentle message
4. The ONLY way to get more time:
   - Earn it through focused work (during a work block)
   - Request extra time from your accountability partner

There is no override, no debt, no "just 5 more minutes." This is the core enforcement mechanism.

---

## Accountability Partner Integration

### When Earned Minutes Hit 0

If the user has an accountability partner set up:
- "Time's up" overlay includes a "Request More Time" button
- Tapping it sends a notification to the accountability partner
- Partner receives: "[Name] has used all their browsing time and is requesting 30 more minutes"
- Partner sends a 6-digit code
- User enters the code → **30 minutes are added to their budget** (configurable variable: `partnerExtraTimeAmount`)
- Cap: **2 requests per day** (60 minutes max, configurable variable: `maxDailyPartnerRequests`)

If the user has NO accountability partner:
- "Time's up" overlay says: "You've used all your browsing time. Focus on your next work block to earn more browsing time."
- No "Request More Time" button — nowhere to go
- This creates strong incentive to set up an accountability partner
- The accountability partner is their safety valve; without it, the system is strict

### Why This Works
- Asking your partner for more social media time is mildly embarrassing
- Having to type your request and wait for a code adds friction
- The daily cap (2 requests) prevents it from becoming a rubber stamp
- No partner = no escape = powerful incentive to set one up

---

## Platform Behavior During Work Blocks

All platforms show the justification screen during work blocks. The AI assesses for all platforms equally — a marketing manager's Instagram research IS legitimate work.

Content filtering differs by platform (only when AI says relevant → 1x cost):
- **YouTube**: Filtered via DistilBERT (video titles checked against work intention). User sees only relevant videos. This is where the AI justification matters most — YouTube has legitimate educational content.
- **Instagram**: Image classification (CLIP) + API interception. Filtered to work intention. Feed is restricted. Most visits will be assessed as not relevant (2x cost stays) unless the user has a genuine work reason.
- **Facebook**: Route guards + scroll limits. Filtered to work intention. Similar to Instagram — most work block visits will stay at 2x.

During free blocks: no filtering on any platform. Just earned minutes ticking down at 1x.

---

## The Numbers

| Parameter | Value | Notes |
|-----------|-------|-------|
| Standard earning rate | 5 min per 25 min focus | 0.2 earned min per real min |
| Deep work earning rate | 7.5 min per 25 min focus | 0.3 earned min per real min |
| Work block default cost | 2x | Configurable: `workBlockCostMultiplier` |
| AI-relevant cost (reward) | 1x | AI assesses justification as relevant → filtered session |
| Free block cost | 1x | No justification, no filtering |
| Initial delay (work block) | 30 sec | First social media visit in a work block |
| Delay escalation | 30s → 60s → 2m → 5m | Per work block, resets each block |
| Daily pool reset | Midnight local time | Clean daily reset |
| Welcome credit | 15 min | First day only, so new users can experience the system |
| Partner extra time amount (`partnerExtraTimeAmount`) | 30 min | Added to budget per request |
| Partner request daily cap (`maxDailyPartnerRequests`) | 2 requests (60 min) | Prevents abuse |

---

## What Gets Removed From the Extension

The unified model simplifies the extension significantly:

### Removed
- Independent daily budget system (`dailyBudgetMinutes`, `dailyUsage`)
- Per-platform free browse budgets (`freeBrowseBudgets`, `freeBrowseUsage`)
- Period limits (`maxPerPeriod`, `periodUsage`)
- Intent prompt during free time (no more "what are you here for?" during free blocks)
- Separate free browse session type (free blocks are inherently free browse)
- Extension-managed session timers (macOS app manages earned minutes countdown)
- Duration picker in intent prompt (no user-set session durations)
- Category picker in intent prompt (categories derived from work block intention automatically)
- Zen loading screens (the delay countdown IS the mindfulness pause)

### Kept
- Content filtering ML (DistilBERT for YouTube, CLIP for Instagram) — used during work blocks when AI says relevant
- Session bar UI — shows earned minutes remaining and cost rate
- Platform-specific content scripts — still handle blur-by-default, shorts blocking, etc. during work blocks
- Native messaging bridge — now carries earned minutes, work block state, AI assessments
- App-required overlay — still needed to ensure macOS app is running
- Platform preferences (block Shorts, hide ads, block Reels) — stay active during free blocks too

### Changed
- Intent screen → Justification screen (simpler: just a text field + delay countdown + cost context)
- Session start/end → Driven by macOS app (earned minutes balance), not user-set timers
- Budget tracking → All in macOS app, extension just displays and enforces
- Free browse → No longer a separate session type; free blocks just don't show overlays/filtering
- Session bar → Shows daily earned minutes remaining (single number) + cost multiplier, not per-session timer

---

## Architecture

```
macOS App (source of truth for everything)
├── ScheduleManager
│   ├── Work blocks + free blocks (required schedule)
│   └── Daily reset at midnight
├── EarnedBrowseManager (NEW)
│   ├── Daily earned minutes pool
│   ├── Earning rate tracking (standard vs deep work)
│   ├── Spending rate tracking (1x or 2x)
│   ├── Escalating delay counter (per block)
│   ├── Partner request count (max 2/day)
│   └── Persistence to earned_browse.json
├── FocusMonitor
│   ├── Monitors foreground app/tab
│   ├── Scores relevance via RelevanceScorer
│   ├── Detects standard focus vs. deep work
│   ├── Calls EarnedBrowseManager.tickEarning() during focus
│   ├── Pauses earning when on social media
│   └── Logs assessments to relevance_log.jsonl
├── RelevanceScorer
│   ├── Assesses foreground activity relevance (existing)
│   ├── Assesses social media justification text (new)
│   └── Generates ML categories from work block intention (new)
├── AccountabilityManager
│   ├── Handles partner extra time requests
│   ├── Tracks daily request count (max 2)
│   └── Validates partner codes
└── NativeMessagingHost
    ├── Sends WORK_BLOCK_STATE to extension
    │   { isWorkBlock, intention, earnedMinutes, earnedToday, usedToday,
    │     delaySeconds, hasPartner, workBlockCostMultiplier, lastActiveApp }
    ├── Receives JUSTIFY_SOCIAL_MEDIA from extension
    │   { platform, justificationText }
    ├── Sends JUSTIFICATION_RESULT to extension
    │   { relevant, costMultiplier, reason, earnedMinutes, categories }
    ├── Sends EARNED_MINUTES_UPDATE to extension (periodic)
    │   { earnedMinutes, earnedToday, usedToday }
    ├── Sends SESSION_EXPIRED to extension
    │   { reason: "earned_minutes_depleted" }
    ├── Receives REQUEST_EXTRA_TIME from extension
    ├── Sends EXTRA_TIME_RESULT to extension
    │   { success, earnedMinutes, requestsRemaining }
    └── Receives SOCIAL_MEDIA_HEARTBEAT from extension
        { platform, secondsSpent, costMultiplier }

Chrome Extension (enforcement layer)
├── background.js
│   ├── On social media tab activation:
│   │   query native app for WORK_BLOCK_STATE
│   ├── Forward justification text to native app for AI assessment
│   ├── Start/stop content filtering based on AI result
│   ├── Report time spent via SOCIAL_MEDIA_HEARTBEAT
│   └── Handle SESSION_EXPIRED by triggering "Time's up" overlay
├── content.js (per platform)
│   ├── Work block + earned > 0: show justification screen with delay + 2x warning
│   ├── Work block + earned = 0: show "earn more" screen (no Continue)
│   ├── Work block + justified relevant: filtered content, session bar at 1x
│   ├── Work block + justified not relevant: unfiltered, session bar at 2x
│   ├── Free block + earned > 0: no overlays, no filtering, session bar at 1x
│   ├── Free block + earned = 0: show "time's up" overlay
│   └── No schedule: treated as work block
└── popup.js
    └── Current block type, earned minutes, cost rate
```

---

## Message Flows

### Work Block Social Media Visit (Has Earned Minutes)

```
1. User navigates to youtube.com during "Taxes" work block
2. content.js detects platform, sends GET_WORK_BLOCK_STATE to background.js
3. background.js queries native app → gets:
   { isWorkBlock: true, intention: "Taxes", earnedMinutes: 12, earnedToday: 45,
     usedToday: 33, delaySeconds: 30, hasPartner: true, workBlockCostMultiplier: 2,
     lastActiveApp: "TurboTax" }
4. content.js shows justification screen:
   - Banner: "WORK TIME · Social media costs 2x"
   - "You're working on: Taxes"
   - "Last active: TurboTax (2 min ago)"
   - Budget: "12 min available" with progress bar (earned 45 / used 33)
   - Text field + 30s countdown
   - Buttons: [Back to TurboTax] [Continue (0:27)]
5. User types "need to look up 1099-NEC filing" and waits for countdown
6. User clicks Continue → content.js sends JUSTIFY_SOCIAL_MEDIA to background.js
7. background.js forwards to native app → RelevanceScorer assesses justification
8. Native app responds:
   { relevant: true, costMultiplier: 1, reason: "Tax filing research", earnedMinutes: 12,
     categories: ["tax preparation", "financial documents", "IRS forms"] }
9. content.js shows "Relevant — cost reduced to 1x" confirmation screen
10. User clicks "Start Filtered Session" → content.js starts filtered session:
    - Sets ML categories from response
    - Applies blur-by-default
    - Shows session bar: "Taxes (filtered) | 12 min remaining" at 1x rate
11. Extension sends SOCIAL_MEDIA_HEARTBEAT every 30s
    { platform: "youtube", secondsSpent: 30, costMultiplier: 1 }
12. Native app decrements earned minutes, sends EARNED_MINUTES_UPDATE periodically
13. When earned minutes hit 0 → native app sends SESSION_EXPIRED
14. content.js shows "Time's up" overlay with:
    - "You've used all your earned time"
    - [Request More Time] (if hasPartner)
    - [Back to Work]
```

### Work Block — AI Says Not Relevant

```
(continues from step 7 above)
8. Native app responds:
   { relevant: false, costMultiplier: 2, reason: "Checking sports scores is not related
     to tax preparation.", earnedMinutes: 12 }
9. content.js shows "Not related — cost stays at 2x" warning:
   - "Your 12 min = 6 min of YouTube"
   - Buttons: [Back to TurboTax] [Continue at 2x]
10. If user continues → unfiltered session at 2x:
    - No content filtering
    - Session bar: "Unfiltered (2x) | 6 min remaining" in amber
    - Heartbeat at costMultiplier: 2
```

### Work Block Social Media Visit (Zero Earned Minutes)

```
1. User navigates to youtube.com during "Taxes" work block
2. content.js sends GET_WORK_BLOCK_STATE to background.js
3. background.js queries native app → gets:
   { isWorkBlock: true, intention: "Taxes", earnedMinutes: 0, delaySeconds: 60,
     hasPartner: true }
4. content.js shows blocked screen:
   "You have 0 earned minutes. Earn more by focusing on: Taxes"
   "25 min focused work = 5 min earned browsing time"
   [Request More Time]  [Back to Work]
5. No Continue button. User cannot proceed to social media.
```

### Free Block Social Media Visit (Has Earned Minutes)

```
1. User navigates to youtube.com during "Lunch" free block
2. content.js sends GET_WORK_BLOCK_STATE to background.js
3. background.js queries native app → gets:
   { isWorkBlock: false, earnedMinutes: 25, earnedToday: 45, usedToday: 20 }
4. content.js does nothing — no overlay, no filtering
5. Session bar shows: "Free Time | 25 min remaining" (subtle, non-intrusive)
6. Extension sends SOCIAL_MEDIA_HEARTBEAT every 30s
   { platform: "youtube", secondsSpent: 30, costMultiplier: 1 }
7. Native app decrements earned minutes, sends EARNED_MINUTES_UPDATE
8. When earned minutes hit 0 → native app sends SESSION_EXPIRED
9. content.js shows gentle "Time's up" overlay
```

### Free Block Social Media Visit (Zero Earned Minutes)

```
1. User navigates to youtube.com during "Lunch" free block
2. content.js sends GET_WORK_BLOCK_STATE to background.js
3. background.js queries native app → gets:
   { isWorkBlock: false, earnedMinutes: 0, hasPartner: false }
4. content.js shows gentle overlay:
   "You've used all your earned time for today."
   "Earn more during your next work block."
   "Next work block: 1:00 PM — Client project"
   (No "Request More Time" — no partner set up)
```

### Partner Extra Time Flow

```
1. User is on "Time's up" overlay, clicks "Request More Time"
2. content.js sends REQUEST_EXTRA_TIME to background.js
3. background.js forwards to native app
4. Native app sends notification to accountability partner:
   "[Name] has used all their browsing time. Requesting 30 more minutes."
5. Partner receives code, shares it with user
6. User enters 6-digit code in the overlay
7. content.js sends VERIFY_EXTRA_TIME_CODE { code: "384521" } to background.js → native app
8. Native app verifies → adds 30 min to budget → responds:
   { success: true, earnedMinutes: 30, requestsRemaining: 1 }
9. content.js dismisses overlay, user can browse
```

---

## Edge Cases

### Block Transitions While Browsing
- **Work → Free while on YouTube**: Justification screen disappears, content filtering stops, cost drops to 1x, session bar switches to "Free Time" mode.
- **Free → Work while on YouTube**: Justification screen appears immediately. User must justify their continued presence. Delay timer starts. Cost jumps to 2x default. Content filtering activates if AI says relevant.
- **Any → No block while on YouTube**: Treated as work block (justification required, 2x default).

### Multiple Social Media Tabs
- Only the **active (focused) tab** decrements earned minutes
- Background social media tabs don't cost anything — they're just sitting there
- If user switches between YouTube and Instagram tabs, the active one costs
- The native app tracks which platform is currently active via heartbeats

### App Disconnection Mid-Session
- If the macOS app disconnects while user is browsing social media:
  - Extension shows "App Required" overlay immediately (existing behavior)
  - Earned minutes freeze — no earning or spending without the app
  - On reconnect: native app sends current WORK_BLOCK_STATE and session resumes

### Midnight Reset
- Earned minutes reset to 0 at midnight local time
- Active social media sessions end at midnight (overlay: "Daily reset — time to rest")
- If user is browsing at 11:59 PM, session ends at midnight

### First-Time User
- Day 1: User gets 15 welcome minutes (no earning required)
- This lets them experience YouTube through the filter, see the session bar, understand the system
- After day 1: welcome credit gone, must earn like everyone else
- Welcome credit is one-time, never refreshes

---

## Resolved Design Decisions

These questions were raised during design and have been resolved:

1. **Free time budget**: There is no separate free time budget. Free blocks spend from the same daily earned pool. One number, one pool.

2. **Earned minutes scope**: Daily pool. Carries across all blocks throughout the day. Resets at midnight. 6 hours of standard work ≈ 60 minutes of social media.

3. **Zero earned minutes**: Hard wall. Cannot proceed to social media. Must earn more time or request extra time from partner. No debt, no override, no exceptions.

4. **Deep work detection**: Based on foreground activity only. If every foreground app/tab the AI assessed over a 25-minute window was relevant, and no irrelevant app/tab appeared in the foreground, that's deep work. Background tabs/apps are not assessed (too invasive and unreliable).

5. **No accountability partner**: No way to request more time. System is strict — this is the forcing function to set up a partner.

6. **Partner extra time**: 30 minutes added to budget per request (`partnerExtraTimeAmount`), max 2 requests per day (`maxDailyPartnerRequests`). Both configurable.

7. **No schedule**: Treated as a work block. Justification required, filtering active, 2x cost. Incentivizes setting up a schedule.

8. **Welcome credit**: 15 minutes on first day only. Lets new users experience the system before they have to earn.

9. **Earning while spending**: No. Earning pauses while on any social media platform, even if the visit is "relevant." You're either working or browsing, never both.

10. **Visit definition for escalating delays**: Each justification screen shown counts as a visit. Navigating away from social media for 5+ minutes expires the session — returning requires new justification. Switching between pages within the same platform does NOT count as a new visit.

11. **ML categories**: The macOS app's AI generates categories from the work block intention and sends them with the justification result. Extension uses them for DistilBERT/CLIP filtering. No user-facing category picker.

12. **Display sync**: Extension locally decrements earned minutes every second for smooth display. Native app sends authoritative updates every 30 seconds. Extension snaps to the authoritative value.

13. **Platform settings during free blocks**: Permanent user preferences (block Shorts, hide ads, block Reels) stay active during free blocks. Only intent-based ML filtering is disabled.

14. **Deep work rate**: 1.5x (not 2x). 25 min → 7.5 min earned. Meaningful bonus without making the currency feel unlimited.

15. **Work block cost model**: Default 2x (configurable via `workBlockCostMultiplier`). AI-relevant justification reduces to 1x as a reward. Framing: you start expensive, earn the discount.

16. **Streaks**: Deferred. Not in v1. May revisit with a daily streak model (days without requesting partner extra time) in a future version.

17. **Only deducted for actual use**: Users are only charged for actual time spent browsing. Ending a session early, closing the tab, or navigating away preserves the remaining earned balance. There is no "use it or lose it" — earned minutes stay in the pool until spent or the day resets. (Note: avoid "pay-as-you-go" terminology in user-facing copy — it implies a payment/subscription model.)

18. **FocusMonitor vs extension enforcement**: FocusMonitor skips its own overlay when the foreground browser has an active extension connection AND the URL is social media. The extension owns the full justification/earned-minutes flow for those sites. Browsers without the extension still get FocusMonitor's native macOS overlay (standard progressive enforcement, no justification text input or AI cost reduction). Checked via `BrowserMonitor`'s existing connection tracking.

19. **Multi-browser spending sync**: When the native app receives a heartbeat from any browser, it pushes `EARNED_MINUTES_UPDATE` to ALL connected browsers (not just the sender). This tightens the sync window. Future improvement: include `activeBrowsers` count so each browser can locally decrement at the combined rate for more accurate display between syncs.

20. **TimeTracker as clock, EarnedBrowseManager as accountant**: TimeTracker remains the single entry point for all heartbeats (handles deduplication, crash recovery, usage analytics). After recording time, it notifies EarnedBrowseManager via a callback (`onSocialMediaTimeRecorded(platform, seconds, isActive)`). EarnedBrowseManager applies cost multipliers and manages the earned pool. Two components, clear ownership, no duplicated logic.

21. **No protocol versioning needed**: Not launched yet — no installed base to migrate. Build the new system directly. Add version handshake later if needed.

---

## Brainstorm Archive

The following concepts were explored but not selected for the shipped system. Preserved for future consideration.

### Focus Streaks
Consecutive work blocks (or days) where user managed social media within their earned budget. Explored as both per-block streaks and daily streaks. Deferred for v1: the daily pool model makes per-block streaks awkward (your pool level at block start is inherited, not earned in that block). Daily streaks (days without requesting partner extra time) are cleaner but add complexity. The earned minutes scarcity is sufficient behavioral pressure for v1.

### Borrow From Tomorrow
Free browsing during a work block borrows from tomorrow's free time budget. Spend 20 minutes today, start tomorrow with 20 fewer. Exploits present bias — future self pays the price. Rejected for v1: adds complexity to budget tracking and the cause-effect loop is too delayed (you don't feel it until tomorrow).

### Gradual Degradation
Social media progressively degrades during work blocks: normal → no autoplay → grayscale → text-only → blocked. Fights the mechanism of distraction rather than time. Rejected for v1: complex to implement (CSS manipulation per platform, detecting autoplay), feels punitive, and the earn system already handles the time constraint naturally.

### Distraction Debt
Free browse during work blocks creates debt that must be repaid through focused work before free-time social media access. Direct cause-effect loop. Rejected for v1: overlaps with earn your browse (which is essentially the same mechanic — you spend earned minutes and have to re-earn them). Could be added later as a stricter mode.

### Reflection Gate (Multiple Choice)
Before free browsing, choose: "I'm stuck" / "I need a break" / "I'm procrastinating." Choice determines cost. Rejected: too easy to game by clicking a button. Replaced by the free-text justification that gets AI-assessed — forces genuine reflection and can't be gamed.

### Separate Free Time Budget
Free blocks would have their own configurable daily budget (e.g., 30 or 60 minutes) independent of earned minutes. Rejected: adds a second number to track, complicates the mental model. The unified earned pool is simpler — one number goes up, one number goes down.

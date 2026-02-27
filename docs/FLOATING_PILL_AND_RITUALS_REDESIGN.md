# Floating Pill & Rituals Redesign

> Design and implementation of the floating timer pill, block end celebration cards, block start rituals, noPlan card, nudge toasts, confetti, and sound effects.

---

## Pill Modes

The floating pill (`DeepWorkTimerController`) is a `KeyablePanel` at `.floating` level, positioned top-right. It transitions between modes via animated resize (spring curve: `controlPoints: 0.34, 1.56, 0.64, 1.0`).

| Mode | Size | Description |
|------|------|-------------|
| `timer` | 300×70 | Normal countdown — dot + intention + MM:SS, stats row below |
| `blockComplete` | 300×70 | Transitional — amber "Block complete" + "0:00" |
| `celebration` | 460×420 (work) / 460×220 (free) | Expanded carousel of celebration cards |
| `startRitual` | 460×160 | "Up next" card with Start/Edit buttons, green border |
| `startRitualEdit` | 460×340 | Inline block editor (title, description, type) |
| `noPlan` | 460×260 | "No plan set" card with Plan/Snooze buttons, amber border |

### Timer Mode

```
┌──────────────────────────────────────────┐
│  ● Software engineering          22:38   │
│  90% focused                    +8.1m    │
└──────────────────────────────────────────┘
```

- Dot color: indigo gradient (focused) / red (distracted)
- Stats row: focus % (green ≥80, amber ≥50, red <50) + earned minutes
- On hover: stats row swaps to "End Block" button (amber)
- Last 60s: timer text turns amber (`isApproachingEnd`)
- Last 3s: Tink countdown tone at 3, 2, 1

### Block Complete Mode

Transitional state when timer hits 0:00. Amber dot + border. Stays until AppDelegate triggers celebration or pill is dismissed.

---

## Celebration Cards (Block End)

When a block ends, the pill expands into an informational carousel. Cards auto-advance every 10s. Navigation dots shown at bottom.

### Work Blocks — 3 or 4 cards:

**Card 1: Session Complete**
- "SESSION COMPLETE" header
- Block title + duration
- Block type dot + label + time range
- "You earned X min of recharge time."
- Next button

**Card 2: Focus Score**
- Large "X% focused" text (colored by score)
- Focus bar (filled proportionally)
- Encouragement message (≥80%: "Great session!", ≥50%: "Good effort", <50%: "Keep showing up")
- Inline confetti overlay when focus ≥ 80% (SwiftUI Canvas particle system, 40 particles, 2.5s fade)
- Next button

**Card 3: App Breakdown**
- "Where you spent your time" header
- Top 6 apps with time (from `relevance_log.jsonl`)
- Next block preview (if no Up Next card)
- Done button (or Next if Up Next card follows)

**Card 4: Up Next** (only for back-to-back blocks, ≤5 min gap)
- "Up next" header
- Block type + time range + duration
- Block title + description
- Start button (goes straight to timer, skipping separate start ritual)

### Free Time Blocks — 1 card:

"Break over" + block type/time + next block preview + Done button.

### Celebration → Next Block Flow

Done button calls `resumeAfterCelebration()` which:
1. Forces `scheduleManager.forceRecalculate()` for fresh state
2. Guards against showing start ritual for the just-celebrated block (`celebrationForBlockId`)
3. Shows start ritual for the new block if within 120s of block start
4. Falls back to timer if no ritual needed

---

## Start Ritual (Pill-Based)

The pill contracts to a 460×160 card with green border:

```
┌──────────────────────────────────────────┐
│  ● FOCUS HOURS                      3m   │
│                                          │
│  Software Engineering 2                  │
│  11:13 AM — 11:16 AM                    │
│                                          │
│  [Start]  Edit              auto: 2:56   │
└──────────────────────────────────────────┘
```

- **Work blocks**: Full ritual — Start button, Edit link, auto-start countdown (3 min)
- **Free time**: Simple card — "Enjoy your break" + Start button, auto-start (30s)
- Edit mode expands to 460×340 with inline title/description/type fields
- `awaitingRitual = true` while showing — all enforcement paused
- `skipNextRitual` flag prevents re-show when `updateBlock` triggers `onBlockChanged`
- `lastRitualShownForBlockId` guards against showing ritual twice for same block

---

## No Plan Card

When `timeState == .noPlan` or `.unplanned`, shows a 460×260 pill with amber border:

- "No plan set for today" message
- "Plan My Day" button → opens dashboard
- "Snooze 30 min" button → sets `noPlanSnoozeUntil`
- Next block preview (if one exists)

---

## Nudge Toasts

Compact 300px-wide toast below the pill. **Translucent red** background (0.92 opacity) with bold white text.

| Level | Behavior | Content |
|-------|----------|---------|
| Level 1 | Auto-dismiss 8s | "Not related to your task" + Got it |
| Level 2 | Stays until interaction | "Off-task X min" + Got it |
| Warning | Stays until interaction | "Off-task X min" / "Intervention in 60s" (deeper red) |

- "This is relevant" secondary link expands inline justification text field
- Positioned right-aligned below pill window frame (`pillWindowFrame`)

---

## Sound Effects

| Event | Tone | Notes |
|-------|------|-------|
| Pill appears (timer starts) | Glass | Block begins, timer shown |
| Start ritual card shown | Funk | Gentle start cue |
| Celebration cards expand | Glass | Block ends |
| Last 3 seconds countdown | Tink × 3 | At 3, 2, 1 seconds remaining |

Sounds controlled by `DeepWorkTimerController.soundEnabled` static toggle.

Sound tone preview available in dashboard Settings → Distractions → "Notification Sound" picker (14 system tones: Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink). Preview only — doesn't change action sounds.

---

## Confetti

Inline SwiftUI Canvas particle effect (`ConfettiCanvasView`), shown inside the focus score celebration card when `focusScore >= 80`. 40 particles burst upward with gravity, colored (green, blue, yellow, orange, pink, purple), fade over 2.5s. Clipped to card bounds.

Previous full-screen Lottie confetti (`ConfettiController`) has been removed along with the `lottie-ios` dependency.

---

## Key Implementation Details

### State Guards

- `awaitingRitual`: Pauses all enforcement in `evaluateApp()` and `pollActiveTab()`
- `pendingBlockStartAfterCelebration`: Defers block start when pill is in celebration mode
- `celebrationForBlockId`: Prevents re-showing start ritual for the block that just ended
- `skipNextRitual`: Prevents ritual re-show when `updateBlock` fires `onBlockChanged` synchronously
- `lastRitualShownForBlockId`: Guards against duplicate ritual for same block

### Block Transition Flow

```
Block A ends
  → ScheduleManager.onBlockChanged fires
  → AppDelegate captures prev block stats
  → AppDelegate calls focusMonitor.showCelebration(prevBlock, stats)
  → If pill in .blockComplete: pendingBlockStartAfterCelebration = true
  → Celebration cards show
  → User clicks Done
  → resumeAfterCelebration()
    → forceRecalculate() (fresh state)
    → Guard: block.id != celebrationForBlockId
    → Show start ritual for new block (if within 120s)
    → Or just show timer
```

### Fallback: resumeIfPendingBlockStart()

If celebration is skipped (e.g. 0 ticks for a free time block), `pendingBlockStartAfterCelebration` is set but `showCelebration()` returns early. `resumeIfPendingBlockStart()` is called from AppDelegate to unblock the deferred start.

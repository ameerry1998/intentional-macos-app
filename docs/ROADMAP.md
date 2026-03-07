# Intentional Product Roadmap

> From cop to coach: building a focus tool that helps users develop genuine self-regulation.

This document consolidates all planned features, design ideas, and product direction for Intentional. It draws on psychological research (Self-Determination Theory, implementation intentions, reactance theory, self-monitoring reactivity) and existing feature specs.

---

## Guiding Principles

These principles should inform every feature decision:

1. **Autonomy over control.** The app should make users feel like they *chose* to focus, not that they're being forced. Reframe enforcement as honoring the user's own commitment. ("You chose Deep Work for this block" vs "You are blocked.")

2. **Celebrate returns, not just streaks.** Every time a user self-corrects after distraction is a win worth acknowledging. Don't just punish the departure — reward the comeback.

3. **Scaffold toward independence.** External enforcement is scaffolding, not the building. The goal is users who can focus without the app, not users who are dependent on it. Features should gradually build internal self-regulation capacity.

4. **Reflection over surveillance.** Self-monitoring and reflection produce sustainable behavior change. External enforcement produces compliance that collapses when the enforcer is removed.

5. **Self-compassion over self-criticism.** The app's tone during failure moments shapes the user's relationship with focus itself. A bad focus block should prompt learning, not shame.

---

## The 5 Core Changes: From Cop to Coach

These are the highest-priority changes to implement. They shift the app's fundamental relationship with the user from enforcer to ally.

### 1. Block Start Ritual
30-second prompt when a block begins: show your intention, set an if-then plan for distraction, close distracting tabs. Strongest research backing of any feature we could add.

### 2. Block End Ritual
30-second reflection when a block ends: self-assessment of focus, what you earned, what went well, what you'd change. Builds the self-awareness muscle so users need less external enforcement over time.

### 3. Coaching Language Overhaul
Replace "intervention exercise" with "refocus break", "blocking overlay" with "pause screen", red timer dot with amber. Add warm messages at every enforcement step: "You set out to work on [title]. Still on track?" and "You chose deep work for this block." The key reframe: *you chose this*, not *you are blocked*.

### 4. Positive Reinforcement for Returning to Focus
Right now returning from distraction just removes the punishment (grayscale fades, dot turns indigo). Add a brief positive signal: subtle glow on the timer, "+1 refocus" counter, "Welcome back." Celebrate the comeback, not just the streak.

### 5. Coaching Mode Toggle
Let users pick their enforcement style: Coach (warm language, reflection prompts, longer grace), Strict (current pipeline), Zen (self-monitoring only, no enforcement). Giving users autonomy over how they're supported is the most SDT-aligned thing we can do. Also opens the door to the scaffolding-to-autonomy pipeline where the app gradually suggests stepping down enforcement as users improve.

---

## Detailed Experience Design for the 5 Core Changes

### 1. Block Start Ritual — The Experience

#### When it appears

Two minutes before a block starts, the floating timer pill appears with a gentle pulse and a countdown: "Deep Work in 2:00". This is the early warning — close what you need to close, finish your sentence, use the bathroom. No enforcement yet, just awareness.

When the block time arrives, a **ritual card** slides in from the floating timer. Not a full-screen takeover — it's a focused card (roughly 400x500px) anchored near the timer pill, dark glass aesthetic, the same visual language as the rest of the app. It feels like a moment of intention, not an interruption.

#### What the user sees

```
┌─────────────────────────────────────┐
│                                     │
│   DEEP WORK · 9:00 — 11:30 AM      │
│   Build auth module                 │
│                                     │
│   ─────────────────────────────     │
│                                     │
│   What do you want to accomplish?   │
│   ┌───────────────────────────────┐ │
│   │ Get login flow working e2e    │ │
│   └───────────────────────────────┘ │
│                                     │
│   If I get distracted, I will...    │
│   ○ Close the tab & return          │
│   ● Take 3 breaths & re-read this  │
│   ○ Write it down for later         │
│                                     │
│   ─────────────────────────────     │
│                                     │
│   ⚠ 3 distracting tabs open        │
│   YouTube · Reddit · Twitter        │
│   [Close them]          [Keep them] │
│                                     │
│          [Start]  [Edit]  [+15 min] │
│                                     │
└─────────────────────────────────────┘
```

#### The details that matter

**The focus question** ("What do you want to accomplish?") is a single free-text field, not a form. It saves to the block's metadata and shows up later in the block end ritual and assessment popover. If the user already wrote a block description during planning, it pre-fills. If not, this is their chance. Pressing Enter or clicking Start submits it.

**The if-then plan** is the psychological core. Three radio options, pre-selected to the user's last choice (or "Close the tab & return" for first-timers). The user reads through them and picks one. This takes 3 seconds but creates the implementation intention that the research shows has d=0.65 effect. The selected plan is stored and referenced later — when a nudge fires during the block, it can say: "You planned to take 3 breaths. Try it now."

**The distracting tab scan** checks for open tabs on known distracting sites. If found, it lists them with a count. "Close them" closes all of them via AppleScript. "Keep them" dismisses the warning — no judgment, no forced action. The user chose. If no distracting tabs are found, this section doesn't appear at all — no empty state clutter.

**The three buttons at the bottom:**
- **Start** — Dismisses the ritual card, the block begins, enforcement activates. The floating timer pill transitions smoothly from the ritual card state to its normal countdown state.
- **Edit** — Opens the block editor inline (change title, description, time). For when you sit down and realize you need to work on something different than what you planned.
- **+15 min** — Pushes the block start back 15 minutes. For when you need a bit more transition time. Can be pressed multiple times. The ritual card stays but the countdown resets.

**If the user ignores the ritual card** — it doesn't force interaction. After 3 minutes, it gently collapses into the timer pill with the block running. The intention question stays blank (defaults to block description). The if-then plan defaults to the user's last selection. No scolding, no popup. The ritual is an invitation, not a gate.

**Skipping entirely** — There should be a small "Skip" link in the corner of the ritual card. Some mornings you just want to dive in. That's fine. The ritual is most valuable in the first few weeks while the user builds the habit.

#### The feel

The ritual should feel like a runner stretching before a race — a moment of preparation that makes the effort ahead feel intentional, not imposed. The card's appearance is calm, not urgent. The transition from ritual to work should feel like stepping through a doorway you chose to walk through.

---

### 2. Block End Ritual — The Experience

#### When it appears

When a block's timer reaches zero, the floating timer pill expands into a **reflection card** — same visual language as the start ritual, anchored to the timer position. The block's enforcement mechanisms immediately deactivate (no more nudges, grayscale cleared, redirects off). The user is free. The reflection card is an invitation to pause before moving on.

#### What the user sees

```
┌─────────────────────────────────────┐
│                                     │
│   DEEP WORK COMPLETE                │
│   Build auth module · 2h 30m        │
│                                     │
│   ─────────────────────────────     │
│                                     │
│   You earned 28 min of recharge     │
│   time this block.                  │
│                                     │
│   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░  82%     │
│   focused                           │
│                                     │
│   ─────────────────────────────     │
│                                     │
│   How focused did you feel?         │
│   😤  😕  😐  🙂  🔥               │
│                                     │
│   What went well?                   │
│   ┌───────────────────────────────┐ │
│   │                               │ │
│   └───────────────────────────────┘ │
│                                     │
│   ─────────────────────────────     │
│                                     │
│   Next: Free Time in 5 min         │
│                                     │
│              [Done]                  │
│                                     │
└─────────────────────────────────────┘
```

#### The details that matter

**"You earned X minutes"** is the first thing the user sees. This is positive reinforcement — the reward for their effort, stated immediately. Not "your focus score was 82%." Not "you were distracted for 27 minutes." The first message is what they *gained*. The focus percentage is secondary, displayed as a subtle bar underneath.

**The self-assessment emoji scale** is deliberately *the user's* assessment, not the app's. The app already has its own focus score from AI polling. This question asks: "How did *you* feel?" Sometimes the AI says 82% but the user felt scattered. Sometimes the AI says 60% but the user had a breakthrough. The user's self-assessment is stored alongside the AI score — over time, the gap between self-assessment and AI score is itself a useful data point.

**"What went well?"** is a single text field. Not "what went wrong." Not "what distracted you." The question deliberately orients toward the positive — self-compassion research shows this framing prevents the shame spiral that leads to burnout. The field is optional. If the user just clicks Done without typing anything, that's fine. But when they do type something ("got the login flow working, felt in the zone after the first 30 min"), it becomes part of their daily narrative.

**The transition preview** — "Next: Free Time in 5 min" — gives the user a sense of what's ahead. If the next block is work, it shows the title. If there's a gap, it says "Nothing scheduled until [time]." This helps the user mentally prepare for the shift.

**No "What would you change?" question by default.** This appears only if the user's self-assessment is 😤 or 😕 (the two lowest). If they felt good, don't prompt for improvement — celebrate the win. If they felt bad, *then* offer the reflective question: "What would help next time?" This avoids reflexive self-criticism after good blocks.

**If the user ignores it** — after 2 minutes, the card fades away on its own. The earned minutes and focus score are still recorded. The self-assessment defaults to null (no entry). No penalty for skipping.

#### Block transitions

Between blocks, the timer pill shows a brief interstitial state:
- **Work -> Free**: The pill glows green briefly. "Enjoy your break. 43 min available." Then transitions to the free time display.
- **Free -> Work**: 2-minute warning appears on the pill. Then the start ritual for the new block appears.
- **Work -> Work**: End ritual for the finished block, brief pause, then start ritual for the new block. The user gets both moments.

#### The feel

The end ritual should feel like reaching a checkpoint in a game — a moment of acknowledgment before the next stage. Not a debriefing. Not a performance review. A pause that says: "You did something. Here's what you gained. Take a breath."

---

### 3. Coaching Language Overhaul — The Experience

#### The principle

Every piece of text the user reads during enforcement should pass this test: **"Would a good coach say this?"** A good coach doesn't say "BLOCKED." A good coach says "Hey, you set out to do X. Let's get back to it." A good coach references *your* goals, not *their* rules.

#### What changes at each enforcement stage

**Nudge card (first contact with distraction):**

Current: A floating notification with "This is relevant" / dismiss options.
New: The nudge card says the block title and intention at the top. Below: "You planned to [focus question from start ritual]. Still on track?" The "This is relevant" button stays (it triggers AI justification). But the dismissal path becomes "Back to [last relevant app]" — named, specific, actionable.

If the user set an if-then plan during the start ritual, the nudge references it: "You said you'd close the tab and return. Want to do that now?" This closes the loop on the implementation intention — the cue (distraction detected) triggers the pre-planned response.

**Screen darkening (progressive overlay):**

Current: Silent. Screen just starts getting dark.
New: When darkening begins, a small text label appears near the top of the overlay (subtle, like a watermark): "Your block has 1h 12m left." No judgment. Just a factual reminder of the opportunity cost. The label fades after 5 seconds so it doesn't become wallpaper.

**Auto-redirect:**

Current: Tab silently switches to last relevant URL. Brief nudge appears.
New: Before redirecting, show a 3-second toast at the top of the browser: "Heading back to github.com — you chose deep work for this block." The redirect still happens, but the user sees *why* and is reminded *they* made this choice. The toast uses warm language and names the destination.

**Pause screen (formerly "blocking overlay"):**

Current: Full-screen "Back to work" overlay.
New: Full-screen overlay with the block title large and centered. Below it: "Take a breath. You planned to work on [title]." Below that: a "Ready to return" button. The overlay is still a hard wall — but it feels like a pause, not a punishment. The language doesn't say "you failed" or "blocked." It says "pause" and "ready."

**Refocus break (formerly "intervention exercise"):**

Current: 60-second mandatory game with escalating duration.
New: Same time requirement (60s / 90s / 120s), but the user chooses their activity:
- "Guided breathing" (in/hold/out cycle with visual)
- "Re-read your intention" (shows the focus question answer from start ritual + if-then plan)
- "Quick body check" (stretch, notice tension, unclench jaw)
- "Just sit with it" (60-second timer, nothing else — for the user who just wants to wait it out)

All four options satisfy the time requirement. The user picks. This tiny bit of choice within the constraint preserves autonomy.

**Timer dot color:**

Current: Red when distracted.
New: Amber when distracted. Red communicates "danger" and "wrong" — it's punitive. Amber communicates "attention" and "caution" — it's informational. Small change, big shift in emotional valence. The dot still clearly signals distraction state, but without the shame association.

#### Language reference table

| Context | Old | New |
|---------|-----|-----|
| Nudge | "Is this relevant?" | "You planned to [X]. Still on track?" |
| Redirect toast | (none) | "Heading back to [site] — you chose deep work" |
| Darkening label | (none) | "Your block has [time] left" |
| Pause screen | "Back to work" | "Take a breath. Ready to return to [title]?" |
| Refocus break title | "Intervention" | "Refocus break" |
| AI verdict: not relevant | "Irrelevant" | "Off-path" |
| Timer dot distracted | Red | Amber |
| Return from distraction | (silent) | "Welcome back" |
| Block assessment label | "Irrelevant time" | "Off-path time" |

#### The feel

The app should sound like a training partner who's been through it themselves — direct, warm, non-judgmental. Not a security guard. Not a disappointed parent. Not a robot. Someone who says "I know this is hard. You chose this. Let's get back to it."

---

### 4. Positive Reinforcement for Returning to Focus — The Experience

#### The core insight

Right now, distraction is a *loud* event in the app: red dot, darkening screen, nudge cards, redirects, blocking overlays. Returning to focus is a *quiet* event: overlay fades, dot turns indigo, done. This asymmetry trains the user to associate the app with what went wrong, never with what went right. Every return to focus is a small victory — the user chose to come back. The app should notice.

#### What happens when the user returns to focus

**Moment of return** (user switches back to relevant app/tab):

1. **Timer pill glow** — The floating timer pill does a brief, subtle pulse. A soft glow effect (indigo/teal) that expands outward and fades over ~1.5 seconds. Not flashy. Not gamified. Just a visual "I see you." Like the pill takes a satisfied breath.

2. **Dot transition** — The timer dot transitions from amber back to indigo with a smooth 0.5s animation (not instant snap). The smooth transition feels earned, not mechanical.

3. **Toast message** — A small, temporary text appears below or beside the timer pill: "Welcome back." It fades after 3 seconds. That's it. Two words. No exclamation mark. Not "Great job!" (patronizing). Not "Focus restored!" (robotic). Just "Welcome back." — warm, brief, human.

4. **Darkening reversal** — The screen darkening already reverses over 2 seconds. Keep this — the brightening feels like relief. The room "opening up" is itself a reward.

5. **Refocus counter** — Somewhere on the timer pill (or in the block end ritual), track a small "+1" for each return to focus during this block. Not prominently displayed during the block — it's not a scoreboard. But at block end, the reflection card can say: "You refocused 3 times this block." This reframes distraction from "I got distracted 3 times" (failure) to "I came back 3 times" (resilience).

#### What this does NOT include

- No sound effects. Sound is intrusive and would feel gamified.
- No points, XP, or rewards. This isn't gamification. It's acknowledgment.
- No streak counter. Streaks create anxiety about breaking them. The refocus counter is the opposite — it celebrates *breaking out of* distraction, which requires the distraction to have happened first.
- No popup or card. The toast is ambient text that appears and disappears. It never blocks anything or requires interaction.

#### Over time

As the user develops their focus muscle, they'll start noticing the pattern: wander, catch themselves, return, see the gentle glow. The app is building a *positive association with the act of self-correction*. Eventually, the user self-corrects faster — not because the punishment got worse, but because coming back feels good.

#### The feel

Think of it like a meditation app. When your mind wanders during meditation and you notice it, that moment of noticing is actually the practice working. A good meditation teacher says "when you notice you've wandered, gently return to the breath." They don't say "you failed at meditating." The glow and "Welcome back" is the app being that teacher — noticing the return, acknowledging it, moving on.

---

### 5. Coaching Mode Toggle — The Experience

#### Why this matters

Different users need different things at different stages. A new user fighting a YouTube addiction needs Strict mode. A seasoned user who has built good habits needs Zen mode. A user somewhere in the middle needs Coach mode. Forcing everyone through the same enforcement pipeline either over-restricts advanced users (breeding resentment) or under-supports new users (letting them fail).

More importantly, *choosing your own enforcement level* is itself an act of autonomy. The user isn't having rules imposed on them — they're selecting their own training regimen.

#### Where it lives

The coaching mode selector is in Settings, near the top — it's a fundamental choice that affects everything else. Three options displayed as cards the user taps to select:

```
┌─────────────────────────────────────────────────────┐
│  HOW SHOULD INTENTIONAL SUPPORT YOU?                │
│                                                     │
│  ┌─────────┐  ┌──────────┐  ┌─────────┐            │
│  │  COACH  │  │  STRICT  │  │   ZEN   │            │
│  │         │  │          │  │         │            │
│  │ Gentle  │  │ Hard     │  │ Aware   │            │
│  │ nudges, │  │ walls,   │  │ only,   │            │
│  │ warm    │  │ firm     │  │ no      │            │
│  │ cues,   │  │ enforce- │  │ enforce-│            │
│  │ your    │  │ ment,    │  │ ment,   │            │
│  │ pace    │  │ no       │  │ full    │            │
│  │         │  │ wiggle   │  │ trust   │            │
│  │         │  │ room     │  │         │            │
│  └────◉────┘  └─────────┘  └─────────┘            │
│                                                     │
└─────────────────────────────────────────────────────┘
```

#### What each mode does

**Coach mode** (default for new users):
- Block start and end rituals enabled
- Nudges appear with coaching language and if-then plan references
- Screen darkening starts after a longer grace period (~20s instead of ~10s)
- Auto-redirect shows a 3-second toast before redirecting (not instant)
- Pause screen uses warm "take a breath" language
- Refocus break offers choice of activities
- Timer dot turns amber (not red) when distracted
- "Welcome back" acknowledgment on return to focus
- All per-block enforcement settings still apply (user can still disable specific mechanisms)

**Strict mode** (for users who want hard boundaries):
- Block start ritual is optional (shown but can be permanently dismissed)
- No block end ritual (just end the block, get back to it)
- Current enforcement language (direct, no-nonsense)
- Faster escalation — shorter grace periods
- Auto-redirect is instant (no toast delay)
- Full blocking overlay with "Back to work" language
- Mandatory intervention exercise (no choice of activity)
- Timer dot turns red when distracted
- No "welcome back" message (the clearing of enforcement is the signal)
- This is the current app behavior, more or less. Some users genuinely want this and would find coaching language patronizing.

**Zen mode** (for users who've built their focus muscle):
- Block start and end rituals enabled (rituals are still valuable)
- **No enforcement mechanisms fire at all** — no nudges, no darkening, no redirect, no overlay, no intervention
- The floating timer pill still shows, with the dot turning amber when the AI detects off-path browsing — but it's purely informational
- Focus scores and per-block stats still tracked and visible
- The earned browse pool still operates (you still earn and spend)
- The block assessment popover still shows your time breakdown
- This is "self-monitoring only" — the research shows awareness alone changes behavior. The user sees their data and makes their own choices.

#### When locked

If the account is locked (partner or self-lock), the coaching mode **cannot be changed**. Whatever the user selected before locking is frozen. This prevents "I'm struggling so I'll switch to Zen mode to avoid enforcement" — the lock applies to the coaching mode too.

The three mode cards render as disabled/grayed out with the lock icon. The user can see which mode they're on but can't change it.

#### Mode transitions

Switching modes takes effect on the next block start, not mid-block. If you're in a Deep Work block and switch from Strict to Coach, the change applies when the block ends and the next one begins. This prevents gaming (switching to Zen during a distraction, then back to Coach).

A confirmation appears when switching: "Switch to Zen mode? Enforcement will be disabled starting next block. Your focus data will still be tracked." This makes the choice deliberate.

#### The scaffolding-to-autonomy nudge

After 2 weeks of consistent use in Strict mode (average focus score above 70%), the app gently suggests: "You've been doing well. Want to try Coach mode? You'll still get support, but with more breathing room." The user can dismiss this permanently ("Don't ask again").

After 2 weeks of consistent Coach mode use (average focus score above 75%), the app suggests Zen mode the same way.

These suggestions are never pushy — one-time offers that can be permanently dismissed. The user is always in control of their own progression. But the app plants the seed: "You might be ready for more autonomy."

#### The feel

The coaching mode toggle should feel like choosing your difficulty level in a game — not a judgment about who you are, but a practical choice about what you need right now. None of the three modes is "better" or "worse." Strict isn't for weak people. Zen isn't for strong people. They're tools for different situations. A marathon runner might want Strict mode during a crunch week and Zen mode during a light week. The app adapts to the user, not the other way around.

---

## Priority Tiers

### P0 — Ship Next (High Impact, Clear Spec)

#### Default Block Duration: 30 Minutes
**Status:** Ready to implement
**Psychological basis:** BJ Fogg's Tiny Habits (lower the activation energy, make it feel small)

Change the default block duration from 60 minutes to 30 minutes everywhere — calendar drag-create, quick-block buttons in the pill, AI planning coach suggestions. 30 minutes feels approachable even when unmotivated. Users can always extend, but starting small reduces planning resistance. The planning coach's system prompt should also default to 30-minute blocks.

#### Rename Block Types for Clarity
**Status:** Ready to implement (display names only, internal IDs unchanged)

Rename the three block types in all user-facing UI:
- `deepWork` → **"Deep Focus"** — "Hard creative/technical work. Distractions aggressively blocked."
- `focusHours` → **"Focus"** — "Moderate focus work. Gentle nudges keep you on track."
- `freeTime` → **"Free Time"** — "Breaks, errands, personal time. No enforcement."

Each block type should show its one-line explanation in the block creation UI, type picker, and planning coach wizard. Internal identifiers (`deepWork`, `focusHours`, `freeTime`) stay the same — this is a display-only change. Affects: dashboard calendar, pill cards, planning coach, start/end rituals, settings.

#### Mid-Block Celebration in Pill
**Status:** Design needed
**Psychological basis:** Variable ratio reinforcement, BJ Fogg's celebration method ("Shine" — the emotional micro-moment after a small win wires the habit)

Show brief motivational messages in the floating pill at variable focus streak milestones (e.g., 10, 20, 30 minutes of continuous focus). The celebration should be:
- Subtle: a brief text swap in the pill (similar to recovery takeover) lasting 2-3 seconds
- Variable: not perfectly predictable — sometimes at 8 min, sometimes at 12 min (variable ratio)
- Warm: messages like "Locked in", "Crushing it", "Deep in the zone", "Flow state"
- Non-interruptive: no sound, no popup, no button — just a visual acknowledgment that fades

This addresses the "punishment-to-reinforcement ratio is inverted" problem — currently the pill only reacts to bad behavior. Mid-block celebrations make it react to good behavior too.

#### One-Time Onboarding Tooltips
**Status:** Design needed
**Psychological basis:** Expectation setting reduces reactance (users accept enforcement better when they understand it in advance)

Show one-time tooltips explaining enforcement features the first time a user encounters them:
- **Screen darkening**: "The screen dims gradually when you're off-task. It clears when you return to your work." (shown on first grayscale activation)
- **Auto-redirect**: "We brought you back to your last relevant page. You chose Deep Focus for this block." (shown on first redirect)
- **Nudge**: "This is a gentle reminder to check if you're still on track." (shown on first nudge)
- **Intervention**: "This is a refocus break. It helps you reset before returning to work." (shown on first intervention)

Each tooltip shown once per feature, tracked via UserDefaults. Dismissible with a single tap. This prevents the "WTF is happening to my screen" moment that can trigger reactance.

#### Self-Accountability Partner Prevention
**Status:** Ready to implement

Prevent users from entering their own email address as their accountability partner. Check `partnerEmail` against the user's registered email (from `deviceId` registration or stored email). Show a friendly message: "Your accountability partner should be someone else — a friend, family member, or colleague who can help keep you honest." This is a simple validation on the partner email input field.

#### Block Start Ritual
**Status:** Design phase
**Psychological basis:** Implementation intentions meta-analysis (d=0.65 effect size, Gollwitzer & Sheeran 2006, 94 studies)

When a block begins, present a 30-60 second ritual screen:

1. **Intention display**: Show block title, description, and time remaining
2. **Focus question**: "What is the one thing you want to accomplish in this block?"
3. **If-then plan**: "If I get distracted, I will..." with options:
   - Close the tab and return to my task
   - Take three breaths and re-read my intention
   - Write down what I was curious about and come back later
   - Custom response
4. **Environmental cue**: "Before you begin: close extra tabs, silence your phone, take a breath"
5. **Actions**: Start / Edit Block / Push Back 15 min

The pre-block prompt also scans for open distracting tabs and offers to close them ("Clean Desk"). This is the single most evidence-backed feature we can add — if-then plans with rehearsal have medium-to-large effects on goal attainment across 642 independent tests.

#### Block End Ritual
**Status:** Design phase
**Psychological basis:** Self-monitoring reactivity, self-compassion research

When a block ends, present a 30-60 second reflection:

1. **Self-assessment**: "How focused did you feel this block?" (1-5 or emoji scale)
2. **What you earned**: "You earned X minutes of recharge time this block" (positive reinforcement)
3. **Highlight**: "What went well?" (orients toward self-compassion)
4. **Learning**: "What would you do differently?" (non-judgmental growth)
5. **Transition preview**: "Your next block is [title] in [X minutes]"

Block transitions should also include brief "palate cleansers":
- Work -> Free: "Nice work. You earned [X minutes]. Enjoy your break."
- Free -> Work: "Break's over. You planned to work on [title]. Ready?"

#### Per-Block Enforcement Settings
**Status:** UI implemented, FocusMonitor integration pending
**Spec:** [BLOCK_TYPE_ENFORCEMENT_SETTINGS.md](./BLOCK_TYPE_ENFORCEMENT_SETTINGS.md)

6 toggleable enforcement mechanisms per block type (Deep Work, Focus Hours):
- Nudge notifications
- Screen red shift (darkening overlay)
- Auto-redirect
- Blocking overlay
- Intervention exercises
- Background audio detection (coming soon)

Deep Work defaults: all ON. Focus Hours defaults: auto-redirect and blocking overlay OFF.
Settings lock when account is locked (partner/self lock).

**Remaining work:** Gate each enforcement mechanism in FocusMonitor.swift behind its toggle.

#### Background Audio Detection from Distracting Sites
**Status:** Toggle in UI, no runtime logic
**Spec:** Referenced in [BLOCK_TYPE_ENFORCEMENT_SETTINGS.md](./BLOCK_TYPE_ENFORCEMENT_SETTINGS.md)

Detect when sites on the user's distracting sites list are playing audio in background tabs during work blocks. Uses existing extension USAGE_HEARTBEAT signals cross-referenced with FocusMonitor state.

Key design decisions:
- If a site is on the distracting sites list AND playing background audio, treat it as active distraction
- `music.youtube.com` exempted even if `youtube.com` is distracting
- Spotify/Apple Music always allowed (music apps, not "distracting sites")
- No new settings needed — uses existing distracting sites config

#### Idle Detection — Anti-Gaming for Earned Browse
**Status:** Design phase
**Priority rationale:** Integrity issue — the earned browse system's credibility depends on earning being real

##### The Problem

The earned browse system currently rewards *presence*, not *activity*. FocusMonitor checks what app or tab is in the foreground and, if it's relevant, records a work tick that earns browse time. But it never checks whether the user is actually *doing anything*. This creates an obvious gaming vector:

1. Open VS Code / a relevant document / your IDE
2. Walk away, scroll your phone, zone out, take a nap
3. Come back to a fat earned browse balance you didn't work for

This undermines the entire earned browse contract ("focus earns you recharge time"). If users discover they can game it — and they will — the system loses its motivational power. Worse, it actively teaches the wrong lesson: that the appearance of work is as good as actual work.

This isn't hypothetical. Any user who spends 5 minutes with the system will realize the timer just needs a relevant app in the foreground. The longer this goes unaddressed, the more users build the habit of gaming rather than focusing.

##### Design Principles

- **Generous, not paranoid.** The threshold should accommodate legitimate low-input work (reading documentation, thinking through a problem, watching a tutorial). The goal is catching someone who walked away for 5 minutes, not penalizing someone who paused to think for 30 seconds.
- **Pause, don't punish.** When idle is detected, earning simply pauses — no penalty, no lost progress, no scolding. The moment you move the mouse or press a key, earning resumes instantly.
- **Transparent, not sneaky.** The user should know idle detection exists and see when it activates. No hidden surveillance. A brief indicator in the pill ("Paused — move mouse to resume") makes the system legible.
- **Coach tone.** If there's a nudge, it should be warm: "Still there?" not "Inactivity detected."

##### Technical Approach: IOKit System Idle Time

macOS exposes system-wide idle time (seconds since last mouse movement or keystroke) via IOKit's `HIDIdleTime` property. This is the simplest and most reliable approach:

```swift
import IOKit

func systemIdleTime() -> TimeInterval {
    var iterator: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOHIDSystem"), &iterator)
    let entry = IOIteratorNext(iterator)
    defer { IOObjectRelease(entry); IOObjectRelease(iterator) }

    var dict: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(entry, &dict, kCFAllocatorDefault, 0)
    let nsDict = dict?.takeRetainedValue() as? [String: Any]
    let nanos = nsDict?["HIDIdleTime"] as? Int64 ?? 0
    return TimeInterval(nanos) / 1_000_000_000
}
```

**Why IOKit over event taps:**
- Single function call vs. setting up a `CGEventTap` listener
- No additional permissions needed beyond what we already have
- Works at the OS level — catches all input devices (trackpad, mouse, keyboard, Touch Bar)
- Can be checked in the existing FocusMonitor polling loop (already runs every 10s)
- No background thread or event stream to manage

##### Behavior Spec

**Idle threshold: 3 minutes (180 seconds).** This is generous enough that reading a long paragraph, thinking through a problem, or watching a code review video won't trigger it. But anyone who walked away or switched to their phone will hit it.

**What happens when idle is detected:**

| Elapsed Idle Time | Action |
|-------------------|--------|
| 0–180s | Normal — work ticks earned as usual |
| 180s+ | **Earning paused.** Work ticks stop accumulating. Pill shows subtle "paused" indicator (e.g., timer text dims or shows a small pause icon). No sound, no popup. |
| 300s (5 min) | **Gentle nudge in pill**: "Still there?" with a subtle pulse. Single click/keypress anywhere dismisses and resumes earning. |
| 600s+ (10 min) | **Block timer pauses entirely.** The countdown stops — idle time shouldn't count toward block duration either. Pill shows "Timer paused" state. Resumes on any input. |

**On activity resume:**
- Earning resumes instantly on first mouse movement or keystroke
- No penalty for the idle period — it simply wasn't counted
- Brief "Welcome back" message (reuses existing recovery takeover pattern, 2s)
- Block timer resumes if it was paused

**Integration points in existing code:**
- `FocusMonitor.evaluateApp()` — check `systemIdleTime() > 180` before calling `recordWorkTick()`. If idle, skip the tick.
- `FocusMonitor.pollActiveTab()` — same check. If idle, skip the relevance evaluation entirely (saves AI calls too).
- `DeepWorkTimerController` — show paused state in pill UI when idle detected.
- `EarnedBrowseManager` — no changes needed. It already just receives ticks from FocusMonitor. Fewer ticks = less earning.

##### Media Playback Exception (IOPMAssertion)

`HIDIdleTime` is purely physical input — it has no idea whether you're watching the screen. A user watching a 20-minute relevant lecture in fullscreen would hit the idle threshold at 3 minutes even though they're legitimately working. To handle this, check for active power management assertions via `IOPMCopyAssertionsByProcess()`.

When any app plays video (browsers, VLC, Zoom, etc.), it creates an `IOPMAssertion` (typically `PreventUserIdleDisplaySleep`) to keep the screen on. We can detect this and use it as a "media is playing" signal.

**The logic (checked in order):**

1. Is `HIDIdleTime` > 180s? If no → earn normally, done.
2. If yes → is any process holding a `PreventUserIdleDisplaySleep` assertion?
3. If yes → is the foreground content **relevant** (already scored by FocusMonitor)? If so → skip idle check, earn normally. Media is playing and the content is on-task.
4. If the foreground content is **irrelevant** → idle detection is moot anyway, because distraction enforcement is already active (nudges, redirects, etc.). No earning regardless.
5. If no media assertion is active → genuinely idle → pause earning per the escalation table above.

**Why this isn't gameable:** The media exception only fires when FocusMonitor has *already* confirmed the foreground content is relevant. You can't exploit it by playing Netflix — the relevance scorer (or distracting sites list) catches that before the idle check is ever reached. The only theoretical gaming vector is playing a relevant-looking video on loop while away, which is contrived enough not to worry about.

**Coverage:** This handles lectures, tutorials, video calls, recorded meetings, screen recordings, presentations — any legitimate passive-viewing work. It uses the same IOKit framework as the idle time check, so no new dependencies.

```swift
func isMediaPlaying() -> Bool {
    var assertions: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
          let dict = assertions?.takeRetainedValue() as? [String: [[String: Any]]] else {
        return false
    }
    return dict.values.joined().contains { entry in
        (entry["AssertionTrueType"] as? String) == "PreventUserIdleDisplaySleep"
    }
}
```

##### Edge Cases

- **External keyboard/mouse:** IOKit `HIDIdleTime` captures all HID devices, so Bluetooth peripherals are included.
- **Sleep/wake:** `SleepWakeMonitor` already handles this — idle time resets on wake.
- **Screen lock:** System idle time continues accumulating while locked, which is correct — you're not working if your screen is locked.
- **Presentation mode / screen sharing:** Covered by the media playback exception — video conferencing apps hold display assertions. If presenting from another machine with a relevant app frontmost, the assertion check handles it.

##### What This Does NOT Do

- **No webcam monitoring.** No eye tracking, face detection, or camera access. Ever.
- **No keystroke logging.** We check *whether* input happened, not *what* was typed.
- **No screenshot analysis.** We don't capture or analyze screen content beyond what FocusMonitor already does (reading the frontmost app name and browser tab title).
- **No punitive response.** Idle time is simply not counted. There's no "you were idle" report, no shame metric, no penalty to earned minutes already banked.

---

### P1 — Next Quarter (Core Experience)

#### Coaching Language Overhaul
**Psychological basis:** SDT autonomy support, reactance theory

Reframe enforcement language throughout the app from punitive to supportive:

| Current | Proposed |
|---------|----------|
| "Intervention exercise" | "Reset moment" or "Refocus break" |
| "Blocking overlay" | "Pause screen" |
| "Irrelevant" (AI verdict) | "Off-path" |
| Timer dot: red | Timer dot: amber (red = danger; amber = attention needed) |
| Silent enforcement | Coaching messages at each stage |

Add warm, autonomy-respecting messages to enforcement moments:
- Nudge: "You set out to work on [block title]. Still on track?"
- Grayscale onset: "It looks like you've wandered. Your block has [X minutes] left."
- Redirect: "Bringing you back. You chose deep work for this block."
- Pause screen: "Take a breath. Ready to return to [block title]?"

The key phrase is **"You chose this"** — reframes enforcement as honoring the user's commitment.

#### Positive Reinforcement for Returns
**Psychological basis:** Positive reinforcement > punishment (behavioral psychology)

Currently, returning from distraction just removes the punishment (grayscale snaps back, dot turns indigo). This is a missed opportunity. Add:
- Subtle positive glow or pulse on the timer pill when returning to focus
- A "+1 refocus" counter visible somewhere (celebrates the act of self-correction)
- Brief warm message: "Welcome back. You've got this."

The current enforcement ratio is ~6 punishment mechanisms to ~4 positive reinforcement mechanisms. This should shift toward at least 1:1.

#### Reframe "Earned Browse" as "Recharge Time"
**Psychological basis:** Positive psychology framing, SDT autonomy

The current "earned browse" framing positions social media as a guilty pleasure that must be rationed. Reframe:
- "Earned browse" -> "Recharge time" or "Recharge budget"
- "Cost multiplier" -> "Energy awareness" ("your budget stretches further when you stay on task")
- "Pool exhausted" -> "Budget check" ("Want to plan more focus time to refill?")
- Show what users accomplished alongside what they spent: "Today: 4.5h on [work], 45m recharging. Focus score: 78%"

#### Coaching Mode Toggle
**Psychological basis:** SDT autonomy over enforcement style

Let users choose their enforcement personality:
- **Coach mode** (default): Warm language, reflection prompts, longer grace periods, self-awareness focus
- **Strict mode**: Current enforcement pipeline for users who want hard boundaries
- **Zen mode**: Self-monitoring only — no enforcement, just awareness and metrics

Giving users autonomy over *how they are supported* is the most SDT-aligned design possible.

#### Chronological Timeline Bar
**Status:** Fully designed
**Spec:** [TIMELINE_BAR_PLAN.md](./TIMELINE_BAR_PLAN.md)

Add chronological timeline view to the block assessment popover. Shows when the user switched between apps, how long each stretch lasted. Two-view swipeable popover (timeline + existing list view).

Requires adding `hostname` field to JSONL logging in FocusMonitor.swift.

#### Today Page Redesign
**Status:** Partially implemented (earned browse widget done, goals moved)

Remaining work:
- Goals + Earned Browse side by side at top of Today page
- Remove "This Week" chart (or move to separate analytics page)
- Compress Focus Score to single-line bar
- Auto-scroll calendar to current time on load
- Smarter block creation (templates, quick-add)

---

### P2 — Medium Term (Depth & Engagement)

#### Scaffolding-to-Autonomy Pipeline
**Psychological basis:** SDT internalization continuum

The long-term goal is users who don't need enforcement. Build a gradual path:

- **Weeks 1-2 (Full support):** Current enforcement level. Building the habit of planning and working in blocks.
- **Weeks 3-4 (Awareness mode):** Offer to reduce enforcement. "You've been using Intentional for 2 weeks. Your average focus score is [X%]. Want to try Awareness Mode? Gentle reminders but no redirects or overlays."
- **Month 2+ (Self-directed mode):** "You've maintained [X%] focus in Awareness Mode. Try Self-Directed Mode — just planning, tracking, and reflection."
- **Regression support:** If focus scores drop, surface the data. Don't auto-escalate. "Your focus score dropped from 82% to 61%. Would you like to adjust your approach?" Let the user decide.

#### Simplify the Planning Process
**Status:** Design needed

Current issue: Creating 10+ blocks per day is tedious. Ideas:
- **Templates**: Save common day layouts ("Standard workday", "Meeting-heavy day")
- **Quick-add**: Tap to add a 2-hour block at the next available slot
- **Smart defaults**: Suggest blocks based on last week's patterns
- **Opt-in at block start**: Instead of rigid pre-planning, allow flexible block creation throughout the day (ties into block start ritual)

#### Daily Reflection Prompt (End of Day)
**Psychological basis:** Self-monitoring reactivity, self-compassion

Brief end-of-day reflection when the last block ends:
1. "Today's focus score: [X%]. How do you feel about today?" (non-judgmental)
2. "Your most focused block was [title] ([score]%). What made it work?"
3. "Tomorrow, what's one thing you want to do differently?"

30 seconds. Builds the user's own evaluative framework rather than accepting the app's scoring as authority.

#### Refocus Break Redesign (formerly "Intervention Exercises")
**Psychological basis:** SDT autonomy within constraints

Instead of a mandatory timed exercise, offer a *choice* of refocus activities:
- Breathing exercise (guided, 60s)
- Re-read your block goals and if-then plan
- Quick body scan
- Reflection prompt: "What pulled you away? What do you actually need right now?"
- "I'm ready to return" (shortest path back)

Giving choice within the constraint satisfies autonomy even inside the enforcement boundary. Escalation still applies (60s -> 90s -> 120s for repeat offenses), but the user chooses *how* to spend that time.

#### Pattern Intelligence
**Status:** Idea phase

Analyze historical focus data to surface patterns:
- "You tend to get distracted around 2:30 PM — consider scheduling free time then"
- "Your best focus blocks are in the morning before 11 AM"
- "Reddit is your #1 distraction, accounting for 40% of off-task time"
- "You focus better on days when you set 3+ goals"

Non-judgmental, data-driven insights that help users design better schedules.

---

### P3 — Future (Ambitious Features)

#### Gamification Layer
**Status:** Extensively brainstormed
**Spec:** [GAMIFICATION_BRAINSTORM.md](./GAMIFICATION_BRAINSTORM.md)

30 gamification ideas documented, from subtle (damage vignette, focus score ticker) to ambitious (skill trees, focus pets, loot boxes). Implementation priority from the spec:

| Priority | Features |
|----------|---------|
| P0 | Damage vignette (#1), Focus score ticker (#3), Poison grayscale (#14) |
| P1 | Combo multiplier (#4), XP/Leveling (#5), Health bar (#6), HUD (#2) |
| P2 | Streaks (#12), Achievements (#8), Kill feed (#10), Screen shake (#22) |
| P3 | Boss battles (#7), Daily quests (#11), Power-ups (#13), Battle report (#20) |
| P4 | Aura (#9), Sound design (#16), Mini-map (#23), Ghost rival (#17) |
| P5 | Skill tree (#21), Focus pet (#25), Loot boxes (#18), Dynamic wallpaper (#29) |

**Important caveat from psychology research:** Gamification works best when it supports *competence needs* (mastery, progress) rather than creating artificial reward loops. Variable ratio reinforcement (the mechanism behind slot machines) can make the *app* more engaging/addictive rather than helping users develop independent focus skills. Gamification should enhance self-awareness, not replace self-regulation.

#### Goal-Block Connection
**Status:** Idea phase

Make goals more than text — connect them to specific blocks:
- Assign goals to blocks ("Build auth module" maps to the 9-11:30 AM Deep Work block)
- Track goal completion across blocks
- Show goal progress in block assessment popovers
- End-of-day summary shows goals completed/incomplete with time invested

#### Social/Community Features
**Status:** Idea phase

- Accountability partner leaderboard (weekly focus comparison)
- Anonymous aggregate comparisons ("Global average focus score: 72%")
- Focus groups (teams working on similar goals)
- Share daily battle reports

#### Multi-Day Analytics
**Status:** Idea phase

- Weekly/monthly focus trends
- Heatmap of focus quality by time of day
- Distraction pattern analysis over time
- "Focus fitness" score (rolling 7-day average)

---

## Psychological Framework Summary

Based on research synthesis across Self-Determination Theory, reactance theory, implementation intentions, self-monitoring reactivity, and positive reinforcement psychology:

### What Intentional Does Well
- **Pre-commitment architecture**: Daily planning + block structure is a well-designed Ulysses contract
- **Competence feedback**: Focus scores, per-block stats, earned pool visibility satisfy competence needs
- **Graduated response**: Escalation from nudges to overlays gives multiple self-correction chances
- **Deep work detection**: Recognizing and rewarding sustained focus aligns with flow research
- **Accountability partner**: Satisfies relatedness needs with social commitment dimension

### Key Psychological Risks
- **Punishment-to-reinforcement ratio is inverted**: Moment-to-moment experience during work blocks is dominated by failure responses, not success responses
- **Reactance escalation**: Each enforcement step increases autonomy threat, potentially making distractions *more* attractive (forbidden fruit effect)
- **Surveillance framing**: AI scoring + 10-second polling creates a panopticon dynamic
- **No recovery narrative**: Bad focus blocks have no reflection/learning mechanism
- **"Earned browse" implies distrust**: Framing social media as rationed implies the user can't be trusted with freedom

### The Paradigm Shift
From: "Prevent bad behavior through escalating consequences"
To: "Support the user's own intention through awareness, rituals, and positive reinforcement"

The enforcement pipeline is effective as scaffolding for new users, but the product should help users *graduate* from needing it. Block start/end rituals, coaching language, and the scaffolding-to-autonomy pipeline are the path from cop to coach.

---

## References

### Existing Feature Specs
- [BLOCK_TYPE_ENFORCEMENT_SETTINGS.md](./BLOCK_TYPE_ENFORCEMENT_SETTINGS.md) — Per-block enforcement toggles
- [TIMELINE_BAR_PLAN.md](./TIMELINE_BAR_PLAN.md) — Chronological timeline view for assessment popover
- [GAMIFICATION_BRAINSTORM.md](./GAMIFICATION_BRAINSTORM.md) — 30 gamification ideas with implementation details
- [UNIFIED_BUDGET_DESIGN.md](./UNIFIED_BUDGET_DESIGN.md) — Earned browse / unified budget system design
- [EARN_YOUR_BROWSE_IMPLEMENTATION.md](./EARN_YOUR_BROWSE_IMPLEMENTATION.md) — Earned browse implementation details
- [CALENDAR_BLOCK_RULES.md](./CALENDAR_BLOCK_RULES.md) — Block manipulation rules
- [FOCUS_MONITOR_LOGGING.md](./FOCUS_MONITOR_LOGGING.md) — Always-allowed app logging

### Psychology Research
- Gollwitzer & Sheeran (2006). Implementation intentions and goal achievement: Meta-analysis (d=0.65). [Link](https://www.researchgate.net/publication/37367696)
- Gollwitzer et al. (2024). Meta-analysis of 642 implementation intention tests (d=0.27-0.66). [Link](https://www.researchgate.net/publication/378870694)
- Roffarello & De Russis (2022). Digital self-control tools: Systematic review and meta-analysis. ACM TOCHI. [Link](https://dl.acm.org/doi/full/10.1145/3571810)
- Ryan & Deci (2000). Self-Determination Theory and intrinsic motivation. [Link](https://selfdeterminationtheory.org/SDT/documents/2000_RyanDeci_SDT.pdf)
- Oxford Academic (2024). Designing for sustained motivation: SDT in behaviour change technologies. [Link](https://academic.oup.com/iwc/advance-article/doi/10.1093/iwc/iwae040/7760010)
- Frontiers in Psychology (2021). Autonomy and reactance in everyday AI interactions. [Link](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2021.713074/full)
- Hobson et al. Psychology of rituals: Anxiety reduction and performance. UC Berkeley. [Link](https://faculty.haas.berkeley.edu/jschroeder/Publications/Hobson%20et%20al%20Psychology%20of%20Rituals.pdf)
- PMC (2024). Gamification of behavior change: Mathematical principles. [Link](https://pmc.ncbi.nlm.nih.gov/articles/PMC10998180/)
- Self-Compassion.org. Self-compassion and burnout research. [Link](https://self-compassion.org/blog/self-compassion-and-burnout/)
- Claessens et al. (2007). Planning granularity meta-analysis: medium granularity (1-2h blocks) outperforms high or low granularity.
- Kahneman & Tversky. Planning fallacy: systematic underestimation of task duration amplified across full-day plans.
- Dai et al. "Fresh Start Effect": motivation spikes at temporal landmarks (Mondays, month starts, post-break).
- Cialdini. Commitment/Consistency: micro-yeses ("yes ladder") increase compliance with larger asks.

---

## Research: Motivating People to Plan Their Day

### Why People Resist Planning (Key Findings)

**BJ Fogg's B=MAP**: Planning fails when motivation is low (mornings, after energy dips), ability is low (blank calendar = decision paralysis), or prompts are poorly timed. When motivation is unreliable, shrink the behavior instead.

**SDT**: Mandatory planning screens trigger reactance (autonomy threat). Failed past plans trigger inadequacy (competence threat). Solo planning lacks relatedness.

**Nir Eyal**: People avoid planning because it surfaces uncomfortable emotions — anxiety about the day, fear of commitment, overwhelm. The emotional cost of planning feels higher than not planning, especially in the moment.

### What Works (Evidence-Based Techniques)

| Technique | Source | Application |
|-----------|--------|-------------|
| **Shrink the behavior** | Fogg's Tiny Habits | Ask for ONE focus item, not a full day plan. Under 2 minutes. |
| **Pre-fill, don't blank-slate** | Successful app patterns | AI suggests blocks based on time/past patterns. User approves/tweaks. |
| **Celebrate immediately** | Fogg's "Shine" method | Satisfying animation/sound when block is created. Wires the habit. |
| **Yes Ladder** | Cialdini's Commitment/Consistency | "Working on something?" → "Set a timer?" → "Plan what's next?" Each micro-yes makes the next easier. |
| **Variable prompts** | Variable ratio reinforcement | Rotate question framing. Skip some days. Never same prompt twice. |
| **Temporal scaffolding** | Educational psychology | Build the day one block at a time (morning prompt → mid-morning → afternoon), not a single planning session. |
| **Fresh start effect** | Dai et al. | Leverage Mondays, post-break, streak recovery for stronger prompts. |
| **Identity framing** | Eyal's precommitment | "You've planned 4 of the last 5 days" reinforces "I'm someone who plans." |
| **Match energy to ask** | Fogg + app research | Low engagement = tiny ask ("one focus?"). High engagement = bigger ask ("plan your afternoon?"). |
| **Fail gracefully** | All sources | If plan breaks, help revise — don't show failure. No punishment for skipping. |

### Micro-Planning > Full-Day Planning

Research overwhelmingly favors micro-planning (1-3 items, next 1-2 hours) over full-day planning:
- **Planning fallacy** amplifies across 8+ blocks — plan is unrealistic by noon, triggering abandonment
- **Medium granularity** (1-2h blocks) outperforms both fine (15-min) and coarse (to-do list) planning
- **Cal Newport's approach**: Plan morning, revise at lunch, plan afternoon — living document, not commitment
- **Core insight**: AI coach's job is getting users to plan their NEXT block. The full day emerges from repeated micro-planning moments.

### AI Coach Anti-Patterns (What Annoys Users)

- Repetitive prompts (habituation kills effectiveness after 3-5 exposures)
- Guilt-tripping ("You haven't planned today!")
- False urgency ("Plan now or lose productivity!")
- Ignoring context (prompting while user is clearly in deep focus)
- Interrupting flow (any prompt that breaks focus is counterproductive)

# Intentional + Puck: System Design Brief

> **Purpose:** I have a powerful set of tools for focus/accountability enforcement across macOS and iOS. The problem is they've been built incrementally and the interactions between them are undefined. I need help designing one coherent system where every mechanism has a clear role, they compose predictably, and the user mental model is simple.

---

## The Core Problem

I watch YouTube all the time. Some of it is genuinely useful for my work (tutorials, design references, coding walkthroughs). Some of it is pure entertainment rabbit holes. I need a system that can tell the difference in real-time and enforce accordingly — but I also need escape valves that have real friction, not just a "skip" button.

More broadly: I have 6+ enforcement mechanisms that overlap in confusing ways. When I'm in a Focus session watching YouTube, is it blocked by my profile? Scored by the AI? Consuming earned browse time? All three? I don't know, and that means the system feels arbitrary instead of fair.

---

## What I Have (Capabilities)

### Physical Hardware: Puck (NFC chip)

- A physical NFC tag I place somewhere in my apartment (e.g., on my desk, by the door)
- Tapping it with my iPhone triggers a focus session start/stop
- The physical walk creates real friction — I can't just click a button to disable blocking
- Multiple pucks possible (e.g., "work puck" on desk, "evening puck" in bedroom)
- Each puck maps to a "focus mode" with its own set of blocked apps

### iPhone App (Puck iOS)

- **App blocking via FamilyControls**: System-level hard blocks. When an app is blocked, iOS shows a custom shield screen — the app literally cannot open. This is the strongest enforcement available on any platform.
- **Per-mode app selection**: Each focus mode has its own list of blocked apps/categories (e.g., "Deep Work" blocks social + gaming + news; "Evening" blocks everything except messages/phone)
- **Block behavior options**: "Block these apps" OR "Allow ONLY these apps" (whitelist mode)
- **Emergency unbrick**: 5 per week, resets Sunday. 3-second countdown before it works. Can be disabled entirely via "Strict Mode"
- **NFC-required alarms**: Morning alarm that rings continuously (50 chained alarms at 30s intervals) until you physically tap the NFC puck. Forces you to get out of bed and walk to the puck.
- **Evening/bedtime mode**: Dims screen brightness, applies in-app grayscale, optionally blocks addictive apps. Different puck required to end it (can't just re-tap the same one).
- **Focus sessions tracked**: Every session records start/end time, which mode, how it ended (timer/NFC/emergency unbrick)
- **Habit tracking**: Pucks can have frequency goals (e.g., "use work puck 5x this week")

### macOS App (Intentional)

#### Blocking

- **Blocking profiles**: Named lists of websites + desktop apps to block. Two modes:
  - **Always-active**: Blocked 24/7 regardless of whether a focus session is running (e.g., social media profile with Twitter, Instagram, TikTok)
  - **Focus-only**: Only blocked during active focus sessions (e.g., gaming profile with Steam, Discord)
- **Website blocking mechanism**: Browser extension intercepts navigation. Fallback: AppleScript reads active tab URL every 10s and redirects blocked sites to about:blank
- **App blocking mechanism**: No hard block (macOS doesn't have FamilyControls). Instead triggers enforcement escalation when user switches to a blocked/irrelevant app

#### AI Relevance Scoring

- **On-device LLM** (Qwen3 4B, runs on Apple Silicon GPU — no cloud, no latency)
- **What it sees**: Active browser tab title + full URL, OR desktop app name + metadata
- **What it does**: Given the user's stated intention (e.g., "Working on dashboard redesign"), scores whether the current activity is relevant
- **YouTube-specific**: Scores the actual VIDEO TITLE, not just "youtube.com". So "CSS Grid Tutorial" = relevant to "Working on dashboard", but "Mr Beast Squid Game" = not relevant
- **Result**: relevant/not-relevant + confidence score + one-line reason
- **Cached**: Same title+intention pair isn't re-scored

#### Enforcement Escalation (when AI says "not relevant" or user is on blocked site)

Two enforcement levels that apply depending on the block type:

**Deep Work (strictest):**
- 10 seconds of distraction → nudge notification overlay
- 20 seconds → auto-redirect tab back to last relevant page + screen goes grayscale
- 20+ seconds on a previously-redirected site → instant redirect
- 5 minutes cumulative → intervention overlay (60-second mandatory lockout with focus exercise)

**Focus Hours (gentler):**
- 10s → nudge (auto-dismisses after 8s)
- 30s → grayscale fades in over 30 seconds
- Every 60s after → nudge repeats
- 4 minutes → warning ("intervention in 60s")
- 5 minutes → intervention overlay (60s, duration escalates with repeated violations, capped at 120s)

#### Earned Browse

- During Focus Hours: every 5 minutes of on-task work earns 1 minute of social media time
- Sustained deep focus (>90% on-task) earns at 1.5x rate
- Social media costs 2x (1 minute of YouTube = 2 minutes deducted from pool)
- During Deep Work: NO earned browse — social media fully blocked
- During Free Time: no cost, browse freely
- Pool resets daily at midnight
- Visual: progress bar in dashboard shows available/used time

#### Focus Sessions

- Started manually from the app OR triggered by Puck NFC tap (via WebSocket relay)
- User selects: which blocking profiles to activate + free-text intention (for AI scoring) + optional AI scoring toggle
- Session persists to disk (survives app restart)
- When session ends: celebration card shows focus stats, time breakdown, earned browse

#### Focus Gate (Hourly Planning Overlay)

- Full-screen overlay that blocks the ENTIRE SCREEN until user declares what they're working on
- Triggers at configurable intervals (e.g., every hour, or at the start of each scheduled block)
- User must type an intention and select blocking profiles before the overlay dismisses
- Grace period: 1/3/5 minutes configurable
- Can be set to "Puck-only" mode (only triggers when Puck tap starts a session)

#### Schedule

- Pre-plan the day with time blocks: Deep Work, Focus Hours, Free Time
- Each block has an intention text and duration
- Schedule drives enforcement level (Deep Work blocks get strict enforcement, Focus Hours get gentle, Free Time gets none)

#### Bedtime Enforcement (Mac)

- Wind-down sequence: notification → red screen shift → grayscale → full lockout
- 15-minute progressive degradation before bedtime
- Full-screen lockout overlay at bedtime (non-dismissable)
- One snooze per night (configurable duration)
- Partner override code required to bypass
- Clock tampering detection (kernel monotonic timer vs wall clock — can't cheat by changing system time)
- Auto-sleep via pmset

#### Content Safety (NSFW Monitoring)

- Captures all screens every 2 seconds
- Runs on-device NSFW classifier (Apple SensitiveContentAnalysis + OpenNSFW model)
- Temporal voting: 3 of last 5 frames must trigger (filters false positives)
- Escalation: 1st detection = local warning, 2nd = threat of partner notification, 3rd+ = blurred screenshot emailed to accountability partner
- Permission revocation detection: if user disables screen recording, shows non-dismissable blocking overlay + alerts partner

#### Accountability Partner System

- Invite a partner via email (must confirm consent)
- Partner lock: all settings changes require a 6-digit code emailed to partner
- Partner receives: content safety alerts (blurred screenshots), tamper alerts (permissions revoked, clock tampered), extension disabled alerts
- Partner dashboard: real-time app health, heartbeat timeline, content safety log, tamper events
- Extra time requests: user asks partner for more browse time, partner gets emailed a code
- AI override requests: user asks partner to approve viewing specific content during Deep Work

#### Anti-Tampering

- Root daemon (syspolicyd_helper) auto-relaunches app if killed during strict mode
- LaunchAgent with KeepAlive ensures app starts on login and restarts on crash
- Cmd+Q blocked when strict mode enabled (unless daemon will relaunch)
- Clock tampering detection for bedtime bypass attempts
- Permission revocation detection for content safety bypass attempts
- Heartbeat monitoring: backend checks every 30 min that extension is running, alerts partner if silent >1 hour

### Cross-Device (Puck iPhone → Mac)

- NFC tap on iPhone → POST /focus/toggle → WebSocket broadcast → Mac receives focus start/stop signal
- Mac shows Focus Start overlay with profile selection + intention input
- Infrastructure built, not yet fully wired (Puck iOS NFC handler doesn't call the API yet)

---

## What I Need You To Design

### 1. A Clear Hierarchy

When I'm watching a YouTube video during Focus Hours with AI scoring enabled, an always-active Social Media blocking profile, and earned browse time available — what happens? Which system takes precedence? Design a clear priority order.

### 2. A Simple User Mental Model

The user (me) should be able to explain the system in 2-3 sentences. Something like: "Puck blocks my phone apps. On my Mac, always-on profiles block the worst stuff 24/7. During focus sessions, AI scores everything else and I earn browse time for staying on task." But make it actually correct and complete.

### 3. How YouTube Specifically Should Work

This is the hardest case because YouTube is both productive and destructive:
- Tutorial videos relevant to my work = should be allowed during focus
- Entertainment videos = should cost earned browse time during Focus Hours, fully blocked during Deep Work
- Always-active blocking profile has youtube.com = currently blocks ALL YouTube

How should these interact? Should YouTube be on an always-active profile or not? Should AI scoring override profile blocking? Should earned browse override AI scoring?

### 4. When Each Mechanism Activates

For each mechanism, specify exactly when it's on and when it's off:
- Always-active profiles: when?
- Focus-only profiles: when?
- AI scoring: when?
- Earned browse: when?
- Enforcement escalation: when?
- Focus Gate: when?
- Puck physical barrier: when?

### 5. The Earned Browse Economy

Current system: work earns minutes, social media costs minutes. But:
- Should AI-approved YouTube (relevant tutorials) cost earned browse time?
- Should earned browse override always-active profiles?
- What happens when the pool hits zero during a video?
- Is the 5:1 earn rate right? The 2x spend rate?

### 6. Puck's Role

Right now Puck starts/stops focus sessions. But should it do more?
- Should always-active profiles be configurable only via Puck tap? (physical barrier to change settings)
- Should bedtime only be overridable by walking to the Puck?
- Should the Puck be required to START any focus session, or should the Mac app allow starting without it?

### 7. Free Time vs No Session

What's the difference between "Free Time" (an explicit session type) and just... not having a focus session running? Should there always be a session running? Should the system care about unplanned time?

---

## Constraints

- The system should be **strict enough to actually work** for someone with ADHD who will find every loophole
- But **fair enough that it doesn't feel punishing** — if I'm watching a relevant tutorial, I shouldn't be fighting the system
- The AI scoring is good but not perfect — there need to be escape valves (earned browse, partner override) for when it's wrong
- Physical friction (Puck) is the most effective enforcement — digital-only barriers are too easy to bypass
- The partner system exists for true accountability (NSFW, tampering) — it shouldn't be needed for routine focus management
- Everything must be explainable to a new user in under 60 seconds

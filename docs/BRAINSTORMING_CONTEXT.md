# Intentional / Puck — Product Design Doc (living)

> **Purpose:** the living design source-of-truth for Intentional + Puck. Self-contained — feedable to any fresh AI agent without extra context.
> **Convention:** newest design decisions land at the top under "Living insights & decisions." Everything below that section is the originating product context (May 13, 2026).

---

## Living insights & decisions

*Newest at the top. Each entry is a load-bearing decision or reframing that should override any conflicting older content in this doc.*

### 2026-05-13 (evening) — Today gets the schedule calendar back

**Correction to the earlier unified design:** The earlier draft moved the schedule calendar entirely off Today and onto Plan. User pushed back — they want to maintain the today schedule visible on Today. **Final layout:**

```
Today
├─ Now card                    (Opal-style — active session loud, or "Nothing running")
├─ Quick actions row           (Start now / Break / Add / Open Plan)
├─ Schedule calendar           (8am–8pm vertical, today's sessions as colored blocks)
│   └─ + Focus / + Free Time   (inline-add buttons preserved)
└─ Status footer               (Partner / Content / Puck — always pinned)
```

The schedule calendar is the visual representation of today's missions. Same data as "Today's missions list" was in the earlier draft — just visualized as a vertical timeline instead of a flat list. Plan tab keeps the higher-level Goals → Missions → Sessions hierarchy and the "Help me plan" ritual. Both tabs render the same daily timeline; Today emphasizes time-of-day, Plan emphasizes mission-ladder-up.

**Updated:** `docs/unified-design-2026-05-13/today.html` rewritten with 15 states all showing the calendar. `architecture.md` updated to reflect calendar staying on Today. `README.md` updated.

---

### 2026-05-13 — Unified Design v1 — every feature placed, complete spec ready for engineering

**TL;DR:** Full unified design now exists at `docs/unified-design-2026-05-13/`. 7 files. 200+ features inventoried and placed in exactly one surface. 130+ states sketched across 6 HTML files. 30 open questions answered (7 still need a verbal yes). Architecture is locked; engineering can start.

**Architecture in 4 bullets:**

1. **Sidebar: 3 tabs.** Today / Plan / Settings. Replaces slice-10's 5-tab layout. Focus Modes folds into Plan as Missions. Sensitive Content + Accountability fold into Settings → Defenses as rows with state pills.
2. **Today: "Now + Next + Plan + Status."** Opal-shaped. The active session is the page's headline. Defenses (Partner / Content / Puck / Strict) are always-on status pills at the bottom. Today morphs across 15 documented states (idle, in-session Standard/Strict, drift L1/L2, wake-up, bedtime wind-down/locked, day complete, etc.).
3. **Plan: Goals → Missions → Sessions.** 3/3/3 hard caps. Three-tier hierarchy. "Help me plan" 4-step AI ritual for empty states. Weekly review auto-fires Monday (3-button segmented: Done/Slipped/Dropped + pattern insight). Monthly review extends weekly with Complete/Continue/Drop/Replace on the last Monday of the month.
4. **Settings: Defenses + AI & Coaching + App + Account.** Each defense row has a state pill (ON / CAITY / ACTIVE / NOT PAIRED). Audit your entire setup in 5 seconds.

**Read this folder in order:**
1. `unified-design-2026-05-13/README.md` — entry point
2. `architecture.md` — every feature → surface mapping
3. Open `today.html` in Chrome — see what users see
4. `open-questions.md` — the 7 things that still need your verbal confirmation

**The 7 still-open questions (need your yes/no):**
- Q11: Cat 4 anti-bypass — spec visible flow, defer phone-off mitigation until Perplexity research lands?
- Q13: Rename "Focus Modes" → "Missions" in UI? (sketches assume yes)
- Q20: Re-surface Earned Browse / Distraction Budget? (was previously "stripped for Puck model")
- Q21: Confirm "Focus Lock" as public name for the Today enforcement toggle?
- Q23: Schedule unification (Mac → backend format) — v1 or v1.1?
- Q25: Theme picker — keep all 4 themes or just Deep Lush + Iridescent?
- Q28: Stripe pricing tier breakdown

**This decision supersedes:**
- The earlier "v0 sketch" at `docs/unified-design-sketch-2026-05-13.html` (kept for history but no longer canonical)
- The Category 1–4 entries in the table below (all four are now placed in this unified design)

---

### 2026-05-13 — Unified design proposal: collapse sidebar 5 → 3, take Opal's shape

**TL;DR:** Our app today has five sidebar items, four competing sections on Today, and buries Sensitive Content + Accountability — our two real differentiators — on pages users never visit. Opal does it with two sidebar items and one "Now" card that screams the active session. Proposal: collapse our sidebar to **Today / Plan / Settings**, reshape Today as **"Now + Next + Plan + Status,"** and fold the defenses into Settings as a "Defenses" section with always-on status pills on Today.

**Sketch:** `docs/unified-design-sketch-2026-05-13.html` — open in Chrome. Three mockup states (Today in-session, Today between sessions, Settings) plus a teardown of what we're copying from each reference (Opal / Unbed / Covenant Eyes) and what specifically we're NOT copying.

**The four unifying moves:**
1. **Sidebar 5 → 3.** Focus Modes absorbs into Plan as missions; Sensitive Content + Accountability fold into Settings as rows.
2. **Today = Now + Next + Plan + Status.** One loud Now card (Opal-shape), one Up-Next row, quick-action buttons, today's missions list, persistent status footer.
3. **Status footer is the differentiator surface.** *Caity · partner active · Content protection · ON · Puck · paired* — visible on every Today view. The user is reminded what's running without navigating.
4. **Settings → Defenses + App.** "Defenses" groups Content Protection, Accountability, Strict Mode, Puck pairing as rows with state pills. App config is its own subsection below.

**What this sketch is and isn't:** it locks the architecture (3-tab sidebar, Now-shape, defenses folded). It does NOT lock typography, exact spacing, motion, or color. A real visual design pass follows.

**Next sketches in priority order:**
1. Plan page — re-sketch in this visual language so all three tabs feel like one product
2. Wake-up flow — alarm fires → tap Puck → enter planning ritual (after Cat 4 Perplexity research lands)
3. Drift redirect overlay — feel like a coach message, not an interrupt
4. End-of-session card — fits the new visual scale

---

### 2026-05-13 — Planning System designed & ready to build (Category 2)

**TL;DR:** No competitor in the planner space matched our ADHD-ritual spec. We designed our own three-tier planning system (monthly → weekly → daily sessions) and have a full visual prototype ready to hand to engineering.

**Canonical artifacts:**
- Spec: `docs/superpowers/specs/2026-05-13-planning-system-spec.md`
- Mockups: `docs/planning-system-design-2026-05-13/Planning Page.html` + `Plan States.html` (open in Chrome)
- Source: `design-canvas.jsx` + `plan-states.jsx` in the same folder

**The single sentence:** *Planning is a ritual, not a tool. The user never plans on a blank canvas. Every layer has structure, caps, and an AI-guided fallback for when they're stuck.*

**The three tiers, with hard caps:**
- Monthly goals — up to 3
- Weekly goals — up to 3 (each links to a monthly goal or is dashed/unlinked)
- Daily sessions — drag weekly goals onto a timeline, snaps to 15-min, NOW indicator

**Key product decisions baked in:**
- **Plan = decide. Today = do.** Two surfaces, one mental model. Schedule lives on Plan; execution lives on Today.
- **One color per monthly goal carries through every layer.** Translucent fill on monthly, left edge on weekly, fill+border on timeline blocks.
- **The weekly review is taps, not writing.** Done / Slipped / Dropped — three buttons per goal. No "what went wrong" text field. System already knows planned vs actual hours.
- **The monthly review extends the weekly review** with one extra row of buttons (Complete / Continue / Drop / Replace) on the last week of the month. Not a separate page.
- **"Help me plan" is the AI fallback** for every empty state. 3–4 step ritual, voice-first in feel, produces draft cards the user can edit before saving.
- **Caps are non-negotiable.** 3/3/3. The user's instinct to overplan is the failure mode we're designing against.
- **Failure is data, not shame.** *Slipped* is a first-class status. Pattern insights surface multi-week trends at review time, not as mid-week nags.

**How this feeds the rest of the product:**
- Focus Modes consume the active weekly goal as their **mission context** — this is how the AI relevance scorer finally gets a specific target to score against (see "missions, not channels" decision below).
- Accountability features (partner, coach) can later read planning data — slipped streaks, pattern insights — to power external accountability.

**Open product questions still to resolve before build:**
1. Week start day (Monday default + settings preference?)
2. Goal carry-over behavior (auto-suggest vs await user decision in review?)
3. Cross-day scheduling (multi-day timeline on Plan, or always go to Today to navigate forward?)
4. Monthly goal mid-month edits (locked, or freely editable with cascade to weekly "For" references?)
5. Voice input — in scope for v1 or text-only with microphone icon for direction?

---

### 2026-05-13 — Four customer-job categories + lead reference per category

We're building one product that competes in four distinct categories. Each maps to a job the customer is hiring us for. For each, we either have a lead reference product we'll model from, or active competitor research in progress.

| # | Job (customer hires us to…) | Status | Lead reference / next step |
|---|---|---|---|
| 1 | Stop me from doing things I'll regret (blocker) | **Lead picked** | **Opal** — copy the session-start ritual, the willingness to feel premium, the refusal to be utilitarian. |
| 2 | Help me plan and execute deliberately (planner) | **Designed, ready to build** | No existing competitor matched the spec, so we designed our own. See `docs/superpowers/specs/2026-05-13-planning-system-spec.md` + mockups in `docs/planning-system-design-2026-05-13/`. |
| 3 | Stop me from looking at porn (sensitive content) | **Lead picked** | **Covenant Eyes** — copy the partner-notification pattern. Our mechanism: on-device screen detection (NSFW + Apple SCA) + System Extension + DNS + AppleScript + per-window capture → notifies accountability partner. |
| 4 | Get me out of bed without checking my phone (alarm) | **Lead picked** | **Unbed** — copy the NFC-tap-to-dismiss pattern. Mechanism: phone fires alarm → user taps phone on Puck (NFC tag, placed across room) to dismiss → routed into morning planning ritual. Open question: how to close the iOS phone-off bypass (AlarmKit may help). |

**For Category 2, the spec we're researching against:** an ADHD user who has lost trust in planning. He doesn't know what to plan or how. He's verbal/conversational, not a writer. He needs a ritual that *discovers* his goals through conversation, not a calendar he fills in. The schedule is the OUTPUT of planning, not the input. Closest inspirations to study (per Ali Abdaal-style productivity): quarterly goals → weekly missions → daily sessions, with AI-coach-style discovery and reflection.

**For Category 4:** Puck-as-alarm is the wedge moment. Alarm starts → can't be silenced from bed → tap Puck to dismiss → tap routes you straight into the morning planning ritual (Category 2). The first surface you touch is hardware, not glass.

**Why this framing matters:** these are four products' worth of differentiation in one. No competitor touches all four. Opal does category 1. Sunsama does part of category 2. Brainbuddy does category 3. Loftie/Alarmy does category 4. We're stitching them — and the AI relevance scorer (which knows what your mission is) is the thread that connects them.

---

### 2026-05-13 — Focus Modes are missions, not channels

**The shift:** Today a "Focus Mode" is a named blocklist + strictness preset ("Coding", "Deep Work"). That framing is wrong for our ICP. He doesn't fail because YouTube is accessible — he fails because he has no plan for the hour and no consequence for drifting. He's a goal-less rower.

**A Focus Mode should be a TASK, not a CHANNEL.**

- Not "Coding" → **"Finish the Stripe webhook integration"**
- Not "Writing" → **"Outline the cross-device positioning doc"**
- Not "Deep Work" → **"Write blog post #3 outline + 500 words"**

**The hierarchy this implies:**

```
GOAL (month-level)         e.g. "Write 4 blog posts in May"
  ↓
MISSION (day or week)      e.g. "Write blog post #3 by Wednesday"
  ↓
SESSION (1–2 hours)        e.g. "10am: outline blog #3"
  ↓
AI SCORING                 live judgment: "does this current activity
                            advance the session's stated mission?"
```

A Focus Mode in the product maps to a **Mission**. Sessions are scheduled chunks of mission work. Goals are the parent of multiple missions.

**Implications across the surface:**

1. **AI scoring sharpens.** Scorer needs the *mission* as its target, not just blocklist + intention title. iTerm = on-mission if today's mission is "ship the Mac app." iTerm = off-mission if today's mission is "write blog post." Same app, different verdicts.
2. **Strict mode meaning changes.** Today strict = "block more sites." With missions, strict = **"actively redirect me back to the mission when I drift."** Coaching, not gating. That's the behavior an ADHD user actually needs.
3. **Progress aggregates upward.** Today's focused minutes → weekly mission progress → monthly goal completion. The product gains a *story to tell at week's end*, not just a daily focus score.
4. **The "title + description + Focus Mode" form collapses.** The mission IS the title. The Focus Mode dropdown is really a strictness picker. "Focus" as a session title is as meaningless as a calendar event named "Event."
5. **Morning planning ritual gains a job.** Not just "pick today's blocks" — also "surface goals + pick which mission each block ladders up to."

**The planning loop this implies:**

- **Morning:** Review goals → pick today's missions (3–5 max, Sunsama-style) → time-block each into the calendar → confirm. Confirmation unlocks the rest of the device.
- **During day:** Sessions auto-start at scheduled time. AI scores live against the session's mission. Drift → nudge → overlay → block escalation. Strict mode = no early exit without partner approval.
- **Evening:** Review what was actually done per mission. Carry uncompleted work forward. Weekly review on Sunday.

**The positioning this implies — significantly more defensible than "Opal + Sunsama merged":**

> **Intentional is a goal-tracking system that defends the time you commit to your goals.**

Four layers, only the first two of which competitors touch:

- **Planning layer** (Sunsama territory): set goals, chunk into missions
- **Defense layer** (Opal/AppBlock territory): block + AI-redirect on drift
- **Friction layer** (unique to us): Puck hardware for moments when willpower fails
- **Coaching layer** (unique to us): AI that knows your mission and pulls you back to it

**Open question — load-bearing, still to decide:**

How are Goals expressed in the data model and UI?
- One-line intentions ("Get better at writing")?
- Structured outcomes with metrics ("Publish 4 blog posts in May", count + deadline)?
- Both, with progressive disclosure (start vague, refine)?

Don't spec the editor or data model until this is decided.

**Renaming question:**

Should "Focus Modes" be renamed to "Missions" in the UI? Argument for: clarity. Argument against: continuity for existing users. Decide in the brainstorming session.

---

## What is Intentional?

A focus-enforcement system that spans a macOS app, an iPhone app, a backend (FastAPI on Railway), a Chrome extension, and a piece of hardware called **Puck**. The point is to prevent the user — a self-aware, ambitious, ADHD-leaning young man — from sabotaging his own work day across every screen he owns.

The founder (Ameer) is both the builder and the prototype customer. He uses what he ships.

## Sibling repos

- `intentional-macos-app` — the Mac app (this repo)
- `intentional-backend` — FastAPI + Postgres/Supabase, deployed to Railway
- `puck-ios` — the iPhone app + Puck device pairing
- `puck-partner-dashboard` — accountability-partner web app
- `puck-site` — marketing site + Stripe checkout
- `intentional-extension` — Chrome extension (sensing layer)

## What exists today (the features)

| Capability | Status | Notes |
|---|---|---|
| **AI relevance scoring** | working | Qwen3-4B local model scores each app/tab against the user's stated intent. Off-task triggers nudges + overlays. |
| **Sensitive-content (porn) blocking** | working | On-device NSFW model + Apple SensitiveContentAnalysis fallback. Multi-layer: System Extension content filter + AppleScript blocking + DNS at OS level. Technically beats Covenant Eyes / Brainbuddy / Blocker X. |
| **Cross-device focus sync** | working | Mac + iPhone share active focus session via backend `/focus/active`. Stop on phone = stop on Mac, simultaneously. |
| **Bedtime lock-loop** | working | Triggers OS lock screen every 10s once bedtime hits. Partner-unlock with duration cap (15/30/60/120 min). T-30 / T-15 / T-5 / T-1 wind-down notifications. |
| **Strict mode** | working | Once on, requires partner unlock to disable. Login-item persistence + watchdog daemon at /Library/LaunchDaemons. Anti-tamper. |
| **Watchdog daemon** | working | Root-level daemon that respawns Intentional.app if killed. Installed via signed PKG; standard-user can't `launchctl bootout` it. |
| **Focus Modes (named intents)** | working | "Coding", "Deep Work" etc — each is a saved intent + per-mode override rules + strictness preset (Standard/Strict). |
| **Global Distractions list** | working | Apps/sites that block during ANY focus session (the 3-tier: Allowed / Distraction / Always-Blocked). |
| **Distraction Budget** | working | "X minutes of social media per day, earned via focused time." Cross-device. |
| **Schedule (Focus + Bedtime + Wake bands)** | working | Calendar of recurring time-blocked focus windows. Renders on both Mac + phone. |
| **Accountability partner** | working | Partner email captured at onboarding. Partner unlocks strict mode + bedtime. Sibling-row sync ensures partner data is account-scoped not device-scoped. |
| **Earned-browse system** | working | Earn distracting-content minutes by working focused. Per-block tracking. |
| **Stripe subscriptions** | partial | $X/mo + annual trial. Backend deployed; trial flow not yet dogfooded end-to-end. |
| **Puck (physical device)** | partial | Physical button-style device, paired with iPhone. Currently only handles "start/stop focus." |
| **Context-switching overlay** | working | Non-skippable countdown on app/tab switches during focus blocks. |

## The ICP — "The Striver With No Brakes"

18-26 male knowledge worker or student. Bright. ADHD, often undiagnosed. Daily timeline:

- Wakes up around 8-10am to his phone, scrolls Instagram for 20+ min before getting out of bed
- Three cups of coffee before noon
- Watches porn before lunch
- Means to work, opens laptop, gets distracted within 10 minutes
- Loses 90 minutes to YouTube / Reels / Reddit / Twitter he can't account for
- Multiple half-finished projects, multiple unread books, multiple gym memberships
- Bedtime is 2am because he can't put the phone down
- The gap between his stated potential and his actual execution is widening month over month

He has tried Cold Turkey, Opal, AppBlock, NoFap apps, Brain.fm, Notion, journaling. Each works for ~a week, then he routes around it. **The shame of failing the tools is now worse than the original problem.**

He doesn't need another tool. He needs a *system* that:

1. Removes the willpower decision from the moment
2. Makes the right choice the only available choice
3. Can't be bypassed at his weakest hours (3am Instagram, post-meeting porn, "just five more minutes")
4. Forces him to plan deliberately so he isn't navigating each day on impulse

## The 3 top struggles we're built to solve

Ranked by leverage (highest first):

1. **No plan = no defense.** Day starts reactive, ends with nothing done. No mechanism enforces yesterday-me's intentions on today-me.
2. **Cross-device leakage.** Phone blocker hits → he opens laptop. Laptop blocker hits → he opens phone. He's faster than his own blockers.
3. **Sensitive-content access is technically too easy.** DNS-only blockers leak. iOS Screen Time has known bypasses. He knows them.

Downstream pains (bedtime drift, wake-up failure, caffeine dependency, gym avoidance) all spring from these three.

## The two competitors to merge

### Opal
The beautiful, premium, focus-session-driven blocker for iPhone. People pay $60+/yr because **it feels nice to use**. Their session-start ritual is the gold standard. We want their *feel*, their willingness to charge, their refusal to be utilitarian.

### Sunsama
The intentional daily planner whose entire product premise is "you cannot start your day until you've planned it." Forces 5-10 minutes of morning planning before the rest of the app unlocks. We want their *insistence*, their planning ritual, their refusal to let the user start blind.

### Why these two
Opal is the best at **enforcement with feel**. Sunsama is the best at **forcing planning**. Neither alone solves our ICP — they each solve half. Merged into one product = the missing offering.

### What we're NOT merging
- **Brainbuddy / Covenant Eyes** — we technically beat them on the porn-blocker layer already. We just need to claim that lane in marketing.
- **AppBlock** — utilitarian, ugly, single-device. We are the premium cross-device successor.
- **Apple Screen Time** — easily bypassable. We close every gap they leave.
- **Notion / Reflect / Mem** — pure planning tools without enforcement. They don't help our ICP.

## One-line positioning candidate

> **The focus operating system you can't bypass. Plan your day, defend it across every screen, and let hardware lock you in when willpower runs out.**

Three nouns: *plan*, *defend*, *hardware*. Each maps to one top struggle.

## What's not yet built but envisioned

- **Puck as wake alarm.** Alarm sound comes from Puck, not phone → phone stays in bedtime mode until you physically tap Puck. Tap routes you into a 5-min morning planning loop. The first thing you touch each morning is the Puck, not your phone.
- **Morning planning ritual.** Sunsama-style forced planning, 5-10 min, gated by Puck tap. Until you've planned, nothing else unlocks.
- **Cross-device shared time budgets.** "30 min of YouTube total today" — across iPhone + Mac, not per-device.
- **Synchronized bedtime + wake.** Already partially exists — bedtime is shared. Wake-up isn't yet.
- **Planning intelligence.** Today's "Coach Context" is passive (assesses what you did). Active planning would propose what your day should look like, learn from history.

## The aesthetic direction

Stop thinking like a SaaS dashboard. Think like a physical product brand.

- **Not:** chirpy (AppBlock), wellness-y (Opal — purple gradients, cute illustrations), corporate (Notion).
- **Yes:** quietly tactile. Mechanical. Solid. Slightly cold. Confident, not friendly.
- **References:** Linear, Teenage Engineering, launch-era Apple Watch, Leica camera, Arc browser.

The product has a job. It does it without bullshit.

## Constraints + preferences

- The founder is one person + occasional contractor help. No design team yet.
- Engineering velocity is high (the existing feature list above was built in months).
- $0-$60K/yr revenue range — building toward a real business but not VC-pressured.
- The customer pays $60+/yr if the product actually sticks where competitors didn't.
- The ICP has tried other tools. They will be skeptical. The pitch has to acknowledge that and prove differentiation immediately.

## What the brainstorm session should produce

1. **A day-in-the-life storyboard** for the merged product, 6am–11pm in 30-min granularity. Where does the user touch which surface? What does Puck do? What does each screen say at each moment? This is the headline output.
2. **Feature categorization** — for every capability in the table above, mark it: *headline* (lead with this in marketing), *table-stakes* (necessary, invisible), or *cuttable* (deprecate or hide).
3. **Visual direction** — 3 specific reference products (with rationale) + one paragraph describing "the feel" in concrete sensory terms (typography, color, motion, sound).
4. **One feature spec'd end-to-end** — recommend the morning planning ritual. Every screen, every state, every error case.

## Pointers for the brainstorming agent

- The founder will paste screenshots of reference products (Opal, Sunsama, AppBlock, Linear, etc.) — use them as concrete anchors.
- Ask clarifying questions one at a time before producing the storyboard.
- The founder is non-technical-leaning in conversation but technical when needed. Plain language unless he asks for depth.
- Save the final output to `docs/superpowers/specs/YYYY-MM-DD-positioning-spec.md`.
- This document (`docs/BRAINSTORMING_CONTEXT.md`) is the source of truth for what exists today. Read it first.

---

*Last updated 2026-05-13.*

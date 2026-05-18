# Deep Work Protocol — Product Vision (May 2026)

**Status:** Draft. Captures the alignment from the 2026-05-18 design conversation. Open decisions are tagged `[OPEN]` and will be resolved in a follow-up brainstorming session.

**Audience:** Future Claude sessions, the user, future collaborators. Read this before touching enforcement logic, session lifecycle, or AI scoring.

---

## The problem we're solving

> The brain is sequential. The computer makes task-switching almost free. Friction is backwards.

Most "productivity apps" treat the symptom (distraction) without naming the mechanism. The mechanism is this:

1. You sit down at the laptop to do something.
2. While you're waiting for that thing (a build, a page load, a thought), you open another tab.
3. That tab leads to another. An hour later you have 30 tabs open and three or four half-finished tasks.
4. You feel busy. You got little done. Cognitive switching cost ate the day.

**This is not a moral failure.** This is what computers are *designed* to invite. The affordances of modern computing — Cmd+T, Cmd+Tab, infinite scrolling feeds, notifications — favor distraction. Sustained focus requires constant self-control, which depletes.

The literature converges on the same diagnosis:

- **Sophie Leroy, "Attention Residue" (2009)**: every task-switch leaves cognitive debris on the next task for 10–25 minutes. Multitasking is rapid switching, not parallel processing.
- **Cal Newport, *Deep Work***: concentration is a trainable skill that atrophies with constant switching. Time-block your day. Drain the shallow work.
- **Cal Newport, *Digital Minimalism***: design your tech to support intent, not engagement.
- **Nicholas Carr, *The Shallows***: the internet has rewired our brains for fragmented attention.
- **Nir Eyal, *Indistractable***: values-driven time-boxing; pre-commit to a single thing.

## The ICP

Per the working hypothesis in memory: **the ADHD impulse-scroller who can't pre-plan.**

- Needs an external executive function he can't override.
- Not another tool that requires self-discipline to operate.
- The product must do the resisting, not the user.

This rules out: "set a focused timer and try harder." This rules in: structural friction the user has consented to in advance.

## The product, in one line

**Deep Work as a Service.** The app enforces — via friction, by consent — the protocol the literature already recommends.

## The Five Stages of a Focus Session

Every session moves through five stages. Each stage is a checkpoint where the app does something concrete the user could not reliably do alone.

### 1. Enter — declare intent

Forced verbalization at session start. Voice preferred (1-min recording, two questions, transcribed locally via Apple Speech / Whisper-MLX):

1. *"What are you doing, and what does done look like?"*
2. *"What's allowed in this session — and what's not?"*

Output: ~100–300 words of dense, specific intent. This becomes the AI scoring context for the entire session AND the raw material for the session-end retrospective AND (potentially) the audio replayed at distraction moments.

Why this works: ADHD brains can talk. They can't pre-plan in writing. The act of saying intent out loud primes commitment; the transcript gives the AI enough to score against.

**Status:** Designed, not yet built. Replaces the current thin `intentText` field.

### 2. Prepare — close the noise

Before the session timer starts, the app surveys the current tab + app state and prompts:

> *"You have 14 tabs open and 6 apps running that aren't on your declared scope. Close them?"*

One-click sweep. Whatever is unrelated to the declared intent gets closed (browser tabs) or hidden / quit (apps). Tabs that match the declared research scope stay open.

Why this works: the multitasking trap starts with what's *already* open before you started. Closing the noise is a one-time cost; living with it is a continuous cost.

**Status:** New idea. Not built. This is the missing stage in the current app.

**[OPEN]:**
- Hard close vs soft hide?
- Allow user-tagged whitelist (apps that are always allowed: password manager, music, Slack DMs)?
- How does VLM/AI decide "this tab is research, that tab is noise"?

### 3. Engage — session runs

The pill shows the active intent. The schedule timer counts down. Two protective surfaces fire:

- **AI relevance scoring** — every 3–30 seconds (cadence under design), against the voice transcript. VLM reads the active window content (text + visuals). Verdict + confidence drive enforcement.
- **Block rules** — pre-declared site/app blocks fire regardless of AI verdict (Twitter, YouTube, etc.). Already shipping.

Visible signals when off-task: red tint of the screen, in-pill "not related" card with "Back to task" CTA, increasing grayscale on sustained drift.

**Status:** Partially built. AI scoring is text-only today (page titles + app names) — VLM upgrade in design. Red tint + nudges + grayscale all working.

### 4. Defend — three tiers of friction when you drift

When the user opens something the declared intent doesn't sanction, the app responds proportionally:

| Tier | Trigger | Response |
|---|---|---|
| **Tier 1: Notify** | New tab/app off-scope, single instance | Toast: *"You said you weren't going to do this. Back to X?"* (the user's own declared scope shown back). No friction beyond the toast. |
| **Tier 2: Soft close** | Continued drift after ~60s | Tab/app auto-closes in 5 seconds with a visible countdown. One-click override extends 5 minutes. |
| **Tier 3: Hard block** (Strict Mode) | Continued drift OR Strict Mode is on | Tab/app hard-closes, no override. Only partner-unlock code can override during the session. |

The tiers escalate within a single session. They don't carry across sessions.

Why this works: the friction is calibrated. The user is not punished for one slip; they are protected from compounding slips. Tier 3 only fires when the user has explicitly opted in (Strict Mode + partner consent).

**Status:** Tier 1 partially works (today's nudge toasts). Tier 2 is new. Tier 3 partially works (blocking overlay for hard-rule sites).

**[OPEN]:**
- How does the user override Tier 2? Click-to-dismiss? Type a reason? Drag a slider?
- What happens if the user closes the override prompt without acting (passive drift)?
- Does Tier 3 apply to native apps or only browser tabs?

### 5. Exit — review the tab graveyard

At session end, the app shows everything that was opened *during* the session: tabs, apps, files. Three actions per item:

- **Keep open** — survives into the next session / "free time."
- **Close all** — every tab/app in the session is dismissed.
- **Mark for tomorrow** — adds to a deferred-list the user reviews at the start of the next planning session.

This is *inbox zero for attention*. It closes the loop the multitasking trap opens.

**Status:** Not built. New idea.

**[OPEN]:**
- Should the review be optional (skippable) or mandatory?
- Does Strict Mode make it mandatory?
- How does the deferred list surface tomorrow — pre-populated in the planning prompt?

## How this changes the existing roadmap

The current app has features (blocking, scoring, scheduling, intentions) that are mostly correct but were built as a *bag* of features without a unifying narrative. This protocol gives them the narrative.

Re-framed:

- **Schedule + weekly goals + intentions** = the *Plan* layer, feeding the *Enter* stage with reusable context across sessions.
- **AI scoring + VLM** = the *Engage* layer, watching the screen during a session.
- **Block rules + Strict Mode + force-close** = the *Defend* layer.
- **Force-to-plan overlay** (the noPlan prompt that just got restored) = the *Enter* gate for the case where the user has skipped planning entirely.
- **End-of-block celebration** = the existing dock-the-pill flow; reshape into the *Exit* review.

Nothing has to be thrown away. Some things have to be **renamed** and **re-sequenced** so the user (and future Claude sessions) see the protocol, not the kitchen sink.

## Naming clarity (also from the conversation)

The current codebase overloads "block":

- **Focus Block** / **FocusBlock** = a calendar entry that creates a session
- **Block Rule** / **BlockingProfile** = an always-on or scheduled site/app block (independent of sessions)

Going forward in spec language:

| Old name | New name (in specs + UI copy) |
|---|---|
| FocusBlock / Calendar block | **Scheduled session** (UI) / **TimeBlock** (code) |
| BlockingProfile / Block Rule | **Standing rule** (UI) / **BlockRule** (code, already partially renamed) |
| Focus Mode controller state | **Session state** — `idle / focused / bedtime` |
| activeProjectSession / injectedFocusBlock / etc. | Single source: `SessionStore.currentSession` |

Code renames are part of the *Single Source of Truth for Session State* cleanup spec (separate, follows this one).

## What's NOT in this spec

To keep the scope tight:

- The phone/iOS side of the protocol (a future expansion).
- The detailed VLM architecture (covered in `2026-05-18-ai-scoring-vlm-design.md`, draft pending).
- The state-model cleanup (covered in `2026-05-18-session-state-cleanup.md`, draft pending).
- Marketing copy / website / pricing.

## Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-05-18 | Five-stage protocol locked in as the canonical frame | Aligns with literature, gives existing features a unifying narrative |
| 2026-05-18 | "Deep Work as a Service" as the one-liner | Distinguishes from generic "blocker" apps; sets the ICP expectation |
| 2026-05-18 | Tier-3 (hard close) gated behind Strict Mode | Consent-based friction; not paternalistic by default |
| 2026-05-18 | Force-to-plan overlay copy: *"You're not in a focus session. Pick something to work on so you don't end up with 30 tabs open and three half-finished tasks."* | Names the actual mechanism (multitasking trap) instead of the abstract concept ("plan your day") |
| 2026-05-18 | "Block" terminology split: TimeBlock (scheduled session) vs StandingRule (always-on rule) | Two distinct concepts; one word was breaking comprehension |

## Open questions to resolve in brainstorming session

These are NOT solved yet. They go into the brainstorming follow-up:

1. **Cadence of AI scoring during a session.** Every 3s, 10s, 30s? Trigger-driven (app switch + idle timer)?
2. **What "research scope" really means in practice.** How explicit must the user be? Does it learn over time?
3. **Defend tier interaction with non-browser apps.** "Soft-close Cursor" doesn't make sense. What's the native-app equivalent?
4. **Exit-review timing.** Right when the session ends, or only at end-of-day rollup?
5. **The phone story.** Out of scope here, but the protocol implies a parallel iOS flow.
6. **Partner accountability surfaces.** Should the partner see daily/weekly aggregates of "how well did they follow the protocol"?
7. **Onboarding.** The protocol assumes the user understands it. First-run flow must teach it.
8. **Backwards compat.** What happens to existing user data (schedules, intentions, block rules) in the renaming?

---

**Next step:** invoke `superpowers:brainstorming` against the open questions above. Outcome: a v2 of this spec with the OPEN tags resolved, ready to slice into implementation plans.

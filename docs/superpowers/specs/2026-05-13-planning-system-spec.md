# Planning System — Feature Spec

> **Status:** Designed, prototyped, ready for build
> **Date:** 2026-05-13
> **Scope:** Category 2 — the structured planning ritual ("Help me plan and execute deliberately")
> **Position in product:** Sits inside Intentional as the **Plan** tab, alongside Today, Focus Modes, Accountability, and Settings.
> **Lineage:** This is the first concrete feature that actualizes the "missions, not channels" reframing (see `docs/BRAINSTORMING_CONTEXT.md` — Living insights & decisions, 2026-05-13).

---

## Design assets (canonical)

Visual handoff and interactive prototype:

- `docs/planning-system-design-2026-05-13/Planning Page.html` — main Plan page mockup
- `docs/planning-system-design-2026-05-13/Plan States.html` — empty states, review states, edit modal states
- `docs/planning-system-design-2026-05-13/design-canvas.jsx` — full React design canvas (source of the Page mockup)
- `docs/planning-system-design-2026-05-13/plan-states.jsx` — React source for the states mockup

Open the two `.html` files in Chrome to see the design. When the design evolves, write a new dated folder; do not edit the originals.

---

## What it is

A three-tier planning system that walks an ADHD user from vague monthly intention down to concrete time blocks on today's calendar. **The user never plans on a blank canvas.** Every layer has structure, caps, and an AI-guided fallback ("Help me plan") for when they're stuck.

**Core idea:** planning is a **ritual**, not a tool. Users don't sit down to "use the planner." They sit down to do a defined ritual — review last week, set this week's intentions, drop sessions onto today. The product gives that ritual a shape.

---

## The three tiers, with strict caps

- **Monthly goals** — up to **3** per month
- **Weekly goals** — up to **3** per week (each can link to a monthly goal, or be standalone)
- **Daily sessions** — drag weekly goals onto a time canvas to schedule work

Caps are **non-negotiable**. They protect against the user's instinct to overplan, which is the failure mode we're explicitly designing against.

---

## The main Plan page

One page, top to bottom: **monthly → weekly → today**. Month at top as context. This week in the middle as the working layer. Today's timeline at the bottom as the bridge to execution.

### Monthly row
Three translucent cards in the goal's identity color (orange, green, purple). Title + outcome ("25 paid orders by May 31"). **No progress bars, no metrics, no buttons.** This is reference — you look up, see what you committed to, move on.

### Weekly row
Three cards. Each card has a **colored left edge** that matches its monthly goal's identity color, making the linkage instantly readable. Unlinked weekly goals are allowed and rendered with a **dashed border + neutral edge** — visually marked as "out on a limb" without shouting about it. Each card shows title, outcome, and status as a lowercase word: `planned`, `in progress`, `slipped`.

### Today strip
A horizontal timeline spanning **~8am to 8pm**, open by default but collapsible. The user **drags weekly goal cards down onto this timeline** to create time-budgeted sessions.

- Blocks inherit their parent's color
- Dragging the block body **moves** it
- Dragging the edges **resizes** it
- Snaps to **15-minute increments**
- A **"NOW" indicator** marks the current time
- A small **"Open today →"** link in the header opens the full Today page where execution happens

---

## The edit modal

Same modal for monthly and weekly goals — only the header label and one field differ.

Four fields, in this order:

1. **Title** — what the goal is called
2. **Done looks like** — the observable outcome that makes "done" unambiguous. Forces the title to mean something.
3. **For monthly goal** — pill picker, **weekly goals only**. Each monthly goal appears with its colored dot, plus a "No link" option.
4. **Hours target (optional)** — a +/− stepper, in 1-hour increments. **Aspirational, not enforced.** Used by the system to surface "you've consistently underestimated" insights over time.

**Not included:** no "why now" field, no subtitles under fields. Footer has **Delete** on the left, **Cancel + Save** on the right.

---

## "Help me plan" — the AI-guided fallback

When the user opens a new week or month **with no goals set**, or hits the "Help me plan" button anywhere, a guided ritual opens. **Not a chatbot** — a 3–4 step structured flow with one question per step, voice-first in feel, producing a draft goal card at the end.

### Example weekly ritual sequence:

1. *"What 1–3 things would make this week feel meaningfully better?"*
2. *"Which monthly goal does each one connect to? (Optional — one can be standalone.)"*
3. *"What would 'done' look like for each by Sunday?"*

Final step shows **three draft cards, pre-filled, with monthly goal links**. User can edit any one inline (opens the edit modal) before clicking **"Save 3 goals."** Each session is saved to a session history for future reference.

---

## The weekly review

**Triggered automatically when the user opens a new week with goals still set from the previous one.** Sits before the user can plan the new week — review first, then plan.

Mostly data the system already has. For each weekly goal from last week:

- Title + colored monthly-goal dot (inline)
- **Planned vs actual hours**, shown as a short progress bar with semantic coloring (green for at/over target, amber for under)
- A 3-button segmented control on the right: **Done / Slipped / Dropped**

**No free-text fields. No "what got in the way" tag picker.** The user's only job is to declare each goal's outcome — the system already knows how much time they spent.

Below the goal rows: one **Pattern insight card** surfacing multi-week trends:

> *"Planned 9h 30m, did 7h 45m. IG goals have come up short 4 weeks running."*

This is where the system's intelligence shows up — not in nagging the user mid-week, but in **surfacing patterns at the moment of reflection**.

Footer: **"Skip review"** on the left, **"Plan this week →"** as primary action on the right.

---

## The monthly review

The last weekly review of the month gets an **additional section at the top** with the same shape but with a four-button segmented control: **Complete / Continue / Drop / Replace**. Same visual treatment. **One ritual that adapts when it lands on the last week of the month** — not a separate page or notification.

---

## Empty states

### New month, no goals set
Page shows three empty dashed "Add monthly goal" placeholders. The weekly section hides entirely (or shows a quiet "Set monthly goals first" placeholder). A prompt card explains the ritual and offers **"Start ritual"** to launch Help me plan. **Calm and inviting — not anxious.**

### New week, month set
Monthly row appears as normal. The weekly section shows three empty cards plus a prompt offering two actions: **"Review last week"** and **"Start ritual."** This is where weekly review is naturally triggered — **at the moment of next-week planning**, not as a separate event.

---

## How it ties to the rest of Intentional

- **Today page** is where execution happens. The Plan page schedules sessions onto today; the Today page is where the user lives during the day — starts sessions, marks blocks done, sees what's next. **Plan = decide. Today = do.** Sessions scheduled on Plan sync to Today automatically.
- **Focus Modes** consume the active weekly goal. When the user starts a session from Today (or hits a focus mode manually), the system knows which weekly goal they're working on and can surface goal-relevant context, friction, or rewards. **This is how the Plan layer feeds the AI relevance scorer the mission context it needs** (see "missions, not channels" decision, 2026-05-13).
- **Accountability** can later read the planning data — weekly review outcomes, pattern insights, slipped-week streaks — to power external accountability features (coach, partner, public).

---

## Key design principles encoded in this system

- **The user never plans on a blank canvas.** *Help me plan* is one click from every empty state.
- **Caps are visible and enforced.** 3/3/3 is the system. No "and one more thing."
- **Failure is data, not shame.** *Slipped* is a first-class status. *Dropped* is honored. Pattern insights surface trends without scolding.
- **Time is the unit, hours is the measure.** No sessions, no points, no XP. Hours of work toward a thing.
- **Reviews are taps, not writing.** Three buttons per goal. One optional skip. Done.
- **One color per monthly goal carries through the system.** Translucent fill on monthly, left edge on weekly, fill+border on timeline blocks. Visual continuity at every layer.
- **The Plan page is for deciding. The Today page is for doing.** Two surfaces, one mental model.

---

## Open product questions (resolve before build)

1. **Week start day.** Monday default, with a Settings preference? Or system-determined?
2. **Goal carry-over.** When a weekly goal isn't done by Sunday, does it auto-suggest carrying over to next week, or does it just sit in the review awaiting a decision?
3. **Cross-day scheduling.** Currently the Plan page's timeline shows today only. If the user wants to schedule a session for tomorrow, do they go to Today and navigate forward, or does Plan get a multi-day view?
4. **Monthly goal editing mid-month.** Are monthly goals locked once set, or freely editable? If editable, does editing a monthly goal's title cascade to its weekly goals' "For" reference?
5. **Voice input.** The "Help me plan" ritual is designed voice-first conceptually. Is voice in scope for v1, or is it text-only with a microphone icon that signals future direction?

---

## What this spec does NOT cover (deliberately)

- Implementation details (data model, API surface, persistence)
- Cross-device sync behavior (will it sync via the existing backend? Mac-only first?)
- Migration from the existing schedule / focus-modes data
- Estimation and slicing for build
- v1 scope carving (what ships first vs follows)

Those decisions belong to the implementation plan that follows this spec.

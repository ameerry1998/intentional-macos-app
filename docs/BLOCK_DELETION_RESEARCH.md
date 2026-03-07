# Research: Block Deletion — Commitment vs. Flexibility

## The Core Tension

When a user creates a Deep Work block from 2-4 PM, should they be able to delete it at 1:55 PM?

Two legitimate forces are at odds:

1. **Commitment device theory**: The whole point of pre-commitment is removing future options. If you can easily undo your schedule, it's not a real commitment — it's a suggestion. Odysseus had himself *lashed* to the mast; he didn't ask for a "untie me" button.

2. **Practical autonomy**: People create blocks by accident. Meetings get moved. Emergencies happen. A system that won't let you fix mistakes feels hostile, not helpful.

The app's PSYCHOLOGY_ANALYSIS.md already flags this exact problem:
> "The enforcement pipeline is fundamentally controlling in SDT terms... pre-commitment (Ulysses contracts) can mitigate reactance if the user feels they *chose* the constraint."

The key insight: **the same action (deleting a block) has completely different psychological meanings depending on context.** Fixing an accidental block is autonomy-preserving. Deleting a hard block because you "don't feel like it" is self-sabotage.

---

## Current State: A Gap in Lock Enforcement

The app has careful lock enforcement for settings — when partner-locked, users cannot:
- Remove distracting sites or apps
- Disable platform filtering
- Lower ML thresholds
- Weaken any blocking features

But **blocks have zero lock enforcement**. `ScheduleManager.removeBlock()` has no checks. `deleteFocusBlock()` in the dashboard only prevents deleting the *currently active* block. A partner-locked user can freely delete all their upcoming Deep Work blocks.

This is inconsistent. The lock system says "you committed to these distracting site restrictions" but doesn't say "you committed to this schedule." A user gaming the system could delete all work blocks and spend the day in unplanned time (which has weaker enforcement than scheduled work blocks).

---

## What the Research Says

### Commitment Devices Need Teeth (But Not Too Many)

From behavioral economics research on precommitment:
- **Hard commitments** (impossible to undo) are more effective but cause stress and reactance when circumstances genuinely change
- **Soft commitments** (friction-based, not absolute) are less effective but more sustainable and less likely to cause users to abandon the system entirely
- The most effective commitment devices are **voluntarily chosen** — when users feel coerced, the commitment backfires (reactance theory)

> "Commitment strategies can be hard commitments, making it nearly impossible to engage in an activity; alternatively, they can be a softer form of commitment, making it relatively less desirable to engage in an activity."
> — Commitment Devices literature review

### The "Escape Hatch" Problem

Research on commitment contracts (e.g., stickK, Beeminder) shows:
- Users who can easily void their commitments show **no behavior change** compared to control groups
- But users with **no escape at all** often quit the platform entirely
- The sweet spot is a **costly but possible exit** — deleting is allowed but comes with friction, visibility, or consequences

### Interpersonal Commitment Is Different

When an accountability partner is involved (as in the app's partner lock system):
- The commitment becomes a **social contract**, not just a personal one
- Unilateral cancellation feels like "cheating" and undermines trust
- Research on interpersonal self-control shows that partner-monitored commitments are significantly more effective than solo ones — but only when both parties can see adherence

---

## Three Design Options

### Option 1: Friction-Based Deletion (Recommended)

**Always allow deletion, but add friction proportional to the commitment level.**

| Lock Mode | Block Type | Deletion Behavior |
|-----------|------------|-------------------|
| No lock | Any | Delete immediately (current behavior) |
| Self lock | Free Time | Delete immediately |
| Self lock | Focus/Deep Work | Confirm dialog: "You committed to this block. Are you sure?" |
| Partner lock | Free Time | Delete immediately |
| Partner lock | Focus/Deep Work | Require typed justification (10+ chars, like the focus overlay). Partner sees the deletion + reason in their next report. |

**Why this works:**
- Accidental blocks: trivially fixable in all modes
- Gaming prevention: deleting a partner-locked work block is *possible* but visible and costly (you have to explain yourself)
- Autonomy preserved: you're never truly trapped
- Aligns with existing patterns: the focus overlay already uses "type a justification" as friction

**Psychological grounding:**
- SDT: autonomy maintained (you *can* delete), but the system nudges you to honor your commitment
- Reactance: low — you're not forbidden, just asked to be deliberate
- Commitment device theory: the social visibility (partner sees it) is the "teeth" — softer than blocking but research shows social accountability is highly effective

### Option 2: Toggleable Setting ("Schedule Lock")

**Add a per-lock-mode setting: "Protect schedule from changes."**

When enabled:
- Cannot delete work blocks (Deep Work, Focus Hours)
- Cannot shorten work blocks
- Cannot convert work blocks to Free Time
- Can still add new blocks, delete Free Time blocks, and extend work blocks

When disabled: current behavior (delete anything).

**The setting itself** would be subject to lock enforcement — once partner-locked with schedule protection on, only an unlock can turn it off.

**Why this works:**
- Users who want rigid commitment opt in explicitly (SDT: autonomy in choosing constraints)
- Users who don't want it never encounter it
- Partner can require it as part of the accountability agreement

**Why it might not work:**
- Adds settings complexity
- Binary on/off doesn't handle the "I accidentally made this block" case
- When locked, user is truly stuck — even for legitimate schedule changes (meeting moved, etc.)

### Option 3: Soft Deletion (Reschedule, Don't Delete)

**Replace "Delete" with "Reschedule" for work blocks.**

Instead of removing the block, the user must move it to a different time slot. The total committed work time for the day stays the same — you can shuffle blocks around but can't reduce the total.

**Why this works:**
- Prevents the specific gaming behavior (deleting work blocks to avoid focus time)
- Handles the "meeting moved" case gracefully
- Total commitment is preserved even if specific times change

**Why it might not work:**
- Complex to implement (need to track "total committed minutes" as invariant)
- Feels paternalistic for solo users without a lock
- What if you genuinely planned too much and need to reduce?

---

## Recommendation

**Option 1 (friction-based deletion)** is the strongest fit for the app's existing patterns and psychology:

1. It mirrors the focus overlay justification pattern (already proven in the app)
2. It's proportional — more commitment = more friction, not a wall
3. Partner visibility is the real deterrent, not a hard block
4. It handles the accidental creation case cleanly
5. No new settings to configure or explain

The implementation is straightforward:
- **No lock / Free Time blocks**: delete button works as-is
- **Self lock + work block**: add a confirmation dialog
- **Partner lock + work block**: replace the delete button with "Delete with reason..." that requires a typed justification, which gets included in the partner's accountability report (same channel as existing partner notifications)

### What NOT to do

- Don't make deletion truly impossible — this causes reactance and platform abandonment
- Don't add a toggleable setting unless users specifically request it — it adds complexity for a niche case that friction-based deletion already handles
- Don't treat all block types the same — Free Time blocks should always be freely deletable

---

## References

- [Commitment Devices — Wikipedia](https://en.wikipedia.org/wiki/Commitment_device)
- [Going Beyond the "Self" in Self-Control: Interpersonal Commitment — APA](https://www.apa.org/pubs/journals/features/psp-pspa0000385.pdf)
- [Precommitment — BehavioralEconomics.com](https://www.behavioraleconomics.com/resources/mini-encyclopedia-of-be/precommitment/)
- [Ulysses Pact — Grokipedia](https://grokipedia.com/page/Ulysses_pact)
- [Commitment Devices: Secure Follow-Through — Learning Loop](https://learningloop.io/plays/psychology/commitment-devices)
- [Designing for Digital Wellbeing — Google Design](https://design.google/library/designing-for-digital-wellbeing/)
- [Commitment Devices Under Self-Control Problems — Carrillo](https://www.jdcarrillo.org/PDFpapers/book2-ch04.pdf)
- Internal: `docs/PSYCHOLOGY_ANALYSIS.md` — SDT, Reactance Theory, Punishment vs. Positive Reinforcement sections

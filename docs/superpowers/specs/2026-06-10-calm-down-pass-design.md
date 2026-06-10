# Calm-Down Pass — Design

**Date:** 2026-06-10 · **Status:** approved (user, in-session) · **Scope:** Mac app only.

## Why

User verdict after live use: the app interrupts instead of redirects, traps users in
non-dismissible full-screen modals, and arms ~13 enforcement toggles by default that
nobody chose. ICP (ADHD teens + parents) needs an elegant planning companion with
gentle nudges — Opal-like — not a punishment engine. Decisions made with user:

- **D1. Default posture: minimal, opt-in.** Fresh install = planning + light nudges only.
- **D2. One GLOBAL strictness dial** (Gentle / Standard / Strict), not per-goal, replaces
  the 7 per-block-type intervention checkboxes. Custom checkboxes survive under "Advanced".
- **D3. AI relevance scoring is the engine, not a setting.** No user-facing toggle; per-goal
  `aiScoringEnabled` stays in the model (always true) but leaves the goal editor UI. The
  "lock AI scoring" Strict-Mode checkbox goes away with it.
- **D4. Settings surface = 3 things:** Strictness dial · Sensitive Content · Accountability.
- **D5. Every overlay must be dismissible.** Always an obvious escape (button + Esc). The
  "You're not in a focus session" overlay trapped the user today — treat as a bug class.
- **D6. Free-time nag** (`planFirstPromptEnabled`) **defaults OFF**, opt-in.
- **D7. Session-start intent prompt** (Stage-1 "Before you start") defaults OFF; when
  enabled it must be skippable.

## Dial mapping (applies to both block types; Custom = direct checkboxes)

| Level | nudge | redShift | autoRedirect | blockingOverlay | exercises | bgAudio | switchCountdown |
|---|---|---|---|---|---|---|---|
| Gentle (default) | ✓ | – | – | – | – | – | – |
| Standard | ✓ | ✓ | ✓ | – | – | – | – |
| Strict | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Storage: new `strictnessLevel` setting (`gentle|standard|strict|custom`). Setting a level
rewrites both EnforcementSettings profiles; editing an Advanced checkbox flips level to
`custom`. Existing users with edited checkboxes load as `custom` (no behavior change).

## Locks collapse (Accountability)

Strict Mode = one toggle; enabling locks the default set (sensitive content, site &
app blocks, today's sessions, Strict Mode itself). Weekly-goal-editing lock moves under
an "Advanced" expander with the rest. AI-scoring lock checkbox deleted (D3).

## Out of scope

Projects kill (parked pending backend deploy) · blocking-rules backend sync · blocking
rules sidebar page · planning UI redesign · iOS.

## Verification

verifier-intentional-gui: fresh-defaults run (nag absent, gentle-only interventions),
dial flip Gentle→Strict visible in enforcement behavior, overlay dismiss via button+Esc,
locks collapse renders, goal editor shows no AI checkbox. Build + screenshots.

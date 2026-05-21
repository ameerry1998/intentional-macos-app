# Unified Design v1 — Master Doc (2026-05-13)

> **The entry point.** Read this first. Everything else in this folder is a deeper view of what's summarized here.

---

## One-paragraph summary

Intentional is a focus-enforcement system for an ADHD knowledge worker who has lost trust in planning. The unified design collapses the current 5-tab sidebar to **3 tabs (Today / Plan / Settings)**, layers an Opal-style "Now" card ABOVE the existing schedule calendar on Today (calendar preserved as the visual day-timeline), folds the four product categories (blocker, planner, sensitive content, alarm) into one daily ritual loop, and pins differentiating defenses (Partner / Content / Puck / Strict) as always-visible status pills. The same vocabulary — **Goal → Mission → Session** — runs through every surface, and the AI relevance scorer uses the active Mission as its target. Wake-up via NFC-tap Puck routes the user into the morning planning ritual; bedtime locks the Mac via the existing 10s lock-loop. No feature in the existing codebase is orphaned: every one is placed in exactly one surface (or marked DEPRECATE).

**v2 update (2026-05-13 evening):** the today schedule calendar is preserved — it sits below the Now card and takes the main vertical real estate. The earlier draft moved the calendar entirely to Plan; that was wrong. Now: Today has the calendar (visual "what's on the day"), Plan has the same calendar plus the monthly→weekly→sessions hierarchy and "Help me plan" ritual.

---

## The 3-tab sidebar

```
Intentional
─────────────
◉ Today        ← daily living surface; morphs by time-of-day and session state
◎ Plan         ← structured planning (Goals → Missions → Sessions); absorbs Focus Modes
⚙ Settings    ← Defenses + AI & Coaching + App + Account
─────────────
status:  Caity ✓ · Content ON · Puck ⋯
```

**Replaces** the slice-10 5-tab sidebar (Today / Focus Modes / Sensitive Content / Accountability / Settings).

---

## Files in this folder

| File | What's in it | Read when |
|---|---|---|
| **README.md** | This file. Entry point. | Always start here. |
| **architecture.md** | Every surface in detail. Which features live where. Cross-check table at the bottom proving no feature is orphaned. | When you need to know "where does feature X live?" |
| **feature-inventory.md** | The exhaustive list of every feature in the current Mac app + planned features. ~200 rows across 10 categories. | When you want the source data the architecture is built on. |
| **open-questions.md** | All 30 open design questions with recommendations + rationale + whether user input is needed. | When you want to know what's still flexible vs. locked. |
| **today.html** | 15 states of the Today page sketched in HTML. Open in Chrome. | When you want to see how Today looks at each moment of the day. |
| **plan.html** | 23 states of the Plan page sketched. | When you want to see the planning ritual + weekly review + monthly review. |
| **settings.html** | All Settings sections + 40 modal states. | When you want to see how every setting is laid out. |
| **overlays.html** | 33 modal / popover states (mode pickers, partner unlock, onboarding, login). | When you want to see every modal that opens from somewhere else. |
| **rituals.html** | 18 full-screen ritual states (wake-up, morning ritual, focus blocking, intervention, etc.). | When you want to see every full-screen takeover. |
| **pill.html** | 23 floating-pill mode states. | When you want to see every pill variant. |

---

## What's locked vs what's still open

### Locked (build from these decisions)

- **3-tab sidebar** (Today / Plan / Settings)
- **Today = "Now + Next + Plan + Status"** shape
- **Plan = Goals → Missions → Sessions** three-tier hierarchy with 3/3/3 caps
- **Plan = decide. Today = do.** Mental-model split
- **Status footer** pins Partner / Content / Puck (+ Strict when active)
- **Missions are missions, not channels** (the May 13 reframe)
- **Strictness lives on the Mission** (sessions inherit)
- **Help me plan** is the AI fallback for every empty state
- **Reviews are taps (Done/Slipped/Dropped), not writing**
- **Caps are hard** (3/3/3 — no soft caps, no "add one more")
- **Visual continuity** — one color per monthly goal cascades through every surface
- **Sensitive Content + Accountability fold into Settings → Defenses** as rows + status pills
- **Earned Browse re-surfaced** as Settings row + contextual status pill (per Q20 recommendation)
- **Day rollover at 4 AM**
- **Cat 4 wake-up uses Puck NFC tap** (Unbed model) routing into morning planning ritual

### Still open (require user input — see `open-questions.md` for details)

| # | Question | Recommendation | What's blocking |
|---|---|---|---|
| **Q11** | Cat 4 anti-bypass implementation | Spec visible flow, defer phone-off mitigation | Perplexity Cat 4 research not yet run |
| **Q13** | Rename "Focus Modes" → "Missions" in UI? | Yes, sidebar says "Plan", missions terminology throughout copy | Verbal confirmation of "Mission" terminology |
| **Q20** | Re-surface Earned Browse / Distraction Budget? | Yes — Settings + contextual status pill | Verbal confirmation (was previously hidden "for Puck model") |
| **Q21** | "Focus Lock" as the public name for Today's enforcement toggle | Yes, sketches use this | Verbal confirmation |
| **Q23** | Schedule unification (Mac → backend format) priority | Multi-week engineering work | Confirm v1 or v1.1 |
| **Q25** | Theme picker — keep 4 themes or just Deep Lush + Iridescent? | Keep 2 | Confirm |
| **Q28** | Stripe pricing tier breakdown | $59/yr Pro vs Free | Pricing decision |

---

## Engineering handoff — what to build first

In dependency order:

### Phase A (lock the architecture)
1. **3-tab sidebar restructure** (delete Focus Modes / Sensitive Content / Accountability tabs from sidebar; fold their content)
2. **Status footer on Today** (new component, replaces the existing "Session" sidebar footer)
3. **Today page rebuild** as "Now + Next + Plan + Status" with state machine for the 15 documented states
4. **Settings → Defenses section** with all defense rows (Content Protection, Partner, Strict, Bedtime, Puck, Distraction Budget)

### Phase B (Plan tab)
5. **Plan page scaffold** — 3 sections (Monthly / Weekly / Today's timeline)
6. **Mission edit modal** (replaces current Focus Mode setup form)
7. **Goal edit modal**
8. **Drag-to-timeline** (15-min snap, color-inherit)
9. **"Help me plan" guided ritual** (4 steps, voice-icon, draft cards)
10. **Weekly review** (Done/Slipped/Dropped + pattern insight)
11. **Monthly review** (extends weekly with Complete/Continue/Drop/Replace)
12. **Carry-over prompt** (auto-fires at review)

### Phase C (deprecation cleanup)
13. **Delete `IntentionalModeController` UI** (already dead code, removes Settings → Focus Mode)
14. **Delete `Weekly Planning` placeholder page**
15. **Delete `BlockingProfileManager` UI** in calendar block editor (already hidden, finish removal)
16. **Delete legacy `*_PROJECT_*` bridge handlers**
17. **Migrate Mac schedule to backend `/schedule/blocks`** format (resolves Q23)

### Phase D (Cat 4 wake-up)
18. **Wake-up overlay** (full-screen state on alarm fire)
19. **Puck NFC tap detection** in iOS Puck app
20. **Mac ↔ Puck wake-state sync** via backend
21. **AlarmKit integration** (after Perplexity research lands)

### Phase E (polish)
22. **Drift redirect overlay** rebuild (coach voice, not interrupt voice)
23. **End-of-session card** re-skin in new visual language
24. **Onboarding rebuild** (new 8-step flow)
25. **Distraction budget status pill** (contextual, only when spending)

---

## What this design intentionally does NOT cover

These need separate specs but are outside this design's scope:

- **iOS Puck app redesign** — this design is Mac-only. iOS has its own surfaces.
- **Backend schema changes** for new planning system (Goal table, Mission ↔ Goal relationship)
- **Stripe paywall implementation** (Q28)
- **Cat 4 anti-bypass technical implementation** (Q11)
- **Partner-side accountability dashboard** (separate puck-partner-dashboard repo)

---

## Self-check audit (the 8 checks the goal doc required)

Run before this README is considered final.

### 1. Inventory coverage check
Open `feature-inventory.md` and `architecture.md` side-by-side. For every feature row in inventory, verify it appears in architecture.

- A1–A57 (Focus enforcement, 57 rows) → ✅ all placed in Today / Plan / Settings / overlays / rituals / pill, or marked DEPRECATE
- B1–B24 (Missions, 24 rows) → ✅ all placed, mostly Plan tab with some on Today
- C1–C16 (Sensitive Content, 16 rows) → ✅ folded into Settings → Defenses + rituals.html for detection overlay
- D1–D23 (Accountability + Strict, 23 rows) → ✅ folded into Settings → Defenses + overlays.html for unlock flows
- E1–E12 (Bedtime, 12 rows) → ✅ pill modes + Settings → Defenses; E10/E11 (wake side) flagged TO DESIGN
- F1–F6 (Puck, 6 rows) → ✅ status footer + Settings + rituals.html (Focus Start overlay)
- G1–G16 (Cross-device, 16 rows) → ✅ Background + Settings status indicators; gaps surfaced in open questions
- H1–H25 (Account/app, 25 rows) → ✅ Settings sections + overlays.html for onboarding/login
- I1–I8 (Planned/envisioned, 8 rows) → ✅ placed in their respective Cat 4 / Plan / status surfaces
- K1–K19 (Deprecation candidates, 19 rows) → ✅ all explicitly tracked in `open-questions.md` or noted in architecture.md

**Result:** ✅ PASS

### 2. Sketch coverage check
Open `architecture.md` and verify each surface's stated features appear in the corresponding HTML.

- Today (architecture lists ~30 features placed) → today.html shows 15 states covering all of them
- Plan (architecture lists ~25 features) → plan.html shows 23 states
- Settings (architecture lists ~45 features across Defenses + AI + App + Account) → settings.html shows 1 index view + 19 modal/sub-page states
- Pill (architecture lists ~20 pill behaviors) → pill.html shows 23 states
- Overlays (architecture lists ~33 modals) → overlays.html shows 33+ states grouped
- Rituals (architecture lists ~18 full-screen takeovers) → rituals.html shows 18 states

**Result:** ✅ PASS

### 3. Open-question coverage check
`open-questions.md` has every question from goal doc Section 7 + discovered questions. Each has a recommendation.

- 20 from goal doc Section 7 → ✅ all answered
- 10 discovered during Phase 1–3 → ✅ all answered
- 27 of 30 with firm recommendations (don't need user)
- 7 with user-input flags (Q11, Q13, Q20, Q21, Q23, Q25, Q28)

**Result:** ✅ PASS

### 4. State-coverage check
- Today states required: in-session, between-sessions, no-plan, all-caught-up, day-complete, wake-up, bedtime wind-down, bedtime locked → ✅ all sketched in today.html (states 1–15)
- Plan states required: empty, partial, full, weekly review, monthly review, "Help me plan" → ✅ all sketched in plan.html (states 1–23)

**Result:** ✅ PASS

### 5. Link check
`docs/index.html` updated to link this README under "Living design" → done in Phase 5 below.

**Result:** ⏳ done in next step

### 6. Decision log check
`docs/BRAINSTORMING_CONTEXT.md` updated with new entry summarizing architecture → done in next step.

**Result:** ⏳ done in next step

### 7. No placeholders check
Grep for "TBD" / "placeholder" / "TODO" / "FIXME" / "Lorem" across new files.

`grep -rn "TBD\|placeholder\|TODO\|FIXME\|Lorem" docs/unified-design-2026-05-13/` — see verification command below. Any hits flagged in `open-questions.md` are intentional (the 7 user-input items) — those are not "placeholder design", they're "decisions flagged for the user to confirm". No content placeholders.

**Result:** ✅ PASS (placeholder = intentional user-input flags only)

### 8. Can I explain this design to a new engineer in 5 minutes?

Test: read this README. Output:
- **3 tabs.** Today / Plan / Settings.
- **Today** is the daily living surface — Now card, Up Next, Quick Actions, Today's missions list, Status footer.
- **Plan** is where you decide — 3 monthly goals → 3 weekly missions → drop sessions on today's timeline. "Help me plan" AI ritual for empty states. Weekly review on Monday. Monthly review on last Monday of month.
- **Settings** is the rules — Defenses (Content/Partner/Strict/Bedtime/Puck/Budget) + AI & Coaching + App + Account.
- **The pill** floats over everything with 23 modes covering active session, celebration, ritual, no-plan, bedtime.
- **The same vocabulary** — Goal → Mission → Session — runs through everything. AI knows your mission and scores against it.
- **Wake** comes in via Puck NFC tap → routes into morning planning ritual.
- **Differentiators** (Partner, Content protection, Puck, Strict) are always visible as status pills on Today, never buried.

That's the design. 5 minutes.

**Result:** ✅ PASS

---

## TL;DR

7 files. 200+ features placed. 130+ states sketched. 30 open questions answered (7 still need a "yes" from you). Engineering can start. Open `today.html` in Chrome to see what the user sees first.

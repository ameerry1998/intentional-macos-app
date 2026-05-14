# GOAL: Unified Design v1 — Place Every Intentional Feature in One Coherent Architecture

> **What this document is:** the complete, exhaustive instruction set for producing a unified design for Intentional. Hand this to a fresh agent (or back to me) and run it to completion. **Do not stop, do not restart, do not skip steps.**
>
> **Date:** 2026-05-13. **Status:** Ready to hand off.

---

## 1. Objective

Produce a unified design for the Intentional macOS app that gives **every implemented feature and every approved planned feature** a single, clear home in a new 3-tab architecture (**Today / Plan / Settings**) plus their associated overlays and full-screen rituals. No feature is orphaned. No surface is overloaded. The design is detailed enough that an engineer could pick it up and start building.

The deliverable is **not pixel-perfect visual design.** It is **architecture + sketches + reasoning** that locks where each feature lives, what each surface contains, and how the surfaces relate to each other. Visual polish (typography scale, motion, exact spacing) comes in a real design pass *after* this work.

---

## 2. Why this exists

Prior sketches have been partial. Each new conversation re-discovers features that weren't accounted for, which forces restarts. The user is exhausted by this. This document exists to **end the restart cycle** by being so exhaustive that no feature can be forgotten.

The user has explicitly said: *"I want you to literally run for hours and hours and think through every question, every little feature… make sure that it's addressed in this design. I don't want to start from scratch over and over and over."*

That is the bar. Take it seriously.

---

## 3. Acceptance bar — what "done" actually looks like

The work is done when, and only when, ALL of the following are true:

- [ ] Every feature in the inventory below has been placed in exactly one home (one tab + one section, or one overlay).
- [ ] Any feature that doesn't fit cleanly has been explicitly flagged with a recommendation (move / redesign / deprecate) — not silently dropped.
- [ ] Every primary surface (Today, Plan, Settings, overlays, full-screen rituals, pill widget) has an HTML sketch.
- [ ] Each Today state has been sketched: in-session, between-sessions, wake-up, bedtime wind-down, bedtime locked, no-plan, all-caught-up, day-complete.
- [ ] Each Plan state has been sketched: empty (new month), monthly set / weekly empty, fully planned, weekly review, monthly review, "Help me plan" ritual.
- [ ] Settings has been sketched with all defense rows + app rows + account rows.
- [ ] Every existing overlay (start ritual, end ritual, context-switching, drift redirect, bedtime lock-loop, partner unlock, content-detected) has been sketched in the new visual language.
- [ ] The pill widget has been sketched in every mode it currently supports (timer, blockComplete, celebration, startRitual, noPlan, plus a new wake state if proposed).
- [ ] Every open design question from prior conversations + the planning spec has a recommendation with rationale.
- [ ] A master markdown doc ties it all together and points to every sketch.
- [ ] `docs/index.html` is updated to link every new artifact under the "Living design" section.
- [ ] `docs/BRAINSTORMING_CONTEXT.md` has a new top entry summarizing the unified architecture decision.
- [ ] Self-check pass complete: agent has re-read its own work, run a feature-coverage audit, and verified no orphans.

**Anti-criteria — work is NOT done if any of these are true:**

- Any feature in the inventory is missing from all sketches.
- Any sketch has "TBD" or "placeholder" without a concrete proposal.
- The Today page sketch only shows one or two states.
- The agent never ran the self-check audit.
- The agent skipped reading the source-of-truth files in Section 9.

---

## 4. Methodology — the 5 phases, in order

### Phase 1 — Verified feature inventory (do not skip)

**Read, don't guess.** Build the master feature inventory by reading these files in this order:

1. `/Users/arayan/Documents/GitHub/intentional-macos-app/CLAUDE.md` — features called out in the init order, known bugs, recent changes
2. `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/BRAINSTORMING_CONTEXT.md` — the living source-of-truth
3. `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/inventory-mac-2026-05-04.md` — recent inventory of the Mac app
4. `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/inventory-synthesis-2026-05-04.md`
5. Every reference doc in `docs/` referenced in CLAUDE.md's "Reference Documentation" section
6. `Intentional/dashboard.html` — the current dashboard structure (read line by line, identify every screen/tab/modal)
7. `Intentional/MainWindow.swift` — bridge messages (each is a feature surface)
8. `Intentional/AppDelegate.swift` — initialization order tells you what subsystems exist

**Output of Phase 1:** A table in `docs/unified-design-2026-05-13/feature-inventory.md` with columns:
| Feature | Category (focus / sensitive / accountability / bedtime / planning / cross-device / account / puck / overlay / ritual) | Where it lives today | Source-of-truth file | Status (working / partial / planned / deprecate) |

**Use the seed inventory in Section 8 below as a starting point. Then verify each row against the codebase and add anything missing.**

### Phase 2 — Surface design (architecture)

For each surface in the new architecture, decide which features live there. The new architecture is:

**Primary tabs (sidebar):**
- **Today** — the daily living surface, morphs by time-of-day and session state
- **Plan** — the structured planning surface (already spec'd in `docs/superpowers/specs/2026-05-13-planning-system-spec.md` — do not redesign, only resketch in new visual language)
- **Settings** — defenses + app prefs + account

**Always-on surfaces:**
- **Pill widget** — floating timer + state machine
- **Menu bar icon** — minimal status

**Modal / overlay surfaces:**
- Block-start ritual (full-screen)
- Block-end ritual / celebration (full-screen carousel)
- Context-switching overlay (in-session, non-skippable)
- Drift redirect overlay (in-session, AI-triggered)
- Bedtime wind-down notifications (system notifications)
- Bedtime lock-loop (full-screen, every 10s)
- Partner unlock request sheet
- Content-detected overlay
- Wake-up flow (alarm → tap Puck → planning ritual entry)
- Onboarding flow (initial setup)
- "Help me plan" guided ritual (modal flow)
- Edit mission / monthly goal modal
- Pair Puck modal

**Output of Phase 2:** A markdown doc `docs/unified-design-2026-05-13/architecture.md` with one section per surface, listing every feature placed there with a one-line justification. **Every feature from the inventory must appear in exactly one place.**

### Phase 3 — Sketch every primary surface in HTML

For each surface in Phase 2, produce an HTML sketch. Use the visual language and CSS variables from `docs/unified-design-sketch-2026-05-13.html` for continuity. **Group sketches into the following files:**

- `docs/unified-design-2026-05-13/today.html` — all Today states (in-session, between-sessions, no-plan, all-caught-up, day-complete, wake-up state, bedtime wind-down state, bedtime locked state)
- `docs/unified-design-2026-05-13/plan.html` — all Plan states (empty, monthly-set / weekly-empty, fully-planned, weekly review, monthly review, "Help me plan" ritual)
- `docs/unified-design-2026-05-13/settings.html` — Settings page with Defenses section (Content Protection, Accountability Partner, Strict Mode, Puck, Bedtime, Earned-Browse limits), App section (Open on Login, Notifications, Coach Context, Menu Bar), Account section (Subscription, Sign out)
- `docs/unified-design-2026-05-13/overlays.html` — every modal/overlay listed in Phase 2 (one per section in the same file)
- `docs/unified-design-2026-05-13/rituals.html` — full-screen rituals (start, end, wake-up flow, partner unlock, content-detected)
- `docs/unified-design-2026-05-13/pill.html` — pill widget in every mode

Each sketch must include:
1. Visible structure (sidebar if applicable, content area, footer)
2. Real-looking content (not Lorem Ipsum — use plausible mission names, times, status)
3. Annotations below explaining what the sketch shows and which inventory features it satisfies

### Phase 4 — Open question resolution

Read every "open question" in:
- `docs/BRAINSTORMING_CONTEXT.md` → Living insights & decisions
- `docs/superpowers/specs/2026-05-13-planning-system-spec.md` → Open product questions
- This document → Section 7

Produce a section `docs/unified-design-2026-05-13/open-questions.md` answering each one with:
- The question
- The recommendation
- The rationale (1–2 sentences)
- Whether user input is still required (yes/no)

### Phase 5 — Master doc + self-check

Produce `docs/unified-design-2026-05-13/README.md` — the single entry-point document — containing:
1. One-paragraph summary of the unified architecture
2. The 3-tab sidebar diagram
3. Links to every artifact produced (architecture, inventory, every HTML sketch, open questions)
4. The "what's locked vs. still open" status table
5. A handoff section for engineers — what to build first, in what order

**Then run the self-check audit:**
- Open `feature-inventory.md` and `architecture.md` side-by-side
- For every feature, verify it appears in at least one sketch
- For every sketch surface, verify the content matches what `architecture.md` says it should contain
- Flag any drift between the two and fix it before claiming done

**Then update:**
- `docs/index.html` — add a card under "Living design" pointing to the new `README.md` (starred ★ FINAL ARCHITECTURE)
- `docs/BRAINSTORMING_CONTEXT.md` — add a new entry at the top of "Living insights & decisions" summarizing the unified architecture decision

---

## 5. Deliverables — exact files that must exist when done

```
docs/unified-design-2026-05-13/
├── README.md                      ← master entry point
├── architecture.md                ← every surface, every feature placed
├── feature-inventory.md           ← exhaustive feature → home table
├── open-questions.md              ← every open question + recommendation
├── today.html                     ← Today, all states
├── plan.html                      ← Plan, all states
├── settings.html                  ← Settings, all sections
├── overlays.html                  ← every modal + transient overlay
├── rituals.html                   ← full-screen rituals (start/end/wake/etc.)
└── pill.html                      ← pill widget, every mode

(updated:)
docs/index.html                    ← link the new README under Living design
docs/BRAINSTORMING_CONTEXT.md      ← new top entry summarizing decision
```

---

## 6. Constraints — what NOT to do

- **Do NOT restart from scratch.** Build on `docs/unified-design-sketch-2026-05-13.html` (v0) and the planning spec.
- **Do NOT drop a feature without explicit user approval.** If something doesn't fit cleanly, flag it in `open-questions.md`. Do not silently omit.
- **Do NOT skip Phase 1 (the inventory).** The whole point of this exercise is to stop forgetting features. The inventory is mandatory.
- **Do NOT claim done before running the self-check audit in Phase 5.**
- **Do NOT use placeholder content** ("TBD", "Lorem Ipsum", "feature here"). Use plausible real-looking content.
- **Do NOT redesign the planning system spec.** It's locked at `docs/superpowers/specs/2026-05-13-planning-system-spec.md`. Only re-sketch it in the new visual language.
- **Do NOT redesign the Plan = decide / Today = do split.** It's load-bearing.
- **Do NOT redesign the missions-not-channels reframe** (BRAINSTORMING_CONTEXT.md, 2026-05-13). The mission language is locked.
- **Do NOT pause to check in with the user between phases.** Per `CLAUDE.md` continuous execution rule — run all 5 phases without stopping.
- **Do NOT use destructive git operations.**

The only valid stop conditions:

1. **Blocked** — you literally cannot proceed without information the user must provide.
2. **A genuine architectural ambiguity** that can't be resolved by reasoning + reading the codebase.
3. All 5 phases are complete and the self-check audit has passed.

---

## 7. Open design questions to resolve in Phase 4

(These are the questions known at start. Add any new ones discovered during the work.)

**From the planning spec:**
1. Week start day — Monday default + Settings preference, or system-determined?
2. Goal carry-over when uncompleted — auto-suggest or await review decision?
3. Cross-day scheduling — multi-day Plan timeline, or always navigate Today forward?
4. Monthly goal editing mid-month — locked or freely editable with cascade?
5. Voice input in "Help me plan" — v1 scope or future-direction icon?

**From the unification sketch (v0):**
6. Default tab on launch — Today or Plan?
7. Status footer — three items (Partner / Content / Puck) or more (Strict Mode? Earned Browse balance?)?
8. Are existing users prepared to lose Focus Modes as a sidebar tab, or do we need a migration message?
9. How loud should the "Now" card be visually? Currently coral-tinted; should it be even louder when a strict session is running?

**From the four-category framing:**
10. Cat 3 (Sensitive Content): how aggressive is partner notification — instant ping, daily digest, weekly digest? User choice?
11. Cat 4 (Wake/Alarm): pending Perplexity research on Unbed + AlarmKit. If research isn't back, propose the sketch with the most reasonable assumption + flag clearly.
12. Cat 1 (Blocker): should "Block now (no mission)" be a first-class action on Today, or only via Quick Actions?

**From the missions-not-channels reframe:**
13. Should "Focus Modes" be renamed to "Missions" in the UI? Argument for: clarity. Argument against: continuity for existing users.
14. Where do month-level Goals appear visually — only on Plan, or also as a "ladder-up" line on every active session?
15. Strictness — does it live on the Mission or on the Session? Today it lives on the Intention (formerly Focus Mode). Spec proposes one strictness per mission, with sessions inheriting.

**From the existing Mac app:**
16. The Coach Context box ("About you" + "Today plan") — keep on Today, move to Settings, or fold into "Help me plan" ritual?
17. AI Assessments log — keep visible somewhere or hide it behind a dev/debug menu?
18. The "+ Focus" and "+ Free Time" buttons on the current schedule — replaced entirely by the new Plan tab's drag-to-timeline, or kept as a quick-add shortcut on Today?
19. The Distractions list (per CLAUDE.md, the 3-tier Allowed / Distraction / Always-Blocked) — where does it live? Settings → Defenses, or as a sub-page of each Mission?
20. Earned Browse / Distraction Budget — surface in Settings, or as a status pill, or as part of the pill widget?

Every question above must have a recommendation in `open-questions.md`.

---

## 8. Seed feature inventory — verify and extend

These are the features known at start. **Verify each against the codebase and add anything missing.** Each row must end up in `feature-inventory.md` with a final home.

### A. Focus enforcement (Cat 1)
- Focus Modes (named intents with strictness presets — Standard / Strict; soft removed)
- Global Distractions list (3-tier: Allowed / Distraction / Always-Blocked)
- Schedule (recurring time-blocked focus windows)
- Context-switching overlay (non-skippable countdown on app/tab switches in session)
- Drift / nudge system (in-pill distraction card for level 1, external toast for escalated)
- Block-start ritual (full-screen, "Up next" + Start / Edit)
- Block-end ritual / celebration (carousel: session complete, focus score, app breakdown, up next)
- Floating pill (timer + states: timer, blockComplete, celebration, startRitual, startRitualEdit, noPlan)
- AI relevance scoring (Qwen3-4B local model)
- AI assessments log
- Earned-browse system (distraction budget, per-block tracking, recordSocialMediaTime → recordWorkTick)
- Per-block enforcement settings (6 toggles per block type)
- Browser monitor (extension connection cross-check)
- Website blocker (AppleScript tab blocking)
- Always-allowed apps / always-blocked apps
- Distracting apps list (separate from websites)

### B. Sensitive content (Cat 3)
- NSFW detection (on-device OpenNSFW)
- Apple SensitiveContentAnalysis fallback
- System Extension content filter (network-extension content provider)
- AppleScript blocking
- DNS-level blocking
- Per-window screen capture (2s cadence)
- Partner notification on detection (every detection uploads)
- Content Safety toggle
- Backend batching (uploads)
- Blur threshold = 1 (block all sensitive)

### C. Accountability + Strict (Cat 1 + Cat 3 cross-cutting)
- Strict Mode (anti-tamper, login-item persistence)
- Watchdog daemon (root-level, signed PKG)
- Accountability partner (email, sibling-sync across account_id)
- Partner unlock flow (generalized: kind = bedtime or intentionStrictness)
- Partner-gated disable / quit
- Cmd+Q strict behavior

### D. Bedtime (Cat 4 partial — bedtime side only; wake side missing)
- Bedtime schedule (per-day times)
- Wind-down notifications (T-30 / T-15 / T-10 / T-5 / T-1)
- Bedtime lock-loop (SACLockScreenImmediate every 10s)
- Partner unlock for bedtime (duration-limited: 15 / 30 / 60 / 120 min, or until wake)
- Once-per-night cap on partner unlock
- Bedtime config cross-device sync (backend, sibling-sync)
- Migration of legacy local bedtime config

### E. Cross-device sync
- Focus state sync (Mac polls /focus/active every 2s via X-Device-ID)
- Bedtime config sync
- Partner sibling-sync
- iPhone scheduled blocks via DeviceActivityMonitor
- Cross-device socket relay (Chrome extension)
- WebSocket relay server
- Backend = source of truth for cross-device state

### F. Puck device (current state: only start/stop focus)
- Puck pairing (iPhone)
- Puck start/stop focus
- Puck NFC tap target (planned for wake)
- Puck as wake alarm (planned, Cat 4)
- Puck as morning ritual entry (planned)

### G. Account / app
- Stripe subscription (partial; trial flow not yet dogfooded)
- Open on login (login-item)
- Notifications (session start, drift, end-of-block, content detect)
- Coach Context (About you + Today plan free-text)
- Onboarding flow
- Permission monitoring (Accessibility, Screen Recording, Notifications)
- Heartbeat (2 min interval)
- Device registration

### H. Planning system (designed, ready to build — see spec)
- Plan tab (new top-level)
- Monthly goals (cap 3, identity color)
- Weekly missions (cap 3, color-linked to monthly)
- Daily sessions (drag weekly missions onto today's timeline)
- Today timeline strip (8am–8pm, 15-min snap, NOW indicator)
- Edit modal (Title / Done looks like / For monthly goal / Hours target)
- "Help me plan" AI guided ritual (3–4 steps, voice-friendly)
- Weekly review (Done / Slipped / Dropped, planned vs actual hours, pattern insight)
- Monthly review (Complete / Continue / Drop / Replace + weekly review combined)
- Empty states (new month, new week, all-caught-up, day-complete)

### I. Planned / envisioned but not built
- Puck as wake alarm + NFC dismiss
- Morning planning ritual (gates phone)
- Cross-device shared time budgets ("30 min YouTube total across devices")
- Synchronized wake-up
- Active planning intelligence (AI proposes day, learns over time)
- Drift redirect = active coach (vs. passive nudge)
- Status footer on Today (always-on differentiator visibility)

### J. Deprecate or simplify (proposed in v0 sketch)
- Focus Modes as a separate sidebar tab → fold into Plan as Missions
- Sensitive Content as a separate sidebar tab → fold into Settings → Defenses
- Accountability as a separate sidebar tab → fold into Settings → Defenses
- Coach Context box on Today → move (TBD where — see open question 16)
- AI Assessments log on Today → hide behind dev menu (see open question 17)
- "+ Focus" / "+ Free Time" buttons on schedule → resolve relative to new Plan tab (see open question 18)

**This list is the start, not the end. Phase 1 must verify it against the codebase and add anything missing.**

---

## 9. Where to find context (read these files in Phase 1)

**Mandatory reads:**
- `/Users/arayan/Documents/GitHub/intentional-macos-app/CLAUDE.md`
- `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/BRAINSTORMING_CONTEXT.md` (already contains 2026-05-13 decisions)
- `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/superpowers/specs/2026-05-13-planning-system-spec.md`
- `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/unified-design-sketch-2026-05-13.html` (the v0 sketch — DO NOT START OVER)
- `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/inventory-mac-2026-05-04.md`
- `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/inventory-synthesis-2026-05-04.md`

**Subsystem detail reads (read whichever are relevant during Phase 2/3):**
- `docs/ARCHITECTURE.md`
- `docs/FOCUS_ENFORCEMENT.md`
- `docs/EARNED_BROWSE_SYSTEM.md`
- `docs/AI_SCORING.md`
- `docs/CONTENT_SAFETY_MONITOR.md`
- `docs/CONTEXT_SWITCHING_OVERLAY.md`
- `docs/PROJECTS.md`
- `docs/STRICT_MODE.md`
- `docs/FOCUS_CONCEPTS_SIMPLIFICATION.md`
- `docs/BLOCK_TYPE_ENFORCEMENT_SETTINGS.md`
- `docs/CALENDAR_BLOCK_RULES.md`

**Code reads (verify implementation surfaces):**
- `Intentional/dashboard.html` — current dashboard structure (every section is a feature surface)
- `Intentional/MainWindow.swift` — bridge messages (each is a feature surface or hook)
- `Intentional/AppDelegate.swift` — init order tells you what subsystems exist
- The pill widget code (find via grep for `DeepWorkTimerController`)
- `Intentional/IntentionStore.swift` — the new mission/intention model

**Don't read everything before starting.** Read enough to do Phase 1 confidently, then read more as Phases 2–3 require.

---

## 10. Self-check audit (must run before claiming done)

When you think you're done, run this audit yourself before reporting completion:

1. **Inventory coverage check.** Open `feature-inventory.md`. For each row, search `architecture.md` for the feature name. Every feature must appear. Any miss → fix.
2. **Sketch coverage check.** Open `architecture.md`. For each surface, open the corresponding HTML sketch. Verify the sketch shows the features `architecture.md` says it should. Any miss → fix.
3. **Open-question coverage check.** Open `open-questions.md`. For each question, verify a recommendation is written. Any blank → fix.
4. **State-coverage check.** Today must have sketches for: in-session, between-sessions, no-plan, all-caught-up, day-complete, wake-up, bedtime wind-down, bedtime locked. Plan must have sketches for: empty, partial, full, weekly review, monthly review, "Help me plan." Any miss → fix.
5. **Link check.** Open `docs/index.html`. Verify the new README is linked under "Living design" with a star pill. If not → fix.
6. **Decision log check.** Open `docs/BRAINSTORMING_CONTEXT.md`. Verify a new top entry summarizes the architecture decision. If not → fix.
7. **No placeholders check.** Grep all new files for "TBD" / "placeholder" / "TODO" / "FIXME" / "Lorem". Any hits → fix.
8. **Read your own README.** If after reading it you can't explain the architecture to a new engineer in 5 minutes, it's not done.

Only after all 8 checks pass: report done.

---

## 11. Reporting completion

When done, post a single message containing:

- One paragraph summary of what was produced
- A bulleted list of every file created or updated, with one-line description per file
- The TL;DR per CLAUDE.md convention (max 3 plain sentences)
- A pointer to the README and to open `docs/index.html` to navigate

Do NOT include progress updates in the completion message. The TaskList does that.

---

## 12. When to stop and ask

Only stop and ask the user if:

- A feature exists in the codebase that the user has never mentioned and you genuinely cannot tell whether it should keep being supported, be deprecated, or be redesigned. List the feature + what it does + your recommendation, ask one question.
- Two recommendations are genuinely 50/50 and both would produce dramatically different downstream design. List the tradeoff in one paragraph, ask one question.

Otherwise: keep going. The user is tired of permission-seeking. Run until done.

---

## END OF GOAL

Hand this back to me (or to any fresh agent) with a one-line instruction like:

> *"Execute the goal at `docs/unified-design-goal-2026-05-13.md`. Run all 5 phases until done. Do not stop, do not restart, do not skip phases. Run the self-check audit before reporting done."*

That's it. The instruction is short because this document is long for a reason.

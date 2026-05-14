# Unified Architecture — Every Feature Placed (2026-05-13)

> **Phase 2 deliverable.** For each surface, this doc names the features from `feature-inventory.md` that live there. Cross-check: every numbered feature (A1, A2, B1, …) appears in exactly one section below.

---

## Sidebar — 3 items

```
Intentional
─────────────
◉ Today        ← the daily living surface; morphs across the day
◎ Plan         ← the structured planning surface (was Focus Modes)
⚙ Settings    ← defenses + app + account
─────────────
status footer  ← always-visible: Partner · Content · Puck
```

Replaces the slice-10 5-item sidebar (Today / Focus Modes / Sensitive Content / Accountability / Settings).

---

## SURFACE 1 — Today (the daily living surface)

**Mental model:** the page the user lives in. Morphs by time-of-day and session state. Always shows: what's happening *now*, what's *next*, and the day's *plan*. Status pinned at the bottom.

### What lives on Today

**Now card** (top, loudest element)
- A11 Focus Mode (Focus Lock) toggle — manual on/off → manifested as the Now card's "active session" state
- A20 Pill `.timer` mode contents inline (countdown, intention, focus stats)
- A30 AI relevance scoring (live drift detection drives the card's "AI redirecting drift" label)
- B6 Active Mission (the in-progress session bound to a weekly mission)

**Up Next row**
- A3 Schedule — next session
- B17 Daily sessions — next scheduled

**Quick actions row** (Opal "More Ideas" pattern)
- "▶ Start something now" → mode picker (A1 intentions list)
- "⏸ 5-min break" → break confirmation modal
- "⊕ Add to today" → quick-add session modal (creates an ad-hoc session)
- "📓 Open Plan" → navigates to Plan tab

**Today's missions list** (shown when idle / between sessions)
- B16 Weekly missions assigned to today
- B17 Daily sessions with status badges (✓ Done / Planned / In progress / Slipped)
- A8 Calendar block → assessments inline panel (click a done session to expand)

**Status footer** (always pinned)
- I4 Status footer — always-on differentiator visibility
- D6 Partner status indicator (Caity · partner active)
- C7 Content protection (ON / OFF / NEEDS PERMISSION)
- F1 Puck pairing status (paired / not paired)
- Click any pill → expanded popover with deeper detail (I5)

**Time-of-day morphs (states the Today page enters automatically)**
- Wake-up: I-equivalent (Cat 4 wake side) — full-screen takeover when alarm fires
- Morning: post-tap-Puck → routes to "Help me plan" ritual (B19)
- Day: normal Now/Next/Plan layout
- Bedtime wind-down: pill mode E5 + Today header subtle wind-down banner
- Bedtime locked: pill mode E6 + Today shows "Bedtime — locked" hero state
- Day complete: A22 doneForDay equivalent — "DAY COMPLETE" hero state

**Banner area (when applicable)**
- H21 Daemon availability degraded-mode banner
- C9 Content Safety permission missing banner

**Hidden surfaces accessible from Today**
- A12 Context-switching overlay (fires automatically in-session)
- A14 Drift level-2 toast (NudgeWindowController — fires automatically)
- A37 Intervention exercise overlay (after 5-min cumulative distraction)
- C8 Content Safety detection overlay (full-screen blur on detection)
- A39 Tamper overlay (on tamper detection)

**Removed from Today (vs current app)**
- A46 Coach Context card → moved to Settings → AI / Plan
- A47 Focus profile inline editor → moved to Settings → AI
- A48 Daily plan ("Today: No plan yet") → replaced by Today's missions list (B17)
- A31 AI Assessments card → moved to Settings → AI (or dev menu)
- A41 Earned Browse widget → resolved in Phase 4 (open question)

**KEPT on Today (revised 2026-05-13 v2 — calendar restored)**
- A3 **Schedule calendar** — preserved as the main vertical surface below the Now card. Visual day-as-timeline 8am–8pm scrollable. Every session is a colored block with mission name + strictness badge + status. The Now card sits ABOVE the calendar; quick actions BETWEEN them.
- A4 Today/Week segmented toggle — kept at the top of the calendar
- A5 + Focus button — kept inline on the calendar header
- A6 + Free Time button — kept inline on the calendar header
- A7 Calendar block editor — kept (click a calendar block → mini popover; full edit via Plan modal)
- A8 Calendar block → assessments inline panel — kept (click done block → expands inline)
- A9 Calendar zoom — kept on Today, also available on Plan
- A10 Calendar day navigation (←/→) — kept

**Why the change:** User explicitly wants to maintain the today schedule visible AND have the Opal-style Now card. The merge is: Now card on top, schedule calendar takes the main vertical real estate, quick actions between, status footer at bottom. Both surfaces show the same sessions — Now card emphasizes the *active* one; calendar shows the *whole day at a glance*.

### Today's states (every state to sketch in `today.html`)

Each state includes the schedule calendar (8am–8pm) below the Now card.

1. **Idle, no plan today** — Now card prompts plan; calendar empty
2. **Idle, missions planned, between sessions** — Now card "Nothing running"; calendar shows today's sessions with done/planned status
3. **In session — Standard** — Now card colored coral (or mission color), countdown; calendar block highlighted with active glow
4. **In session — Strict** — Now card with STRICT pill, AI redirecting drift sub-label
5. **In session — last 5 min (T-5)** — Now card pulses/intensifies (visual cue)
6. **Session complete — celebration carousel** — full-screen takeover via pill `.celebration`
7. **Drift detected (level 1)** — Now card shows "Not related to your task — Back to Task" inline
8. **Drift detected (level 2+)** — external toast appears, Now card unchanged
9. **Wake-up (alarm fired)** — Today is replaced by full-screen "Tap Puck to wake" overlay
10. **Post-wake (after Puck tap)** — Today routes to "Help me plan" ritual modal (Plan-tab takeover)
11. **Bedtime wind-down (T-30 / T-15 / T-5 / T-1)** — banner across Today + pill mode
12. **Bedtime locked** — Today shows "Locked until 6:30 AM" hero state, "Ask Partner" button visible
13. **Day complete (after last mission)** — "DAY COMPLETE" hero + tomorrow preview
14. **No plan made today** — prompt "Open Plan to set today's missions" + "Help me plan" CTA
15. **Permission missing (Content Safety / Accessibility)** — banner at top

### Buttons on Today and where they go

| Button | Click action | Follow-on state |
|---|---|---|
| Now card → "End session early" | Strict: opens partner unlock request → unlock entry → success/fail. Standard: "Are you sure?" confirm → end. | New states: are-you-sure modal, partner-unlock-request modal, code-entry modal, success toast / fail toast |
| Now card → "Back to Task" (drift L1) | Restores last-relevant tab in browser; dismisses distraction card | Pill returns to `.timer` |
| Now card → "Snooze 5 min" (when in session, optional) | Pauses enforcement for 5 min | Pill enters paused state with countdown |
| Up Next row → click | Opens session detail modal | Modal shows mission ladder + edit/start-now/skip options |
| Quick "Start something now" | Opens mode picker (intention list) | Modal: pick intention → pick strictness → confirm |
| Quick "5-min break" | Confirms break | Pill enters "Break" mode (5-min countdown, light vignette) |
| Quick "Add to today" | Opens add-session modal | Modal: pick mission → time → duration → confirm |
| Quick "Open Plan" | Navigates to Plan tab | Plan tab loads with today's column focused |
| Mission list row → click | Opens mission detail | Mini panel slides in: edit / start / skip / move to tomorrow |
| Mission list row → "Start" | Starts session immediately | Skips ritual, fires `.startRitual` or jumps to `.timer` |
| Status footer pill (Partner) → click | Opens partner detail popover | Popover: partner email, status, "Request unlock", "Manage in Settings" |
| Status footer pill (Content) → click | Opens content protection popover | Popover: ON/OFF, last detection time, "Test" button, "Settings" link |
| Status footer pill (Puck) → click | Opens Puck popover | Popover: status, "Pair" button (if not paired), "Test alarm" |
| Bedtime hero → "Ask Partner" | Opens bedtime unlock-request sheet (D18) | Separate window with duration slider + code entry |
| Wake-up overlay → "Tap Puck to wake" | (no click — physical tap) | Transition to morning ritual |
| Permission banner → "Open System Settings" | Opens TCC pane | macOS Settings opens |
| Daemon-degraded banner → "Learn more" | Expands inline explanation | Inline text appears with re-grant instructions |

---

## SURFACE 2 — Plan (the structured planning surface)

**Mental model:** the place you go to decide. Three tiers: monthly → weekly → daily timeline. Caps enforced (3/3/3). "Help me plan" is one click from any empty state.

### What lives on Plan

**Top row (monthly goals)**
- B15 Monthly goals (cap 3, identity color)
- B18 Edit monthly goal modal

**Middle row (weekly missions)**
- B16 Weekly missions (cap 3)
- B18 Edit mission modal
- B1 Intentions list — but reframed as "Mission templates" if user wants to reuse
- B7 Strictness preset (set per mission)
- B14 Weekly budget hours (schema fields — D9 deferred but field exists, shown as Hours target)

**Bottom (today's timeline)**
- B17 Daily sessions (drag-and-drop, 15-min snap, NOW indicator)
- B24 Today timeline strip (8am-8pm scroll, drag-to-create-session)

**Header toggles**
- Today / Week (replaces A4 from Today)
- Plan / Review (when a new week starts with last week's data — Review opens first)

**Floating actions**
- "+ Goal" (when < 3 monthly)
- "+ Mission" (when < 3 weekly, with anchor to monthly goal)
- "Help me plan" (always-visible button, primary in empty states)
- "Open today →" (navigates back to Today)

**Settings/contextual**
- Week start day preference (Open question — Section 7 of goal doc, Q1)
- Calendar zoom (A9 — moves here from Today)

**Embedded sub-surfaces**
- B19 "Help me plan" guided ritual (multi-step modal)
- B20 Weekly review (top of Plan when a new week starts with prior missions)
- B21 Monthly review (combined with weekly review last week of month)
- B23 Pattern insight card (shows at bottom of weekly review)

**Removed from Plan (vs Focus Modes today)**
- B5 Delete intention → still possible, but under edit modal trash icon (not a separate page)
- B11 Cancel pending strictness change → in edit modal
- B9 24h cool-down soften → removed if Soft removed; otherwise in edit modal "save" flow

### Plan's states (every state to sketch in `plan.html`)

1. **Empty (new month, no goals set)** — 3 dashed "Add monthly goal" placeholders + "Start ritual" prompt
2. **Monthly set, weekly empty** — monthly row populated, weekly row dashed, prompt "Review last week" + "Start ritual"
3. **Weekly partially planned** — some weekly cards filled, some dashed
4. **Fully planned (3 monthly + 3 weekly + timeline populated)** — full canonical view
5. **Drag mid-state** — dragging a mission down to today's timeline, visual snap targets visible
6. **Drag-complete (session created on timeline)** — new colored block appears
7. **Edit monthly goal modal** — Title / Done looks like / (color picker?) / Delete
8. **Edit weekly mission modal** — Title / Done looks like / For monthly goal pill picker / Hours target / Strictness picker / Delete
9. **"Help me plan" — step 1** — "What 1–3 things would make this week feel meaningfully better?"
10. **"Help me plan" — step 2** — "Which monthly goal does each connect to?"
11. **"Help me plan" — step 3** — "What would 'done' look like for each by Sunday?"
12. **"Help me plan" — step 4 (draft cards)** — 3 draft cards pre-filled, each editable inline, "Save 3 goals"
13. **Weekly review** — list of last week's missions with Done/Slipped/Dropped segmented per row, pattern insight at bottom, "Skip review" / "Plan this week →"
14. **Monthly review** — top section adds Complete/Continue/Drop/Replace per monthly goal; rest is weekly review
15. **Pattern insight expanded** — click insight to expand multi-week chart
16. **Strictness picker** — radio Standard / Strict with descriptions; Strict shows "Step-down requires partner unlock"
17. **Pending strictness change** — softening cool-down banner with "Cancel" link
18. **Cancel-pending confirmation** — small modal
19. **Strict → softer partner unlock flow (DEFERRED backend)** — UI shows "Couldn't reach partner" error state currently
20. **Carry-over prompt** — when uncompleted mission carries to next week (resolution TBD per open question 2)
21. **Multi-day timeline (FUTURE — open question 3)** — if Plan gets a multi-day view, this is the placeholder
22. **Delete monthly goal confirmation** — "All 2 linked weekly missions will become unlinked. Continue?"
23. **Delete weekly mission confirmation** — "1 session scheduled on today's timeline will be removed. Continue?"

### Buttons on Plan

| Button | Click action | Follow-on state |
|---|---|---|
| "+ Goal" | Opens edit monthly goal modal (empty) | State 7 |
| Monthly card → click | Opens edit monthly goal modal (populated) | State 7 |
| Monthly card → "Done looks like" inline text | Inline edit | (autosave on blur) |
| Monthly card → identity color | Color picker popover | Color persists, cascades to linked weeklies |
| Monthly card → trash icon | Delete confirmation modal | State 22 |
| "+ Mission" | Opens edit weekly mission modal (empty) | State 8 |
| Weekly card → click | Opens edit weekly mission modal (populated) | State 8 |
| Weekly card → "For monthly goal" pill | Opens dropdown picker | Pill picker, then save |
| Weekly card → strictness pill | Opens strictness picker | State 16 |
| Weekly card → "Hours target" +/− stepper | Adjusts hours | Autosaves |
| Weekly card → drag (hold left edge) | Initiates drag-to-timeline | Visual drag state (state 5) |
| Weekly card → trash icon | Delete confirmation | State 23 |
| Timeline block → click | Opens edit-session inline (start/end/duration) | Mini popover |
| Timeline block → drag body | Moves session | Live position update + autosave |
| Timeline block → drag edge | Resizes (snap to 15-min) | Live resize |
| Timeline → empty area click | Quick-add session modal | Modal: pick mission, time, duration |
| Timeline → NOW indicator | (passive, marks current time) | n/a |
| "Help me plan" | Opens guided ritual | State 9 |
| Guided ritual → Next | Advances step | State 10 → 11 → 12 |
| Guided ritual → Back | Reverses step | (previous state) |
| Guided ritual → "Save 3 goals" | Saves and closes ritual | Returns to populated Plan |
| Guided ritual → Cancel | Confirms discard | "Discard?" mini modal then closes |
| Weekly review → Done | Marks row Done | Save indicator |
| Weekly review → Slipped | Marks row Slipped | Save indicator + "Carry to next week?" toggle |
| Weekly review → Dropped | Marks row Dropped | Save indicator |
| Weekly review → "Skip review" | Closes review, opens Plan | (skip stamps so it doesn't reopen until next week) |
| Weekly review → "Plan this week →" | Closes review, opens empty weekly section in Plan | State 2 (or 9 via "Help me plan") |
| Monthly review → Complete/Continue/Drop/Replace | Per-row segmented action | Save + next-month rollover preview |
| Pattern insight → click | Expands chart | State 15 |
| "Open today →" header link | Navigates to Today tab | (tab switch) |
| Today/Week toggle | Switches timeline view | (view re-renders) |
| Plan/Review toggle (auto when new week) | Switches to review pane | State 13 |
| Carry-over prompt → "Yes, carry" | Carries mission to new week | (mission cloned with status reset) |
| Carry-over prompt → "No, drop" | Drops cleanly | (mission archived) |

---

## SURFACE 3 — Settings (defenses + app + account)

**Mental model:** the rules of the game. Two main sections: Defenses (the protections running on your behalf) and App (preferences). Plus Account at the bottom.

### What lives on Settings

**Section: Defenses**
- C7 Content protection toggle (NSFW screen monitoring)
- C8 Content Safety detection overlay (configured behavior — auto-dismiss grace period)
- C10 Partner notification on detection
- C12 Test detection button
- C13 Open System Settings link (for ScreenRecording permission)
- D1–D7 Accountability partner (email, name, status, resend, remove, sibling-sync)
- D4 Lock-Mode (None / Partner)
- D5 Enable Partner Lock button
- D8 Strict Mode toggle
- D10 Watchdog daemon status (read-only indicator)
- D13 Cmd+Q strict behavior (informational)
- D14–D17 Unlock flow (Request / Verify / Re-lock / Status)
- F1–F3 Puck (pairing status, pair button, test alarm — when wake alarm built F4+)
- E1–E2 Bedtime (toggle, times)
- E3 Bedtime config sync (informational, read-only "synced" pill)
- E4 Wind-down notifications (sub-toggle for which milestones to fire)
- A40–A41 Earned Browse (per Phase 4 open question — likely surfaced here as "Distraction budget" row)
- I1 Cross-device shared budgets (when built — shown as sub-toggle under Earned Browse)

**Section: AI & Coaching**
- A33 AI Model selector (Apple FM / Qwen)
- A34 Enable Daily Focus Plan (schedule engine on/off)
- A35 Focus Enforcement mode (nudge vs block)
- A36 Per-block enforcement toggles (6 mechanisms × 2 block types)
- A38 Intervention toggles
- A46 Coach Context (moved from Today) — "About you" + optional "Today plan" free-text
- A47 Focus profile editor
- A31 AI Assessments log button → opens log viewer modal
- A32 Export Relevance Log

**Section: Schedule (legacy — replaced by Plan, but some controls live here)**
- A52 Always-allowed apps list (editor)
- A53 Always-blocked apps list (editor)
- A54 Distracting apps list (legacy editor — may be removed if BlockingProfileManager removed)
- K4 BlockingProfileManager (Distractions list) — until removal, lives here as "Default block profiles"

**Section: App**
- H7 Theme picker (Deep Lush / Iridescent / Warm / etc.)
- H8 Open on login
- H9 Notifications
- H10 Sound effects toggle + preview
- A24 Pill position reset (right side of screen)
- A45 Block ritual variant picker (8 variants)
- A44 Default if-then plan picker
- H17–H18 Browsers (per-browser status + Open Extensions Page)
- H22 Native messaging setup (informational + "Re-install manifests" button)
- H14 Debug Monitor (moved to dev section / removed)

**Section: Account**
- H5 Account info (email / member since / devices)
- H6 Subscription status (Stripe)
- H3 Sign out
- H4 Delete account
- H15 Reset all settings
- H23 Usage history view
- H24 Sessions journal

### Settings' states (every state to sketch in `settings.html`)

1. **Index view (all defenses + app + account rows visible)** — main settings page
2. **Defenses section expanded** — shows all defense rows with state pills
3. **AI section expanded** — model selector, enforcement, coach context
4. **App section expanded** — theme grid, toggles, sound preview
5. **Account section expanded** — info + sign-out + danger zone
6. **Theme picker modal** — grid of theme tiles with previews
7. **AI model selector modal** — Apple FM vs Qwen with descriptions
8. **Coach Context editor** — full-page editor (textarea-style)
9. **Enforcement grid editor** — 6×2 matrix of toggles
10. **Intervention toggles** — per-intervention list with descriptions
11. **Distractions list editor (legacy)** — per-profile editor (until deprecated)
12. **Always-allowed apps editor** — search + add + remove
13. **Always-blocked apps editor** — same
14. **Browsers list** — per-browser status with "Open Extensions Page"
15. **Manage Partner modal** — partner detail with resend / remove
16. **Resend invite confirmation** — small confirm
17. **Remove partner confirmation** — small confirm + warning ("She'll lose access to your defenses")
18. **Lock-Mode change confirmation** — "Switching to None disables partner gating. Continue?"
19. **Strict Mode enable confirmation** — "You won't be able to disable Intentional without partner approval. Continue?"
20. **Strict Mode disable — partner unlock flow** — request → code entry → success/fail
21. **Bedtime time picker** — start time / end time (replaces hard-coded labels)
22. **Bedtime active-days picker** — Mon-Sun pills
23. **Wind-down notification picker** — which milestones to fire
24. **Puck pair modal** — instructions + waiting-for-tap state + success/fail
25. **Puck test alarm modal** — fires alarm, user taps Puck to confirm
26. **Earned Browse / Distraction budget config** — per-platform minutes per day, multiplier, reset time
27. **Pill position reset confirmation** — "Move pill back to top-right?"
28. **Block ritual variant picker** — gallery of 8 variants
29. **Default if-then plan picker** — list of N preset plans
30. **Notifications detail** — per-event toggle list
31. **Sound effects detail** — per-event sound picker + preview button
32. **AI Assessments log viewer** — scrollable list of verdicts with timestamps, "Export" button
33. **Subscription detail** — plan / renewal date / "Manage subscription" link
34. **Sign-out confirmation** — small confirm
35. **Delete account flow** — multi-step: warning → confirmation → final confirm → goodbye screen
36. **Reset all settings confirmation** — multi-step: warning → confirmation
37. **Uninstall flow** — request partner code → code entry → final goodbye
38. **Usage history viewer** — bar chart (7-day default) + per-app breakdown
39. **Sessions journal** — list of past sessions with dates / durations / focus scores
40. **Permission re-prompt** — Accessibility / Screen Recording / Notifications

### Buttons on Settings

Each row in Settings has 1–3 controls. Comprehensive table below.

| Row | Button / Control | Click action |
|---|---|---|
| Content protection | Toggle | ON/OFF — immediately syncs to backend |
| Content protection | "Test" button | Triggers fake detection through pipeline |
| Content protection | "Permission needed" banner → "Grant" | Opens TCC pane |
| Accountability partner | "Manage" link | Opens manage modal (state 15) |
| Accountability partner | "Resend invite" | State 16 |
| Accountability partner | "Remove" | State 17 |
| Lock-Mode | Picker (None / Partner) | State 18 |
| Strict Mode | Toggle ON | State 19 |
| Strict Mode | Toggle OFF (when ON) | State 20 |
| Bedtime | Toggle | ON/OFF |
| Bedtime | Start time | State 21 |
| Bedtime | End time | State 21 |
| Bedtime | Active days | State 22 |
| Bedtime | Wind-down toggles | State 23 |
| Puck | "Pair" button (when not paired) | State 24 |
| Puck | "Test alarm" (when paired) | State 25 |
| Puck | "Unpair" (when paired) | Confirm modal |
| Distraction budget | "Configure" | State 26 |
| AI Model | Picker | State 7 |
| Coach Context | "Edit" | State 8 |
| Focus profile | Inline textarea | Autosave on blur |
| Enable Daily Focus Plan | Toggle | ON/OFF |
| Focus Enforcement | Picker | nudge / block |
| Per-block enforcement | "Edit" → matrix | State 9 |
| Intervention toggles | "Edit" → list | State 10 |
| AI Assessments | "View log" | State 32 |
| AI Assessments | "Export" | Opens Finder with file |
| Theme | "Change" → grid | State 6 |
| Open on login | Toggle | ON/OFF |
| Notifications | Toggle + "Details" | State 30 |
| Sound effects | Toggle + "Configure" | State 31 |
| Pill | "Reset position" | State 27 |
| Block ritual variant | "Change" | State 28 |
| Default if-then plan | "Change" | State 29 |
| Browsers | "Open Extensions Page" | Opens Web Store URL |
| Account | "Sign out" | State 34 |
| Account | "Delete account" | State 35 |
| Account | "Subscription" | State 33 |
| Reset & Delete | "Reset all settings" | State 36 |
| Reset & Delete | "Uninstall Intentional" | State 37 |
| Usage history | "View" | State 38 |
| Sessions journal | "View" | State 39 |

---

## SURFACE 4 — Floating pill (persistent overlay)

Lives independently of any tab. Driven by FocusMonitor + BedtimeEnforcer.

### Pill modes to sketch in `pill.html`

1. **`.timer`** — 300×70, MM:SS countdown, dot color (indigo / red / green)
2. **`.timer` recovery** — 3s motivational message takeover after returning to relevant content
3. **`.timer` distraction card** — "Not related" + "Back to Task" inline (8s auto-dismiss)
4. **`.blockComplete`** — amber, "Block complete · 0:00"
5. **`.celebration` — Session Complete card** — duration + earned minutes
6. **`.celebration` — Focus Score card** — % + bar + Lottie confetti (≥80%)
7. **`.celebration` — App Breakdown card** — top 6 apps by time
8. **`.celebration` — Up Next card** — conditional, back-to-back only, with Start button
9. **`.celebration` — skip link** — bottom of carousel
10. **`.startRitual`** — green border, "Up next: TITLE" + Start + Edit (460×160)
11. **`.startRitual` auto-start countdown** — 3 min for work, 30s for free
12. **`.startRitualEdit`** — title/desc/type fields + Done (460×340)
13. **`.startRitualEdit` empty title rejection** — toast "Title required"
14. **`.noPlan` — noPlan substate** — quick blocks + Plan Day
15. **`.noPlan` — gap substate** — block list + Schedule Now
16. **`.noPlan` — allCaughtUp substate (before 9 PM)** — stats + Schedule More
17. **`.noPlan` — doneForDay substate (9 PM+)** — green "DAY COMPLETE"
18. **`.bedtimeWindDown` — T-30 (minimize allowed)** — moon glyph + countdown
19. **`.bedtimeWindDown` — T-15 / T-10 / T-5 / T-1** — progressively more visible
20. **`.bedtimeLocked`** — lock glyph + "Bedtime active — locked until 6:30 AM" + Ask Partner
21. **`.bedtimeLocked` after Ask Partner pressed** — shows "request sent" state
22. **Pill minimize to dock** — dock icon with badge
23. **Pill drag-to-move** — drag handle visible on hover

### Pill buttons

| Pill state | Button | Action |
|---|---|---|
| any | drag handle | Move pill, position persists |
| any | minimize (-) | Minimize to dock |
| `.timer` distraction card | "Back to Task" | Restore last-relevant tab, dismiss card |
| `.startRitual` | Start | Begin session, transition to `.timer` |
| `.startRitual` | Edit | Open `.startRitualEdit` |
| `.startRitualEdit` | Done | Save, return to `.startRitual` + auto-start |
| `.startRitualEdit` | Cancel | Return to `.startRitual` |
| `.celebration` | carousel dots | Manual advance |
| `.celebration` | skip | End celebration, transition to next |
| `.celebration` Up Next card | Start | Begin next session immediately |
| `.noPlan` | 15/30/60 min quick block | Start quick block |
| `.noPlan` | "Plan Day" | Open Plan tab |
| `.noPlan` | "Schedule Now" | Open Plan tab with new-session pre-populated |
| `.noPlan` | Snooze | Hide pill for 30 min |
| `.noPlan` | dismiss (-) | Minimize to dock |
| `.bedtimeWindDown` T-30 | minimize | Allowed; pill hides until T-15 |
| `.bedtimeLocked` | Ask Partner | Open bedtime unlock-request sheet |

---

## SURFACE 5 — Overlays (modals, full-screen, transient)

Sketched in `overlays.html` and `rituals.html` (split because rituals deserve full-screen treatment of their own).

### Modal overlays (in `overlays.html`)

1. **Mode picker** — list of intentions/missions, search, recent
2. **Strictness picker** — Standard vs Strict with descriptions
3. **"Block now (no mission)" config** — duration + strictness + apps to block
4. **5-min break confirmation** — confirm + start
5. **Add-to-today / quick-add session** — pick mission + start time + duration
6. **End session early — Strict** — "You're in Strict. Ask partner to end?" + "Cancel" / "Ask Partner"
7. **End session early — Standard** — "Are you sure? You're 12 min in." + Cancel / End
8. **Partner unlock request** — sent state with "Waiting for Caity..."
9. **Partner unlock code entry** — 6 boxes for code + "Resend"
10. **Partner unlock success** — green check + "Unlocked for 30 min"
11. **Partner unlock fail** — red x + "Wrong code. Try again."
12. **Calendar block editor (legacy, replaced by Plan timeline)** — kept for compatibility
13. **Per-block AI assessments panel** — inline expand on a done session
14. **Intention setup form** — name + blocklist + strictness (legacy; will fold to Mission edit)
15. **Status footer popover — Partner** — partner detail
16. **Status footer popover — Content** — content protection detail
17. **Status footer popover — Puck** — Puck detail
18. **Status footer popover — Strict Mode** — Strict detail + unlock CTA
19. **Bedtime unlock-request sheet** — full duration slider + code entry
20. **Intention strictness unlock sheet** — same view, no slider
21. **Confirmation: "Discard plan ritual?"** — for "Help me plan" cancel
22. **Permission re-prompt** — Accessibility / Screen Recording / Notifications
23. **Onboarding step 1: Welcome** — single-screen value prop
24. **Onboarding step 2: Lock mode** — None / Partner picker
25. **Onboarding step 3: Partner email** — email input + invite
26. **Onboarding step 4: Theme** — theme grid
27. **Onboarding step 5: Permissions** — required permissions list + grant
28. **Onboarding step 6: Connect Puck (optional)** — pairing instructions
29. **Onboarding step 7: Coach Context** — "Tell me about your work" textarea
30. **Onboarding complete** — "You're set" + "Set today's first plan →"
31. **Login: email entry** — email input + magic link
32. **Login: code entry** — 6 boxes for code
33. **Daemon-degraded banner expanded** — re-grant instructions inline

### Full-screen overlays / rituals (in `rituals.html`)

1. **Wake-up: alarm fired** — "Good morning. Tap Puck to wake." + alarm name + pulsing visual
2. **Wake-up: alarm + bypass attempt** — "Phone power-off prevented" (if we can detect it) or graceful failure: "Tap Puck to dismiss"
3. **Wake-up: after Puck tap** — transition to morning ritual
4. **Morning ritual = "Help me plan" step 1** — first question full-screen
5. **Morning ritual = step 2 / 3 / 4** — progressively
6. **Morning ritual = draft cards saved → "Today is ready"** — exit + Today loads with plan visible
7. **Block start ritual (legacy BlockRitualController full-screen variant)** — focus question, if-then, slider, Start
8. **Block end ritual / celebration full-screen (BlockEndRitualController variant)** — 3 cards: reflection + self-assessment + AI verdict log
9. **Context-switching countdown overlay** — full-screen, "5… 4… 3… Back to work" + "Continue anyway"
10. **Focus blocking overlay** — "Back to work" + "Why?" disclosure + "Approve for this block" + "This was wrong"
11. **Intervention exercise — Scrambled Words** — puzzle + 60/90/120s timer
12. **Intervention exercise — Reflect & Commit** — text prompt + timer
13. **Tamper overlay** — "Settings were tampered. We've restored them." + OK
14. **Content Safety detection overlay** — "Take a breath" + auto-dismiss
15. **Content Safety permission overlay** — "Re-grant permission" + open System Settings
16. **Focus Start overlay (Cmd+Shift+P / Puck / WS)** — profile chips + intention text + AI scoring toggle + Start + Cancel
17. **Grayscale / vignette overlay (deep-work)** — passive, no controls
18. **Bedtime OS lock screen** — (system, not us) every 10s

### Overlay buttons (selection)

| Overlay | Button | Action |
|---|---|---|
| Mode picker | Mission row → click | Pick this mission, advance to strictness picker |
| Mode picker | "+ Quick block (no mission)" | Open Block-now config |
| Strictness picker | Standard | Save + start |
| Strictness picker | Strict | Save + show "you'll need partner to end early" + start |
| Block-now config | Start | Begin session bound to no mission |
| End-early Standard | End | End session, transition to celebration |
| End-early Strict | Ask Partner | Open partner unlock request |
| Partner unlock request | Cancel | Close, return |
| Partner unlock code entry | Submit | Verify code |
| Partner unlock code entry | Resend | Re-trigger code email |
| Bedtime unlock sheet | Duration slider | Pick 15/30/60/120/until-wake |
| Bedtime unlock sheet | Send request | Sends to partner |
| Status footer popover | "Request unlock" / "Pair" / "Test" / "Settings" | Routes accordingly |
| Onboarding step | Next | Advance |
| Onboarding step | Back | Reverse |
| Onboarding final | "Set today's first plan →" | Navigate to Plan + open "Help me plan" |
| Wake-up overlay | (physical Puck tap) | Trigger transition |
| Morning ritual | Next / Back / Skip | Advance / reverse / abandon |
| Block start ritual | Start / Edit / Push Back | Begin / edit details / delay |
| Celebration carousel | dots / skip | Manual control |
| Context-switch overlay | Back to work | Restores app |
| Context-switch overlay | Continue anyway | Allows (counts against budget) |
| Focus blocking overlay | Back to work | Closes overlay, restores focus |
| Focus blocking overlay | Why? | Inline disclosure |
| Focus blocking overlay | Approve for this block | One-time override |
| Focus blocking overlay | This was wrong | Marks as false positive (feeds back) |
| Intervention | (puzzle completion) | Auto-advances when solved + timer elapsed |
| Tamper overlay | OK | Dismiss |
| CS detection overlay | (auto-dismiss) | n/a |
| CS permission overlay | Open System Settings | Opens TCC pane |
| Focus Start overlay | Start | Activate FocusModeController |
| Focus Start overlay | Cancel | Dismiss |
| Grayscale | (none, click-through) | n/a |

---

## SURFACE 6 — Menu bar icon

Always present. Right-click menu.

### Menu items
- Status (read-only, e.g. "Focus active · 36 min left")
- Show Window (→ opens main window)
- Debug Monitor (⌘M) — moved to dev section / removed (K16)
- Open Dashboard — same as Show Window
- Toggle Focus (⌘⇧P) — triggers FocusStartOverlay or stops current session
- Quit — partner-gated if Strict Mode ON, else direct quit

### Menu bar states
1. **Idle (no session)** — gray icon
2. **Focus active** — colored icon (mission color)
3. **Bedtime wind-down** — moon icon
4. **Bedtime locked** — lock icon
5. **Permission missing** — yellow exclamation icon

---

## SURFACE 7 — In-browser pages (rendered inside browser, not our app)

- A55 `focus-blocked.html` — "Blocked by Intentional" page shown on blocked tab redirect
- A55 `blocked.html` — older variant
- These are static HTML, not in our design scope but listed for completeness.

---

## Cross-check — every feature placed

This section explicitly maps every numbered feature from `feature-inventory.md` to its surface in this doc. **No orphans allowed.**

### Category A — Focus enforcement
- A1 → Plan (Mission templates) + Today (mode picker)
- A2 → Settings → Schedule (legacy) or Defenses (Distractions list)
- A3 → Plan (the timeline)
- A4 → Plan (Today/Week toggle)
- A5, A6 → Plan (add via mission drag or Plan empty-area click)
- A7 → Plan (edit session on timeline)
- A8 → Today (click a done session in missions list)
- A9 → Settings → App
- A10 → Plan (calendar nav)
- A11 → Today (Now card / Focus Lock toggle)
- A12 → fires automatically; sketched in overlays.html
- A13 → Pill `.timer` distraction card sketch
- A14 → overlays.html (NudgeWindow toast)
- A15–A19 → Pill `.startRitual` modes + celebration
- A20–A23 → Pill modes (pill.html)
- A24 → Settings → App (pill position reset) + pill drag itself
- A25–A27 → Pill `.noPlan` modes
- A28 → rituals.html (passive overlay) + Settings → AI (enable toggle if exposed)
- A29 → rituals.html (Focus Start overlay)
- A30 → Today (Now card AI sub-label) + Settings → AI (model selector)
- A31 → Settings → AI (AI Assessments log)
- A32 → Settings → AI (Export)
- A33 → Settings → AI (Model picker)
- A34 → Settings → AI (Daily Focus Plan toggle)
- A35 → Settings → AI (Enforcement mode)
- A36 → Settings → AI (per-block enforcement grid)
- A37 → rituals.html (Intervention exercise overlay) + Settings → AI (toggles)
- A38 → Settings → AI (Intervention toggles)
- A39 → rituals.html (Tamper overlay)
- A40 → Settings → Defenses (Distraction budget)
- A41 → DEPRECATE (hidden widget — replaced by Status footer budget pill)
- A42 → Settings → Defenses (Extra Time request from budget detail)
- A43 → Plan (Mission edit modal — "Promote learned site")
- A44 → Settings → App (default if-then plan)
- A45 → Settings → App (block ritual variant)
- A46 → Settings → AI (Coach Context editor — moved from Today)
- A47 → Settings → AI (Focus profile editor)
- A48 → DEPRECATE (replaced by Today's missions list)
- A49–A55 → Background; informational rows in Settings → Defenses for status
- A56 → All surfaces (in-app toast pattern)
- A57 → DEPRECATE (will be restored as wake-up ritual entry point)

### Category B — Intentions / Missions / Goals
- B1–B5 → Plan (mission CRUD lives there)
- B6 → Today (Start mission from mission row)
- B7–B11 → Plan (strictness picker in edit modal)
- B12 → overlays.html (unlock sheet)
- B13 → DEPRECATE (Weekly Planning placeholder)
- B14 → Plan (Mission edit modal — Hours target field maps to weeklyBudgetHours)
- B15–B24 → Plan (all the new planning system features)

### Category C — Sensitive content
- C1–C6 → Background (informational status in Settings → Defenses)
- C7 → Settings → Defenses (Content protection toggle)
- C8–C9 → rituals.html (detection overlay) + overlays.html (permission overlay)
- C10 → Settings → Defenses (Partner notification sub-row)
- C11 → Background (informational; surfaces via Tamper overlay)
- C12 → Settings → Defenses (Test button)
- C13 → Settings → Defenses (banner action)
- C14 → Background
- C15 → DEPRECATE as sidebar page (folded into Settings → Defenses)
- C16 → Settings → Defenses (single home, not duplicated)

### Category D — Accountability + Strict
- D1–D7 → Settings → Defenses (Partner row + Manage modal)
- D8–D17 → Settings → Defenses (Strict Mode + Unlock flow)
- D18 → overlays.html (Bedtime unlock sheet)
- D19 → overlays.html (Intention strictness unlock sheet — backend deferred)
- D20–D21 → rituals.html (Tamper overlay)
- D22 → DEPRECATE (Self lock mode)
- D23 → Settings → Account (Uninstall)

### Category E — Bedtime
- E1–E2 → Settings → Defenses (Bedtime row + time picker)
- E3 → Settings → Defenses (informational sync pill)
- E4 → Settings → Defenses (wind-down sub-toggles)
- E5–E6 → Pill modes (pill.html)
- E7 → Background (lock-loop) — informational in Settings
- E8 → overlays.html (bedtime unlock sheet)
- E9 → Background
- E10 → **TO DESIGN** (rituals.html wake-up flow — Cat 4 still partially open)
- E11 → **TO DESIGN** (cross-device wake sync)
- E12 → Background (one-time migration)

### Category F — Puck
- F1 → iOS-side (informational status row in Settings → Defenses)
- F2 → Background (informational)
- F3 → rituals.html (Focus Start overlay)
- F4–F6 → **TO DESIGN** (Cat 4 wake-up flow in rituals.html)

### Category G — Cross-device sync
- G1–G11 → Background; status pills in Settings → Defenses where relevant
- G12 → DEPRECATE (BlockingProfileManager — fold into Settings as legacy "Default profiles" until removed)
- G13 → KNOWN GAP — surfaced in open questions (Earned Browse cross-device)
- G14 → KNOWN GAP — surfaced in open questions (iOS Alarms)
- G15 → KNOWN GAP — surfaced in open questions (Schedule unification)
- G16 → KNOWN GAP — Settings → Defenses informational

### Category H — Account / app
- H1 → overlays.html (Onboarding sequence)
- H2 → overlays.html (Login sequence)
- H3–H6 → Settings → Account
- H7 → Settings → App (Theme picker)
- H8–H10 → Settings → App
- H11–H13 → Menu bar (no separate surface)
- H14 → DEPRECATE / hide behind dev menu
- H15 → Settings → Account
- H16 → Settings → Defenses (banner action)
- H17–H18 → Settings → App (Browsers row)
- H19 → onboarding + Settings → App (Permission re-prompt as needed)
- H20 → Background
- H21 → Today (banner)
- H22 → Settings → App
- H23 → Settings → Account (Usage history)
- H24 → Settings → Account (Sessions journal)
- H25 → All pages (in-app toast pattern)

### Category I — Planned
- I1 → Settings → Defenses (Distraction budget cross-device sub-toggle when built)
- I2 → Plan ("Help me plan" intelligence + adaptive re-plan)
- I3 → Today (drift redirect overlay UX upgrade)
- I4–I5 → Today (Status footer + popovers)
- I6 → Today (bedtime / end-of-day hero state)
- I7 → Plan (adaptive re-plan logic — surfaces as button on Today "Replan rest of day")
- I8 → Onboarding + Plan empty states

### Category K — Deprecation
- All K rows tracked in `open-questions.md` Phase 4 with explicit "remove / keep until X" disposition.

---

**No orphans.** Every feature in `feature-inventory.md` is placed in exactly one surface above (or marked DEPRECATE in K).

The HTML sketches in Phase 3 will visualize the placements in this doc, state by state, button by button.

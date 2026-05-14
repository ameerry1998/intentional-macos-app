# Open Questions — Resolved (2026-05-13)

> **Phase 4 deliverable.** Every open question from the goal doc (Section 7) and any discovered during Phases 1–3, with a recommendation, rationale, and whether user input is still required.

---

## From the planning system spec

### Q1. Week start day — Monday default + Settings preference, or system-determined?

**Recommendation:** **Monday default, with a Settings preference (Mon/Sun)**. Do NOT auto-detect from system locale in v1.

**Rationale:** Monday is the canonical "work week start" for our ICP (young male knowledge workers). Sunday-start would feel like a calendar app, not a work tool. A settings preference covers the minority who genuinely think in Sun-Sat weeks. System-detection is over-engineering and adds an obscure failure mode (locale changes mid-week → user confused).

**User input needed:** No. Default applied; preference is one row in Settings → App.

---

### Q2. Goal carry-over when uncompleted — auto-suggest or await user decision?

**Recommendation:** **Auto-prompt during weekly review, defaults to "carry as-is"**. Three options: Carry as-is / Edit before carrying / Drop.

**Rationale:** ADHD users will not remember to make a decision. The prompt forces a small choice. "Carry as-is" is the default because aspiration-momentum is good; the user explicitly chooses to drop if they want. "Edit before carrying" handles the common case where the goal is right but the scope was wrong.

**User input needed:** No.

---

### Q3. Cross-day scheduling — multi-day Plan timeline, or navigate Today forward?

**Recommendation:** **v1: Today timeline only on Plan. Multi-day view DEFERRED.** Cross-day scheduling happens via the calendar block editor (you can pick a non-today start time). Today-tab calendar navigation (← →) lets you preview tomorrow's plan.

**Rationale:** Multi-day grid is significantly more design work and the ICP doesn't actually plan a full week of sessions in advance — they plan the week's missions (which the weekly missions row already does) and let today-me schedule the day. v1.5 candidate.

**User input needed:** No. Confirm DEFERRED status.

---

### Q4. Monthly goal mid-month editing — locked or freely editable?

**Recommendation:** **Freely editable. Editing the title or color cascades to all linked weekly missions automatically.** Deletion shows the cascade impact in the confirmation modal.

**Rationale:** Locking would punish refinement and force users to delete + recreate (loses history). Cascading is the visual-continuity principle — color and identity should stay coherent across the hierarchy. The "Done looks like" field is the only field that doesn't cascade (it's goal-level, not mission-level).

**User input needed:** No.

---

### Q5. Voice input in "Help me plan" — v1 scope or text-only with mic icon for direction?

**Recommendation:** **v1: text-only with 🎙 icon present as direction.** Voice arrives in v1.5 after AlarmKit / wake-flow research lands.

**Rationale:** Voice is non-trivial (macOS Speech framework permissions, transcription quality, multilingual). Shipping text-first lets us validate the planning ritual itself before adding voice complexity. The icon signals direction so it's not a surprise when added.

**User input needed:** No.

---

## From the v0 unification sketch

### Q6. Default tab on launch — Today or Plan?

**Recommendation:** **Today, except first launch of a new week with last week's missions still set, where Plan opens directly to the weekly review.**

**Rationale:** Today is the daily living surface — that's where most launches happen. Plan is the deliberate-go-there surface. Weekly review is the one case where the user needs to be forced into Plan before Today is useful.

**User input needed:** No.

---

### Q7. Status footer — three items or more?

**Recommendation:** **Three by default (Partner, Content, Puck). Add Strict Mode as a fourth when active. Earned Browse / Distraction budget surfaces as a status pill only when the user is actively spending budget (not when they're at full pool).**

**Rationale:** Footer real estate is limited. The three always-on defenses are the differentiators. Strict Mode adds visual weight when on (justifies its own slot). Budget is contextual (only relevant when actively spending).

**User input needed:** No.

---

### Q8. Are existing users prepared to lose "Focus Modes" as a sidebar tab? Migration message?

**Recommendation:** **Yes, but show a one-time banner on Today: "Focus Modes moved to Plan. You can find your intentions there."** Banner has a "Got it" dismiss. Survives until clicked or 7 days, whichever first.

**Rationale:** Existing users have muscle memory for the Focus Modes tab. A silent migration would frustrate them. A one-time banner respects them.

**User input needed:** No.

---

### Q9. How loud should the "Now" card be visually when Strict is active?

**Recommendation:** **Red-tinted background + red STRICT pill + drops "End early" button (replaced with "Ask partner to end early" with red icon).** Same width and height as Standard — only color and copy change.

**Rationale:** Strict shouldn't physically dominate the screen — it should feel different but not punitive. The button-copy change does more cognitive work than visual loudness.

**User input needed:** No.

---

## From the four-category framing

### Q10. Cat 3 partner notification — instant ping, daily digest, or weekly digest?

**Recommendation:** **Instant ping for detection events (porn / tamper / bedtime bypass attempt). Daily digest for "you were focused X hours, drift count, mission progress."** Two channels, two purposes.

**Rationale:** Detection events are urgent (the trust contract needs them visible immediately). Productivity summaries are reflective (better as a digest the partner can review when convenient). Users can configure both in Settings (Partner row → Notification preferences).

**User input needed:** No, but consider whether the partner can opt OUT of instant pings (i.e., partner-side preference, not user-side). That's a sibling-sync concern.

---

### Q11. Cat 4 wake — what to spec while AlarmKit research is pending?

**Recommendation:** **Spec the visible flow (alarm fires → tap Puck → enter ritual → unlock phone). Leave the anti-bypass implementation TBD with explicit notes. Ship visible behavior in v1 with the known phone-off bypass; close the gap in v1.5 once AlarmKit research is back.**

**Rationale:** Visible UX is decoupled from anti-bypass tech. We can ship the morning ritual loop now and harden the alarm later. Without that decoupling, the entire planning ritual is gated on iOS research.

**User input needed:** Wait — run the Perplexity prompt drafted on 2026-05-13. Result determines whether v1 ships with phone-off bypass acknowledged or not.

---

### Q12. Cat 1 — "Block now (no mission)" first-class on Today or only via Quick Actions?

**Recommendation:** **Only via Quick Actions on Today (the "Block now" button in the row).** Not a primary action.

**Rationale:** Promoting "Block now (no mission)" too prominently weakens the missions-not-channels reframing. Quick Actions is fine — it's there when needed, not in your face.

**User input needed:** No.

---

## From the missions-not-channels reframe

### Q13. Rename "Focus Modes" to "Missions" in the UI?

**Recommendation:** **YES — rename throughout the UI. Backend table can stay `intentions` (no migration needed). Sidebar label uses "Missions" or just "Plan" (since Plan absorbs Focus Modes).**

**Rationale:** "Focus Modes" was always a placeholder name for what they actually are. "Missions" maps directly to the mental model (a specific task tied to a goal). Cleaner conceptual mapping. The migration-message banner (Q8) absorbs the rename for existing users.

**User input needed:** **YES — minor ambiguity.** Confirm:
- Sidebar label: "Plan" (matches the goal hierarchy nicely)
- Internal terminology: "Missions" (used throughout copy, tooltips, AI prompts)
- Backend table: `intentions` (no change — internal only)

The sketches above use "missions" consistently. Adjust if you prefer different terminology.

---

### Q14. Where do month-level Goals appear visually — only on Plan, or also as a ladder-up line on every active session?

**Recommendation:** **Both. Plan shows the full goal cards at the top. Today's active Now card shows a "Toward 'goal name' · 6h of 16h done" subtitle.** Reinforcement at every visible moment.

**Rationale:** ADHD users benefit from constant reminder of the why. The subtitle is low-cost visually (one line) but high-value cognitively.

**User input needed:** No.

---

### Q15. Strictness — does it live on Mission or Session?

**Recommendation:** **On the Mission (one strictness per mission). Sessions inherit. Quick-block "Block now (no mission)" gets its own strictness picker at start time.**

**Rationale:** Strictness is a property of "how you want to defend this work" — that's a mission-level concern, not session-level. Inheritance keeps it simple. Quick-blocks are ad-hoc so they need their own picker.

**User input needed:** No.

---

## From the existing Mac app (Phase 1 audit)

### Q16. Coach Context box — keep on Today, move to Settings, or fold into "Help me plan"?

**Recommendation:** **Move to Settings → AI & Coaching. Fold the "today plan" sub-row into the morning planning ritual (where it's actually used).**

**Rationale:** Coach Context is configuration, not daily-loop. The "today plan" sub-row never made sense on Today (it was redundant with the calendar). The morning ritual is where context-setting actually fits.

**User input needed:** No.

---

### Q17. AI Assessments log — keep visible somewhere or hide behind a dev/debug menu?

**Recommendation:** **Visible in Settings → AI & Coaching → "AI assessments". Default collapsed. Useful for debugging false positives.** Not on Today.

**Rationale:** It's useful when investigating "why did the AI block this?" but not part of daily flow. Settings is the right home.

**User input needed:** No.

---

### Q18. "+ Focus" / "+ Free Time" buttons on the current schedule — replaced or kept as Today shortcuts?

**Recommendation:** **Replaced entirely by Plan tab's drag-to-timeline + Today's "Add to today" quick action.** Remove the buttons from Today's calendar header.

**Rationale:** Two ways to add a session is one too many. The new model is: missions are scheduled via Plan; ad-hoc additions via Today's Quick Action.

**User input needed:** No.

---

### Q19. Distractions list / BlockingProfileManager — where does it live?

**Recommendation:** **For v1: Settings → Schedule → "Default block profiles" (kept until BlockingProfileManager is fully removed). Each mission can override its own block list (already supported via Intention.macWebsites + macBundleIds in Spec 1).**

**Rationale:** BlockingProfileManager is deprecated per Spec 1 D14 — keep its UI in Settings as a legacy editor until ≥2 weeks of stability lets us remove it.

**User input needed:** No, but flag: this is genuinely cleanup work that should land before public launch.

---

### Q20. Earned Browse / Distraction Budget — surface where?

**Recommendation:** **Three places:**
1. **Settings → Defenses → "Distraction budget"** row (configuration: rate, cap, reset time, cross-device sync toggle).
2. **Today status footer** — show as a status pill only when user has spent < 100% of budget (e.g., "20m left in budget · ON").
3. **Pill widget** — when actively spending budget (browsing a distraction site within budget), pill shows minutes remaining inline.

**Rationale:** The mechanic shouldn't be hidden (currently `display:none`). But it also shouldn't be loud. Show it where the user is *spending* it. Configuration lives in Settings.

**User input needed:** **YES — minor.** Confirm we want to re-surface this. The CLAUDE.md note "stripped for Puck model" suggests it was intentionally hidden. Decide:
- (a) Keep hidden and remove pipeline (cleanest)
- (b) Re-surface as proposed above (recommended)
- (c) Re-surface only in Settings, no status pill

---

## Discovered during Phase 1–3 audit

### Q21 (new). The 4 "Focus Mode" naming collision (per inventory synthesis §2)

**Recommendation:** **Resolve as follows:**
- (a) `FocusModeController.state` → unchanged, technical concept, never user-facing
- (b) Sidebar "Focus Modes" tab → DELETED in this design (folded into Plan as Missions)
- (c) Settings → Focus Mode → Screen Lock toggle (dead `IntentionalModeController`) → DELETED entirely
- (d) Today's "Focus Mode" toggle → renamed **"Focus Lock"** (per user's verbal intent) and lives as the Now card's headline action

**User input needed:** **YES — naming.** Confirm "Focus Lock" as the public name for (d). The sketches above use "Focus Lock" terminology.

---

### Q22 (new). `.allCaughtUp` NoPlanData state — referenced in memory but enum may not have it

**Recommendation:** **Add the enum case (it's referenced in code and represents real user state).** It distinguishes "day is done before 9pm" (positive, schedule-more option visible) from "day is done at 9pm+" (just say good night).

**User input needed:** No. Engineering decision.

---

### Q23 (new). Schedule unification across Mac and iPhone (inventory synthesis §5)

**Recommendation:** **Mac migrates to backend `/schedule/blocks` format (canonical). iPhone already uses it.** Mac's local `daily_schedule.json` becomes a cache only. This is significant engineering work but it's the only path to one schedule across devices.

**User input needed:** **YES — scope.** This is multi-week engineering work and touches the core scheduling primitives. Confirm priority: ship before v1 launch, or v1.1 follow-up?

---

### Q24 (new). BlockingProfileManager cross-device sync (currently Mac-only)

**Recommendation:** **DEPRECATE. Per Spec 1 D14, BlockingProfileManager is a one-cycle holdover. Remove in this design pass — fold its data into per-Intention/Mission blocklists which are already cross-device.**

**User input needed:** No — already designated for removal.

---

### Q25 (new). Iridescent/Warm/Light themes — keep all in slice-10 theme picker?

**Recommendation:** **Keep Deep Lush + Iridescent. Remove Warm and Light from v1 launch.** Limit choice; the visual identity is anchored to Deep Lush.

**User input needed:** Confirm. The current app supports all four; the slice-10 picker shows them all.

---

### Q26 (new). Onboarding step ordering for new users with no partner

**Recommendation:** **Skip-able partner step.** If user picks "Lock Mode: None" in step 2, the partner step (step 3) is skipped automatically. Re-enable by going to Settings → Defenses → Accountability.

**User input needed:** No.

---

### Q27 (new). What happens at midnight (day rollover)?

**Recommendation:** **Day rolls over at 4 AM local time (not midnight).** The "Today" tab shows the new day's plan starting at 4 AM. Sessions before 4 AM count toward the previous day.

**Rationale:** 4 AM is the safe rollover for night-owls. Midnight rollover would frustrate users still working a late session.

**User input needed:** No.

---

### Q28 (new). Stripe subscription gating

**Recommendation:** **Free tier (basic blocking + Today/Plan/Settings) + Pro tier ($59/yr — AI scoring, Puck pairing, Strict Mode, Partner accountability, Cross-device sync).** Gating happens on paywalled features with an inline upgrade prompt; nothing breaks if you let your sub lapse.

**User input needed:** **YES — pricing.** Confirm tier breakdown. Not in scope for visual design but downstream of architecture.

---

### Q29 (new). What happens when user adds a 4th monthly goal (over cap)?

**Recommendation:** **Block. The "+ Add monthly goal" button disappears at 3. To add a new one, replace an existing one (monthly review → Replace) or delete one.**

**Rationale:** Caps are non-negotiable. No "soft cap" with a warning. The whole point of the cap is to force prioritization.

**User input needed:** No.

---

### Q30 (new). What happens when user adds a 4th weekly mission?

**Recommendation:** **Same as Q29 — block, no soft cap.** Mission edit modal shows count "Mission 3 of 3"; "+" disappears.

**User input needed:** No.

---

## Summary

- **27 of 30** open questions have firm recommendations.
- **3 require user input:** Q11 (Cat 4 spec assumptions), Q13 (sidebar label / mission terminology), Q20 (re-surface Distraction Budget), Q21 (Focus Lock naming confirmation), Q23 (schedule unification priority), Q25 (theme picker count), Q28 (Stripe tier breakdown).

All other questions are committed in the architecture and HTML sketches. Engineering can build from these decisions; the user can override any by re-opening this doc and changing the recommendation.

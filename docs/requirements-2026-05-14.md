# Production Port — Full Requirements Captured From User

**Date:** 2026-05-14
**Source:** every explicit requirement Ameer stated during the May 2026 design sprint, captured verbatim where possible.
**Use:** companion to `docs/prototype-to-production-2026-05-14.md` (the diff brief). The brief explains WHAT changed. This document is the WHY / EXACT BEHAVIOR for each piece.

If a requirement here conflicts with the brief, this document wins. The user's words are the source of truth.

---

## 1. Sidebar layout

1.1. Order of sidebar nav items (top → bottom):
- Today
- Plan
- Sensitive Content
- Accountability
- Settings
- *(Focus Modes was removed — the full-page Weekly Goal editor reachable from Today/Plan cards replaces it)*

1.2. Bottom-left of the sidebar (stacked, top → bottom):
- Time + status footer (e.g. "2:24 PM · Caity · Content ON")
- **Blocking status pill** (e.g. "3 blocking" with chevron) — shows count of active blocks. Click to expand and see what's blocking.
- **Dark / Light theme toggle** at the very bottom.

1.3. Direct user quote: *"put it at the bottom left right above dark"* — referring to the blocking pill placement.

1.4. The blocking pill must visually echo Opal's "blocking now" widget. If multiple blocks are active, split the pill into separate stacked cards (one per block). Use the Opal pattern, not custom.

---

## 2. Today page

2.1. **Always show today's schedule.** Direct user quote: *"you should just always have the today schedule visible."* Do not hide the calendar behind a tab toggle. The calendar is the constant primary surface of Today.

2.2. **Top strip = 3 weekly goal cards.** Replaces what used to be the "Now card" / blocking-now widget. Each card shows: title, outcome, status pill (`in-progress` / `planned` / `unlinked`), hours-done count.

2.3. **Card body click → open full-page Weekly Goal editor.** Every weekly goal card must be clickable. Click anywhere on the card body (not just the title, not just a button) opens the editor.

2.4. **Card grip (⋮⋮) → drag onto schedule.** Small drag handle in the bottom-right of each card. Drag onto an hour on the calendar below → creates a Session bound to that goal at that hour.

2.5. Session creation from drag must be **immediate** — user drops, session appears on the calendar, no confirmation modal in between.

2.6. **Blocking pill is NOT in the Today page header.** It moved to the sidebar bottom-left. Direct user quote: *"let's leave the blocking now to the bottom left of the sidebar."*

2.7. The header above the goal cards reads "This week's goals · drag onto schedule to create a session." Plus an "Open Plan →" link top-right.

---

## 3. Plan page (Cloud Design React app)

3.1. **Embed the Cloud Design React app verbatim.** Source: `docs/planning-system-design-2026-05-13/Planning Page.html`. Direct user quote: *"I'm gonna need you to follow the fucking design exactly as I give it to you from cloud design."* No SwiftUI rewrite. No reskinning. No substituting colors/typography/spacing.

3.2. **Embed it into `dashboard.html` via WKWebView**, not a separate window. Same React + Babel CDN pattern already inline in `app.html`.

3.3. Plan page must contain:
- Week selector with history dropdown (4 weeks back minimum)
- **Monthly goals row** — currently 3 cards (Ship Puck / 4hr deep work / 10k followers). User clicks a monthly card to filter weekly cards.
- **Weekly goals row** — 3 cards per week, same shape as the Today cards.
- **Timeline strip** — "Today · Wednesday" hour markers with current `NOW` indicator.

3.4. **Drag weekly card onto timeline = create session.** Direct user quote: *"this week on the planning page should be draggable onto the chronological tape under it."*

3.5. **The dragged session must reflect in the Today schedule too.** Direct user quote: *"this should reflect in the schedule."* Plan-tab timeline and Today-tab calendar share the same underlying data — drop on Plan, appears on Today.

3.6. **Both surfaces must sync to backend immediately.** Direct user quote: *"these things should sync up to the backend immediately."* No 800ms debounce loss (see CLAUDE.md known bug #6). Treat session-create as an immediate POST, not a deferred save.

3.7. Plan page weekly cards must also be clickable to open the same full-page Weekly Goal editor as Today.

3.8. Plan page must support viewing past weeks (drilling into `apr20`, `apr27`, `may4`, `may11` etc) and showing the weekly cards' status pills as they were that week. Historical view is read-mostly.

---

## 4. Weekly Goal full-page editor

4.1. **MUST be a full page, not a modal overlay.** Direct user quote: *"You turned it into some kind of overlay. It's supposed to be a full page on its own."* The reference is the actual app's Focus Mode editor (which is a full page inside the Focus Modes tab).

4.2. Editor structure (top → bottom):
- `‹ All Weekly Goals` back link (top, coral text)
- Title (click-to-rename, large 24px+ font) + "✏️ Click to rename" hint below
- **"What are you working on?" card** — colored left-edge stripe matching the goal's hue, contains:
  - Card title with info icon ⓘ
  - **AI scoring toggle** (right side of card header) — per-goal toggle, default on for new goals
  - Textarea, **140-character max**, character counter at the bottom
  - Note: *"🤖 Only used if AI scoring is on. The AI uses this text to judge if your activity is on-task."*
- **Custom rules drilldown row** — colored square, "Custom rules" title, counts of `0 blocked` + `3 allowed` with colored dots, chevron `›`. Click opens the Custom Rules sub-page.
- **Outcome (done looks like)** — textarea, no character limit, goal-specific
- **Status pills** — `In progress` / `Planned` / `Done` (radio-style)
- **For monthly goal** — link/dropdown showing parent monthly goal name in color
- `ADVANCED` divider
- **Strictness pills** — `Standard` / `Strict` (radio-style; Soft was dropped per CLAUDE.md #14)
- **Weekly target** — number input + "hrs / week"
- Bottom footer: `Delete this Weekly Goal` link (left) + `Cancel` (quiet) + `Done` (primary, coral gradient) (right)

4.3. While editing a goal, the sidebar must keep the **originating tab highlighted** (Today or Plan, whichever the user came from). Same UX as the Focus Mode editor reference where "Focus Modes" stays highlighted.

4.4. Back button (`‹ All Weekly Goals`) returns to the originating tab — not always Today.

---

## 5. Custom Rules sub-page (full page, not modal)

5.1. Same full-page treatment as the editor. Not a popup.

5.2. Header: `‹ [Goal title]` back link + "Custom rules" title + sub-text *"During [Goal title] blocks only."*

5.3. Info card at top: *"Most goals don't need custom rules — the AI handles the rest. Add tweaks here only if you want to."*

5.4. **BLOCK section** — input field placeholder `e.g. slack.com`, `+ Site` button, `+ App` button. Entry list below shows existing blocks with `name`, type pill (`Site` / `App`), `×` remove button. Empty state: *"Nothing extra to block — the AI is doing the work."*

5.5. **ALLOW section** — same shape as Block. Empty state: *"No allow overrides yet."* Placeholder: `e.g. github.com`.

5.6. **Block-conflict warning** — when user adds an entry to Allow that is currently blocked by an active global Time Block, show inline warning. User context: *"basically I have a rule set that like from 9 to 12 all Instagram is blocked but at the same time for one of my tasks I need Instagram."*

5.7. **Conflict resolution rule.** Direct user quote: *"maybe blocks should be the winners not the allow list."* Globally-active Blocks override goal-specific Allow lists during the Block's active window. The goal's Allow list only applies when no conflicting Block is active. Surface this clearly so the user understands what'll happen.

---

## 6. Blocks ("Opal-exactly")

6.1. Direct user quote: *"we want the blocks section to work exactly exactly like Opal in every single way."* Treat Opal's blocking UX as the target. Read its docs, its support pages, its review videos. Match patterns.

6.2. Blocks are **rules** (e.g. "Block social media", "Block video", "Block everything", "Workout", "Study"). They are NOT the same as Deep Work / Focus Hours sessions.

6.3. **Multiple blocks can be active at once.** A user can have "Block social media 9-5" AND "Block video weekdays" active simultaneously.

6.4. Blocks have a schedule (recurring time window) and a blocklist (sites + apps).

6.5. Blocks are global / not tied to a specific Weekly Goal. They run whenever scheduled regardless of which goal is in session.

6.6. The sidebar bottom-left pill shows the count of currently-active blocks. Click expands to show each one.

6.7. Per Opal: include block start ritual UX (typing intention to activate), block end ritual UX (celebration card), and the "earned browse" pool concept where focused minutes accrue browse time. *These already exist in the macOS app — reuse, don't rebuild.*

---

## 7. Drag-and-drop behavior

7.1. **Click vs drag isolation.** Whole card body must NOT be `draggable` — that swallows clicks in Chrome. Pattern: card body has `onclick`, only a small ⋮⋮ grip element has `draggable`. Reference test: `scripts/playwright-tests/weekly-goal-click.mjs` (19 assertions).

7.2. Drop targets: every hour row on the Today calendar AND every hour cell on the Plan timeline strip.

7.3. Visual hover state when dragging over a drop target (e.g. coral border).

7.4. After drop, the new session appears immediately. No "confirm" dialog.

7.5. New session inherits the dragged goal's strictness preset and custom rules.

---

## 8. Backend sync — IMMEDIATE

8.1. Direct user quote: *"these things should sync up to the backend immediately."* No deferred saves, no batched writes for state-changing actions like session-create, goal-update, block-toggle.

8.2. Follow the partner-sync architecture (CLAUDE.md known fix #11a) — pull on launch + foreground + 60s timer; push on every user edit immediately.

8.3. Cross-device propagation: when a Mac edits a Weekly Goal, a paired iPhone should reflect the change within 5 seconds (silent APNs or WebSocket, same pattern as `/focus/toggle`).

8.4. Specific endpoints that must exist on backend (subset — full list in the brief):
- `GET/POST/PUT/DELETE /weekly_goals` (renaming `/intentions` — keep alias for one release)
- `GET/POST/PUT/DELETE /monthly_goals` (new)
- `PUT /weekly_goals/{id}/links_to` (set monthly parent)
- `POST /sessions` (immediate session create from drag)
- `GET /weekly_goals?week=YYYY-MM-DD`
- `GET /monthly_goals?month=YYYY-MM`

---

## 9. Wake / Alarm / Bedtime

9.1. Direct user quote: *"all we need is for the mac app to actually cover the screen at night time until morning time at wakeup time."*

9.2. Existing `BedtimeLockLoop.swift` already does this (SACLockScreenImmediate every 10s). **No new Mac surface needed.**

9.3. iPhone owns the alarm/wake trigger.

9.4. No "Wake" tab in the Mac sidebar. No morning-routine card on Today. The bedtime category is invisible UI except for the screen-cover behavior.

---

## 10. Theme

10.1. **THEME TOGGLE IS OUT OF SCOPE FOR THIS RUN (locked 2026-05-14).** Direct user instruction: *"don't implement the dark/light theme toggle."* Ship dark-only. Do NOT add the toggle UI to the sidebar. Do NOT add a `SET_THEME` bridge message. Do NOT spend time on light-theme CSS.

10.2. Sidebar bottom-left still contains the blocking pill (above where a future theme toggle would land); the toggle slot is just empty / nonexistent for v1.

10.3. (Deferred to a future spec.) When light theme ships later, it'll use `body[data-theme="light"]` and propagate to embedded Plan tab CSS. Not in this scope.

---

## 11. Strictness

11.1. Two presets: `Standard` / `Strict`. (Soft was dropped per CLAUDE.md known fix #14.)

11.2. Tightening (Standard → Strict): instant, no cool-down.

11.3. Softening (Strict → Standard): 24-hour cool-down via server-side cron. Cancelable. Warm-tone confirmation copy.

11.4. Strictness control is greyed out during an active Session of that goal (per CLAUDE.md known fix #14, decision D6).

11.5. Strictness applies per Weekly Goal. No global strictness.

---

## 12. AI scoring toggle (per-goal)

12.1. Toggle lives in the "What are you working on?" card header.

12.2. When OFF: the intent text is hidden from the AI prompt; relevance scoring falls back to the goal's custom block/allow lists only.

12.3. When ON: the intent text is fed into the prompt the local Qwen3-4B model uses for relevance scoring (per `docs/AI_SCORING.md`).

12.4. New goals default to AI scoring **on**.

---

## 13. Settings drilldown

13.1. Settings index lists 11 rows. Each row navigates to a sub-page using a `‹ Settings` back link pattern.

13.2. Sub-page IDs (per the prototype's `openSettingsSub` switch):
`focus-mode`, `always-blocked`, `enforcement`, `account`, `theme`, `ai`, `content-safety`, `distractions`, `budget`, `bedtime`, `browsers`.

13.3. Settings does not surface Focus Modes anymore as a top-level concept — the `focus-mode` row is about interventions + screen lock (not "create a focus mode").

---

## 14. Sensitive Content (placeholder)

14.1. Sidebar tab kept, but contents are placeholder for v1. Direct user quote (paraphrased): *"Sensitive Content already a sidebar tab, but the page itself is mostly placeholder right now."*

14.2. Treat the existing in-app Sensitive Content page (already deployed) as the v1 baseline. Don't redesign.

14.3. v1.5 follow-up — flesh out: today's events, recent flags, partner notify status, NSFW model status, 7-day trend chart.

---

## 15. Accountability (existing)

15.1. Sidebar tab kept. Already-deployed functionality (partner pairing + cross-device sync) covers it.

15.2. No new product behavior in this scope.

---

## 16. New session overlay

16.1. Click an empty hour on the Today calendar → opens "New session" overlay.

16.2. Required field: title.

16.3. **Collapsible optional sections** (each starts collapsed):
- Done looks like
- Goal link (pick a Weekly Goal to bind this session to)
- Auto-activate blocks (which blocks should fire when this session starts)
- AI scoring (override per-session)

16.4. Title-only sessions save with a `Free Time` or `Untitled` default block type.

---

## 17. UX patterns that bit the user

17.1. **Every interactive element must do something visible.** Direct user quote (paraphrased): *"can you verify that all the buttons are pressable."* No placeholder buttons, no `(coming soon)`, no dead links. Every button → at minimum, a toast or modal or visible state change.

17.2. **Click vs drag isolation on draggable cards** — see §7.1. Failing this caused 3 broken fixes in a row.

17.3. **Don't fragment HTML across multiple files** — the canonical prototype lives in `app.html`. Per CLAUDE.md MANDATORY rule.

17.4. **Follow Cloud Design output verbatim** when one is provided. Per CLAUDE.md MANDATORY rule.

17.5. **TL;DR at the end of every response** — plain English, max 3 sentences. Per CLAUDE.md MANDATORY rule.

17.6. **Verify with Playwright before claiming done.** Per CLAUDE.md MANDATORY rule (added 2026-05-14 because of this exact bug class).

---

## 17b. Answers locked in 2026-05-14 (supersede agent defaults)

After the planning agent surfaced 13 open questions, the user answered them. **The plan agent's defaults are accepted EXCEPT where this section overrides:**

17b.1. **Q1 Monthly window** — calendar month (`YYYY-MM-01`). ✓ accept default.

17b.2. **Q2 Week window** — Monday-start (ISO week). ✓ accept default.

17b.3. **Q3 Goal carry-over** — **FREEZE.** End of week = clean slate. Weekly goals not marked `done` stay in past week's history. New week = user manually picks new goals. Forces intentionality. *(Overrides any prior assumption about auto-roll.)*

17b.4. **Q4 Status enum** — one shared 5-value enum: `planned` / `in-progress` / `done` / `slipped` / `dropped`. ✓ accept default.

17b.5. **Q5 Monthly goals cross-device sync** — same pattern as Intentions (pull on launch+foreground+60s; push immediately on edit; APNs silent push to peers). ✓ accept default.

17b.6. **Q6 AI scoring off** — skip scoring entirely; allow all (no keyword fallback). ✓ accept default.

17b.7. **Q7 Block-conflict resolution** — **BLOCK WINS + warning on Allow add.** Globally-active Time Blocks always override a goal's Allow list. When the user tries to add a globally-blocked site/app to a goal's Custom Rules Allow list, surface a warm warning inline: e.g. *"Heads up — instagram.com is blocked 9–5 by your 'Block social media' rule. Adding it here won't override that during the blocked window."* The user can still add it (it'll work when the Block isn't active). *(This supersedes §5.7 and the agent's "allow wins" default.)*

17b.8. **Q8 description → intent_text migration** — auto-copy on first launch, idempotent receipt at `~/Library/Application Support/Intentional/migration_intent_text_v1.json`. ✓ accept default.

17b.9. **Q9 Drag-to-schedule day target** — session lands on **today**, regardless of which week the user is viewing in Plan. (Future-week scheduling deferred to v1.5.) ✓ accept default.

17b.10. **Q10 Monthly goal as session-strictness source** — weekly_goal owns strictness; `monthly_goal_id` on session is analytics-only. ✓ accept default.

17b.11. **Q11 Sidebar bottom blocking-pill destination** — add a "Today → Blocks" sub-view that the pill links to. Don't fall back to Settings → Always-Blocked. ✓ accept default.

17b.12. **Q12 Theme toggle — OVERRIDDEN 2026-05-14.** Do NOT implement the dark/light theme toggle at all in this run. Direct user quote: *"don't implement the dark/light theme toggle."* Dark-only. The agent should treat any task referencing the theme toggle (sidebar UI, SET_THEME bridge, light-theme CSS) as no-op / skipped. *Supersedes the earlier "cosmetic stub" default.*

17b.13. **Q13 Feature flag for monthly goals on backend** — ship unconditional; schema is purely additive. ✓ accept default.

---

## 18. What the prototype DOES NOT specify (yet) — surface as questions

*(These were all addressed in §17b above. Section retained for traceability of what the agent asked.)*

18.1. **Monthly goal lifecycle.** When does a new month start — calendar month or rolling 30-day from creation? Are monthly goals carried over if not "Done"?

18.2. **Goal → Session binding semantics.** If a Session is bound to a Weekly Goal, does running an off-task app during that Session hard-block (overlay) or just nudge (toast)? Does the Goal's strictness override the Block's strictness during the Session?

18.3. **Drag from Plan timeline cross-day.** If user drags a Weekly Goal card to a future day in Plan, does it create the session immediately or schedule it for that day?

18.4. **Multiple Sessions per Goal per day.** Allowed? Or one Session per Goal per day max?

18.5. **Block-conflict warning text.** The exact warning copy when adding a globally-blocked site to a Goal's Allow list. (Tone: warm, not alarmist.)

18.6. **Strictness step-down from Strict — backend.** Partner-unlock endpoints are DEFERRED. The UI will throw "Couldn't reach partner" — is that acceptable for v1 ship, or block ship on backend completion?

18.7. **History data for past weeks.** Show real backend data (slow if many users) or computed-on-demand?

18.8. **Weekly target enforcement.** What happens if user hits 4 hrs / week target — celebration? Soft-cap? Just a stat?

18.9. **"Unlinked" weekly goals — show in monthly card filter?** Currently visible regardless. Confirm.

18.10. **Migration plan for existing Intention data.** What does `outcome` default to for existing rows? What does `weeklyTarget` default to?

---

## 19. Verification expectations (per CLAUDE.md)

Before claiming any slice is done:

19.1. **Playwright test for any UI change.** `scripts/playwright-tests/<feature>.mjs` runs against `app.html` (prototype) OR `dashboard.html` (production WKWebView).

19.2. **PKG build succeeds** with no AMFI Error 163, no entitlement stripping, no signing regression. Per `docs/PKG_BUILD_GUIDE.md`.

19.3. **Backend tests pass** — existing pytest suite in `intentional-backend/tests/`.

19.4. **End-to-end smoke**: Mac dashboard loads, sidebar renders, click a weekly goal card → full-page editor opens, drag a goal onto calendar → session appears AND backend recorded the POST.

---

## 20. Cross-repo / overnight log

20.1. The final progress log lives at `docs/overnight-run-2026-05-14.md` in the macOS app repo. Update it as work progresses — what was completed, what's blocked, what's in which PR.

20.2. Sibling repo paths (relative to home):
- macOS app: `Documents/GitHub/intentional-macos-app`
- Backend: `Documents/GitHub/intentional-backend`
- iPhone (read-only in this scope): `Documents/GitHub/puck-ios`

20.3. Each PR description references this requirements doc, the brief, and the plan files.

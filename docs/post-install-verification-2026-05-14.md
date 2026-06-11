# Post-Install Verification Checklist — 17 Fixes (2026-05-14)

Run through each item with the freshly-installed PKG. Mark ✅ pass / ❌ fail / ⚠️ partial. Report failures back so I can fix.

**Pre-flight:**
- [ ] Supabase migration 026 has been run (you confirmed earlier)
- [ ] Backend PR #5 deployed OR running against `feat/prototype-to-production` branch
- [ ] Mac PKG installed: `sudo installer -pkg /tmp/intentional-pkg-build/Intentional-1.0.pkg -target /`
- [ ] Launch Intentional from Applications

---

## FIX-1 — Opal-style Blocks page

1. Today tab → top-right of header should show **Schedule / Blocks** segmented toggle
2. Click **Blocks** → see "Quick Actions" row (Block Now / Plan Day / Pomodoro / Set Limits) + "Your blocks" list with count pill
3. Click `+ Create your first block` (empty state) OR existing block → editor (currently 3 sequential `prompt()` dialogs — accept this for v1)
4. Verify created block appears in list with schedule formatted ("Weekdays · 9a–5p") + toggle on right
5. Toggle off → pill greys, toggle on → pill returns

**Known limitation (FIX-18 follow-up):** the rule doesn't actually BLOCK anything yet — schedule fields are stored but no enforcement ticker exists. UI works; backend wiring works; OS-level blocking doesn't fire until FIX-18 ships.

---

## FIX-2 — Drag-to-schedule creates real session

1. Today tab → 3 weekly goal cards at top
2. Grab the `⋮⋮` grip on one card → drag onto an empty hour on the calendar below
3. Drop → a session block appears on the calendar at that hour with the goal's name
4. The block persists after refresh (proves backend wrote it via ScheduleManager.pushToBackend)
5. Same flow on Plan tab → drag a weekly card onto the Today timeline at the bottom of Plan

**Failure mode you'd see if broken:** "Missing intention id" red toast (the original bug) — should NOT appear.

---

## FIX-3 — Goal create flow

1. Today → top of "This week's goals" header → click `+ New` → editor opens BLANK
2. Type title, intent text, outcome → click **Save** → editor closes → new card appears in Today strip
3. Plan tab → `+ Weekly` button next to History → same flow
4. Plan tab → `+ Monthly` button → prompt for title/outcome → new card appears in Plan's Monthly row

---

## FIX-4 — "Intention" → "weekly goal" copy sweep

1. Trigger an error path (e.g. drag-drop on a calendar hour with no active intention id) — the resulting toast should say "weekly goal" not "intention"
2. Skim Settings sub-pages and any prompts — should see "weekly goal" in user copy
3. Variable names internally are still `Intention` / `IntentionStore` — that's correct

---

## FIX-5 — Empty-state replaces hardcoded fallback

1. Open Plan tab on a fresh account / cleared cache → should see "+ Add your first monthly goal" centered CTA (NOT the prototype's hardcoded "Ship Puck" / "4hr deep work" / "Hit 10k followers" cards)
2. Same for weekly cards row → empty state CTA instead of hardcoded `wg1`/`wg2`/`wg3`

---

## FIX-6 — Sidebar pill destination + count

1. Sidebar bottom-left → "X blocking" pill
2. With no active block rules → pill says "Nothing blocking" + greyed
3. Create a block rule whose schedule includes "now" → pill should update to "1 blocking"
4. Click the pill → should navigate to Today → Blocks view

---

## FIX-7 — Plan history shows real data

1. Plan tab → click **History** button
2. Dropdown should show the current week + any past weeks that have goals in cache (labels like "May 11", "May 4")
3. Should NOT show the prototype's hardcoded `apr20` / `apr27` / `may4` / `may11` placeholders
4. Click a past week → cards reflect that week's real goals (or empty if none); on-demand fetches via GET /intentions?week=

---

## FIX-8 — Originating sidebar tab stays highlighted

1. On Today tab, click a weekly-goal card → editor opens
2. Sidebar: **Today** stays highlighted (not unhighlighted) while editor is visible
3. Click `‹ All Weekly Goals` → return to Today
4. Now on Plan tab → click a weekly-goal card → editor opens
5. Sidebar: **Plan** stays highlighted while editor is visible

---

## FIX-9 — Block-conflict warning when adding to Allow list

1. Create a block rule "Block social" that blocks `instagram.com` daily 9–5
2. Open a Weekly Goal editor → Custom Rules
3. Add `instagram.com` to the **Allow** section
4. Should see confirm dialog: "Heads up — instagram.com is blocked by your 'Block social' rule…"
5. Click OK → entry still saves (Block wins at runtime, but Allow is recorded)

---

## FIX-10 — Strictness pills greyed during active session

1. Start a focus session bound to a specific weekly goal (drag onto NOW or use Block Now)
2. Open that goal's editor
3. The **Strictness** pills (Standard / Strict) should be greyed + non-clickable
4. Hint text below: "Strictness locked — active session of this goal is running."
5. End session → reopen editor → pills are interactive again

---

## FIX-11 — AI scoring toggle enforced

1. Open a Weekly Goal editor → toggle AI scoring OFF → Save
2. Start a session bound to that goal
3. Open some off-task page (e.g. twitter.com) — should NOT get a relevance nudge (scoring skipped, allow all)
4. Toggle back ON + set Intent text to "Working on demo videos" → restart session
5. Open a clearly off-task page → should get a nudge (scoring active, uses intent_text in prompt)
6. Verify in app logs: `🧠 [scorer] ai_scoring_enabled=false → allow all` line should appear when toggle is off

---

## FIX-12 — Settings 11-subpage drilldown

1. Sidebar → Settings → see 11 rows: Focus Mode behavior, Always blocked, Enforcement, Account, Theme, AI scoring, Sensitive content, Distractions, Weekly distraction budget, Bedtime, Browsers
2. Click any row → opens sub-page with `‹ Settings` back link top-left
3. Click `‹ Settings` → returns to index
4. Theme sub-page body: "Coming soon — dark mode only for now."

---

## FIX-13 — New session overlay (click empty calendar hour)

1. Today tab → calendar at bottom
2. Click an empty hour (no existing block there)
3. "New session" modal opens with: Title input (required) + collapsible Done looks like / Goal link / Auto-activate blocks / AI scoring
4. Type title, optionally pick a weekly goal → click Create session
5. New session appears on the calendar at that hour

---

## FIX-14 — Weekly goal freeze

1. On Today tab, current week's goals should ONLY show goals whose `week_of` matches this Monday's ISO date
2. Past-week goals should NOT bleed into Today (even if no current-week goals exist — should show empty state, not fall back to "show top-3")
3. Plan tab → History → past week → those goals show there (in their own week)

---

## FIX-15 — Status footer wired to real state

1. Bottom of sidebar → see 3 pills: Partner / Content protection / Puck
2. Pills reflect ACTUAL state (not static text):
   - Partner: shows partner name + "partner active" or "No accountability partner"
   - Content protection: "ON" if ContentSafetyMonitor.enabled, else "OFF"
   - Puck: "paired" if connected, else "not paired" (currently always "not paired" on Mac — that's expected)
3. Toggle Content Protection in Settings → status footer should update immediately (push)

---

## FIX-16 — Calendar drop-target selectors

1. Same as FIX-2: drag-to-schedule should work cleanly on first try (no need to land on a hedged selector)
2. Drop hover state: orange/coral outline on the hour cell when dragging over it
3. No JS console errors about "drop-hover" or missing data-hour attribute

---

## FIX-17 — Backend POST /time_blocks

Implicit in FIX-2 — if drag-to-schedule round-trips through backend and the session persists across app restart, this is working.

---

## After running through all 17

If anything failed, tell me which fix # + what you saw. I'll dispatch a follow-up subagent to fix it.

If everything passed, the goal is closed. Outstanding work that's NOT in this PR:
- **FIX-18 (Opal-parity enforcement)** — make BlockingProfile schedules actually block at the OS level. Est. 3–4 hrs. Documented in overnight-run-2026-05-14.md.
- Real native modals (not `prompt()`) for block create/edit + monthly goal create — would polish the create flow. Est. 1–2 hrs.

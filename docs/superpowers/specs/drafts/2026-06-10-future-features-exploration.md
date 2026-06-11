# Future Features — Design Explorations (Draft)

**Date:** 2026-06-10 · **Status:** draft exploration, NOT a spec, NOT approved
**Source:** the user's May 18 self-messages (4 raw feature notes)
**Vocabulary:** Monthly Goals → Weekly Goals (→ Tasks, not built yet), Sessions, Rules
**Design language:** elegant/Opal-like, minimal-by-default, agency-over-automation, one-dial simplicity
**Reading order for context:** `docs/superpowers/specs/2026-05-18-deep-work-protocol.md` (five stages), `2026-06-10-rules-consolidation-design.md` (Rules + leisure pool), `2026-05-13-planning-system-spec.md` (planning ritual + the already-designed weekly review)

Each section: (a) current state in code, (b) approaches + recommendation, (c) ASCII sketch, (d) implementation shape, (e) testing, (f) open questions for the user.

---

## Feature 1 — Task commitment mechanic ("commit icon" halfway measure)

### (a) Current state in code

There is no Tasks layer yet. What the user calls "a session's tasks" today is two things:

- **Scheduled sessions (FocusBlocks) on Today.** Created/edited via the block editor (`Intentional/dashboard.html:12243` editor markup, `saveBlockEdit()` at `:12423`, `deleteFocusBlock()` at `:12508`). The current anti-gaming rule is hard-coded: `deleteFocusBlock` silently refuses when `isBlockActive(block)` (`dashboard.html:12510`) — an *active* session can never be deleted, full stop, no explanation shown.
- **The Strict Mode lock** `today_schedule` — "Can't delete sessions scheduled for today (future days remain editable)" (`dashboard.html:6284`, default ON at `:6360`). It's saved to settings via `SAVE_STRICT_MODE_LOCKS` (`Intentional/MainWindow.swift:605–614`) but the delete path (`deleteFocusBlock`, `_blkCtxDelete` at `dashboard.html:15144`) never consults it — consistent with the rules-consolidation research finding that "current locks guard a settings mirror." So in practice: active block = undeletable always; everything else = deletable always. Both ends are wrong.
- **The "3 daily goals" inputs** (`focus-goal-1..3`, `dashboard.html:5261–5271`, persisted via `focusState.goals` → `SET_SCHEDULE`) are free-text, never locked, and not what the commit mechanic should target.
- Calendar manipulation rules already exist as a concept doc: `docs/CALENDAR_BLOCK_RULES.md` (past locked / active limited / future editable).

### (b) Design approaches

**Approach 1 — Commit icon = opt-in lock per item (the user's raw idea, literal).**
Each scheduled session (and later, each Task) gets a small flag/pin icon. Untouched items behave like normal calendar items — freely editable and deletable, even mid-day. Pressing the icon marks it *committed*: it locks (no delete, no shrink, no retitle) until its end time passes. Committing is one-way for the day (uncommitting = the thing the anti-gaming rule exists to prevent).
- Pros: pure agency-over-automation — the user clicks the lock, the app doesn't. Replaces the rigid blanket rule with a per-item choice. Tiny UI footprint.
- Cons: ADHD ICP may never press it (commitment is exactly what's hard). Zero-commit weeks make the mechanic decorative.

**Approach 2 — Commit-on-start (automatic), everything else free.**
Drop the explicit icon. Starting a session auto-commits it (can't delete it or its linked goal mid-session — basically today's `isBlockActive` rule, kept); everything not yet started is freely editable. No new UI.
- Pros: zero new chrome; matches "the moment you start is the commitment."
- Cons: this is just the status quo minus the broken strict lock; doesn't give the user the *pre*-commitment device they asked for. Doesn't solve "I committed to doing this at 3pm and then quietly deleted it at 2:55."

**Approach 3 — Commit icon + soft lock (friction, not wall).** Commit icon as in Approach 1, but a committed item isn't absolutely locked: deleting it requires a deliberate ritual — a 10-second hold-to-delete with copy like *"You committed to this at 9:14 AM. Still deleting?"* — and the deletion is recorded and shown in the weekly review ("2 committed sessions deleted"). With Strict Mode on, the soft lock becomes hard (partner-code only), reusing the existing strict-lock plumbing.
- Pros: matches the product's whole philosophy (Defend tiers = calibrated friction, not walls; agency preserved; failure is data, not shame — the review surfaces it instead of the app forbidding it). One mechanic gracefully scales from Soft → Strict via the dial that already exists.
- Cons: slightly more build than 1 (hold-to-delete + review surfacing + strict gating).

**Recommendation: Approach 3.** It's the real "halfway measure" the note asks for: the icon is the user's voluntary pledge, the friction makes breaking it deliberate and visible rather than impossible. It also retires the silent-refusal bug (`deleteFocusBlock`'s `return` with no feedback) and gives the dormant `today_schedule` strict lock a real enforcement point. Apply the same mechanic to Tasks when that layer lands — committed = attached to this session, lockable.

### (c) ASCII sketch (recommended)

```
Today calendar — a scheduled session card (hover state)

┌──────────────────────────────────────────────┐
│ ▌ Outline blog post #3          1:00–3:00 PM │
│ ▌ Weekly Goal: Ship content engine    ⚑  ✎  │   ⚑ = commit toggle (hollow)
└──────────────────────────────────────────────┘

After pressing ⚑  (one-tap, fills in, tiny toast "Committed")

┌──────────────────────────────────────────────┐
│ ▌ Outline blog post #3          1:00–3:00 PM │
│ ▌ Weekly Goal: Ship content engine    ⚑̶ 🔒  │   filled flag + lock glyph
└──────────────────────────────────────────────┘

Attempting delete on a committed session:

┌──────────────────────────────────────────────┐
│  You committed to this at 9:14 AM.           │
│  Hold the button for 10s to delete anyway.   │
│  This will show up in your weekly review.    │
│                                              │
│        [ Cancel ]   [ ◉ hold to delete ]     │
│  Strict Mode on → button replaced by:        │
│        "Ask <partner> for an unlock code"    │
└──────────────────────────────────────────────┘
```

### (d) Implementation shape

- `ScheduleManager.FocusBlock` gains `committedAt: Date?` (`Intentional/ScheduleManager.swift:376+` model area); round-trips through `SET_SCHEDULE` / `_scheduleStateResult` and `/time_blocks` (backend: one nullable column on `time_blocks`, migration ~029).
- dashboard.html: commit toggle on calendar block render (`renderCalendarBlocks` `:11398`) + block editor footer (`:12265`); `deleteFocusBlock` (`:12508`) branches → free delete / hold-to-delete modal (`.ns-modal-overlay` pattern — never `confirm()` per WKWebView memory, though MainWindow does implement the confirm panel at `MainWindow.swift:362`, modals are the house style) / partner-unlock sheet (reuse `BedtimeUnlockRequestView` kind pattern).
- Deletion-of-committed events appended to a tiny local JSONL (mirror `relevance_log.jsonl` pattern) for the weekly review to read (Feature 3 consumes this).
- Strict gating: make `today_schedule` lock actually consulted at the delete path — closes the settings-mirror gap.
- Rough size: ~2–3 days. Mac-heavy, backend one column + passthrough.

### (e) Testing

- `verifier-intentional-gui`: click commit flag → screenshot filled state; attempt delete → screenshot friction modal; hold 10s → deleted + JSONL row asserted via file read; Strict Mode on → attempt delete → partner-code sheet screenshot.
- Restart app mid-commitment → `committedAt` survives (file + backend round-trip).
- Regression: uncommitted future block still deletes in one click; active block delete now shows the modal instead of silently no-op'ing.

### (f) Open questions for the user

1. Once you press the commit flag, should there be **any** way to un-press it the same day (before the session starts), or is one tap final until tomorrow?
2. When you delete a committed session the slow way, is "it shows up in your weekly review" enough consequence — or should it also cost something now (e.g. a note to your partner)?
3. Should starting a session **auto-commit** it (start = commitment), or is committing always your explicit tap?
4. Does the commit flag belong on Weekly Goals too, or only on scheduled sessions (and later Tasks)?

---

## Feature 2 — Quick-capture "remember this for later" from the pill

### (a) Current state in code

Survey of the floating surfaces:

- **Pill** (`Intentional/DeepWorkTimerController.swift`, 2,684 lines). Modes: `timer / blockComplete / celebration / startRitual / startRitualEdit / noPlan / bedtimeWindDown / bedtimeLocked` (`:48–58`). The timer pill already has a hover state (`viewModel.isHovered`, `:935`) revealing Mute + Minimize (`:1148–1170`) and a Break / End Block row (`:1182–1217`). The window is a `KeyablePanel` with an `allowKeyboardInput` switch (`:6–8`) — already used by `startRitualEdit` for typing, so **in-pill text entry is proven feasible**.
- **Distraction takeover** in-pill card (`:1067–1121`): "Not related to your task" + Back to Task / This is relevant / Override AI. This is the moment a "save it for later" affordance is most valuable — the user is mid-temptation.
- **NudgeWindowController** — external toast below the pill for escalated nudges.
- **Menu bar** `NSMenu` (`Intentional/AppDelegate.swift:1379–1413`) — Show Window / Toggle Focus / debug items; no capture.
- **Storage precedent:** `SessionStash` (`Intentional/SessionStash.swift:3–74`) — file-per-session JSON store at `session_stashes/`, used by the close-the-noise sweep for stashed tabs. The Exit stage of the Deep Work protocol already specs a "**Mark for tomorrow** → deferred-list reviewed at next planning" (`2026-05-18-deep-work-protocol.md:116`), which is *the same list* this feature feeds.

There is no capture affordance anywhere today; a mid-session idea has two outcomes: open a tab (distraction) or lose it.

### (b) Design approaches

**Approach 1 — In-pill capture line.** Hover the pill → a `+` glyph next to Mute; click (or global hotkey ⌘⇧Space) → the pill grows one row with a single text field ("Park it for later…"); Enter saves + collapses with a 1s "Parked ✓"; Esc cancels. Items land in a `ParkedItemStore` (SessionStash pattern), tagged with session id + timestamp.
- Pros: zero new windows; the pill is already where the eyes are; KeyablePanel keyboard path exists; fastest possible loop (≤3s, idea never leaves the pill).
- Cons: pill steals key focus from the work app for a moment (must restore frontmost app after Enter); text-only, one line.

**Approach 2 — Things-style quick-entry panel.** Global hotkey opens a small centered floating capture window (independent of pill mode — works in `noPlan`, bedtime, even no-session). Slightly bigger: text + optional "open this tab later" button that grabs the current tab's URL via the existing AppleScript path.
- Pros: works even when the pill is minimized/absent; can capture the current URL ("this tab, tomorrow") which is the highest-value ADHD capture; room to grow (voice later).
- Cons: a new window controller; one more floating surface in an app trying to calm down (calm-down pass just ran 2026-06-10); hotkey discoverability.

**Approach 3 — Capture as the third button on the distraction card.** No general capture; instead the in-pill distraction card gains "Save for later" next to "Back to Task" — it records the off-task tab/app (title + URL already known from the relevance entry) and closes it.
- Pros: zero typing; intercepts the exact moment of drift; pairs perfectly with Defend Tier 2 ("soft-close in 5s… or park it").
- Cons: only captures *things on screen*, not *thoughts in head* ("remember to email Sam") — which is most of what the user's note describes.

**Recommendation: Approach 1 + the Approach-3 button, phased.** Ship the in-pill capture line first (it's the user's literal ask and the smallest build), and add "Park this" to the distraction card as a fast follow since it shares the same store. Skip the separate quick-entry window for now — it fights the calm-down direction; revisit if pill-minimized capture proves needed. All captures flow into one **Parked list** that surfaces in two existing places: the session-end celebration (one extra card: "3 things parked — they'll be waiting") and the next planning ritual / Exit review (per the protocol's deferred-list design). Never as notifications — parked means *quiet*.

### (c) ASCII sketch (recommended)

```
Timer pill (hover)                       Capture row open (⌘⇧Space or +)
┌────────────────────────────┐          ┌────────────────────────────┐
│ ● Outline blog post  47:12 │          │ ● Outline blog post  47:12 │
│ ──────────────────  🔇 − + │   ──►    │ ────────────────────────── │
│ 84% focused      +12m      │          │ ✎ Park it for later…       │
└────────────────────────────┘          │   [Enter saves · Esc]      │
                                        └────────────────────────────┘
                                          ↳ collapses to "Parked ✓" (1s),
                                            focus returns to your app

Distraction card (fast follow)
┌──────────────────────────────────────┐
│  Not related to your task            │
│  [Back to Task]  [Park this for later]│   ← saves title+URL, closes tab
└──────────────────────────────────────┘

Session-end celebration — extra card
┌──────────────────────────────────────┐
│  PARKED DURING THIS SESSION          │
│  · email Sam re: invoice             │
│  · that HN thread on local LLMs  ↗   │
│  · book dentist                      │
│  [Open now]   [Keep for planning →]  │
└──────────────────────────────────────┘
```

### (d) Implementation shape

- New `ParkedItemStore` (~80 lines, clone `SessionStash.swift` shape): `{id, text, url?, appName?, sessionId?, createdAt, resolvedAt?}` at `~/Library/Application Support/Intentional/parked_items.json`. Local-only v1 (no backend) — cross-device later if it earns it.
- `DeepWorkTimerController`: `+` hover button (next to `:1148` mute), `isCapturing` published state, one-row pill grow (reuse spring resize), `allowKeyboardInput=true` while capturing, restore previous frontmost app on commit (`NSWorkspace` re-activate).
- Global hotkey: Carbon/`NSEvent.addGlobalMonitorForEvents` registration in AppDelegate (only fires capture when pill exists; otherwise no-op v1).
- Distraction-card button: `FocusMonitor` already holds the triggering `RelevanceEntry` (`overlayTriggerEntry`, `FocusMonitor.swift:3491`) — park = write entry title/hostname + close tab via existing WebsiteBlocker AppleScript path.
- Celebration: one new card in the carousel (`DeepWorkTimerController` celebration section ~`:1418+`); planning surface = a small "Parked" list on the Plan tab (read-only v1, dashboard bridge `GET_PARKED_ITEMS`).
- Rough size: 2–3 days for the pill line + store + celebration card; +1 day for the distraction-card button.

### (e) Testing

- `verifier-intentional-gui`: hover pill → screenshot `+`; open capture → type → Enter → assert `parked_items.json` contents via file read; assert frontmost app restored (AppleScript `frontmost`).
- Esc cancels without writing; capture during `noPlan` mode (decide: hidden or allowed); pill restores exact previous size.
- End session → celebration shows the parked card with the exact items; SessionStash-style purge tested for old resolved items.

### (f) Open questions for the user

1. When you park something mid-session, when do you want to see it again: end of that session, next morning's planning, or both?
2. Should parking work by **voice** (hold the hotkey, speak, transcribed) or is typing one line fine for v1?
3. If you're NOT in a session and an idea hits — should quick capture work then too, or is this strictly a during-session tool?
4. On the distraction card, is "Park this for later" allowed to **close the tab for you** after saving it (you pressed the button, so it's your action) — or should it only save and leave the tab open?

---

## Feature 3 — End-of-week review rebuild

### (a) Current state in code

- **What exists is a passive stats strip, not a review.** The Plan tab React app (`Intentional/dashboard.html:15579 PlanApp`) shows a "Last week summary" only when the user manually picks a past week from the History dropdown: 4 stat tiles (goals / hours focused / done / incomplete) computed client-side (`dashboard.html:15814–15833`). Nothing triggers it; nothing asks the user anything; past weeks are read-only (`:15743`). That's the "barely works."
- **Weeks do auto-key off ISO Mondays** — `_currentISOMonday()` (`:14868`), `week_of` on each Intention, `GET_INTENTIONS_FOR_WEEK` fetch on past-week selection (`:15604`). This part works, per the user.
- **Data already available:** per-goal `hours_done` summed from backend `focus_sessions` (`BackendClient.swift:1572–1589`; fan-out in `MainWindow.swift:3511–3526`), `weekly_target_hours`, `status` enum already includes `slipped`/`dropped` (CLAUDE.md, migration 026), manual `LOG_GOAL_TIME` (`MainWindow.swift:437`), per-block focus scores + app breakdown from `relevance_log.jsonl` (`BlockEndRitualController.swift:109`) and `EarnedBrowseManager.todaySummary()`. Rule-violation data is thinner: relevance log `action`/`userOverride` fields exist per entry, but nothing aggregates "violations per week" yet.
- **The design already exists on paper.** `2026-05-13-planning-system-spec.md:93–117` specs the weekly review: auto-trigger when opening a new week with last week's goals set, per-goal row (planned vs actual bar + Done/Slipped/Dropped segmented control), one pattern-insight card, footer "Skip review / Plan this week →", and the monthly variant on month-boundary weeks. It was never built.

### (b) Design approaches

**Approach 1 — Build the May 13 spec as designed (modal ritual, gate-before-plan).** Monday (or first app open of a new week), opening the Plan tab with unreviewed prior-week goals shows the review as a full-page takeover before the new week is plannable. Taps only: Done/Slipped/Dropped per goal, pattern card, skip link.
- Pros: design work is done and user-approved in spirit; review-then-plan is the ritual shape the spec argues for; taps-not-writing fits ADHD.
- Cons: a gate is friction at the exact moment the user finally showed up to plan; "Skip review" must be honored or it becomes a nag.

**Approach 2 — Review woven into the planning empty state (no gate).** New week's Plan tab simply renders last week's three cards in "review dress" (bar + 3 buttons inline) above the empty new-week row. Reviewing and planning are one screen; no modal, no trigger logic. Pattern card sits between them.
- Pros: zero interruption; the review is *encountered*, not imposed; cheapest build (PlanApp already renders past weeks).
- Cons: loses the ritual framing; easy to plan around it and never tap; monthly variant gets cramped.

**Approach 3 — Pill-delivered Sunday-evening review.** The pill (which already does celebration carousels) shows a week-end carousel Sunday 6pm: stats card → per-goal verdict cards (tap Done/Slipped/Dropped) → "plan next week" CTA opening the dashboard.
- Pros: meets the user where they already look; carousel machinery exists.
- Cons: Sunday evening is the lowest-energy moment for an ADHD user; pill taps for 3-state choices are fiddly; splits planning surface in two.

**Recommendation: Approach 1, softened by Approach 2 as the fallback.** Build the spec'd ritual as a Plan-tab takeover (not an OS-level interruption — it appears only when the user opens Plan in a new week), with "Skip review" demoting it to Approach-2 inline cards rather than dismissing it forever. Unreviewed goals default to auto-verdicts (`hours_done ≥ target → done`, else `slipped`) after 7 days so the data never rots. Scope the review's content to what the data already supports: per-goal planned-vs-actual + verdict taps, week focus score (avg of block scores), one pattern insight, and — once Feature 1 ships — "committed sessions deleted: N". Rule violations wait for the Rules-consolidation pool data (migration 028) rather than inventing a new aggregate now. The review's verdicts then feed next week's empty state: slipped goals appear as one-tap "Carry over →" chips.

### (c) ASCII sketch (recommended)

```
Plan tab, first open in a new week (takeover within the page)

┌────────────────────────────────────────────────────────────┐
│  LAST WEEK · May 26 – Jun 1                                │
│                                                            │
│  ● Ship content engine        ▓▓▓▓▓▓▓▓░░  7h45 / 9h30      │
│                               [ Done ] [ Slipped ] [ Drop ]│
│  ● Onboarding revamp          ▓▓▓▓▓▓▓▓▓▓  6h10 / 6h  ✓auto │
│                               [✓Done ] [ Slipped ] [ Drop ]│
│  ● Gym 3×                     ▓▓░░░░░░░░  1h / 4h          │
│                               [ Done ] [ Slipped ] [ Drop ]│
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 📈 Planned 19h 30m, did 15h. Writing goals have hit  │  │
│  │    target 3 weeks running; gym has slipped 4 weeks.  │  │
│  │    1 committed session deleted (Thu 2:55 PM).        │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  Skip review                        [ Plan this week → ]   │
└────────────────────────────────────────────────────────────┘

After "Plan this week →": slipped goals offered as chips
   This week:  [ + Carry over: Gym 3× ]  [ + Add a weekly goal ]
```

### (d) Implementation shape

- **Trigger + state:** `reviewedAt: Date?` per Intention (backend: one column, refresh `intentions` view — mirrors migration 026 pattern) OR a per-week `weekly_reviews` row (`{account_id, week_of, completed_at, skipped}`); the row version is better since it also stores the pattern snapshot. PlanApp checks on mount: current week ≠ last reviewed week AND last week had goals → render `<WeeklyReview/>` instead of the goal grid.
- **Frontend:** new React component inside the existing Plan Babel block (`dashboard.html:14824+`); verdict taps reuse `UPDATE_INTENTION {status}` (`:15239` markDone pattern); carry-over chip = `CREATE` with new `week_of` (decide: duplicate vs move — see Q3).
- **Pattern insight:** v1 computed client-side from cached weeks (needs `GET_INTENTIONS_FOR_WEEK` for trailing 4 weeks + their `hours_done` — extend the fan-out in `MainWindow.swift:3511`). No LLM needed for "X has slipped N weeks running"; template strings.
- **Backend:** 1 small migration + `GET/POST /weekly_reviews`; `hours_done?week=` already exists.
- Rough size: 3–4 days Mac + 1 day backend. The monthly variant (+1 day) can trail.

### (e) Testing

- `verifier-intentional-gui` with clock/data seeding: seed last-week goals with known `hours_done`, open Plan → screenshot review takeover; tap Slipped → assert `UPDATE_INTENTION` fired (relevance: settings JSON / backend row); Skip → inline cards screenshot; re-open Plan → no second takeover.
- Auto-verdict after 7 days: seed `week_of` two weeks back, assert statuses resolved.
- Carry-over chip creates next-week goal with link preserved; week boundary math verified around a real Monday (and the `toISOString` UTC-offset footgun in `_isoWeekStartFromDate` `:14840` — check it against a Sunday-night local time).

### (f) Open questions for the user

1. When the review appears, should it **block** planning the new week until you've tapped each goal (or hit skip) — or sit quietly above the planning area where you can ignore it?
2. If you never review, is it OK for the app to **auto-mark** last week's goals (hit target = done, missed = slipped) after a few days, so history stays honest?
3. When a goal slipped and you carry it over, should it move to the new week (last week shows "slipped") or copy (both weeks show it)?
4. Do you want the review to mention the **uncomfortable stuff** — deleted committed sessions, overrides, leisure-pool spend — or keep v1 to goals and hours only?
5. Should your accountability partner ever see the weekly review summary, or is it private for now?

---

## Feature 4 — Automatic time timeline ("how I actually spent the day," next to the plan)

### (a) Current state in code

- **Planned side:** Today's calendar renders absolutely-positioned planned blocks on an hour grid (`renderCalendar` `dashboard.html:11344`, `renderCalendarBlocks` `:11398`) — there is no "actual" lane.
- **Existing signals (no screenshots needed):**
  - `relevance_log.jsonl` (`FocusMonitor.swift:428–456`): per scoring tick — ISO timestamp, `appName`, `hostname`, `title`, `relevant`, `confidence`, `path`, optional `ocrExcerpt`. Rich enough to reconstruct *what was front-most and whether it was on-task* — **but only while a session is active** (FocusMonitor evaluation is gated on `focusModeController.isOn`). It's already mined per-block for the celebration app breakdown (`BlockEndRitualController.loadAppBreakdown` `:109`).
  - `TimeTracker` (`TimeTracker.swift:5–126`): always-on but **only for distracting platforms** — per-platform daily minutes to `daily_usage.json`, backend sync timer (`:511–517`).
  - No always-on, all-apps sampler exists. That's the actual gap — not intelligence, coverage.
- **VLM:** specced 2026-05-18, **never built** (memory: `project_no_vlm_in_intentional.md`). On-device today = text-only Qwen3-4B (`RelevanceScorer.swift`, 1,415 lines) + Vision OCR (`OCREngine.swift`); `ScreenCapture.captureFrontmostWindow` exists via ScreenCaptureKit (`ScreenCapture.swift:11–26`) and ContentSafety already navigates the Screen Recording permission minefield (`ContentSafetyMonitor.swift:585–605`).
- **Privacy/Sensitive-Content interplay:** CS captures are analyze-and-discard for NSFW; persisting *screenshots* for time classification would be a new, much heavier privacy posture on a machine that is deliberately locked down.

### (b) Design approaches

**Approach 1 — Lightweight always-on sampler + existing signals, no screenshots, coarse taxonomy.**
A new `ActivityTimeline` sampler ticks every 30–60s (NSWorkspace frontmost app + existing AppleScript active-tab path), writes compacted segments (`{start, end, appName, hostname?, category}`) to a local day file. Categorization is layered and cheap: during sessions, reuse the relevance verdicts already in `relevance_log.jsonl` (focused/off-task); outside sessions, map via Rules treatments (🚫/⏳ targets = distraction, ✅ = neutral) + a small static app taxonomy (backend migration 024 `app_taxonomy` already exists) → work / browsing / distraction / idle (no input events ≥3 min = idle, via `CGEventSourceSecondsSinceLastEventType`). Rendered as a slim "actual" lane beside the planned blocks.
- Pros: ships on signals that already exist; ~zero battery/CPU; no new permissions; no stored screen content beyond app/host/title (same sensitivity class as the existing relevance log); honest about granularity.
- Cons: coarse — "Chrome · github.com · work" not "reviewing PR #412"; native apps without URL context are categorized by app only.

**Approach 2 — Approach 1 + on-demand Qwen text classification for the "unknown" residue.**
Same sampler, but segments the static taxonomy can't place (unknown apps/sites) get batched once an hour through the existing Qwen3-4B with window titles + (optionally) an OCR excerpt — temperature 0, benchmark-first per house rules. Still no screenshots persisted.
- Pros: closes the long tail without screenshots; reuses the loaded model; cost bounded (only unknowns, batched).
- Cons: background LLM wakeups on battery; needs a ground-truth benchmark before tuning (banked lesson); marginal gain if taxonomy + Rules already cover 90% of the user's day.

**Approach 3 — Periodic screenshot + VLM categorization (the note's other branch).**
Every N minutes capture the frontmost window, run a local VLM (would have to be *built* — none exists), store category + thumbnail for the timeline ("Rewind-lite").
- Pros: richest semantics; could distinguish "writing in Google Docs" from "reading memes in Google Docs."
- Cons: the VLM doesn't exist (specced only); MLX VLM inference every few minutes is real battery/thermal cost on-device; persisted screenshots are a privacy cliff (and collide with the Sensitive-Content posture — CS deliberately discards captures); retention/encryption questions multiply; weeks of foundation work for a v1 timeline that mostly needs *coverage*, not vision.

**Recommendation: Approach 1 now, Approach 2 as a measured follow-up, Approach 3 explicitly deferred.** The timeline's job is the *gap between plan and reality* — "you planned Deep Work 1–3pm; you were actually in Slack until 1:40" — and app+host+relevance-verdict resolution already tells that story. Taxonomy: general categories only in v1 (focused / other-work / browsing / distraction / idle, plus "in session" shading), because the per-goal attribution for specific categories already comes free *during sessions* from the session's intention. Retention: rolling 30 days local, day-level aggregates only to backend (for weekly review + cross-device), raw segment files never leave the Mac. Sensitive-Content interplay: timeline sampler stores **no titles** for incognito/private windows and drops the `hostname` for anything CS flags — only the category survives.

### (c) ASCII sketch (recommended)

```
Today — calendar with "actual" lane (planned │ actual, per hour)

         PLANNED                    ACTUAL
  9 AM ┌─────────────────────┐  ▓▓▓ focused (Xcode, github.com)
       │ Deep Work:          │  ▓▓▓
       │ Outline blog post   │  ░░░ idle 22m
 10 AM │                     │  ▓▓▓ focused
       └─────────────────────┘  ▒▒▒ browsing (docs, HN)        ← drift visible
 11 AM                          ▒▒▒ browsing
       (nothing planned)        ███ distraction (youtube) 34m  ← red
 12 PM ┌─────────────────────┐  ▓▓▓ focused
       │ Focus Hours: email  │  ▓▓▓
  1 PM └─────────────────────┘  ░░░ idle (lunch)

  Legend: ▓ focused/work · ▒ neutral browsing · █ distraction · ░ idle
  Hover a segment → "10:42–11:16 · Chrome · youtube.com · 34m"
  Day footer:  5h 10m work · 1h 12m browsing · 49m distraction · 1h 30m idle
```

### (d) Implementation shape

- **New `ActivityTimelineTracker.swift`** (~250 lines): 30s timer (background queue — never sync AppleScript on main, bug-fix #9), frontmost app via `NSWorkspace`, active tab via the existing WebsiteBlocker AppleScript path (piggyback its existing poll rather than adding a second one), idle via `CGEventSource`. Segment compaction (merge same-key consecutive ticks) → `~/Application Support/Intentional/timeline/YYYY-MM-DD.json`.
- **Categorizer** (~100 lines): session-time → join against `relevanceLog`/`relevance_log.jsonl`; otherwise Rules treatments (post-028 store) → taxonomy table → `other`.
- **Dashboard:** an `actual` gutter strip in `renderCalendar` (`dashboard.html:11344+`) fed by new bridge `GET_ACTIVITY_TIMELINE {date}`; hover tooltips; day footer totals. Past-day navigation already exists in the calendar.
- **Backend (optional, phase 2):** daily aggregate rows (`{date, category, minutes}`) for the weekly review + iPhone; raw segments stay local.
- Feeds Feature 3 directly (week focus totals stop depending on scheduled-block math alone) and gives the Rules ⏳ pool an audit trail for free.
- Rough size: 4–5 days Mac for sampler + categorizer + render; +1–2 days for aggregates/backend.

### (e) Testing

- Sampler correctness: scripted run — foreground Xcode 2 min, youtube 1 min, idle 3 min → assert segment file matches (automated via AppleScript app activation + file assert; no GUI guess-work).
- `verifier-intentional-gui`: screenshot the actual lane against a seeded timeline file; hover tooltip; day totals.
- Performance: confirm no main-thread AppleScript (Instruments / fps log per bug-fix #9 pattern), CPU < 1% sustained.
- Categorizer: ground-truth-labeled JSON test cases (mirror `SweepBenchmark.swift` discipline) BEFORE any Qwen involvement in phase 2.
- Privacy: incognito window produces category-only segment (assert no hostname in file).

### (f) Open questions for the user

1. Should the timeline run **all the time** (including evenings/weekends, no session anywhere), or only between your first and last session of the day? Always-on is the honest mirror but it also watches your downtime.
2. Are app + website names enough detail ("Chrome · youtube · 34m"), or do you want it smarter about *what* you were doing — knowing that the smart version (screenshots + a vision model we'd have to build) costs battery and stores much more sensitive data?
3. How long should the detailed minute-by-minute history live on your Mac — a week, a month, forever? (Summaries can live longer than detail.)
4. Should your partner / future parent-view ever see this timeline, or is it for your eyes only?
5. When the timeline catches drift in real time isn't the point here — but should the **weekly review** quote it ("you averaged 50 min of YouTube on weekdays"), or does that cross into nagging?

---

## Cross-feature notes

- Features 1+3 interlock: commitment-break events are *consumed* by the weekly review — build the JSONL in F1 with F3's read in mind.
- Features 2's parked list is the Deep Work protocol's Exit-stage deferred list — one store, two doors. Don't build a second list later.
- Feature 4 is upstream of honest F3 numbers (`hours_done` today counts scheduled-block duration / manual logs, not observed work).
- All four stay inside the calm-down direction: no new notification surfaces, one new floating affordance total (the pill `+`).

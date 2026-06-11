# Design Debt Audit — 2026-06-11

**Scope:** dashboard.html (all pages incl. Rules/allowance), pill (DeepWorkTimerController.swift), overlays (FocusOverlayWindow.swift, focus-blocked.html, blocked.html, SweepReviewWindow.swift, StashInspectorWindow.swift), onboarding.html, login.html.
**Verdict:** the app isn't ugly — it's *five apps wearing one trenchcoat*. There is a real palette (coral `#E87461` + gold `#F0B060` on near-black) and it's good. The debt is that at least **four parallel design systems** coexist inside dashboard.html alone, three surfaces still ship the **old indigo/violet brand**, and there's no type/spacing/button scale — every component re-invents its own.

**P0 count: 7. P1 count: 8. P2 count: 5.**

---

## 1. Inventory of Inconsistencies

### P0 — brand-breaking / user-visible in one viewport

**P0-1. Four parallel design-token systems in dashboard.html.**
- Root system: `--accent-primary: #E87461`, `--text-primary/secondary/tertiary` — `dashboard.html:19–72`
- `.fm-v3` (Focus Mode editor): its own accent `--fm-accent: #FF7A2E` (different orange!), its own 4-step text scale `--fm-text-1..4` — `dashboard.html:4365–4383`
- `.cd-plan` (Plan page, ported prototype): its own `--text-1..4`, its own radii tokens `--r-sm/md/lg`, its own status colors, and a **cream light theme** (`#F7F3EA`) embedded in a dark app — `dashboard.html:4616–4660`
- `.ge-page` / `.cr-page` (goal editor / check-in review): partially their own label/button styles — `dashboard.html:4859–4897`
Same concept, four names: `--text-tertiary` ≈ `--fm-text-3` ≈ `--text-3` ≈ `#8e8e93`. This is the root cause of "feels vibecoded."

**P0-2. Three different brands across app surfaces.**
- Dashboard: coral/gold (`#E87461`/`#F0B060`)
- Pill + FocusOverlay: **old indigo/violet** — `focusedStart = Color(red: 0.39, 0.4, 0.95)` ≈ `#6366F2` at `DeepWorkTimerController.swift:905–906`, `focusHoursColor ≈ #7375FF` at `:915`; `accentStart/accentEnd` indigo→violet at `FocusOverlayWindow.swift:286–287`
- focus-blocked.html: indigo gradient `#6366f1 → #8b5cf6` — `focus-blocked.html:92`
- blocked.html: **stock-template purple** `#667eea → #764ba2` (the default "every vibecoded app" gradient) — `blocked.html:149`
- onboarding.html: violet/pink/cyan (`#8b5cf6`, `#ec4899`, `#06b6d4`) — old brand
- login.html: a *third* coral (`#FF7A2E`, `#FFB347`, `#FF4D5E`) that matches neither
The user sees the coral dashboard, an indigo pill, and a purple blocked page in the same session.

**P0-3. Indigo leftovers inside the coral dashboard.** `.btn-small` paints `color: #a5b4fc` (indigo-300) on a coral-rgba background — `dashboard.html:2151–2157`; same `#a5b4fc` on `.calendar-empty-btn` — `dashboard.html:2471`. These are the `+ Focus` button and the empty-calendar CTA — both in the owner's screenshot.

**P0-4. Button anarchy: ~25 distinct button classes, 4+ visual languages in one viewport.**
On Today alone: `+ Focus` (coral-tint outline pill, `dashboard.html:5034`), `+ Free Time` (green-tint outline pill, `:5035` via `.btn-small-free:2170`), `+ New` / `Open Plan →` (bare coral text spans, inline-styled, `:9711–9712, 9748–9750`), `…` (naked icon button, `:5037`). Elsewhere: `.btn-primary` (gradient, radius 12, `:1546`), `.rules-add-btn` (gradient but radius 7, weight 700, dark text `#1a0f0a`, `:1692`), `.inline-add-btn` (flat coral, radius 8, `:943`), `.ge-done-btn` (`:4872`), `.cr-add-btn` (`:4897`), `.cd-plan .btn-primary` (near-white bg, `:4691`), `.save-btn` (`:567`), plus `.btn-secondary`, `.btn-danger`, `.btn-ghost`, `.btn-quiet`, `.rules-btn-quiet`, `.blk-idea-btn`, `.create-profile-btn`, `.br-add-app-btn`, `.detail-add-btn`… Three different "primary" treatments (gradient/flat-coral/white) and three different radii (7/8/12) for the same intent.

**P0-5. Dark-theme contrast failures on body text.** Estimated ratios against `--bg-base: #060806`:
| Token / hex | Effective grey | Est. ratio | Used at | Verdict |
|---|---|---|---|---|
| `--text-tertiary: rgba(255,255,255,0.25)` (`:54`) | ≈ `#434443` | **≈ 2.0:1** | section headers, sidebar Session status (`:4970`), wg-section-header (`:427`), empty states | FAIL (AA needs 4.5) |
| `--text-4: rgba(255,255,255,0.22)` / `--fm-text-4: 0.24` | ≈ `#3c3d3c` | **≈ 1.9:1** | cd-plan/fm-v3 metadata | FAIL |
| `.calendar-empty-text rgba(255,255,255,0.3)` (`:2469`) | ≈ `#4f504f` | **≈ 2.4:1** | the main empty-page message | FAIL |
| `.section-title rgba(255,255,255,0.35)` (`:616`) | ≈ `#5c5d5c` | **≈ 2.9:1** | "SCHEDULE" header in screenshot | FAIL |
| `#636366` (9 uses, e.g. `:937`, `:949`) | — | **≈ 3.1:1** | chip labels at 9px, detail-empty | FAIL |
| `--text-secondary: rgba(255,255,255,0.5)` (`:53`) | ≈ `#838483` | ≈ 5.0:1 | body secondary | borderline pass |
This is the "washed-out grey" symptom. Tertiary text is being used for *content* (session status, empty-state copy), not just decoration.

**P0-6. Zero-stats shown as content.** `renderCalendar()` always renders "`--` focused / `--` off-task / `--` free" into the calendar header (`dashboard.html:11146–11149`), which becomes "0m focused 0m off-task 0m free" on an empty day — three dead numbers above an empty calendar. No hide-when-zero rule anywhere; same issue in Goal stat tiles ("Total hours / Sessions this week / Avg focus", `:13150–13161`).

**P0-7. Notification card overlaps the titlebar.** The sweep toast is injected at `position:fixed; top:20px; right:20px; z-index:99999` via inline `cssText` (`dashboard.html:6343–6347`). The WKWebView window's titlebar/traffic-light region owns the top ~28–52px, so the card sits on the chrome. `.save-indicator` has the same bug (`top: 12px; right: 24px`, `:589–598`). Neither respects a safe-area offset, and the sweep toast is 100% inline styles — invisible to any future theming.

### P1 — systemic inconsistency

**P1-1. 25 distinct font sizes** in dashboard.html (9, 9.5, 10, 10.5, 11, 11.5, 12, 12.5, 13, 13.5, 14, 14.5, 15, 16, 17, 18, 20, 22, 24, 26, 28, 32, 36, 40, 48px) — counted via grep. Half-pixel sizes (11.5, 12.5, 13.5, 14.5) are pure drift. Swift surfaces add their own ad-hoc ramp (10–24pt in FocusOverlayWindow).

**P1-2. ALL-CAPS dev-tool headers: 43 `text-transform: uppercase` rules.** `.section-title` (`:617`, renders "SCHEDULE"), `.wg-section-header` (`:426`, "THIS WEEK'S GOALS"), `.sidebar-label` (`:300`, "SESSION"), `.rules-section-h` (`:1677`), `.ns-modal-field label` (`:1655`), `.ge-advanced-label` with `letter-spacing: 1.4px` (`:4865`), stat tile labels (`:13152–13160`), eyebrows in cd-plan (`:4685, 4695`)… ALL-CAPS + low-contrast grey + 10–12px is the exact "engineer's debug UI" look. Opal uses sentence-case headers at full contrast.

**P1-3. 118 distinct padding combos, 13 gap values** (gap: 1,2,4,5,6,8,10,12,14,16,18,22,28px). No spacing scale exists; 5px/9px/7px paddings betray eyeballing.

**P1-4. 15 border radii** (1,2,3,4,5,6,7,8,9,10,12,14,16,20,999px). The same "card" concept renders at 7, 8, 10, 12 and 14px radii.

**P1-5. ~50 hardcoded hexes bypass the palette.** Top offenders inside dashboard.html: `#fa6464` (9× — a red that isn't `--color-error: #d45050`, e.g. sidebar stop-button `:4977`), `#7c3aed`/`#a78bfa` (violet leftovers), `#4ade80`/`#5cc09a`/`#1d9e75`/`#6fb58e` (four different greens for "success"), `#ef4444`/`#dc2626`/`#f87171`/`#d45050` (four reds), `#8e8e93`/`#636366`/`#6b7280` (three greys outside the token scale). Anything not routed through `--color-*` can't be retuned globally.

**P1-6. Two modal systems + inline one-offs.** `.ns-modal-overlay` (`:1650`, the sanctioned pattern per house rules) vs legacy `.modal-overlay/.modal-content` (`:2984`) vs `.ge-page .modal-*` (`:4859–4863`) vs the slide-in `#intention-mini-editor` built entirely from a 6-line inline style (`:14242`). Field labels differ per system (uppercase 11.5px vs uppercase 11px ls-1px vs none).

**P1-7. 13+ empty-state implementations**, each different: `.blocks-empty-card` (dashed border, `:415`), `.rules-empty` (`:1691`), `.detail-empty` (hardcoded `#636366`, `:949`), `.empty-state` (48px emoji icon, `:1284–1291`), `.calendar-empty-state` (`:2462`), `.br-empty` (italic, `:1669`), `.journal-empty` (`:1917`), `.ba-empty` (`:2584`), `.plan-memories-empty` (`:4003`), `.fm-v3 .empty-hint/.empty-list` (`:4543, 4600`), `.cd-plan .plan-empty-cta` (`:4697`), inline weekly-goal empty (`:9715–9717`). Some have CTAs, some don't; dashed vs solid vs none; italic vs not.

**P1-8. Swift surfaces are unstyled system-default.** SweepReviewWindow and StashInspectorWindow are plain NSPanels: system font, `.secondary` colors, default checkboxes, **system-blue** `.borderedProminent` confirm button (`SweepReviewWindow.swift:271`) — zero brand. They look like Xcode debug panels next to the coral dashboard.

### P2 — polish

**P2-1. 381 inline `style="…"` attributes** in dashboard.html markup + JS string templates — uncountable one-off decisions that can never be themed (e.g. `:5034` styles the + Focus button inline *on top of* `.btn-small`).
**P2-2. Title typography**: weights are fine (only 500/600/700) but heading sizes jump 22→26→28→32→36→40→48 with no scale; onboarding has 56px and 80px.
**P2-3. Emoji as icons** (🛡 🔒 ⏳ ✎ ⏹ ⋮⋮) — rendered at OS emoji style, fighting the sleek dark UI (`:4957, 4963, 5162, 5165, 4977`).
**P2-4. `.cd-plan` ships its own font stack** (`--font`, `:4617`) and its own light/dark themes inside a dark-only app (theme toggle is explicitly out of scope per CLAUDE.md).
**P2-5. Free-time green has 5 shades** (`#6ee7b7`, `#5cc09a`, `#4ade80`, `#6fb58e`, `#34d399` in onboarding) for the same semantic.

---

## 2. The Minimal Design System (proposal — restyle, not rebrand)

Everything below uses the **existing** root palette (`dashboard.html:19–72`). The job is deleting the parallel systems, not inventing a new one.

### Tokens (one source of truth, `:root` only)

```css
/* TYPE — 5 sizes, period. Kill all half-pixels. */
--type-display: 22px/600;   /* page titles, big numbers */
--type-title:   15px/600;   /* card titles, modal titles */
--type-body:    13px/400;   /* default. THE size. */
--type-label:   12px/500;   /* secondary rows, buttons-small, field labels */
--type-caption: 11px/500;   /* timestamps, counts — never for content */

/* SPACING — 4pt grid: 4, 8, 12, 16, 24, 32. Nothing else. */
--space-1: 4px; --space-2: 8px; --space-3: 12px;
--space-4: 16px; --space-6: 24px; --space-8: 32px;

/* RADIUS — 3 values. */
--radius-sm: 6px;   /* chips, inputs */
--radius-md: 10px;  /* buttons, cards */
--radius-lg: 14px;  /* modals, panels */

/* TEXT — keep existing tokens but FIX tertiary: */
--text-primary:  #f7f8f8;                  /* unchanged */
--text-secondary: rgba(255,255,255,0.62);  /* was 0.5 — lift to cd-plan's 0.62 (≈7:1) */
--text-tertiary: rgba(255,255,255,0.45);   /* was 0.25 — decoration only, NEVER content */
```

### Casing rules
- **Kill ALL-CAPS headers.** Section headers become sentence-case `--type-title` at `--text-primary`: "Schedule", "This week's goals", "Session". Delete all 43 `text-transform: uppercase` (exception: 2–4 char badges like "META").
- Subtitles: 3–7 words, sentence case, `--text-secondary` (house rule).
- Letter-spacing: 0 everywhere except badges.

### ONE button hierarchy (3 levels, delete the other ~22 classes)
```
.btn-primary    coral gradient (--accent-gradient), dark text #1a0f0a,
                radius-md, 8px 16px, 13px/600.  ONE per view max.
.btn-secondary  transparent, 1px solid rgba(255,255,255,0.14),
                --text-secondary, same metrics. Everything else.
.btn-text       bare --accent-primary text, no border, 12px/500.
                Inline affordances only ("+ New", "Open Plan →").
Destructive   = .btn-secondary with --color-error text/border. No solid-red buttons.
```
Today's header becomes: `+ Focus` → `.btn-secondary` (coral text), `+ Free Time` → `.btn-text`. The green-vs-coral type-coding moves into the *calendar blocks*, not the buttons.

### Empty-state template (one class, used everywhere)
```
.empty
  headline:  --type-body, --text-secondary, sentence case, ≤7 words
  action:    ONE .btn-secondary or .btn-text underneath
  container: no border (kill the dashed boxes), centered, padding --space-6
```
Copy pattern: *what's missing* + *the one verb*. "No goals this week yet — **+ Add a goal**". Never two CTAs, never an emoji glyph at 48px.

### Stat-display rule
**A zero/no-data stat is never rendered.** If `focusedMinutes == 0 && offTaskMinutes == 0`, the stats row doesn't exist — the empty state speaks instead. Stats appear only once they have ≥1 nonzero value, and "--" placeholders are forbidden in shipped UI. Applies to calendar header (`:11146`), goal tiles (`:13150`), pill stats.

### Card pattern (one card)
```
.card  background: var(--bg-elevated); border: 1px solid var(--border-subtle);
       border-radius: var(--radius-md); padding: var(--space-4);
       hover: border-color var(--border-hover);   /* no shadow-on-hover zoo */
```
Title row inside card: `--type-title` + optional `.btn-text` action on the right. That's the whole anatomy. `.settings-card`, `.wg-card`, allowance card, rule rows all collapse into this.

### Modal pattern
`.ns-modal-overlay` is the only modal (already the house rule for WKWebView). Port `.modal-overlay`, `.ge-page .modal-*`, and `#intention-mini-editor` to it. Field labels: `--type-label`, sentence case, `--text-secondary`.

### Cross-surface rule (the brand fix)
Define the palette once and mirror it into Swift as a `Theme` enum (`Theme.accent = #E87461`, `Theme.success = #5cc09a`, `Theme.error = #d45050`, `Theme.warning = #F0B060`). Pill, FocusOverlay, SweepReview, StashInspector, blocked.html, focus-blocked.html, login.html, onboarding.html all consume it. **Indigo (#6366f1 family) and stock-purple (#667eea/#764ba2) are deleted from the codebase.**

---

## 3. Sweep-Review Modal Redesign Sketch

**Current** (`SweepReviewWindow.swift:83–98, 202–276`): 640×640 system NSPanel, four collapsible sections (Probably close / Borderline / Probably keep / Apps), per-row checkboxes + strikethrough, per-section Check all/Uncheck all, confidence percentages, a "trust AI" toggle, and a footer with Cancel + "Close N items → Start" in system blue. It's an *audit table* — 640px of homework standing between the user and their focus session. Decision cost: ~15 micro-decisions before starting.

**Proposed: one-line consent card** (same `SweepReviewResult` contract, agency preserved — the user still clicks the button that closes things; nothing auto-closes):

```
┌────────────────────────────────────────────────────────┐
│  12 noise tabs found that don't match your goal        │
│  "Ship the billing refactor"                           │
│                                                        │
│      [ Stash 12 tabs ]      Keep everything            │
│       (primary, coral)       (text button)             │
│                                                        │
│  ⌄ Review them first                                   │
└────────────────────────────────────────────────────────┘
```
- Default surface: ~480×170. Headline = count + "noise" framing; subtitle = the intent (3–7 words, truncated).
- **[Stash N tabs]** = `.btn-primary` (coral, not system blue) → closes exactly the AI's probably-close + borderline set. **Keep everything** = `.btn-text` → `cancelled: true`.
- **⌄ Review them first** expands in-place to a single flat checklist (today's probably-close + borderline rows, pre-checked; probably-keep rows shown unchecked at the bottom, collapsed under "8 staying open ⌄"). No per-section bulk buttons, no confidence %, no four headers — the buckets become row *ordering*, not chrome.
- "Skip this review next time" moves out of the modal into Settings (it's a policy, not a per-session decision; the checkbox at `:258` invites accidental opt-in to exactly the auto-close behavior that burned us 2026-05-18).
- Words "probably close" (AI hedging) → "noise" (product language matching "close the noise").
- Esc = keep everything (unchanged). ⌘↩ = stash (unchanged).

Decision cost drops from ~15 to **1** for the 90% case, with the full review one click away — same consent principle, Opal-grade surface.

---

## 4. Today-Page Recomposition Sketch

Current order: weekly-goal cards strip → coach context (usually hidden) → "SCHEDULE" header + 3 button styles → giant empty calendar with "0m / 0m / 0m" stats and a dead zoom slider. The page leads with *infrastructure*, not the user's day.

Proposed (leads with the daily-commitment question per the locked product direction; calendar demoted; zero stats removed):

```
┌──────────────────────────────────────────────────────────────┐
│  Today                                          Wed, Jun 11  │   ← page title, sentence case
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  What are you working on today?                        │  │   ← THE daily commitment card.
│  │  Pick something so you don't end up with 30 tabs       │  │     state A (no commitment):
│  │  open and three half-finished tasks.                   │  │     question + goal picks
│  │                                                        │  │
│  │  ○ Ship billing refactor        ○ Write launch post    │  │   ← this week's goals as picks
│  │  ○ Something else…                                     │  │
│  │                                                        │  │
│  │              [ Start a focus session ]                 │  │   ← the ONE primary button
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ── when a session is live, the same card becomes: ──────    │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  ● Ship billing refactor          42:10 left           │  │   state B (committed):
│  │  2h 10m focused so far · on track          [ End ]     │  │   stats appear ONLY here,
│  └────────────────────────────────────────────────────────┘  │   only nonzero
│                                                              │
│  This week's goals                              + Add       │   ← sentence case, .btn-text
│  [ Billing refactor ] [ Launch post ] [ + ]                  │   ← compact chips, not 3 cards
│                                                              │
│  Schedule                              + Focus  + Free time  │   ← .btn-secondary + .btn-text
│  ┌────────────────────────────────────────────────────────┐  │
│  │  (collapsed: today's blocks as a LIST when ≤2 blocks)  │  │   ← calendar demoted: agenda
│  │  9:00   Deep work — billing        2h                  │  │     list by default; full
│  │  No more sessions planned — + add one                  │  │     timeline grid one click
│  │                                          Open calendar │  │     away ("Open calendar")
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

Rules encoded above:
1. **Daily commitment card is first and is the only primary action.** Empty day = a question, not a void. (Copy mirrors the unscheduled-time overlay copy locked in CLAUDE.md.)
2. **Calendar demoted** to an agenda list when the day has ≤2 blocks; the hour grid (+zoom slider) lives behind "Open calendar". An empty page never shows 14 empty hour rows.
3. **No dead zeros**: the "0m focused / 0m off-task / 0m free" row is deleted; focus stats render only inside the live-session card / end-of-day summary when nonzero.
4. **Button hierarchy applied**: one `.btn-primary` (Start a focus session), `+ Focus` as `.btn-secondary`, everything else `.btn-text`. The 3-style pile-up in one viewport is gone.
5. **Sentence-case headers** ("This week's goals", "Schedule") at full contrast — no more ALL-CAPS grey.

---

## Answer: P0 count + 5 highest-impact fixes

**P0s: 7** (parallel token systems · three brands across surfaces · indigo leftovers in coral UI · button anarchy · contrast failures · dead zero-stats · titlebar-overlapping toasts).

1. **Unify the brand across surfaces** — kill indigo in the pill/FocusOverlay/focus-blocked and stock-purple in blocked.html; one Swift `Theme` mirroring the coral CSS vars. Biggest "is this even one app?" fix.
2. **Collapse to one button hierarchy** (primary/secondary/text) and apply it to the Today header — directly erases the owner's 3-buttons-in-one-viewport screenshot.
3. **Fix the grey scale** — tertiary 0.25→0.45 alpha, secondary 0.5→0.62, and ban tertiary for content; instantly un-washes every page for ~4 lines of CSS.
4. **Kill ALL-CAPS section headers** (43 rules → sentence-case 15px/600 at full contrast) — the single biggest "dev tool → product" perception shift.
5. **Recompose Today around the daily-commitment card** — question-first, agenda-list calendar, no zero stats; turns the emptiest screen in the app into the most intentional one.

# Design System (polish wave, 2026-06-11)

Source of truth for the dashboard's visual scale. Establishes ONE token set so
new components stop re-inventing their own type/spacing/radius/button language.
This is a **restyle, not a rebrand** — the coral (`#E87461`) → gold (`#F0B060`)
palette on near-black is unchanged.

## Tokens (defined once, `:root` in `Intentional/dashboard.html`)

```css
/* TYPE — 5 sizes, no half-pixels */
--type-display: 22px;   /* page titles, big numbers */
--type-title:   15px;   /* card titles, section headers, modal titles */
--type-body:    13px;   /* default — THE size */
--type-label:   12px;   /* secondary rows, small buttons, field labels */
--type-caption: 11px;   /* timestamps, counts — never for content */

/* SPACING — 4pt grid */
--space-1: 4px; --space-2: 8px; --space-3: 12px;
--space-4: 16px; --space-6: 24px; --space-8: 32px;

/* RADIUS — 3 values */
--radius-sm: 6px;   /* chips, inputs */
--radius-md: 10px;  /* buttons, cards */
--radius-lg: 14px;  /* modals, panels */

/* TEXT — lifted for AA contrast on --bg-base (#060806) */
--text-primary:   #f7f8f8;
--text-secondary: rgba(255,255,255,0.62);  /* was 0.5  — body secondary */
--text-tertiary:  rgba(255,255,255,0.45);  /* was 0.25 — DECORATION ONLY */
```

**Rule: never use `--text-tertiary` for content.** It's for decorative
separators/hints only. Session status, empty-state copy, and section headers use
`--text-secondary` or `--text-primary`.

## Casing

- **No ALL-CAPS section headers.** Section headers are sentence-case
  `--type-title` at `--text-primary`/`--text-secondary` (e.g. "Schedule",
  "This week's goals", "Rules"). The `text-transform: uppercase` rules on
  `.section-title` / `.wg-section-header` / `.rules-section-h` / `.blk-section-h`
  / `.detail-section-label` were removed. (Short 2–4 char badges may stay caps.)

## Buttons (3 tiers — prefer these over the ~25 legacy classes)

- `.btn-primary` — coral gradient, dark text `#1a0f0a`, `--radius-md`. One per view.
- `.btn-secondary` — transparent, 1px `rgba(255,255,255,0.14)` border,
  `--text-secondary`. Everything else.
- `.btn-text` — bare `--accent-primary` text, no border, `--type-label`. Inline
  affordances ("+ New", "Open Goals →").

Legacy button classes still exist (full migration is out of scope for the polish
wave) but new UI should use these three.

## Zero-stat rule

**A zero/no-data stat is never rendered.** The calendar focus-stats row
(`#calendar-focus-stats`) is `display:none` until at least one of
focused/off-task/free is nonzero — no "0m focused · 0m off-task · 0m free" above
an empty day. The pill shows a neutral "Focusing" (grey) instead of an angry red
"0% focused" until the first real score lands (`hasFocusData` flag in
`DeepWorkTimerController`).

## Cross-surface brand (the one-app fix)

The pill, the focus overlay, the blocked pages, and login all use coral/gold —
indigo (`#6366f1` family) and stock-purple (`#667eea`/`#764ba2`) were removed:

| Surface | File | Was | Now |
|---|---|---|---|
| Pill focus dot + focus-hours color | `DeepWorkTimerController.swift` | indigo→violet | coral→gold |
| Focus overlay accent | `FocusOverlayWindow.swift` | indigo→violet | coral→gold |
| Free-time / unscheduled blocked page | `focus-blocked.html` | `#6366f1→#8b5cf6` | coral→gold |
| Site-blocked page (install button) | `blocked.html` | `#667eea→#764ba2` | coral→gold |
| Focus Mode editor accent | `dashboard.html` `.fm-v3` | `#FF7A2E` (2nd orange) | coral |

Still-pending (out of scope for this wave): SweepReviewWindow / StashInspector
Swift panels are still system-default; onboarding.html still ships old violet;
a shared Swift `Theme` enum mirroring the CSS vars is not yet built.

## Provenance

Audits that drove this: `docs/design-debt-audit-2026-06-11.md` (P0/P1/P2
inventory + proposed scale) and `docs/jargon-audit-2026-06-11.md` (copy).

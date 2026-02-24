# Chronological Timeline Bar in Assessment Popover

## Context

The block assessment popover (opened by clicking a completed/active block in the dashboard calendar) shows a summary of how the user spent time during that block. Currently it groups entries by app/title and shows proportional bars — but this loses the **chronological story** of the block. The user wants to see *when* they switched between apps, how long each stretch lasted, and be able to hover over segments to see details.

**Goal:** Add a new chronological timeline view to the assessment popover. Keep the existing list view. Let the user swipe/click between both views to compare them.

---

## Design

### Two-View Swipeable Popover

The popover gets a **view container** with two panels:
1. **Timeline View** (new, default) — chronological bar + legend
2. **List View** (existing) — current app-grouped rows

Navigation: two dots at the bottom of the popover (like iOS page indicators). Click a dot or swipe left/right to switch. CSS `transform: translateX()` for smooth sliding.

### Timeline View Layout

```
┌──────────────────────────────────────┐
│ Deep Work Block           87%   ✕    │  ← header (unchanged)
│ 5 apps · 3 relevant · 1 irrel · 52m │  ← summary (unchanged)
│ ▓▓▓▓▓▓▓▓▓▓▓▓░░░░▓▓▓▓▓▓▓▓▓▓░░▓▓▓▓▓ │  ← CHRONOLOGICAL bar (20px tall)
│ 9:00              9:30         10:00 │  ← time axis labels
│                                      │
│  ● VSCode             38m   73%      │  ← legend rows (top apps)
│  ● Chrome (github)    8m    15%      │
│  ● Chrome (reddit)    4m     8%      │  ← red dot, irrelevant
│  ● iTerm              2m     4%      │
│                                      │
│              ● ●                     │  ← page dots
└──────────────────────────────────────┘
```

### Chronological Bar

- **20px tall**, rounded corners, each segment is a contiguous time range where the user stayed on one app/domain
- Colors: green (#34d399) for relevant, red (#ef4444) for irrelevant, gray (#6b7280) for neutral
- Segment widths proportional to time duration (not tick count)
- **Hover tooltip** shows: app name (or domain for browser), time range ("9:02 — 9:15"), duration, page titles seen during that stretch
- Minimum segment width: 2px (very short segments still visible)

### Grouping for Timeline Segments

A new segment starts when the user switches to a different app OR a different domain within a browser. Consecutive entries with the same key merge into one segment.

- **Non-browser app**: key = appName (e.g. "VSCode", "iTerm")
- **Browser tab**: key = hostname extracted from the title, or appName fallback

Since hostname isn't in the JSONL yet, we need to add it.

### Legend Rows (below timeline bar)

Compact rows showing the top apps/domains sorted by time:
- Colored dot + name + total time + percentage
- Click a legend row to highlight its segments in the timeline bar

---

## File Changes

### 1. `Intentional/FocusMonitor.swift` — Add hostname to JSONL

**`RelevanceEntry` struct** (line 269): Add `hostname: String` field.

**`logAssessment()`** (line 284): Add `hostname` parameter (default `""`).

**`persistAssessment()`** (line 296): Add `"hostname": entry.hostname` to the dict.

**Call sites** — pass hostname where available:
- Browser tab assessments in `readAndScoreActiveTab()` (~line 794): already has `info.hostname`, pass it through
- Non-browser assessments: pass `""` (empty, will use appName in JS)
- Event logging (nudge/blocked): pass current hostname if available

### 2. `Intentional/MainWindow.swift` — Pass hostname to JS

**`handleGetBlockAssessments()`** (line 1546): Add `"hostname": obj["hostname"] ?? ""` to the entry dict.

### 3. `Intentional/dashboard.html` — New timeline view + swipe

#### New JS: `buildChronologicalSegments(entries)`

Takes raw entries (with timestamps), produces chronological segments:
```
[{ key, appName, hostname, startMs, endMs, durationMs, state, titles: [...] }, ...]
```

Algorithm:
1. Sort entries by timestamp
2. Walk entries — if same key as previous, extend current segment's endMs
3. If different key, close current segment, start new one
4. Each segment's state = majority vote of its entries (relevant/irrelevant/neutral)
5. Collect unique titles within each segment

#### New JS: `renderTimelineView(entries, data)`

- Renders the chronological bar: each segment is a `<div>` with width proportional to `(segment.durationMs / totalDurationMs) * 100%`
- Renders time axis labels (block start, middle, end)
- Renders legend rows (aggregated by key, sorted by total time)
- Attaches hover event listeners for tooltip

#### New CSS classes

- `.ba-views-container` — overflow hidden, holds both views side by side
- `.ba-view` — width 100%, inline-block
- `.ba-view-timeline` / `.ba-view-list` — the two view panels
- `.ba-timeline-bar` — 20px height, flex, rounded, overflow hidden
- `.ba-timeline-seg` — individual segment in timeline
- `.ba-timeline-seg:hover` — slight brightness increase
- `.ba-timeline-axis` — flex row with start/mid/end time labels
- `.ba-timeline-legend` — compact legend list
- `.ba-timeline-legend-row` — dot + name + time + pct
- `.ba-page-dots` — centered dot indicators at bottom
- `.ba-page-dot` / `.ba-page-dot.active` — inactive/active dot styling
- `.ba-tooltip` — positioned tooltip on hover (dark bg, rounded, pointer-events none)

#### Modified: `openBlockAssessments()`

- Popover HTML structure adds the view container and page dots
- Default view: timeline (index 0)

#### Modified: `_blockAssessmentsResult(entries)`

- Calls existing `aggregateAssessments()` for the list view (unchanged)
- Calls new `buildChronologicalSegments()` for the timeline view
- Renders both views into their respective containers
- Sets up swipe/click handlers on page dots

#### Swipe logic

- Track `touchstart` / `touchmove` / `touchend` on `.ba-views-container`
- On swipe > 50px threshold: switch view via `transform: translateX(-100%)` or `translateX(0)`
- Page dots clickable to switch directly
- CSS transition: `transform 0.3s ease`

---

## Files Modified

| File | Change |
|------|--------|
| `Intentional/FocusMonitor.swift` | Add `hostname` to `RelevanceEntry`, `logAssessment()`, `persistAssessment()`, and call sites |
| `Intentional/MainWindow.swift` | Pass `hostname` field in `handleGetBlockAssessments()` |
| `Intentional/dashboard.html` | New timeline view, chronological bar, legend, swipe navigation, page dots, tooltip CSS+JS |

---

## Verification

1. **Click a completed block** → popover opens on **timeline view** by default
2. **Chronological bar** shows segments in time order, colored by relevance, width proportional to duration
3. **Hover a segment** → tooltip shows app/domain, time range, duration, page titles
4. **Legend rows** below bar show top apps sorted by time
5. **Click the second page dot** (or swipe left) → slides to existing **list view** with all current functionality intact
6. **Click first dot** (or swipe right) → slides back to timeline view
7. **Hostname grouping**: browser tabs grouped by domain (e.g. "github.com"), not individual page titles
8. **Non-browser apps**: grouped by app name as before
9. **Build succeeds** with no warnings from the hostname field additions

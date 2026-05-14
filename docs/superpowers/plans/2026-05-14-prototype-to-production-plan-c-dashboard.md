# Prototype → Production — Dashboard / WKWebView Implementation Plan (Plan C)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the May 2026 prototype's UI surface from `docs/unified-design-2026-05-13/app.html` into the production dashboard `Intentional/dashboard.html`: (1) restructure the sidebar (drop Focus Modes, add Plan, add bottom blocking-pill + theme toggle), (2) replace the Today header with the 3-Weekly-Goal cards strip, (3) embed the Cloud Design Plan tab's React app verbatim, (4) build the full-page Weekly Goal editor + Custom Rules sub-page, and (5) wire all of these to the new bridge messages from Plan B.

**Architecture:** The dashboard already lives inside a single WKWebView fed by `MainWindow`. We keep that. We do not introduce new HTML files. We follow the [CLAUDE.md rule: design from `docs/unified-design-2026-05-13/app.html` must be reproduced exactly](../../../CLAUDE.md) — copying CSS scoped under `.cd-plan` and React JSX verbatim. The Cloud Design React Plan app is embedded the same way it is in the prototype (React+Babel CDN, mounted into `#plan-react-root` inside `#page-plan`). All data is fetched via the new bridge messages.

**Tech Stack:** Vanilla JS + WKWebView bridge, React 18 + Babel via CDN for the Plan tab only, CSS variables + nested selectors.

**Source-of-truth brief:** `docs/prototype-to-production-2026-05-14.md`.

**Prototype source:** `docs/unified-design-2026-05-13/app.html` — lines 656–680 (sidebar), 678–733 (Today + Plan view shells), 1062–1340 (Weekly Goal cards + editor + custom rules), 2310–2730 (Plan React app).

**Worktree:** same as Plan B — `/Users/arayan/Documents/GitHub/intentional-macos-app/.claude/worktrees/prototype-to-production`. Plan C work commits to the same branch (`feat/prototype-to-production`) after Plan B Phase 3 lands.

**Backend / Mac dependency:** Bridge messages (`GET_MONTHLY_GOALS`, `_monthlyGoalsList` receiver, extended `_intentionsList` payload, `LINK_WEEKLY_TO_MONTHLY`, `START_GOAL_SESSION`) must be live (Plan B Task 6 merged) before Phase 3 of this plan ships meaningfully — Phase 1 (sidebar + theme toggle) can land independently.

---

## Open questions for the user (consolidated — shared with Plans A + B)

These do NOT block Phase 1. They affect Phase 3 acceptance:

1. **Sidebar bottom blocking-pill behavior.** The prototype shows a "3 blocking" pill at the bottom of the sidebar that opens Today → Blocks mode. The current production dashboard has no Blocks-mode panel under Today. Default: **add a `Blocks` sub-view inside Today** that lists active blocking items (mirrors prototype 704–714). Confirm we want that sub-view, OR fall back to "pill click navigates to Settings → Always-Blocked sub-page".
2. **Theme toggle scope.** Light theme exists in the prototype but production has only dark today. Default: **ship the theme toggle as a no-op cosmetic placeholder for v1** — the toggle button is visible but flips a class on `<body>` that is not yet styled for light mode. (Full light-theme implementation is its own follow-up plan.) Confirm or override.
3. **Drag-to-schedule from Today card grip.** Drop target on the Today calendar (which is the existing Mac calendar, NOT the prototype's HTML calendar). Does the existing dashboard calendar accept HTML5 drag events on hour rows? Default: **add minimal drop-target hooks during this plan, fall back to "click grip → opens hour picker modal" if drop wiring proves brittle**. To be confirmed during Playwright verification.

---

## What this plan does NOT do

- Does not create new top-level HTML files (per CLAUDE.md rule: one canonical `dashboard.html` + the prototype `app.html`).
- Does not rewrite the existing Mac calendar component — Today's calendar stays as-is, only the header strip above it changes.
- Does not implement the block-conflict warning popup (deferred).
- Does not implement calendar drag-to-create / move / resize gestures (still deferred).
- Does not ship a polished light theme — toggle is cosmetic only (see Open Q 2).
- Does not ship the prototype's "+ Task" / "+ Free Time" overlay redesign — production keeps its existing `addFocusBlock` flow.
- Does not migrate the existing Settings page sidebar to the prototype's 11-subpage drilldown. (Brief item H.) Sidebar restructure includes adding/removing items; deep Settings restructure is deferred.

---

## File map

| File | Op | Purpose |
|---|---|---|
| `Intentional/dashboard.html` | MODIFY | (Phase 1) Sidebar: drop `Focus Modes`, add `Plan`, add bottom blocking-pill + theme toggle. Add CSS for `.sb-blocking`, `.theme-toggle-btn`, `[data-theme="light"]` stub. (Phase 2) Today: replace top-of-today section with `#now-card-mount` rendering 3 weekly-goal cards + drag/click handlers. (Phase 3) Plan: add `#page-plan` view container + the Cloud Design React app verbatim + React/Babel CDN scripts. (Phase 4) Weekly Goal editor: add `#page-goal-edit` view container + `openWeeklyGoalEdit` + `renderGoalEdit` + `openGoalCustomRules` (verbatim port from prototype). (Phase 5) Wire all bridge calls. |
| `scripts/playwright-tests/prototype-port-today-cards.mjs` | CREATE | Playwright: load `dashboard.html` via Mac app launch (or static `file://` against a fixture that stubs the bridge), assert 3 weekly cards visible, click opens editor, grip is draggable. |
| `scripts/playwright-tests/prototype-port-plan-tab.mjs` | CREATE | Playwright: switch to Plan tab, assert React app mounts, drag a weekly card onto Timeline strip, assert TimelineBlock appears. |
| `scripts/playwright-tests/prototype-port-goal-edit.mjs` | CREATE | Playwright: open editor, edit title/intent/outcome, save, assert UPDATE_INTENTION bridge call shape. |
| `Intentional/dashboard.html` (small JS test-mode hook) | MODIFY | Add `window.__INTENTIONAL_TEST_MODE` that, when set before bridge messages send, captures messages into `window.__capturedBridgeMessages` for Playwright assertions instead of failing on missing bridge. |

---

## Phase 1: Sidebar restructure (independently mergable)

### Task 1: Update sidebar HTML

**Files:**
- Modify: `Intentional/dashboard.html` at lines 4630–4663

- [ ] **Step 1.1: Replace sidebar inner HTML**

Find the existing `<div class="sidebar">` block (line 4630). Replace the items section (lines 4642–4662) with:

```html
  <div class="sidebar-item active" data-page="today" onclick="navigateTo('today')">
    <span class="sidebar-item-icon">◉</span> Today
  </div>
  <div class="sidebar-item" data-page="plan" onclick="navigateTo('plan')">
    <span class="sidebar-item-icon">📓</span> Plan
  </div>
  <!-- Focus Modes tab removed 2026-05-14 — replaced by Weekly Goal full-page editor reachable from Today/Plan cards -->
  <div class="sidebar-item" data-page="sensitive" onclick="navigateTo('sensitive')">
    <span class="sidebar-item-icon">◔</span> Sensitive Content
  </div>
  <div class="sidebar-item" data-page="lock" onclick="navigateTo('lock')">
    <span class="sidebar-item-icon">◫</span> Accountability
  </div>
  <div class="sidebar-item" data-page="settings" onclick="navigateTo('settings')">
    <span class="sidebar-item-icon">⚙</span> Settings
  </div>
  <div style="flex:1;"></div>

  <!-- Bottom: blocking-pill + theme toggle (May 2026 prototype port) -->
  <div class="sb-blocking" id="sb-blocking" onclick="navigateTo('today');setTodayMode && setTodayMode('blocks');">
    <span class="shield">🛡</span>
    <span id="sb-blocking-label">Nothing blocking</span>
    <span class="arrow">›</span>
  </div>
  <div class="theme-toggle-btn" onclick="toggleTheme()" id="theme-toggle-btn" title="Toggle theme">
    <span id="theme-toggle-icon">🌙</span>
    <span id="theme-toggle-label">Dark</span>
  </div>

  <div class="sidebar-label">Session</div>
  <div style="padding:4px 20px 8px;">
    <div id="sidebar-session-status" style="font-size:11px;color:var(--text-tertiary);">Free Time</div>
    <div id="sidebar-session-detail" style="font-size:10px;color:var(--text-tertiary);margin-top:2px;">No active session</div>
  </div>
```

- [ ] **Step 1.2: Add the CSS for `.sb-blocking`, `.theme-toggle-btn`, `[data-theme]`**

In the dashboard's `<style>` block, find the existing sidebar styles. Append (copy from `app.html` lines 60–120; CSS is verbatim):

```css
.sb-blocking { display:flex; align-items:center; gap:8px; margin: 6px 12px;
  padding: 8px 10px; border-radius: 8px; background: rgba(255,255,255,0.04);
  font-size: 12px; color: var(--text-primary); cursor: pointer; user-select: none; }
.sb-blocking .shield { font-size: 13px; }
.sb-blocking .arrow { margin-left:auto; color: var(--text-tertiary); }
.sb-blocking.empty { opacity: 0.55; }
.theme-toggle-btn { display:flex; align-items:center; gap:6px; margin: 4px 12px 12px;
  padding: 6px 10px; border-radius: 8px; background: rgba(255,255,255,0.03);
  font-size: 11px; color: var(--text-secondary); cursor: pointer; user-select: none; }
.theme-toggle-btn:hover { background: rgba(255,255,255,0.06); }
/* Light theme stub — toggled by .toggleTheme(). v1: cosmetic only. */
body[data-theme="light"] { /* placeholder for future light-theme styling */ }
```

- [ ] **Step 1.3: Add the `toggleTheme()` + sidebar-blocking-pill JS**

Append to the dashboard's main `<script>`:

```js
// Theme toggle (v1: cosmetic placeholder per Plan C open Q 2)
function toggleTheme() {
  const isLight = document.body.getAttribute('data-theme') === 'light';
  document.body.setAttribute('data-theme', isLight ? 'dark' : 'light');
  document.getElementById('theme-toggle-icon').textContent = isLight ? '🌙' : '☀️';
  document.getElementById('theme-toggle-label').textContent = isLight ? 'Dark' : 'Light';
  try { localStorage.setItem('intentional.theme', isLight ? 'dark' : 'light'); } catch {}
}
// On load, restore theme:
(function restoreTheme() {
  try {
    const t = localStorage.getItem('intentional.theme') || 'dark';
    if (t === 'light') {
      document.body.setAttribute('data-theme', 'light');
      document.getElementById('theme-toggle-icon').textContent = '☀️';
      document.getElementById('theme-toggle-label').textContent = 'Light';
    }
  } catch {}
})();

// Sidebar blocking pill — populated by the schedule/focus state.
// For now, count actively-enforcing intentions / blocks.
function refreshSidebarBlockingPill() {
  // Source: window._activeBlockCount is set by existing schedule sync.
  // If we don't have it yet, fall back to 0.
  const count = (typeof window._activeBlockCount === 'number') ? window._activeBlockCount : 0;
  const el = document.getElementById('sb-blocking');
  const lbl = document.getElementById('sb-blocking-label');
  if (!el || !lbl) return;
  if (count === 0) {
    el.classList.add('empty');
    lbl.textContent = 'Nothing blocking';
  } else {
    el.classList.remove('empty');
    lbl.textContent = `${count} blocking`;
  }
}
// Hook into existing schedule push:
const _origScheduleSync = window._scheduleSync;
window._scheduleSync = function(payload) {
  if (_origScheduleSync) _origScheduleSync(payload);
  if (payload && Array.isArray(payload.active_blocks)) {
    window._activeBlockCount = payload.active_blocks.length;
    refreshSidebarBlockingPill();
  }
};
refreshSidebarBlockingPill();
```

(If `_scheduleSync` doesn't exist under that name in the production dashboard, grep for the existing schedule-push receiver and bind to that. Common candidates: `window._scheduleUpdate`, `window._scheduleSync`. The hook must compose with whatever is there — never replace.)

- [ ] **Step 1.4: Add the `plan` page container stub**

In the main view area (after `<div class="page active" id="page-today">` and before `<div class="page" id="page-intentions">` if present), add:

```html
<!-- Page: Plan (Cloud Design React app — see Phase 3) -->
<div class="page" id="page-plan">
  <div class="cd-plan" data-theme="dark">
    <div id="plan-react-root"></div>
  </div>
</div>
```

- [ ] **Step 1.5: Build + test + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
# Manual: launch Intentional, confirm sidebar shows 5 items + bottom pill + theme toggle.
git add Intentional/dashboard.html
git commit -m "feat(goals): sidebar restructure + blocking pill + theme toggle stub"
```

**Acceptance criteria:**
- Sidebar shows Today / Plan / Sensitive Content / Accountability / Settings.
- Plan tab is clickable and switches the page container (content empty for now).
- Bottom blocking pill is visible and reads "Nothing blocking" by default.
- Theme toggle flips `body[data-theme]` + persists.

---

## Phase 2: Today header — weekly-goal cards strip (depends on Plan B Task 6)

### Task 2: Replace Today header with 3 weekly-goal cards

**Files:**
- Modify: `Intentional/dashboard.html` (inside `#page-today`)

- [ ] **Step 2.1: Add a mount div at the top of `#page-today`**

Find `<div class="page active" id="page-today">` (line 4679). Immediately after the opening `<div>`, add:

```html
  <div id="now-card-mount"></div>
```

- [ ] **Step 2.2: Add CSS for weekly-goal cards**

Copy verbatim from `docs/unified-design-2026-05-13/app.html` (find the `.wg-section-header`, `.wg-row`, `.wg-card`, `.wg-edge`, `.wg-ttl`, `.wg-out`, `.wg-foot`, `.wg-status`, `.wg-grip` rules — they live in the prototype's `<style>` block, ~lines 290–360). Paste into the dashboard's main `<style>`.

- [ ] **Step 2.3: Add `renderNowCard()` + drag-and-drop handlers (verbatim port)**

Append to the dashboard's `<script>` (mirrors prototype lines 1102–1170):

```js
// May 2026 prototype port — weekly-goal cards strip on Today.
// Source: docs/unified-design-2026-05-13/app.html lines 1062–1170.

window._intentionsCache = window._intentionsCache || [];
window._monthlyGoalsCache = window._monthlyGoalsCache || [];

// Hook the existing _intentionsList receiver so we cache + render.
(function () {
  const orig = window._intentionsList;
  window._intentionsList = function (list) {
    window._intentionsCache = Array.isArray(list) ? list : [];
    renderNowCard();
    if (typeof orig === 'function') orig(list);
  };
})();

// Add a new receiver for monthly goals.
window._monthlyGoalsList = function (list) {
  window._monthlyGoalsCache = Array.isArray(list) ? list : [];
  renderNowCard();
};

// Filter: only show goals for the current week (ISO Monday). Fall back to
// "all intentions" if none have a week_of set yet.
function _currentWeekISO() {
  const d = new Date();
  const day = d.getDay() || 7;  // 1..7, Mon=1
  d.setDate(d.getDate() - (day - 1));
  return d.toISOString().slice(0, 10);
}

function renderNowCard() {
  const mount = document.getElementById('now-card-mount');
  if (!mount) return;
  const week = _currentWeekISO();
  let goals = (window._intentionsCache || []).filter(g => g.week_of === week);
  if (goals.length === 0) {
    // Fallback during migration: show top-3 unscheduled
    goals = (window._intentionsCache || []).slice(0, 3);
  } else {
    goals = goals.slice(0, 3);
  }
  if (goals.length === 0) {
    mount.innerHTML = `
      <div class="wg-section-header">
        <span class="wg-lbl"><strong>This week's goals</strong></span>
        <span class="wg-hint" onclick="navigateTo('plan')" style="cursor:pointer;color:var(--accent-primary);">Open Plan →</span>
      </div>
      <div style="padding:18px;border:1px dashed rgba(255,255,255,0.12);border-radius:10px;font-size:13px;color:var(--text-tertiary);text-align:center;">No goals yet. Open Plan to add this week's goals.</div>
    `;
    return;
  }
  const cards = goals.map(g => {
    const monthly = (window._monthlyGoalsCache || []).find(m => m.id === g.monthly_goal_id);
    const hue = (monthly && monthly.color_hex) ? monthly.color_hex : null;
    const edge = hue ? `<span class="wg-edge" style="--wg-hue: ${hue};"></span>` : '';
    const status = g.status === 'in_progress' ? 'in progress' : (g.status || 'planned');
    const statusClass = monthly ? (g.status || 'planned').replace('_', '-') : 'unlinked';
    const hoursLine = g.hours_done > 0 ? ` · ${g.hours_done}h done` : '';
    return `
      <div class="wg-card${monthly ? '' : ' unlinked'}"
        onclick="openWeeklyGoalEdit('${g.id}')">
        ${edge}
        <div class="wg-ttl">${escapeHTML(g.name)}</div>
        <div class="wg-out">${escapeHTML(g.outcome || '')}</div>
        <div class="wg-foot">
          <span class="wg-status ${statusClass}">${status}${hoursLine}</span>
          <span style="margin-left:auto;" class="wg-grip"
            draggable="true"
            ondragstart="event.stopPropagation(); weeklyGoalDragStart(event, '${g.id}')"
            ondragend="weeklyGoalDragEnd(event)"
            onclick="event.stopPropagation()"
            title="Drag to schedule">⋮⋮</span>
        </div>
      </div>
    `;
  }).join('');
  mount.innerHTML = `
    <div class="wg-section-header">
      <span class="wg-lbl"><strong>This week's goals</strong> · drag onto schedule to create a session</span>
      <span class="wg-hint" onclick="navigateTo('plan')" style="cursor:pointer;color:var(--accent-primary);">Open Plan →</span>
    </div>
    <div class="wg-row">${cards}</div>
  `;
}

let _dragGoalId = null;
function weeklyGoalDragStart(e, id) {
  _dragGoalId = id;
  e.target.classList.add('dragging');
  e.dataTransfer.effectAllowed = 'copy';
  e.dataTransfer.setData('text/plain', id);
}
function weeklyGoalDragEnd(e) {
  _dragGoalId = null;
  e.target.classList.remove('dragging');
  document.querySelectorAll('.calendar-hour-row.drop-hover').forEach(r => r.classList.remove('drop-hover'));
}

// Wire drop-target onto existing calendar hour rows. The exact selector
// depends on the dashboard's calendar markup — grep for the hour-row class.
// Per Open Q 3 default: minimal wiring; fall back to click-grip-→-modal if
// drop wiring is brittle.
function _wireGoalDropTargets() {
  const rows = document.querySelectorAll('.calendar-hour-row, .calendar-row');
  rows.forEach(row => {
    row.addEventListener('dragover', e => {
      if (!_dragGoalId) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
      row.classList.add('drop-hover');
    });
    row.addEventListener('dragleave', () => row.classList.remove('drop-hover'));
    row.addEventListener('drop', e => {
      if (!_dragGoalId) return;
      e.preventDefault();
      row.classList.remove('drop-hover');
      const hour = parseInt(row.dataset.hour || '9', 10);
      // Bridge: create a session bound to this goal at this hour, today.
      window.webkit?.messageHandlers?.bridge?.postMessage({
        type: 'START_GOAL_SESSION',
        intention_id: _dragGoalId,
        start_hour: hour,
        start_date: new Date().toISOString().slice(0, 10),
      });
      _dragGoalId = null;
    });
  });
}
// Re-wire whenever the calendar re-renders.
const _origRenderCalendar = window.renderCalendar;
if (typeof _origRenderCalendar === 'function') {
  window.renderCalendar = function () {
    _origRenderCalendar.apply(this, arguments);
    _wireGoalDropTargets();
  };
}

function escapeHTML(s) {
  return String(s || '').replace(/[&<>"']/g, c => ({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
  })[c]);
}

// Pull initial data on dashboard ready.
window.addEventListener('DOMContentLoaded', () => {
  if (window.webkit?.messageHandlers?.bridge) {
    window.webkit.messageHandlers.bridge.postMessage({type: 'GET_INTENTIONS'});
    window.webkit.messageHandlers.bridge.postMessage({type: 'GET_MONTHLY_GOALS'});
  }
});
```

- [ ] **Step 2.4: Verify with Playwright (test mode)**

```bash
cd scripts/playwright-tests
node prototype-port-today-cards.mjs
```

(See Task 6 for the script.)

- [ ] **Step 2.5: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "feat(goals): Today header — 3 weekly-goal cards with drag-to-schedule"
```

**Acceptance criteria:**
- On Today, the 3 (or fewer) current-week weekly-goal cards render at the top.
- Clicking a card opens the editor (Phase 4).
- The grip is draggable; dropping on a calendar hour row sends `START_GOAL_SESSION`.

---

## Phase 3: Plan tab — Cloud Design React app verbatim (depends on Plan B Task 6)

### Task 3: Embed React + Babel CDN + Plan app

**Files:**
- Modify: `Intentional/dashboard.html`

- [ ] **Step 3.1: Add React + Babel CDN scripts in `<head>`**

Right before the existing `</head>`, add:

```html
<!-- React + Babel for the Plan tab (May 2026 prototype port — Cloud Design verbatim). -->
<script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
<script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
<script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
```

Note: WKWebView allows external scripts by default unless CSP locks them down. If `dashboard.html` has a `<meta http-equiv="Content-Security-Policy">`, extend `script-src` with `https://unpkg.com`.

- [ ] **Step 3.2: Copy the Cloud Design CSS verbatim**

Copy the `.cd-plan { ... }` CSS block from `docs/unified-design-2026-05-13/app.html` (the `.cd-plan`-scoped rules — locate by searching for `.cd-plan` in the prototype's `<style>`). Paste verbatim into the dashboard's `<style>`.

- [ ] **Step 3.3: Copy the React script verbatim**

Find the `<script type="text/babel">` block in `docs/unified-design-2026-05-13/app.html` starting at line 2310 (`const HUE = ...`) and ending at the `ReactDOM.createRoot(...).render(<PlanApp />)` at line 2726. Copy it **verbatim** into a new `<script type="text/babel">` block at the bottom of `dashboard.html`, just before the closing `</body>`.

Per CLAUDE.md rule: "Use the actual code provided. ... Don't substitute colors, typography, spacing, or layout."

- [ ] **Step 3.4: Replace the hardcoded `MONTHLY` and `WEEKLY` constants with bridge-fed state**

The verbatim React app uses hardcoded `MONTHLY` and `WEEKLY` arrays. To wire it to bridge data, change ONLY the top-of-script constants to read from `window._monthlyGoalsCache` and `window._intentionsCache` if those are populated:

```js
// Initialize from the dashboard's cache (Mac bridge data); fall back to the
// prototype's hardcoded sample data for off-line dev.
const MONTHLY = (window._monthlyGoalsCache && window._monthlyGoalsCache.length)
  ? window._monthlyGoalsCache.map(g => ({
      id: g.id, title: g.title, outcome: g.outcome,
      hue: g.color_hex || HUE.coral,
    }))
  : [
      { id:'m1', title:'Ship Puck to 25 founding members', outcome:'25 paid orders by May 31', hue: HUE.coral },
      { id:'m2', title:'4hr deep work daily',              outcome:'20 weekdays averaged',     hue: HUE.green },
      { id:'m3', title:'Hit 10k followers on Puck IG',     outcome:'From 0 to 10k by May 31',  hue: HUE.pink  },
    ];
```

Same approach for `WEEKLY`: group `window._intentionsCache` by `week_of`. Provide a `mapIntentionsToWeekly()` helper that groups by Monday-of-week and produces the `{may11: [...]}` shape the React app expects. Keep the hardcoded fallback for offline dev.

For Phase 3 the data flow is: `_intentionsList` / `_monthlyGoalsList` arrives → cache updated → if Plan tab is mounted, re-render via React state push. Easiest pattern: add `useEffect` inside `PlanApp` that registers `window._planAppRefresh = () => setSeed(Date.now())` and call it from the cache-update receivers.

- [ ] **Step 3.5: Mount the React app only when Plan tab is first opened**

Wrap the `ReactDOM.createRoot(...).render(<PlanApp />)` call in a function `mountPlanApp()` and call it from `navigateTo('plan')` exactly once. Without this guard, the unmounted div causes a console warning on first dashboard load.

```js
let _planAppMounted = false;
window.mountPlanApp = function () {
  if (_planAppMounted) return;
  const root = document.getElementById('plan-react-root');
  if (!root) return;
  ReactDOM.createRoot(root).render(React.createElement(PlanApp));
  _planAppMounted = true;
};
// Hook navigateTo
const _origNavigateTo = window.navigateTo;
window.navigateTo = function (page) {
  if (typeof _origNavigateTo === 'function') _origNavigateTo(page);
  if (page === 'plan') window.mountPlanApp();
};
```

- [ ] **Step 3.6: Wire the React app's `openWeeklyGoalEdit` → dashboard's editor**

The React app calls `window.openWeeklyGoalEdit(g.id)`. Phase 4 will define that function. Until then, the click is a no-op safely (the function reference doesn't exist yet — the React app's check `window.openWeeklyGoalEdit` is truthy after Phase 4 lands).

- [ ] **Step 3.7: Wire React drop → bridge**

The React app's `handleDropOnTimeline({start, end})` adds a block to its local state. In production we also want to persist it as a session/time block. After the local `setBlocks(...)`, post a bridge message:

```js
window.webkit?.messageHandlers?.bridge?.postMessage({
  type: 'START_GOAL_SESSION',
  intention_id: dragSource.goalId,
  start_hour: Math.floor(start),
  start_minute: Math.round((start % 1) * 60),
  end_hour: Math.floor(end),
  end_minute: Math.round((end % 1) * 60),
  start_date: new Date().toISOString().slice(0, 10),
});
```

- [ ] **Step 3.8: Playwright + commit**

```bash
cd scripts/playwright-tests
node prototype-port-plan-tab.mjs
git add Intentional/dashboard.html scripts/playwright-tests/prototype-port-plan-tab.mjs
git commit -m "feat(goals): Plan tab — Cloud Design React app embedded verbatim + bridge wiring"
```

**Acceptance criteria:**
- Navigating to Plan mounts the React app once (no console warnings).
- Monthly cards row + Weekly cards row + Timeline strip render.
- Dragging a weekly card onto Timeline produces a TimelineBlock + emits `START_GOAL_SESSION` bridge message.
- History dropdown opens; clicking a past week loads its data.
- "Open today →" link navigates back to Today.
- The CSS palette + spacing match the prototype EXACTLY (visual diff against `app.html`).

---

## Phase 4: Full-page Weekly Goal editor + Custom Rules sub-page (depends on Plan B Task 6)

### Task 4: Add `#page-goal-edit` view container + editor JS

**Files:**
- Modify: `Intentional/dashboard.html`

- [ ] **Step 4.1: Add the page container**

After `#page-plan`, before the next existing page, add:

```html
<!-- Page: Weekly Goal full-page editor (May 2026 prototype port) -->
<div class="page" id="page-goal-edit">
  <div id="goal-edit-mount"></div>
</div>
```

- [ ] **Step 4.2: Copy the editor CSS verbatim from `app.html`**

From `docs/unified-design-2026-05-13/app.html` `<style>` block, find the `.ge-`, `.gm-`, `.cr-` selectors. Copy verbatim into `dashboard.html`'s `<style>`. (Approximately 80 lines.)

- [ ] **Step 4.3: Add `openWeeklyGoalEdit`, `closeGoalEdit`, `renderGoalEdit`, `openGoalCustomRules` — verbatim port from prototype lines 1172–1340 — adapted to use bridge-cached data**

```js
let _goalEditReturnTo = 'today';

function openWeeklyGoalEdit(id) {
  // Switch the dashboard page
  _goalEditReturnTo = (window.currentPage === 'plan' || window.currentPage === 'today')
    ? window.currentPage : 'today';
  navigateTo('goal-edit');
  renderGoalEdit(id);
}
window.openWeeklyGoalEdit = openWeeklyGoalEdit;  // exposed for the React app

function closeGoalEdit() {
  navigateTo(_goalEditReturnTo || 'today');
}

function renderGoalEdit(id) {
  const g = (window._intentionsCache || []).find(x => x.id === id);
  if (!g) {
    document.getElementById('goal-edit-mount').innerHTML = `<div style="padding:24px;color:var(--text-tertiary);">Goal not found.</div>`;
    return;
  }
  const monthly = (window._monthlyGoalsCache || []).find(m => m.id === g.monthly_goal_id);
  const hue = monthly?.color_hex || 'var(--accent-primary)';
  const intentLen = (g.intent_text || '').length;
  const blockCount = ((g.mac_websites || []).length) + ((g.mac_bundle_ids || []).length);
  const allowCount = ((g.allow_websites || []).length) + ((g.allow_bundle_ids || []).length);
  const monthlyLabel = monthly ? `${monthly.title}` : 'No link · standalone';
  const aiOn = g.ai_scoring_enabled !== false;
  const status = g.status || 'planned';
  const strict = g.strictness_preset || 'standard';

  document.getElementById('goal-edit-mount').innerHTML = `
    <div class="ge-page">
      <div class="ge-back" onclick="closeGoalEdit()">‹ All Weekly Goals</div>

      <div class="ge-title-row">
        <input type="text" class="ge-title-input" value="${escapeHTML(g.name)}" id="ge-title-input">
        <div class="ge-rename-hint">Click to rename</div>
      </div>

      <div class="ge-main-card" style="--ge-hue: ${hue};">
        <div class="gm-header" style="justify-content: space-between;">
          <div style="display:flex; align-items:center; gap:6px;">
            <h3>What are you working on?</h3>
            <span class="gm-info" title="Drives local AI relevance scoring for this goal.">ⓘ</span>
          </div>
          <div style="display:flex; align-items:center; gap:6px;">
            <span style="font-size:10px; text-transform:uppercase; letter-spacing:0.8px; color:var(--text-tertiary); font-weight:700;">AI scoring</span>
            <div class="toggle-switch ${aiOn ? 'on' : ''}" id="ge-ai-toggle" onclick="this.classList.toggle('on')"></div>
          </div>
        </div>
        <textarea class="gm-textarea" id="ge-intent-text" maxlength="140"
          placeholder="Describe what you'll be doing — apps, sites, what success looks like."
          oninput="document.getElementById('ge-intent-counter').textContent = this.value.length + ' / 140'"
          >${escapeHTML(g.intent_text || '')}</textarea>
        <div style="display:flex; align-items:center; justify-content:space-between; margin-top:6px;">
          <div style="font-size:11px; color:var(--text-tertiary);">Only used if AI scoring is on.</div>
          <div class="gm-counter" id="ge-intent-counter">${intentLen} / 140</div>
        </div>
      </div>

      <div class="ge-row" onclick="openGoalCustomRules('${g.id}')" style="--ge-hue: ${hue};">
        <div class="gm-color-square"></div>
        <div class="gm-row-title">Custom rules</div>
        <div class="gm-row-counts">
          <span class="gm-count"><span class="dot block"></span>${blockCount} blocked</span>
          <span class="gm-count"><span class="dot allow"></span>${allowCount} allowed</span>
        </div>
        <span class="gm-row-chev">›</span>
      </div>

      <div class="modal-field"><label>Outcome (done looks like)</label>
        <textarea class="modal-input textarea" id="ge-outcome">${escapeHTML(g.outcome || '')}</textarea>
      </div>

      <div class="modal-row">
        <div class="modal-field"><label>Status</label>
          <div class="strict-pills" id="ge-status-pills">
            <span class="strict-pill ${status==='in_progress'?'active':''}" data-value="in_progress">In progress</span>
            <span class="strict-pill ${status==='planned'?'active':''}" data-value="planned">Planned</span>
            <span class="strict-pill ${status==='done'?'active':''}" data-value="done">Done</span>
          </div>
        </div>
        <div class="modal-field"><label>For monthly goal</label>
          <div class="modal-input" id="ge-monthly-picker" style="cursor:pointer;" onclick="openMonthlyGoalPicker('${g.id}')">${escapeHTML(monthlyLabel)}</div>
        </div>
      </div>

      <div class="ge-divider"></div>
      <div class="ge-advanced-label">Advanced</div>

      <div class="ge-adv-row">
        <span class="gm-adv-label">Strictness</span>
        <div class="strict-pills" id="ge-strict-pills">
          <span class="strict-pill ${strict==='standard'?'active':''}" data-value="standard">Standard</span>
          <span class="strict-pill ${strict==='strict'?'active':''}" data-value="strict">Strict</span>
        </div>
        <span class="gm-adv-label" style="margin-left:30px;">Weekly target</span>
        <input type="number" class="ge-num-input" id="ge-weekly-target" value="${g.weekly_target_hours || ''}" placeholder="—">
        <span style="font-size:12px; color:var(--text-tertiary);">hrs / week</span>
      </div>

      <div class="ge-foot">
        <button class="ge-delete-link" onclick="deleteWeeklyGoal('${g.id}')">Delete this Weekly Goal</button>
        <div class="right" style="display:flex; gap:8px;">
          <button class="btn-quiet" onclick="closeGoalEdit()">Cancel</button>
          <button class="ge-done-btn" onclick="saveWeeklyGoal('${g.id}')">Done</button>
        </div>
      </div>
    </div>
  `;
  // Wire pill toggling for status + strictness
  document.querySelectorAll('#ge-status-pills .strict-pill').forEach(p => {
    p.onclick = () => {
      document.querySelectorAll('#ge-status-pills .strict-pill').forEach(x => x.classList.remove('active'));
      p.classList.add('active');
    };
  });
  document.querySelectorAll('#ge-strict-pills .strict-pill').forEach(p => {
    p.onclick = () => {
      document.querySelectorAll('#ge-strict-pills .strict-pill').forEach(x => x.classList.remove('active'));
      p.classList.add('active');
    };
  });
}

function saveWeeklyGoal(id) {
  const g = (window._intentionsCache || []).find(x => x.id === id);
  if (!g) return;
  const name = document.getElementById('ge-title-input').value.trim() || g.name;
  const intentText = document.getElementById('ge-intent-text').value;
  const outcome = document.getElementById('ge-outcome').value;
  const status = document.querySelector('#ge-status-pills .strict-pill.active')?.dataset.value || 'planned';
  const strictness = document.querySelector('#ge-strict-pills .strict-pill.active')?.dataset.value || 'standard';
  const weeklyTarget = parseFloat(document.getElementById('ge-weekly-target').value) || null;
  const aiOn = document.getElementById('ge-ai-toggle').classList.contains('on');
  window.webkit?.messageHandlers?.bridge?.postMessage({
    type: 'UPDATE_INTENTION',
    id, version: g.version,
    name,
    description: g.description || '',
    color_hex: g.color_hex || null,
    icon: g.icon || null,
    mac_websites: g.mac_websites || [],
    mac_bundle_ids: g.mac_bundle_ids || [],
    allow_websites: g.allow_websites || [],
    allow_bundle_ids: g.allow_bundle_ids || [],
    monthly_goal_id: g.monthly_goal_id || null,
    week_of: g.week_of || _currentWeekISO(),
    intent_text: intentText,
    ai_scoring_enabled: aiOn,
    outcome,
    status,
    weekly_target_hours: weeklyTarget,
    strictness_preset: strictness,
  });
  // For strictness changes, the existing UPDATE_INTENTION_STRICTNESS path
  // owns cool-down + partner-unlock. If strictness changed, fire that too.
  if (g.strictness_preset && g.strictness_preset !== strictness) {
    window.webkit?.messageHandlers?.bridge?.postMessage({
      type: 'UPDATE_INTENTION_STRICTNESS',
      id, to_preset: strictness,
    });
  }
  showToast?.('Saved');
  closeGoalEdit();
}

function deleteWeeklyGoal(id) {
  if (!confirm('Delete this weekly goal? Past sessions stay; future sessions become unlinked.')) return;
  window.webkit?.messageHandlers?.bridge?.postMessage({type:'DELETE_INTENTION', id});
  closeGoalEdit();
}

function openGoalCustomRules(goalId) {
  const g = (window._intentionsCache || []).find(x => x.id === goalId);
  if (!g) return;
  const blocks = [
    ...(g.mac_websites || []).map(name => ({name, type:'site'})),
    ...(g.mac_bundle_ids || []).map(name => ({name, type:'app'})),
  ];
  const allows = [
    ...(g.allow_websites || []).map(name => ({name, type:'site'})),
    ...(g.allow_bundle_ids || []).map(name => ({name, type:'app'})),
  ];
  const renderEntries = list => list.map(e => `
    <div class="cr-entry">
      <span class="name">${escapeHTML(e.name)}</span>
      <span class="type-pill">${e.type}</span>
      <span class="remove" data-name="${escapeHTML(e.name)}" data-type="${e.type}" onclick="removeRule('${goalId}', this.dataset.name, this.dataset.type, this.closest('.cr-section').classList.contains('cr-block') ? 'block' : 'allow')">×</span>
    </div>
  `).join('');
  document.getElementById('goal-edit-mount').innerHTML = `
    <div class="ge-page cr-page">
      <div class="ge-back" onclick="openWeeklyGoalEdit('${goalId}')">‹ ${escapeHTML(g.name)}</div>

      <div class="ge-title-row" style="margin-bottom:6px;">
        <div style="font-size:22px; font-weight:700;">Custom rules</div>
        <div style="font-size:13px; color:var(--text-tertiary); margin-top:4px;">During <strong>${escapeHTML(g.name)}</strong> sessions only.</div>
      </div>

      <div class="cr-info-card">
        <strong>Most goals don't need custom rules</strong> — AI scoring handles the rest. Add tweaks here only if you want to.
      </div>

      <div class="cr-section cr-block">
        <div class="cr-section-header">
          <span class="left block"><span class="dot block"></span>Block</span>
          <span class="right">${blocks.length} entries</span>
        </div>
        <div class="cr-input-row">
          <input type="text" placeholder="e.g. slack.com" id="cr-block-input">
          <button class="cr-add-btn" onclick="addRule('${goalId}', 'block', 'site')">+ Site</button>
          <button class="cr-add-btn" onclick="addRule('${goalId}', 'block', 'app')">+ App</button>
        </div>
        ${blocks.length === 0 ? `<div class="cr-empty">Nothing extra to block.</div>` : `<div class="cr-entry-list">${renderEntries(blocks)}</div>`}
      </div>

      <div class="cr-section cr-allow">
        <div class="cr-section-header">
          <span class="left allow"><span class="dot allow"></span>Allow</span>
          <span class="right">${allows.length} entries</span>
        </div>
        <div class="cr-input-row">
          <input type="text" placeholder="e.g. github.com" id="cr-allow-input">
          <button class="cr-add-btn" onclick="addRule('${goalId}', 'allow', 'site')">+ Site</button>
          <button class="cr-add-btn" onclick="addRule('${goalId}', 'allow', 'app')">+ App</button>
        </div>
        ${allows.length === 0 ? `<div class="cr-empty">No allow overrides.</div>` : `<div class="cr-entry-list">${renderEntries(allows)}</div>`}
      </div>

      <div class="ge-foot">
        <div></div>
        <div class="right" style="display:flex; gap:8px;">
          <button class="btn-quiet" onclick="openWeeklyGoalEdit('${goalId}')">Done</button>
        </div>
      </div>
    </div>
  `;
}

function addRule(goalId, kind, type) {
  const g = (window._intentionsCache || []).find(x => x.id === goalId);
  if (!g) return;
  const inputId = (kind === 'block') ? 'cr-block-input' : 'cr-allow-input';
  const val = document.getElementById(inputId).value.trim();
  if (!val) return;
  const macField = (type === 'site') ? 'mac_websites' : 'mac_bundle_ids';
  const allowField = (type === 'site') ? 'allow_websites' : 'allow_bundle_ids';
  const target = (kind === 'block') ? macField : allowField;
  g[target] = [...(g[target] || []), val];
  // Send update; on success the bridge response will re-render via _intentionsList
  window.webkit?.messageHandlers?.bridge?.postMessage({
    type: 'UPDATE_INTENTION',
    id: goalId, version: g.version,
    name: g.name, description: g.description || '',
    color_hex: g.color_hex || null, icon: g.icon || null,
    mac_websites: g.mac_websites || [], mac_bundle_ids: g.mac_bundle_ids || [],
    allow_websites: g.allow_websites || [], allow_bundle_ids: g.allow_bundle_ids || [],
    monthly_goal_id: g.monthly_goal_id || null,
    week_of: g.week_of || _currentWeekISO(),
    intent_text: g.intent_text || '', ai_scoring_enabled: g.ai_scoring_enabled !== false,
    outcome: g.outcome || '', status: g.status || 'planned',
    weekly_target_hours: g.weekly_target_hours || null,
    strictness_preset: g.strictness_preset || 'standard',
  });
  openGoalCustomRules(goalId);
}

function removeRule(goalId, name, type, kind) {
  const g = (window._intentionsCache || []).find(x => x.id === goalId);
  if (!g) return;
  const macField = (type === 'site') ? 'mac_websites' : 'mac_bundle_ids';
  const allowField = (type === 'site') ? 'allow_websites' : 'allow_bundle_ids';
  const target = (kind === 'block') ? macField : allowField;
  g[target] = (g[target] || []).filter(x => x !== name);
  // Send the same UPDATE_INTENTION payload as addRule (mac field already mutated)
  addRule(goalId, kind === 'block' ? 'block' : 'allow', type);
  // The above sends + re-renders via openGoalCustomRules.
}

function openMonthlyGoalPicker(goalId) {
  const monthly = window._monthlyGoalsCache || [];
  if (monthly.length === 0) {
    if (confirm('No monthly goals yet. Create one?')) {
      const title = prompt('Monthly goal title:');
      if (title) {
        window.webkit?.messageHandlers?.bridge?.postMessage({
          type: 'CREATE_MONTHLY_GOAL',
          title, month_of: new Date().toISOString().slice(0,7) + '-01',
          status: 'planned',
        });
      }
    }
    return;
  }
  // Minimal v1: prompt-based chooser. Phase 5 polish replaces with a proper popover.
  const labels = monthly.map((m, i) => `${i+1}. ${m.title}`).join('\n');
  const pick = prompt(`Link to which monthly goal?\n${labels}\n(empty = unlink)`);
  let monthlyGoalId = null;
  if (pick) {
    const idx = parseInt(pick, 10) - 1;
    if (!Number.isNaN(idx) && monthly[idx]) monthlyGoalId = monthly[idx].id;
  }
  window.webkit?.messageHandlers?.bridge?.postMessage({
    type: 'LINK_WEEKLY_TO_MONTHLY',
    intention_id: goalId,
    monthly_goal_id: monthlyGoalId,
  });
  // refresh editor after the response
  setTimeout(() => renderGoalEdit(goalId), 200);
}
```

- [ ] **Step 4.4: Make `navigateTo('goal-edit')` show the page**

If the existing `navigateTo()` only toggles pages that are in a known list, add `goal-edit` to that list (or add a wildcard fallback that shows `#page-<id>`).

- [ ] **Step 4.5: Wire `_intentionUpdated` receiver to re-render**

```js
const _origIntentionUpdated = window._intentionUpdated;
window._intentionUpdated = function (updated) {
  if (updated && updated.id) {
    // Replace in cache
    window._intentionsCache = (window._intentionsCache || []).map(x => x.id === updated.id ? updated : x);
    if (typeof renderNowCard === 'function') renderNowCard();
    if (window.currentPage === 'goal-edit') renderGoalEdit(updated.id);
  }
  if (_origIntentionUpdated) _origIntentionUpdated(updated);
};
```

- [ ] **Step 4.6: Playwright + commit**

```bash
node scripts/playwright-tests/prototype-port-goal-edit.mjs
git add Intentional/dashboard.html scripts/playwright-tests/prototype-port-goal-edit.mjs
git commit -m "feat(goals): full-page Weekly Goal editor + Custom Rules sub-page"
```

**Acceptance criteria:**
- Click on a Today weekly-goal card opens the editor.
- Title input is click-to-rename.
- Intent textarea capped at 140 chars with live counter.
- AI scoring toggle persists.
- Status + strictness pills toggle correctly.
- Custom Rules drilldown opens, BLOCK + ALLOW sections work for sites + apps.
- Save sends `UPDATE_INTENTION` with all 9 new fields populated.
- Delete sends `DELETE_INTENTION` and returns to Today.

---

## Phase 5: Playwright tests (required per CLAUDE.md — verify before claiming done)

### Task 5: Test mode hook in `dashboard.html`

**Files:**
- Modify: `Intentional/dashboard.html`

- [ ] **Step 5.1: Add test-mode bridge stub**

Near the top of the main `<script>`:

```js
// Test mode for Playwright. When window.__INTENTIONAL_TEST_MODE is set true
// BEFORE any bridge calls, captures each message into window.__capturedBridgeMessages
// and prevents the missing-bridge errors when running over file://.
if (window.__INTENTIONAL_TEST_MODE) {
  window.__capturedBridgeMessages = [];
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.webkit.messageHandlers.bridge = {
    postMessage(msg) { window.__capturedBridgeMessages.push(msg); }
  };
}
```

- [ ] **Step 5.2: Commit**

```bash
git add Intentional/dashboard.html
git commit -m "test(goals): bridge test-mode hook for Playwright"
```

---

### Task 6: Playwright — Today weekly-goal cards

**Files:**
- Create: `scripts/playwright-tests/prototype-port-today-cards.mjs`

- [ ] **Step 6.1: Write the test**

```js
import { chromium } from 'playwright';
import path from 'path';
import fs from 'fs';

const ROOT = path.resolve(process.cwd(), '../..');
const DASHBOARD = `file://${path.join(ROOT, 'Intentional', 'dashboard.html')}`;
const OUT = '/tmp/intentional-pw/prototype-port-today';
fs.mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({ headless: false });
const ctx = await browser.newContext();
const page = await ctx.newPage();
page.on('pageerror', e => console.log('[pageerror]', e.message));
page.on('console', m => { if (m.type() === 'error') console.log('[console.error]', m.text()); });

// Inject test mode before page loads
await ctx.addInitScript(() => { window.__INTENTIONAL_TEST_MODE = true; });

await page.goto(DASHBOARD);
await page.waitForLoadState('domcontentloaded');

// Seed bridge response receiver with sample data
await page.evaluate(() => {
  window._intentionsList && window._intentionsList([
    { id: 'wg1', name: 'Record 3 demos', outcome: 'Posted to IG by Sun',
      status: 'in_progress', week_of: (() => {
        const d=new Date(); const day=d.getDay()||7; d.setDate(d.getDate()-(day-1));
        return d.toISOString().slice(0,10);
      })(),
      monthly_goal_id: 'm1', mac_websites: [], mac_bundle_ids: [],
      allow_websites: [], allow_bundle_ids: [], strictness_preset: 'strict',
      ai_scoring_enabled: true, intent_text: 'Recording demo videos.', version: 1 },
    { id: 'wg2', name: 'Block phone 9-5', outcome: 'Zero scrolls', status: 'planned',
      week_of: (() => { const d=new Date(); const day=d.getDay()||7; d.setDate(d.getDate()-(day-1));
        return d.toISOString().slice(0,10); })(),
      monthly_goal_id: 'm2', mac_websites: ['instagram.com'], mac_bundle_ids: [],
      allow_websites: [], allow_bundle_ids: [], strictness_preset: 'strict',
      ai_scoring_enabled: true, intent_text: '', version: 1 },
  ]);
  window._monthlyGoalsList && window._monthlyGoalsList([
    { id: 'm1', title: 'Ship Puck', outcome:'25 paid', color_hex:'#D85A30', month_of:'2026-05-01', status:'in_progress', version:1 },
    { id: 'm2', title: '4hr deep work', outcome:'20 weekdays', color_hex:'#1D9E75', month_of:'2026-05-01', status:'planned', version:1 },
  ]);
});

await page.screenshot({ path: `${OUT}/01-loaded.png`, fullPage: true });

// Assert: 2 .wg-card elements
const cards = await page.locator('.wg-card').count();
console.log('wg-card count:', cards);
if (cards < 2) { console.error('FAIL: expected ≥2 weekly cards'); process.exit(1); }

// Click first card — should switch to goal-edit page
await page.locator('.wg-card').first().click();
await page.waitForTimeout(200);
await page.screenshot({ path: `${OUT}/02-edit-open.png`, fullPage: true });
const editorVisible = await page.locator('#goal-edit-mount .ge-page').isVisible().catch(() => false);
if (!editorVisible) { console.error('FAIL: editor did not open'); process.exit(1); }

// Verify the grip is draggable=true
await page.click('.ge-back');
await page.waitForTimeout(100);
const draggable = await page.locator('.wg-grip').first().getAttribute('draggable');
if (draggable !== 'true') { console.error('FAIL: grip is not draggable'); process.exit(1); }

console.log('PASS: Today weekly-goal cards.');
await browser.close();
```

- [ ] **Step 6.2: Run + commit**

```bash
cd scripts/playwright-tests && node prototype-port-today-cards.mjs
git add scripts/playwright-tests/prototype-port-today-cards.mjs
git commit -m "test(goals): Playwright — Today weekly-goal cards"
```

---

### Task 7: Playwright — Plan tab React mount + drag-to-schedule

**Files:**
- Create: `scripts/playwright-tests/prototype-port-plan-tab.mjs`

- [ ] **Step 7.1: Write the test**

```js
import { chromium } from 'playwright';
import path from 'path';
import fs from 'fs';

const ROOT = path.resolve(process.cwd(), '../..');
const DASHBOARD = `file://${path.join(ROOT, 'Intentional', 'dashboard.html')}`;
const OUT = '/tmp/intentional-pw/prototype-port-plan';
fs.mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({ headless: false });
const ctx = await browser.newContext();
const page = await ctx.newPage();
page.on('pageerror', e => console.log('[pageerror]', e.message));

await ctx.addInitScript(() => { window.__INTENTIONAL_TEST_MODE = true; });
await page.goto(DASHBOARD);
await page.waitForLoadState('domcontentloaded');

// Seed bridge data BEFORE switching tab so React picks it up on first mount
await page.evaluate(() => {
  window._intentionsList && window._intentionsList([
    { id: 'wg1', name: 'Record 3 demos', outcome:'Posted to IG by Sun', status:'in_progress',
      week_of: (() => { const d=new Date(); const day=d.getDay()||7; d.setDate(d.getDate()-(day-1));
        return d.toISOString().slice(0,10); })(),
      monthly_goal_id: 'm1', mac_websites: [], mac_bundle_ids: [],
      allow_websites: [], allow_bundle_ids: [], version: 1 },
  ]);
  window._monthlyGoalsList && window._monthlyGoalsList([
    { id: 'm1', title: 'Ship Puck', outcome:'25 paid', color_hex:'#D85A30', month_of:'2026-05-01', status:'in_progress', version:1 },
  ]);
});

// Navigate to Plan tab
await page.click('[data-page="plan"]');
await page.waitForTimeout(800);  // give React + Babel time
await page.screenshot({ path: `${OUT}/01-plan-mounted.png`, fullPage: true });

// Assert: page-plan is visible AND a .cd-plan wrapper has rendered children
const planVisible = await page.locator('#page-plan').isVisible();
if (!planVisible) { console.error('FAIL: #page-plan not visible'); process.exit(1); }
const planChildren = await page.locator('#plan-react-root *').count();
if (planChildren < 5) { console.error('FAIL: React app did not mount'); process.exit(1); }

// Assert: at least one .mcard (monthly card) is visible
const mcards = await page.locator('.cd-plan .mcard').count();
if (mcards < 1) { console.error('FAIL: no monthly cards'); process.exit(1); }

console.log('PASS: Plan tab React mount.');
await browser.close();
```

- [ ] **Step 7.2: Run + commit**

```bash
cd scripts/playwright-tests && node prototype-port-plan-tab.mjs
git add scripts/playwright-tests/prototype-port-plan-tab.mjs
git commit -m "test(goals): Playwright — Plan tab React mount"
```

---

### Task 8: Playwright — Goal edit save → bridge contract

**Files:**
- Create: `scripts/playwright-tests/prototype-port-goal-edit.mjs`

- [ ] **Step 8.1: Write the test**

```js
import { chromium } from 'playwright';
import path from 'path';
import fs from 'fs';

const ROOT = path.resolve(process.cwd(), '../..');
const DASHBOARD = `file://${path.join(ROOT, 'Intentional', 'dashboard.html')}`;
const OUT = '/tmp/intentional-pw/prototype-port-goal-edit';
fs.mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({ headless: false });
const ctx = await browser.newContext();
const page = await ctx.newPage();
page.on('pageerror', e => console.log('[pageerror]', e.message));

await ctx.addInitScript(() => { window.__INTENTIONAL_TEST_MODE = true; });
await page.goto(DASHBOARD);
await page.waitForLoadState('domcontentloaded');

await page.evaluate(() => {
  const week = (() => { const d=new Date(); const day=d.getDay()||7; d.setDate(d.getDate()-(day-1));
    return d.toISOString().slice(0,10); })();
  window._intentionsList && window._intentionsList([
    { id:'g1', name:'Record demos', outcome:'IG by Sun', status:'in_progress',
      week_of: week, monthly_goal_id: null, mac_websites:[], mac_bundle_ids:[],
      allow_websites:[], allow_bundle_ids:[], strictness_preset:'standard',
      ai_scoring_enabled: true, intent_text:'original text', version: 1 },
  ]);
});

await page.click('.wg-card');
await page.waitForTimeout(200);
await page.screenshot({ path: `${OUT}/01-editor.png`, fullPage: true });

// Edit fields
await page.locator('#ge-title-input').fill('Record 5 demos');
await page.locator('#ge-intent-text').fill('Updated focus text');
await page.locator('#ge-outcome').fill('Done = 5 clips posted');
await page.locator('#ge-weekly-target').fill('6');
await page.locator('#ge-strict-pills .strict-pill[data-value="strict"]').click();
await page.screenshot({ path: `${OUT}/02-filled.png`, fullPage: true });

// Save
await page.locator('.ge-done-btn').click();
await page.waitForTimeout(200);

const msgs = await page.evaluate(() => window.__capturedBridgeMessages);
const updateMsg = msgs.find(m => m.type === 'UPDATE_INTENTION' && m.id === 'g1');
if (!updateMsg) { console.error('FAIL: no UPDATE_INTENTION bridge call', msgs); process.exit(1); }
if (updateMsg.name !== 'Record 5 demos') { console.error('FAIL: name not updated'); process.exit(1); }
if (updateMsg.intent_text !== 'Updated focus text') { console.error('FAIL: intent_text not updated'); process.exit(1); }
if (updateMsg.weekly_target_hours !== 6) { console.error('FAIL: weekly_target_hours wrong', updateMsg.weekly_target_hours); process.exit(1); }
if (updateMsg.strictness_preset !== 'strict') { console.error('FAIL: strictness'); process.exit(1); }
// Should also fire a separate UPDATE_INTENTION_STRICTNESS since strictness changed.
const strictMsg = msgs.find(m => m.type === 'UPDATE_INTENTION_STRICTNESS' && m.id === 'g1');
if (!strictMsg || strictMsg.to_preset !== 'strict') { console.error('FAIL: no strictness call'); process.exit(1); }

console.log('PASS: Goal edit save.');
await browser.close();
```

- [ ] **Step 8.2: Run + commit**

```bash
cd scripts/playwright-tests && node prototype-port-goal-edit.mjs
git add scripts/playwright-tests/prototype-port-goal-edit.mjs
git commit -m "test(goals): Playwright — Goal editor save contract"
```

---

## Phase 6: Final PR (depends on all earlier phases)

### Task 9: Open PR + cross-repo log update

- [ ] **Step 9.1: Push + open PR**

```bash
git push -u origin feat/prototype-to-production
gh pr create --title "feat(goals): dashboard prototype port (sidebar + Today + Plan + editor)" --body "$(cat <<'EOF'
## Summary
- Sidebar restructure: Today / Plan / Sensitive Content / Accountability / Settings + bottom blocking pill + theme toggle.
- Today: 3-weekly-goal cards strip above the calendar, with drag-to-schedule.
- Plan: Cloud Design React app embedded verbatim (React+Babel CDN).
- Weekly Goal full-page editor + Custom Rules sub-page (replaces Focus Modes modal).
- 3 Playwright tests covering Today cards, Plan mount, Editor save.

## Test plan
- [ ] `xcodebuild build` clean
- [ ] All 3 Playwright tests pass (`node scripts/playwright-tests/prototype-port-*.mjs`)
- [ ] Manual: launch Intentional, open dashboard, walk Today → Plan → Editor → Custom Rules
- [ ] Visual diff against `docs/unified-design-2026-05-13/app.html`

Per docs/prototype-to-production-2026-05-14.md.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 9.2: Append "Dashboard (Plan C)" section to cross-repo log**

In `docs/cross-repo-prototype-to-production-2026-05-14.md`, add a section listing the dashboard changes, PR link, Playwright test paths, and remaining open Qs.

---

## Migration / rollback summary

- **Forward:** ship after Plan B Task 6 (bridge handlers) merges. Sidebar + theme toggle (Phase 1) can ship independently of bridge wiring — they don't depend on new server data.
- **Rollback:** revert the PR. The dashboard reverts to the pre-redesign sidebar; nothing on-disk to clean up (theme toggle leaves an orphan `localStorage` key but it's benign).
- **Compatibility:** dashboard reads `_intentionsCache` defensively (falls back to hardcoded prototype data if bridge is silent), so a partial deploy where the bridge handlers haven't shipped yet still renders the UI with stub data + a warning toast.

---

## Self-review checklist

- [x] **Spec coverage:** Brief A/B/C/D map to Phases 1/2/3/4. Brief E (block-conflict warning), F (Sensitive shell), H (Settings drilldown), I (task overlay) are explicitly listed under "Does NOT do".
- [x] **No placeholders.** All JS function bodies are written. CSS references the prototype verbatim (Task 3.2, Task 4.2 — instructed to copy literal text from `app.html`).
- [x] **Type consistency.** Bridge message types match Plan B verbatim (`GET_MONTHLY_GOALS`, `UPDATE_INTENTION`, `LINK_WEEKLY_TO_MONTHLY`, `START_GOAL_SESSION`, `UPDATE_INTENTION_STRICTNESS`). Field names (`mac_websites`, `allow_websites`, `intent_text`, `monthly_goal_id`, `week_of`) match Plan A migration 026.
- [x] **Verification via Playwright per CLAUDE.md.** Three tests cover the three main user flows.
- [x] **Cloud Design rule honored.** React Plan app is "copy verbatim" per CLAUDE.md "Cloud Design output — FOLLOW IT EXACTLY".

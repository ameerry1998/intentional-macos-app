# UI Overhaul — Design Spec

## Problem

The Settings and Accountability pages are cluttered, inconsistent, and don't match the Puck iOS design language. Settings shows everything inline with no hierarchy. Terminology is confusing ("Intentional Mode", "Focus Profile"). The visual style (emoji icons, inconsistent spacing, different card styles per page) feels amateurish compared to the Puck iOS app's clean glass-card system.

## Solution

1. Redesign Settings as a drill-down list (like iOS Settings / like our Distractions page)
2. Move "Intentional Mode" to Today page as "Focus Gate" card, reuse FocusStartOverlay
3. Unify design language with Puck iOS: glass cards, emerald/amber accents, SF-symbol-style icons, consistent spacing
4. Clean up Accountability page to match

---

## Unified Design Tokens (Puck iOS → macOS)

Replace the current ad-hoc color values with Puck's design system:

```css
:root {
  /* Backgrounds */
  --bg-primary: #0a0a0b;
  --bg-card: rgba(255, 255, 255, 0.04);
  --bg-input: rgba(255, 255, 255, 0.06);
  --bg-hover: rgba(255, 255, 255, 0.08);

  /* Borders */
  --border-subtle: rgba(255, 255, 255, 0.08);
  --border-strong: rgba(255, 255, 255, 0.14);

  /* Text */
  --text-primary: #f0f0f0;
  --text-secondary: rgba(255, 255, 255, 0.55);
  --text-tertiary: rgba(255, 255, 255, 0.3);

  /* Accents (Puck's three-color system) */
  --accent-focus: #34d399;       /* emerald — focus/blocking */
  --accent-focus-dim: rgba(52, 211, 153, 0.15);
  --accent-wake: #fbbf24;        /* amber — alarms/wake */
  --accent-wake-dim: rgba(251, 191, 36, 0.15);
  --accent-evening: #818cf8;     /* indigo — evening/bedtime */
  --accent-evening-dim: rgba(129, 140, 248, 0.15);

  /* Status */
  --success: #34d399;
  --danger: #ef4444;
  --danger-dim: rgba(239, 68, 68, 0.15);
  --warning: #fbbf24;

  /* Layout (from Puck) */
  --radius-sm: 8px;
  --radius-md: 16px;
  --radius-lg: 24px;
  --radius-pill: 100px;
  --spacing-sm: 8px;
  --spacing-md: 16px;
  --spacing-lg: 24px;
  --spacing-xl: 32px;
}
```

### Note on existing accent color

The current app uses violet (`#8b5cf6`) as the primary accent. Puck uses emerald (`#34d399`) for focus actions. Decision: **switch to Puck's emerald for focus-related actions** (blocking, profiles, focus start). Keep violet only for the "iridescent" theme's decorative elements. This aligns the action color language across both apps.

---

## Settings Page Redesign

### Current (cluttered):
Everything inline — theme picker, toggles, grids, dropdowns, account forms, delete buttons all on one scrolling page.

### New (drill-down list):

```
Settings
────────────────────────────────

  Account                    ›
  Theme                      ›
  AI Scoring                 ›
  Enforcement                ›
  Content Safety             ›
  Bedtime                    ›
  Browsers                   ›
  Reset & Delete             ›
```

Each row is a tappable card that drills into a detail view (same slide transition as Distractions profiles).

### Row design:

```
┌─────────────────────────────────────┐
│  ⚙  Account                      › │
│     arayan@email.com                │
└─────────────────────────────────────┘
```

- Left: SF-symbol-style icon (text character, not emoji)
- Title: 15px semibold
- Subtitle: 13px secondary text (optional — shows current value)
- Right: chevron ›
- Card style: glass card (bg 4%, border 8%, radius 16px)

### Detail views for each section:

#### Account
- Email display
- Sign out button
- Member since
- Devices list

#### Theme
- 4 theme options as selectable cards (Iridescent, Classic, Emerald, Warm)
- Selected = emerald border ring

#### AI Scoring
- Enable/disable toggle
- Model picker: Qwen3 4B / Apple 3B
- Description: "AI scores whether what you're looking at is relevant to your task"

#### Enforcement
- Toggle rows for each enforcement type:
  - Nudge notifications
  - Screen red shift
  - Auto-redirect
  - Blocking overlay
  - Intervention exercises
  - Background audio detection
- Single column (no Deep Focus vs Focus grid — there's only one enforcement level now)

#### Content Safety
- Enable/disable toggle with clear description
- Permission status indicator
- "Open System Settings" button if permissions needed
- "Test Detection" button

#### Bedtime
- Enable/disable toggle
- Bedtime start time picker
- Wake time picker
- Active days checkboxes
- Description of wind-down progression

#### Browsers
- Extension status per browser
- Install instructions

#### Reset & Delete
- Reset all settings button (danger)
- Delete account button (danger, with confirmation)
- Uninstall button (danger, with partner code if locked)

---

## Focus Gate (renamed from "Intentional Mode")

### Moved to Today page as a card:

```
┌─────────────────────────────────────┐
│  Focus Gate                    [ON] │
│  Asks what you're working on        │
│  each hour                          │
│                                     │
│  Grace period: 3 min                │
│  Configure ›                        │
└─────────────────────────────────────┘
```

- Position: above the schedule timeline on Today page
- Toggle directly on the card (no drill-down needed to turn on/off)
- "Configure ›" link drills into detail settings:
  - Grace period: 1 min / 3 min / 5 min
  - That's it — schedule options removed (Puck model, no schedules)

### Behavior change:

- Focus Gate overlay is now the SAME `FocusStartOverlay` used by Puck tap
- `IntentionalModeController.showOverlay()` calls `AppDelegate.showFocusStartOverlay(isPuckTriggered: false)` instead of showing its own custom overlay
- This eliminates the separate Deep Focus / Focus / Free Time buttons — the FocusStartOverlay already has profile selection + intention + free time (when Puck not active)

### When Puck is active:
- Focus Gate card shows "Managed by Puck" instead of the toggle
- The gate is effectively always on (Puck already forced the planning step)

### Settings page reference:
- Settings page still has a "Focus Gate ›" row that links to the same configure view
- But the primary interaction is the Today page card

---

## Accountability Page Cleanup

### Current state: Works fine functionally but uses emoji icons and inconsistent styling.

### Changes:
- Replace emoji (🔓, 🔒) with text-based status indicators matching Puck style
- Use glass card style matching new Settings cards
- Status badges use Puck's pill style (rounded, colored background at 15% opacity)
- Content Safety section moves to Settings (it's a setting, not accountability)
- Accountability page becomes purely about the partner relationship:
  - Partner status card (connected / pending / locked)
  - Unlock code entry
  - Partner management (change / remove)

---

## Today Page Updates

### Changes:
- Add Focus Gate card (described above)
- Replace `+ Deep Focus` / `+ Focus` / `+ Free Time` buttons with `+ Focus` / `+ Free Time`
  - `+ Focus` opens block creation with profile selection
  - `+ Free Time` hidden when Puck active
- Schedule blocks show profile names instead of "Deep Focus" / "Focus" labels
- Earned Browse card gets glass card treatment
- Bedtime block on timeline uses indigo accent (matching Puck evening mode)

---

## Component Updates (Global)

### Cards
All cards across all pages switch to glass card style:
- Background: `rgba(255, 255, 255, 0.04)`
- Border: `1px solid rgba(255, 255, 255, 0.08)`
- Border radius: 16px
- Padding: 16px

### Toggles
- Match Puck: 50px × 30px, emerald when on, `rgba(255,255,255,0.12)` when off

### Buttons
- Primary: emerald background, dark text
- Secondary: transparent, subtle border
- Danger: red at 15% opacity background, red text

### Icons
- Replace all emoji with text symbols or CSS-drawn icons
- Sidebar: use simple unicode symbols (already done) but ensure consistency

### Section headers
- 13px, semibold, uppercase, letter-spacing 1px
- Color: text-tertiary (30% white)

---

## Scope

This spec covers:
- Settings page drill-down restructure
- Focus Gate rename + move to Today
- Accountability page cleanup
- Design token unification with Puck
- Component style updates

This spec does NOT cover:
- Distractions page (already done)
- Schedule block creation form (separate spec — profile selection in blocks)
- FocusStartOverlay changes (already built)

---

## Architecture

### Modified files:
- `dashboard.html` — Settings page HTML/CSS/JS, Today page Focus Gate card, Accountability page cleanup, global CSS token updates
- `MainWindow.swift` — Add Focus Gate message handlers (GET/SAVE), remove Intentional Mode references from settings
- `IntentionalModeController.swift` — Delegate overlay to FocusStartOverlay instead of custom overlay
- `AppDelegate.swift` — Wire Focus Gate card state

### NOT modified:
- `BlockingProfileManager.swift` — already done
- `FocusSessionManager.swift` — already done
- `FocusStartOverlay.swift` — already built, reused by Focus Gate
- `BedtimeEnforcer.swift` — settings detail view just reads/writes existing bedtime_settings.json

---

## Testing

1. Settings page: every row drills into detail, back button returns
2. Each detail view: all toggles/inputs work and persist
3. Focus Gate: toggle on Today page enables/disables the hourly overlay
4. Focus Gate overlay: shows FocusStartOverlay (profile chips + intention), not the old custom overlay
5. Accountability: partner lock/unlock flow still works
6. Visual: glass cards, emerald accents, no emoji icons, consistent spacing across all pages

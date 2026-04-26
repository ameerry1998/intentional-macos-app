# Puck iOS + Intentional macOS — UI/UX Coordination Analysis

## Current State (April 2026)

### Puck iOS
- **Design system:** Fully documented in `Theme.swift` (451 lines)
- **Colors:** Three-accent system: emerald (focus), amber (wake), indigo (evening)
- **Backgrounds:** Pure black (`#0a0a0b`), glass cards at 4% white opacity
- **Typography:** SF Pro, strict size hierarchy (32/28/22/17/15/13/12px)
- **Components:** Glass cards, 100px-radius pills, 52px buttons, bottom sheet modals
- **Navigation:** 5-tab bottom bar (Home, Routine, Wake, Partner, Settings)
- **Focus flow:** Tap physical NFC puck → blocking activates immediately → simple "blocking active" screen

### Intentional macOS
- **Design system:** Ad-hoc, improving — some Puck tokens now in CSS but not everywhere
- **Colors:** Violet accent (`#8b5cf6`) historically, emerald (`#34d399`) being introduced
- **Backgrounds:** `#0e0e12`, glass cards partially adopted
- **Typography:** System font, sizes inconsistent across old vs new sections
- **Components:** Mix of old `.settings-card` and new glass card styles
- **Navigation:** 4-item sidebar (Today, Distractions, Accountability, Settings)
- **Focus flow:** Cmd+Shift+P (mock) → overlay with profile selection + intention → blocking + enforcement

---

## Where They Diverge (Problems)

### 1. Accent Color Conflict
**Puck:** Emerald (`#34d399`) = focus/blocking. Violet doesn't exist.
**Intentional:** Violet (`#8b5cf6`) = primary accent everywhere. Emerald only on new components.
**Impact:** When a user looks at both apps, the "focus" color is different. Puck says green = focus. Intentional says purple = focus.
**Fix:** Migrate Intentional's primary accent to emerald for all focus-related actions. Keep violet only for the "iridescent" theme decorative background.

### 2. Card Style Mismatch
**Puck:** `rgba(255,255,255,0.04)` bg, `rgba(255,255,255,0.08)` border, 16px radius
**Intentional:** `rgba(255,255,255,0.03)` bg, `rgba(255,255,255,0.07)` border, 12px radius, plus `::before` pseudo-element glow
**Impact:** Subtle but cards feel "different" on each platform.
**Fix:** Update `.settings-card` CSS to match Puck exactly. Drop the `::before` glow effect.

### 3. Navigation Pattern
**Puck:** Bottom tab bar (iOS convention)
**Intentional:** Left sidebar (macOS convention)
**Impact:** This is correct — each platform follows its native convention. No change needed.

### 4. Focus Start Experience
**Puck:** Tap NFC → instant blocking → simple "Blocking Active" screen. No profile selection, no intention. Phone is a distraction machine, so just block everything.
**Intentional:** Overlay with profile chips + intention field + optional AI. Laptop is a work tool, so you need to specify WHAT you're working on.
**Impact:** This asymmetry is intentional and correct. Phone = dumb block. Laptop = smart block.
**BUT:** The visual language of the overlays should match. Puck's blocking screen uses emerald. Intentional's FocusStartOverlay should also use emerald (currently uses violet buttons).

### 5. Partner/Accountability
**Puck:** Simple "Partner" tab — invite form or connected card.
**Intentional:** "Accountability" page with complex lock state machine (pending, confirmed, locked, unlock code entry, temporarily unlocked, declined, expired).
**Impact:** The Mac handles the complexity. The phone is simple. This is fine.
**BUT:** When partner sends an unlock code, it should look/feel the same on both platforms. Same code entry UI pattern (6-digit, monospaced, centered).

### 6. Settings
**Puck:** Flat list in Settings tab (Account, Focus, Notifications, Support)
**Intentional:** Now drill-down list (9 items). More settings because the Mac has more features.
**Impact:** Different number of settings is fine. But the ROW STYLE should match — same padding, same font size, same chevron.

### 7. Evening Mode / Bedtime
**Puck:** "Evening Mode" — grayscale screen, moon icon, indigo accent, gratitude prompt
**Intentional:** "Bedtime Enforcer" — dark overlay, countdown to sleep, snooze button
**Impact:** Same feature, different names, different UX. Should be unified:
- Same name: "Bedtime" or "Evening Mode" (pick one)
- Same color: indigo on both
- Intentional already uses indigo for bedtime blocks ✓
- Puck uses indigo for evening mode ✓
- Name should match: recommend "Bedtime" (clearer)

---

## Coordination Roadmap

### Phase 1: Color Alignment (quick wins)
1. Intentional primary accent → emerald for focus actions (buttons, toggles, profile chips)
2. Keep indigo for bedtime/evening
3. Keep amber for warnings
4. Violet → decorative only (theme backgrounds)
5. Update FocusStartOverlay "Start Focus" button to emerald
6. Update all focus-related toggles to emerald (some already done)

### Phase 2: Component Alignment
1. Match card styles exactly (bg, border, radius from Puck Theme.swift)
2. Match button styles (52px height on important actions, 14px radius)
3. Match pill/chip styles (100px radius for status pills)
4. Match toggle styles (50x30, emerald when on)
5. Code entry UI (6-digit): same style on both platforms

### Phase 3: Terminology Alignment
1. "Intentional Mode" → "Focus Gate" (done ✓)
2. "Evening Mode" (Puck) ↔ "Bedtime" (Mac) → pick one name for both
3. "Blocking Active" (Puck) ↔ "Focus Session" (Mac) → "Focus Session" on both
4. "Deep Focus" → removed (done ✓) 
5. Profile names should sync between devices (future, via backend)

### Phase 4: Shared State via Backend
1. Blocking profiles sync Mac ↔ Phone (backend stores profiles)
2. Focus session state shared (Puck tap affects both)
3. Partner relationship shared (already is, via backend)
4. Bedtime settings could sync (same bedtime on both devices)

---

## What's Unique to Each Platform (and should stay unique)

### Mac Only
- AI relevance scoring (too resource-intensive for phone)
- Schedule/timeline view (desktop has the screen real estate)
- Enforcement escalation (nudge → grayscale → intervention)
- Content Safety screen monitoring
- Browser extension integration
- Focus Gate hourly planning overlay

### Phone Only
- FamilyControls app blocking (iOS-only API)
- NFC puck tap (requires physical hardware)
- Alarm/wake features
- Routine tracking
- Physical puck color assignment

### Shared
- Blocking profiles (which sites/apps to block)
- Partner/accountability relationship
- Focus session state (active or not)
- Bedtime/evening mode timing
- Account & authentication

---

## Immediate Action Items

1. **CSS token update** — Replace violet accent with emerald for focus actions across dashboard.html
2. **FocusStartOverlay** — "Start Focus" button should be emerald, not blue/violet
3. **BedtimeOverlayView** — Already uses dark theme + indigo tones ✓
4. **Card border-radius** — Bump from 12px to 16px to match Puck
5. **Toggle size** — Standardize to match Puck's 50x30
6. **Rename "Evening Mode" to "Bedtime" in Puck iOS** — or vice versa, pick one

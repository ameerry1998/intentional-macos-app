# Puck + Intentional — Unified Design System

> **"Deep Lush"** — Rich dark surfaces with warm coral→gold gradient accents and ambient emerald glow. Every color is a gradient. Nothing flat.

## Brand Identity

The physical Puck device is coral (#E87461). This warm coral→gold gradient is the brand signature across all surfaces: macOS app, iOS app, marketing site.

## Color System

### Brand Accent (Coral→Gold Gradient)
All primary actions, CTAs, active states, selected elements, toggles-on.
```css
background: linear-gradient(135deg, #E87461, #F0B060);
/* Text gradient */
background: linear-gradient(135deg, #E87461, #F0B060);
-webkit-background-clip: text;
-webkit-text-fill-color: transparent;
/* Glow shadow on interactive elements */
box-shadow: 0 0 12px rgba(232, 116, 97, 0.25);
/* Dim background for selected/active cards */
background: rgba(232, 116, 97, 0.06);
border-color: rgba(232, 116, 97, 0.15);
```

### Success (Forest→Sand Gradient)
Status indicators, "on-task" percentages, completion states. Warm green, not neon.
```css
background: linear-gradient(135deg, #5cc09a, #c0b060);
-webkit-background-clip: text;
-webkit-text-fill-color: transparent;
```

### Bedtime (Dusk→Rose Gradient)
Bedtime blocks, evening mode, wind-down states. Soft, not bright blue.
```css
background: linear-gradient(135deg, #a898c8, #c898a8);
-webkit-background-clip: text;
-webkit-text-fill-color: transparent;
/* Block border */
border-left-color: rgba(168, 152, 200, 0.4);
background: rgba(140, 120, 180, 0.04);
```

### Warning (Gold→Coral Gradient)
Warnings, attention needed, alarms.
```css
background: linear-gradient(135deg, #F0B060, #E87461);
```

### Danger (Deep Red Gradient)
Errors, destructive actions, content safety alerts.
```css
background: linear-gradient(135deg, #d45050, #aa3333);
/* Dim background */
background: rgba(212, 80, 80, 0.1);
```

### NEVER use flat saturated colors
No `#34d399`, no `#818cf8`, no `#fbbf24` as flat text or backgrounds. Everything is a gradient or a muted glow.

## Backgrounds

### Base: `#060806`
Very dark with an imperceptible green-warm undertone. Not pure black, not cold.

### Ambient Glows
Two radial gradient glow layers on every screen:
```css
/* Coral glow — top area */
position: absolute;
background: radial-gradient(circle, rgba(232, 116, 97, 0.12) 0%, transparent 70%);

/* Emerald glow — bottom area */
position: absolute;
background: radial-gradient(circle, rgba(40, 160, 110, 0.1) 0%, transparent 70%);
```
These are background decoration only. Content sits above with `position: relative; z-index: 1;`.

### Cards: `rgba(255, 255, 255, 0.025)`
Glass cards with very subtle borders and backdrop-filter blur.
```css
background: rgba(255, 255, 255, 0.025);
border: 1px solid rgba(255, 255, 255, 0.05);
border-radius: 14px;
backdrop-filter: blur(30px);
```

### Sidebar: `rgba(255, 255, 255, 0.01)`
Barely visible surface differentiation.

## Text

| Role | Color | Usage |
|------|-------|-------|
| Primary | `#f7f8f8` | Headings, important content |
| Secondary | `rgba(255,255,255,0.5)` | Body text, descriptions |
| Tertiary | `rgba(255,255,255,0.25)` | Metadata, timestamps, hints |
| Disabled | `rgba(255,255,255,0.15)` | Inactive, placeholder |

Never use pure `#ffffff`. The slight warmth of `#f7f8f8` prevents eye strain.

## Borders

| Type | Value | Usage |
|------|-------|-------|
| Default | `rgba(255,255,255,0.05)` | Card borders, dividers |
| Subtle | `rgba(255,255,255,0.04)` | Sidebar, tab bar borders |
| Focus/Active | `rgba(232,116,97,0.15)` | Active card borders (coral tint) |
| Bedtime | `rgba(168,152,200,0.15)` | Bedtime-related borders |

## Typography

Font: `-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif`

| Role | Size | Weight | Notes |
|------|------|--------|-------|
| Page title | 20px | 700 | |
| Section title | 15px | 700 | |
| Card title | 14px | 600 | |
| Body | 13px | 400 | |
| Label | 12px | 500 | |
| Section label | 11px | 600 | Uppercase, letter-spacing 0.5-1px |
| Caption | 10px | 400 | |
| Micro | 9px | 500 | Metadata below elements |

## Interactive Elements

### Buttons — Primary
```css
background: linear-gradient(135deg, #E87461, #F0B060);
color: #0a0a0b;
border: none;
border-radius: 12px;
padding: 10px 16px;
font-weight: 600;
box-shadow: 0 4px 20px rgba(232, 116, 97, 0.2);
```

### Buttons — Secondary
```css
background: rgba(255, 255, 255, 0.03);
border: 1px solid rgba(255, 255, 255, 0.06);
color: rgba(255, 255, 255, 0.5);
border-radius: 12px;
```

### Buttons — Danger
```css
background: rgba(212, 80, 80, 0.1);
border: 1px solid rgba(212, 80, 80, 0.2);
color: #d45050;
border-radius: 12px;
```

### Pill buttons (schedule add)
```css
border-radius: 100px;
padding: 4px 14px;
font-size: 10px;
/* Primary pill uses the gradient */
```

### Toggle — On
```css
width: 36px;
height: 20px;
border-radius: 10px;
background: linear-gradient(135deg, #E87461, #F0B060);
box-shadow: 0 0 12px rgba(232, 116, 97, 0.2);
/* Thumb: 16px white circle */
```

### Toggle — Off
```css
background: rgba(255, 255, 255, 0.1);
```

### Focus indicator dot
```css
width: 7px;
height: 7px;
border-radius: 50%;
background: linear-gradient(135deg, #E87461, #F0B060);
box-shadow: 0 0 10px rgba(232, 116, 97, 0.3);
```

### Active nav item (sidebar)
```css
background: rgba(232, 116, 97, 0.08);
color: #E87461;
```

## Layout

| Value | Usage |
|-------|-------|
| 16px radius | Cards, modals |
| 12px radius | Buttons, inputs |
| 6px radius | Chips, small elements, time blocks |
| 100px radius | Pill buttons |
| 16px padding | Card content |
| 12px padding | Compact cards |
| 8px gap | Between chips |
| 10px gap | Between cards |

## Spacing

Base: 8px grid. Primary rhythm: 8, 12, 16, 20, 24, 32px.

## Terminology (Unified)

| Concept | Term | NOT |
|---------|------|-----|
| Focus session | "Focus" | "Deep Focus", "Focus Hours" |
| Blocking profile | "Profile" | "Block list" |
| Hourly planning overlay | "Focus Gate" | "Intentional Mode" |
| Evening enforcement | "Bedtime" | "Evening Mode" |
| Non-enforced time | "Free Time" | "Off", "Unplanned" |
| Physical device | "Puck" | — |
| Focus start trigger | "Tap Puck" or "Start Focus" | — |
| AI scoring | "AI Scoring" | "Focus Plan", "Relevance" |

## Platform-Specific

### macOS (Intentional)
- Left sidebar navigation
- WKWebView dashboard (HTML/CSS/JS)
- Schedule timeline view
- Settings drill-down pages
- Enforcement escalation (nudge → grayscale → intervention)

### iOS (Puck)
- Bottom tab navigation
- SwiftUI native
- Simple tap-to-toggle focus
- FamilyControls app blocking
- NFC puck interaction

### Shared visual elements
- Coral→gold gradient on all primary actions
- Glass cards with backdrop blur
- Ambient glow backgrounds
- Gradient text for active/status elements
- Same border opacity values
- Same text opacity hierarchy

## Do's and Don'ts

### Do
- Use gradients for ALL accent colors (brand, success, bedtime, warning, danger)
- Add glow `box-shadow` to interactive gradient elements
- Use ambient background glows (coral top, emerald bottom)
- Keep text opacity hierarchy strict (100%, 50%, 25%, 15%)
- Use `backdrop-filter: blur(30px)` on glass cards
- Match coral→gold to the physical Puck device color

### Don't
- Use flat saturated colors (`#34d399`, `#818cf8`, `#8b5cf6`, `#fbbf24`)
- Use pure black (`#000000`) — use `#060806` or `#070707`
- Use pure white (`#ffffff`) text — use `#f7f8f8`
- Use box-shadow for elevation on dark surfaces — use background luminance stepping
- Mix the old violet accent (`#8b5cf6`) with the new coral system
- Use emoji as icons in the UI

# UI Design Reference — Intentional macOS App

Sourced from Perplexity Deep Research, April 2026.

## Design Tokens (Dark Theme)

```css
:root {
  color-scheme: dark;
  --surface-base: #111111;
  --surface-raised: #1c1c1e;
  --surface-elevated: #2c2c2e;
  --surface-hover: #3a3a3c;
  --text-primary: #f2f2f7;
  --text-secondary: #8e8e93;
  --text-tertiary: #636366;
  --accent: #8b5cf6; /* violet, matching existing theme */
  --accent-hover: #a78bfa;
  --border-subtle: rgba(255,255,255,0.08);
  --border-strong: rgba(255,255,255,0.18);
  --danger: #ef4444;
  --success: #4ade80;
  --warning: #f59e0b;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
}
```

## UX Patterns

- **Master-detail** for profile management (list on left, editor on right)
- **Inline toggle** on each profile row (always visible, no modal)
- **Bottom toolbar** for add/delete (+ and − buttons, macOS convention)
- **Tag chips** for blocked domains/apps inside a profile (dismissible × chips)
- **Sheet modal** for adding items (search field + scrollable list + checkboxes)

## Prompt Structure for AI UI Generation

Use XML-tagged prompts with: context, design_tokens, component_inventory, constraints, task.

## Key Rules

- All colors via CSS custom properties, never hardcoded hex
- -apple-system font stack only
- No box-shadow for elevation — use background-color steps
- Avoid: generic card borders, gradients, rounded-2xl, emoji icons
- Keyboard: Return confirms, Escape cancels, Delete removes, ⌘N adds

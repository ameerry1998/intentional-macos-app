# Cross-repo log — Puck pivot suite — 2026-04-26

This is the single source of truth for the multi-stream "Puck pivot" overnight session.
Two agents are working in parallel:

- **Login agent** (other) — owns `puck` branch on `intentional-macos-app`, executing the 6-task macOS login port. Plan: `docs/superpowers/plans/2026-04-26-macos-login-port.md`.
- **Pivot suite agent** (this one) — owns icon updates, partner-sync investigation, iPhone home/routine layout, and this log.

Each agent appends to its own section below. Do not overwrite the other agent's entries.

---

## Repos & branches in flight

| Repo | Branch | Worktree | Owner | Purpose |
|------|--------|----------|-------|---------|
| intentional-macos-app | `puck` | (main checkout) | Login agent | macOS login screen port |
| intentional-macos-app | `feat/mac-app-icon` | `.claude/worktrees/mac-icon` | Pivot suite | macOS app icon refresh from `~/Downloads/brand/` |
| intentional-macos-app | `docs/puck-pivot-suite` | `.claude/worktrees/puck-pivot-docs` | Pivot suite | This log + partner-sync investigation doc |
| puck-ios | `feat/ios-app-icon` | (main checkout, switched) | Pivot suite | iOS app icon refresh |
| puck-ios | `feat/home-restructure` | (TBD) | Pivot suite | Home page + routine tab restructure |

---

## Pivot suite agent — work log

### 1. Cross-repo log scaffold
- Branch: `docs/puck-pivot-suite`
- Status: in-flight
- File: `docs/cross-repo-puck-pivot-2026-04-26.md` (this file)

### 2. macOS app icon
- Branch: `feat/mac-app-icon`
- Status: pending
- Source assets: `/Users/arayan/Downloads/brand/puck-app-icon-{1024,512,256,128}.png`
- Target: `Intentional/Assets.xcassets/AppIcon.appiconset/` (10 image entries — Mac legacy multi-size format)
- Note: Mac asset catalog uses explicit per-size files. Need to generate 16/32/64 sizes from 1024 master via `sips`.

### 3. iOS app icon
- Branch: `feat/ios-app-icon`
- Status: pending
- Source: `/Users/arayan/Downloads/brand/puck-app-icon-1024.png`
- Target: `puck-ios/Puck/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- Note: iOS uses modern single-size format (1024×1024 universal); Xcode generates the rest at build time.

### 4. Partner sync investigation
- Branch: `docs/puck-pivot-suite`
- Status: pending
- Bug: User just logged in to both macOS and iOS, partner not syncing across.
- Output: `docs/cross-repo-partner-sync-investigation-2026-04-26.md` (findings only, no fix).

### 5. iPhone home + routine layout
- Branch: `feat/home-restructure` (off `main`, not yet created)
- Status: pending
- Asks: (a) move multi-puck pairing to Settings, (b) shrink/remove Reclaimed time card from home, (c) Today section first on home, (d) Routine tab → schedule placeholder ("coming soon").

---

## Bugs surfaced

- **Partner sync not propagating after login** — see `docs/cross-repo-partner-sync-investigation-2026-04-26.md` (in-flight).

## Pending decisions for the user

(None yet. Will be filled in as work completes.)

---

## Login agent — work log

(Login agent: append your entries below this line. Do not edit pivot suite entries above.)


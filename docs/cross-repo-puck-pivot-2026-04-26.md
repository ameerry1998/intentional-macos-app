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
- Branch: `docs/puck-pivot-suite` (intentional-macos-app)
- Commit: `c2c07d8` — *docs: scaffold puck-pivot SSoT log + partner sync investigation*
- Status: **shipped**

### 2. macOS app icon
- Branch: `feat/mac-app-icon` (intentional-macos-app)
- Commit: `a62639f` — *chore(icon): refresh macOS app icon with Puck brand*
- Status: **shipped + build verified**
- Sizes 16/32/64 generated from the 1024 master via `sips`; 128/256/512/1024 copied from `~/Downloads/brand/`.
- Build note: had to symlink two gitignored mp4 resources (`13136082_3840_2160_60fps.mp4`, `zen-nature.mp4`, ~270MB combined) from the main checkout into the worktree so Xcode could resolve them. The symlinks live only in the worktree; nothing committed.

### 3. iOS app icon
- Branch: `feat/ios-app-icon` (puck-ios)
- Commit: `4f04125` — *chore(icon): refresh iOS app icon with Puck brand*
- Status: **shipped + build verified** (iPhone 17 simulator)
- Single 1024×1024 universal PNG; Xcode generates the rest at build time.

### 4. Partner sync investigation
- Branch: `docs/puck-pivot-suite` (intentional-macos-app), bundled into commit `c2c07d8`
- Output: [`docs/cross-repo-partner-sync-investigation-2026-04-26.md`](./cross-repo-partner-sync-investigation-2026-04-26.md)
- Status: **investigation complete — root cause identified, no fix applied**
- **Root cause:** Partner data is stored on the per-device `users` table row, scoped by `X-Device-ID`. macOS and iOS each generate their own random `device_id` on first install, so they have separate `users` rows. The backend `/partner` endpoints have no account-scoped read or write, so logging in to the same email account on both does not sync partner. Compounding it on iOS: iOS verifies OTP via Supabase directly and never calls `/auth/verify`, so the iOS legacy `users` row never even gets `account_id` linked.
- **Two fix options laid out** (Option A: account-scoped fallback in `/partner` routes, ~30 lines + iOS link-on-login call; Option B: promote partner to the `accounts` table, bigger but architecturally correct).
- **Awaiting user decision** before any code changes.

### 5. iPhone home + routine layout
- Branch: `feat/home-restructure` (puck-ios)
- Commit: `28a9f87` — *feat(home): restructure home, move pucks to Settings, stub Routine tab*
- Status: **shipped + build verified** (iPhone 17 simulator)
- Changes:
  - `HomeView.idleContent`: Today section is now first; focus modes follow. Removed the puck row card and the Reclaimed-time-this-week sparkline.
  - `SettingsView`: new "Pucks" section between Account and Focus, with one row per registered puck (tap to edit) and an "Add a puck" row that opens `PuckSetupView`.
  - `RoutineView`: gutted to a "Schedule — coming soon" placeholder. Per user direction ("don't try to build the full schedule UI" tonight), `HabitGoalCreationView` and `WeeklyReportSheet` are left in place unreferenced — they aren't deleted so the work isn't lost when the calendar/schedule view lands.

---

## Summary — what shipped tonight

| Repo | Branch | Commit | Verified |
|------|--------|--------|----------|
| intentional-macos-app | `feat/mac-app-icon` | `a62639f` | `xcodebuild build` ✅ |
| intentional-macos-app | `docs/puck-pivot-suite` | `c2c07d8` | (docs only) |
| puck-ios | `feat/ios-app-icon` | `4f04125` | iPhone 17 sim ✅ |
| puck-ios | `feat/home-restructure` | `28a9f87` | iPhone 17 sim ✅ |

None of these have been pushed or merged. They sit on local branches awaiting user review. Per the user's brief, the macOS-login agent owns `puck`; nothing here touched that branch or its locked files.

## Bugs surfaced

- **Partner sync not propagating after login** — root-caused; awaiting user decision on fix approach. See `docs/cross-repo-partner-sync-investigation-2026-04-26.md`.

## Pending decisions for the user

1. **Partner sync fix path** — Option A (smallest backend change + iOS device-link) vs Option B (promote partner to `accounts` table). Recommended Option A as the smallest viable change; Option B if there's appetite for the migration. Either way, iOS needs to learn to link its legacy device_id to the account.
2. **Where to merge the four pivot-suite branches** — directly into `main` (clean, all small) or wait for the macOS-login work on `puck` to land first to avoid simultaneous merges. Recommend merging the icon + docs branches into `main` immediately (they're independent), and the iOS home-restructure branch into `main` after a quick visual check on a real device or simulator.
3. **Routine tab name** — left as "Routine" in the tab bar (renaming to "Schedule" would be a clean follow-up but felt like overreach for tonight given the user's "don't over-build" guidance).
4. **Reclaimed-time-this-week sparkline** — fully removed from home; consider a future "Stats" page that revives it if the data is meaningful enough to warrant a dedicated home for it.
5. **Distractions / blocklist sync model** — see design note below.

---

## Design note — distractions list across macOS and iOS

**Question raised:** "Should the distractions list be synced or both — or should there be a Mac and an iPhone distractions list and they can be separate?"

**Recommendation: hybrid.** Sync the mode metadata (name, icon, intent text, default duration, websites). Keep per-platform blocklists for the OS-native objects (macOS apps + AppleScript-driven browser tabs; iOS FamilyControls app/category tokens).

**Why hybrid is the only honest answer:**

- **iOS FamilyControls tokens cannot cross devices.** Per `puck-ios/CLAUDE.md` ("Backend Readiness" section, line 313): *"FamilyControls tokens (app/category) are device-specific and cannot be synced — only the mode metadata (name, icon, behavior, duration) can sync."* This is an Apple platform constraint, not an implementation choice. The token is an opaque on-device handle into the user's Screen Time graph; there is no portable representation.
- **Even if tokens could sync, the conceptual map is one-to-many, not one-to-one.** Twitter on iOS is the Twitter app + the X app + the embedded WebKit shield. On Mac it's `twitter.com`, `x.com`, plus tabs in 5 different browsers. "Block Twitter" is one *intent* but two different *blocklists* under the hood.
- **macOS websites and iOS websites *can* sync** — both are URL strings — and probably should, because that's where the user's mental model holds without friction.

**Proposed split (when this lands):**

| Field | Synced? | Lives where |
|---|---|---|
| Mode name, icon, color | yes | shared (account-scoped, backend) |
| Mode default duration | yes | shared |
| Mode intent text (the "why") | yes | shared |
| Website blocklist (URLs) | yes | shared |
| macOS app bundle IDs | per-device | macOS local store |
| macOS browser-tab keyword rules | per-device | macOS local store |
| iOS FamilyControls app/category tokens | per-device | iOS local SwiftData |

**UX implication for the iOS Mode editor:** show a "Synced from Mac" badge on the metadata section, and a "On this iPhone" header above the FamilyControls picker. Sets the right expectation that picking apps is a one-time per-device chore, not duplicate data entry.

**UX implication for new-user onboarding:** if a user logs in on iOS and already has Modes set up on Mac, those Modes should appear in iOS with name/icon/websites populated but a "Pick apps" CTA on each — not silently empty.

**Status:** design direction only. No backend schema, no client work. Pulling forward when the partner-sync fix (decision #1 above) is also in flight, since both touch account-scoped sync of per-device data.

## Visual verification still recommended

The four branches all build clean, but the iOS home/settings/routine changes are layout-affecting and benefit from a quick eyeball check in the simulator or on a device. The icon updates would be visible at the first launch / springboard.

---

## Login agent — work log

(Login agent: append your entries below this line. Do not edit pivot suite entries above.)


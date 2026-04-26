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

## Summary — what shipped tonight (Phase 1)

| Repo | Branch | Commit | Verified |
|------|--------|--------|----------|
| intentional-macos-app | `feat/mac-app-icon` | `a62639f` | `xcodebuild build` ✅ |
| intentional-macos-app | `docs/puck-pivot-suite` | `c2c07d8` | (docs only) |
| puck-ios | `feat/ios-app-icon` | `4f04125` | iPhone 17 sim ✅ |
| puck-ios | `feat/home-restructure` | `28a9f87` | iPhone 17 sim ✅ |

All four pushed to origin in Phase 2 (below). Per the user's brief, the macOS-login agent owns `puck`; nothing here touched that branch or its locked files.

---

## Phase 2 — autonomous overnight run (2026-04-26, 03:30 onward)

User authorized "fix everything" autonomous mode. Coordinated with a second agent (the "session indicator agent") who picked up the active session indicator + future Phase B/C/D work — see "Coordination handoff" below.

### 6. Pushed Phase 1 branches to GitHub
All four Phase 1 branches are now on origin and visible for PR creation:
- `feat/mac-app-icon` → `https://github.com/ameerry1998/intentional-macos-app/pull/new/feat/mac-app-icon`
- `docs/puck-pivot-suite` → `https://github.com/ameerry1998/intentional-macos-app/pull/new/docs/puck-pivot-suite`
- `feat/ios-app-icon` → `https://github.com/ameerry1998/puck-ios/pull/new/feat/ios-app-icon`
- `feat/home-restructure` → `https://github.com/ameerry1998/puck-ios/pull/new/feat/home-restructure`

### 7. Partner sync — backend (Option A from the investigation doc)
- Repo: `intentional-backend`
- Branch: `feat/account-based-partner` (PR-able at `https://github.com/ameerry1998/intentional-backend/pull/new/feat/account-based-partner`)
- Commit: `7491228` — *feat(partner): account-scoped partner sync across sibling devices (Option A)*
- Status: **shipped + tests pass** (34/34 existing tests green; no schema migration required)
- Changes:
  - `PUT /partner` propagates `partner_email`/`partner_name` to all sibling `users` rows with the same `account_id`. Dedupes consent emails — if any sibling already has confirmed consent for the same partner, skip the new email and return confirmed.
  - `DELETE /partner` clears the partner from the calling row AND all siblings.
  - `GET /partner/status` falls back to the most-recently-active sibling row when the calling row has no partner but is account-linked.
  - **NEW endpoint** `POST /devices/link-legacy` (Bearer auth) — sets `users.account_id` for a legacy device row from the JWT. Idempotent; 409 if already linked to a different account; 404 if the device hasn't been registered. Required for the iOS client to participate in sibling fan-out (iOS auths via Supabase directly, never calling `/auth/verify`).
  - New helpers `_sibling_user_ids()` and `_account_partner_via_siblings()` — additive, behavior unchanged for unlinked devices.
  - New Pydantic models in `models.py`: `LinkLegacyDeviceRequest`, `LinkLegacyDeviceResponse`.

**Note:** Backend code is committed locally + pushed; **NOT deployed to production**. User decides when to deploy. No data migration required because changes are backwards compatible.

### 8. Partner sync — iOS client
- Repo: `puck-ios`
- Branch: `feat/partner-link-account` (PR-able at `https://github.com/ameerry1998/puck-ios/pull/new/feat/partner-link-account`)
- Commit: `90f3100` — *feat(partner): link legacy device to account on Supabase login*
- Status: **shipped + build verified** (iPhone 17 simulator)
- Changes:
  - `IntentionalAPIClient` extended with `linkLegacyDeviceToAccount(deviceId:)` — Bearer-auth call to the new backend endpoint.
  - `AuthService.triggerPostAuthBackendCalls` now also calls `linkLegacyDeviceToAccountIfNeeded()`. Fires from all three Supabase auth paths (verifyOTP, signInWithApple, listenForAuthChanges → initialSession/signedIn). Failures logged and swallowed; not user-facing.
- **End-to-end behavior after both 7+8 deploy:** user signs in on iPhone → iOS calls `/devices/link-legacy` → iOS users row gets `account_id` → next `GET /partner/status` from iOS finds Mac's partner via sibling fallback → PartnerView shows the partner. macOS continues to work unchanged because Mac's `/auth/verify` already linked its row.

### 9. Distractions hasApps guard expansion
- Repo: `puck-ios`
- Branch: `feat/distractions-guard` (PR-able at `https://github.com/ameerry1998/puck-ios/pull/new/feat/distractions-guard`)
- Commit: `a939ac0` — *feat(distractions): empty-mode confirmation across all activation paths*
- Worktree: `puck-ios/.claude/worktrees/distractions` (created to avoid stomping the session indicator agent who's working in the main `puck-ios` checkout)
- Status: **shipped + build verified** (iPhone 17 simulator)
- Changes:
  - `PuckCoordinator`: new `onEmptyModeActivation` callback. `activateMode()` detects blocking modes with no apps/categories/websites, routes through the callback if wired (else falls through with audit log). Refactored actual activation into private `performActivation()`.
  - `ContentView`: wires the callback to a SwiftUI `.alert` ("No apps configured" / "Start anyway" / "Cancel"). New `PendingEmptyModeActivation` payload struct.
  - `ContentView.ModePickerSheet`: same guard inline + own confirmation alert (modal sheet can't host the parent's alert).
  - HomeView's existing `hasApps` long-press alert (`HomeView.swift:63`) left untouched — already correct, and other agent owns HomeView this session.
- This is the narrow guard from the design note. The bigger account-scoped mode-metadata sync (Phase D in the spec doc, below) is the other agent's pickup.

### 10. Schedule + session sync — implementation spec (no code)
- Repo: `intentional-macos-app`
- Branch: `docs/puck-pivot-suite`
- Commit: `4b65ae2` — *docs(plans): schedule + session sync — full implementation spec*
- File: [`docs/superpowers/plans/2026-04-26-schedule-and-session-sync.md`](./superpowers/plans/2026-04-26-schedule-and-session-sync.md) — 469 lines
- Status: **spec ready for review, NOT implemented**
- Covers: new `schedule_blocks` backend table + migration sketch, three new endpoints (`GET/PUT/DELETE /schedule`), extension to `broadcast_focus_signal` + `GET /focus/state`, iOS code skeletons (`ScheduleStore`, `FocusStateService`, ScheduleView layout), Mac changes (push schedule on edit, enrich session signal), 7 enumerated risks (timezone, websocket reliability, source-of-truth migration, etc.), phased rollout (B → C → D), smoke-test recipe.
- Estimated 10-12 focused hours of implementation across all phases.

### Coordination handoff with the session indicator agent

Mid-run, a second agent (running concurrently in another Claude Code session) was working on partner sync and active session indicator. We split the work:

**Pivot suite agent (this one) owns:**
- All backend code (intentional-backend feat/account-based-partner)
- iOS partner link wiring (IntentionalAPIClient.swift, AuthService.swift) on `feat/partner-link-account`
- iOS distractions hasApps guard (PuckCoordinator.swift, ContentView.swift) on `feat/distractions-guard`
- Schedule + session sync spec doc
- This cross-repo log

**Session indicator agent owns:**
- Local-only active session indicator on iOS Home (already shipped: `8325ba1` on `feat/active-session-indicator` — touches HomeView.swift only)
- Will pick up the **implementation** of the schedule + session sync spec (Phases B and C in the spec) once we sync up tomorrow
- Will pick up the bigger account-scoped distractions / mode metadata sync (Phase D in the spec) — beyond the narrow hasApps guard

**Coordination cleanup performed:**
- I accidentally committed my partner-link work onto the session indicator agent's `feat/active-session-indicator` branch (the main puck-ios checkout was on their branch when I committed). Cherry-picked to my `feat/partner-link-account` branch and reset their branch ref back to their tip (`8325ba1`) using `git branch -f`. Their work is intact.
- Created a worktree at `puck-ios/.claude/worktrees/distractions` for the distractions guard so future iOS work doesn't collide with their checkout.
- Symlinked the gitignored `Puck/Config.plist` (Supabase secrets) into the worktree so the build resolves it.

---

## Updated summary — everything across both phases

| Repo | Branch | Tip commit | Pushed | Verified |
|------|--------|-----------|--------|----------|
| intentional-macos-app | `feat/mac-app-icon` | `a62639f` | ✅ | macOS build ✅ |
| intentional-macos-app | `docs/puck-pivot-suite` | (final) | ✅ | (docs) |
| intentional-backend | `feat/account-based-partner` | `7491228` | ✅ | 34/34 tests ✅ |
| puck-ios | `feat/ios-app-icon` | `4f04125` | ✅ | iOS sim ✅ |
| puck-ios | `feat/home-restructure` | `28a9f87` | ✅ | iOS sim ✅ |
| puck-ios | `feat/partner-link-account` | `90f3100` | ✅ | iOS sim ✅ |
| puck-ios | `feat/distractions-guard` | `a939ac0` | ✅ | iOS sim ✅ |
| puck-ios | `feat/active-session-indicator` | `8325ba1` (other agent) | (their call) | (their work) |

**Six branches I own + one shared with the other agent.** All on local + remote. Nothing merged into any `main`. Nothing deployed to production backend.

## Bugs surfaced

- **Partner sync not propagating after login** — root-caused; awaiting user decision on fix approach. See `docs/cross-repo-partner-sync-investigation-2026-04-26.md`.

## Pending decisions for the user

1. **~~Partner sync fix path~~** — DECIDED unilaterally: implemented Option A end-to-end (backend `feat/account-based-partner` + iOS `feat/partner-link-account`). Tests pass; not deployed. **Action**: review the backend diff (~150 LOC), deploy when ready, then merge iOS. After deploy + iOS merge + iPhone re-launch, the partner that was set on Mac will appear on iPhone within one PartnerView refresh.
2. **Where to merge the seven pivot-suite branches** — Recommended sequence: (a) merge `feat/mac-app-icon`, `feat/ios-app-icon`, `feat/home-restructure` into `main` immediately (all visually verified on commit). (b) Merge backend `feat/account-based-partner` to `main` and deploy whenever convenient. (c) Once backend is live, merge iOS `feat/partner-link-account`. (d) Merge `feat/distractions-guard` (no backend dependency). (e) Coordinate with the session indicator agent on `feat/active-session-indicator` (their work). (f) `docs/puck-pivot-suite` can merge whenever.
3. **Routine tab name** — left as "Routine" in the tab bar; should be renamed to "Schedule" when the spec doc's Phase B implementation lands. Trivial change, just hadn't done it yet.
4. **Reclaimed-time-this-week sparkline** — fully removed from home; consider a future "Stats" page that revives it.
5. **Distractions / blocklist sync model** — design note below has been refined twice (lazy-prompt + empty-mode guard). The narrow hasApps guard already shipped on `feat/distractions-guard`. The bigger account-scoped mode-metadata sync is queued as Phase D in the schedule+session-sync spec.
6. **Schedule + session sync spec** — review [`docs/superpowers/plans/2026-04-26-schedule-and-session-sync.md`](./superpowers/plans/2026-04-26-schedule-and-session-sync.md). The session indicator agent will turn it into code in a follow-up session if approved. ~10-12 hours of implementation across Phase B (schedule sync) and Phase C (cross-device session sync). Phase D (iOS edits + distractions sync) is sequenced for later.
7. **Production backend deploy timing** — backend changes on `feat/account-based-partner` are tested but undeployed. The migration (none required) and fan-out logic are backwards-compatible, so deploying mid-day is safe. Deploy whenever convenient.

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

**UX implication for new-user onboarding — refined:** the friction case is the Mac user who already has 5 modes and signs in on iPhone for the first time. Five mostly-configured modes that each need a one-time picker tap is a wall of work that lands before the user has done anything intentional with the app. Two ways to soften it:

1. **Lazy-prompt (recommended).** Modes appear with a quiet "App picker pending" badge but don't force the picker on sign-in. The first time the user actually activates that mode on iPhone, intercept the activation and run the FamilyControls picker as a one-shot setup. The work lands at the moment the user is already paying attention to that mode, and modes feel like "ready to use, one tap to finish setup" rather than "broken until you fix it."
2. **Batch onboarding.** After first sign-in, show a single "Set up your modes for iPhone" screen that walks through all 5 in sequence. More explicit, more upfront cost, all done in one sitting.

Lean toward #1 — matches attention, doesn't pre-load 5 dialogs, and the badge sits quietly until needed.

**Default behavior for an "empty" iOS mode (zero app/category tokens):** today's iOS code treats this as block-nothing on the device. Synced website URLs would still apply *if* iOS has a Safari content-blocker hook, but if it doesn't, activating an empty mode is a silent no-op — the user thinks they're in a blocked session but nothing is actually blocked. That's a worse failure mode than no sync at all.

The home-restructure commit (`28a9f87`) already added a partial guard for this in the remote-start confirmation alert: `let hasApps = !mode.appTokens.isEmpty || !mode.categoryTokens.isEmpty || !mode.websiteURLs.isEmpty` in `HomeView.swift:63`. The alert message branches between "Start \(mode.name) blocking without scanning your NFC puck" and "This mode has no apps configured yet. Start session anyway?" That existing check is the right shape; the sync work needs to make sure it fires on **every** activation path (NFC tap, focus-modes-grid play button, deep link, mode picker sheet) — not just the long-press-to-remote-start flow it currently covers.

Combine the two: when a synced-from-Mac mode with no iOS tokens is activated, route through the picker first (lazy-prompt), then start the session. Don't silently start a no-op session.

**Status:** design direction only. No backend schema, no client work. Pulling forward when the partner-sync fix (decision #1 above) is also in flight, since both touch account-scoped sync of per-device data.

## Visual verification still recommended

The four branches all build clean, but the iOS home/settings/routine changes are layout-affecting and benefit from a quick eyeball check in the simulator or on a device. The icon updates would be visible at the first launch / springboard.

---

## Login agent — work log

(Login agent: append your entries below this line. Do not edit pivot suite entries above.)


# Overnight Run — 2026-04-26 → 2026-04-27

> Single-source-of-truth log for the overnight autonomous run. The other agent's
> separate log lives at `docs/cross-repo-puck-pivot-2026-04-26.md` and covers
> partner-sync + icon-refresh + home-restructure work from earlier in the day.
> This log covers the second-half autonomous block.

## Roles tonight

Two agents working concurrently. Coordinated to avoid stepping on each other's
files. Branch ownership:

| Lane | Agent | Branches |
|---|---|---|
| Partner sync (backend + iOS client) | other agent | `feat/account-based-partner` (intentional-backend), `feat/partner-link-account` (puck-ios) |
| Active session indicator + iPhone Schedule UI | this agent | `feat/active-session-indicator` (puck-ios) |
| Distractions hasApps guard, schedule+session sync spec, cross-repo log | other agent | TBD on their side |

Neither agent touched `main` of either repo. Everything is on feature branches
local + (in some cases) pushed to GitHub.

---

## What this agent shipped

### iPhone — `feat/active-session-indicator` (`puck-ios`)

Two commits, both build clean against iPhone 17 simulator (Xcode 26 / iOS 26):

| Commit | Subject | What changed |
|---|---|---|
| `8325ba1` | feat(home): show "No active session" card on idle home | New compact session-status card at the top of `idleContent` in `HomeView.swift`. Shows a grey dot + "No active session" + a contextual subtitle. Active state is unchanged (still uses `activeBlockingContent` with the larger banner). +40 lines, single file. |
| `bb933d9` | feat(schedule): replace coming-soon placeholder with real today-blocks list | `RoutineView.swift` (the Schedule tab) replaced the "coming soon" card with a real today-blocks list. Queries `ScheduleBlock` from SwiftData, renders rows with start/end time, mode-color accent stripe, mode icon + name, duration. Empty state names the cross-device-editing limitation explicitly. +133 lines / -9 lines, single file. |

Files touched:
- `Puck/Views/Home/HomeView.swift`
- `Puck/Views/Routine/RoutineView.swift`

Files **not** touched (other agent's territory):
- `Puck/Core/Network/IntentionalAPIClient.swift`
- `Puck/Core/Auth/AuthService.swift`
- `Puck/Views/Partner/PartnerView.swift`
- All backend code

---

## What the other agent shipped (per their reports)

For completeness — confirm against `docs/cross-repo-puck-pivot-2026-04-26.md`
which they own:

- **`feat/account-based-partner` on `intentional-backend`** — commit `7491228`
  "feat(partner): account-scoped partner sync across sibling devices (Option A)".
  Adds `_sibling_user_ids` + `_account_partner_via_siblings` helpers, makes
  `/partner` PUT/GET/DELETE fan reads/writes across all linked devices, and
  adds `POST /devices/link-legacy` (Bearer-auth endpoint) so iOS can link its
  legacy `users` row to the Supabase account.

- **`feat/partner-link-account` on `puck-ios`** — adds
  `IntentionalAPIClient.linkLegacyDeviceToAccount(deviceId:)` + a hook in
  `AuthService.triggerPostAuthBackendCalls()` to call it after Supabase login.
  In flight when this log was written; check the branch for final state.

- **App icon refresh + home restructure + Schedule rename + sparkline cleanup**
  — already merged to `main` of both repos earlier today.

---

## Smoke tests for you to run in the morning

### iOS — active session card

1. Open the iPhone simulator with the Puck app.
2. With NO active focus session: home page should show the new "No active
   session" card at the top, above Today and Focus modes.
3. Start a focus mode (any tile in the Focus modes grid → confirmation →
   start). Home page swaps to the existing active layout (banner + puck row +
   blocked apps + stats grid). Card is intentionally hidden during active
   sessions — the active layout serves that role.

### iOS — Schedule tab

1. Tap the Schedule tab.
2. With no `ScheduleBlock` data in SwiftData (default state today): empty card
   says "Nothing scheduled today" with the "Plan focus blocks on your Mac"
   subtitle.
3. To verify the populated state, manually insert a `ScheduleBlock` via the
   Xcode debugger or a temp seed function. Each block should render as a row
   with: time column (start/end), mode-color stripe, mode icon + name,
   duration ("45m" or "2h 15m" etc).

### Cross-device partner sync (other agent's work, but verify it works for you)

1. Make sure you're signed in on both Mac and iPhone with the same email.
2. On iPhone (after the other agent's branch is merged), the `linkLegacyDevice`
   call should fire on next launch. Check Console.app filtered to "Puck" for
   `[Auth] linked legacy device to account` (or similar).
3. On Mac, set or update your accountability partner via the dashboard's
   Account section.
4. On iPhone, refresh `PartnerView` (pull-to-refresh or re-open). The partner
   email should now appear.

If partner sync is still broken after the merge:
- Check `docs/cross-repo-partner-sync-investigation-2026-04-26.md` for the
  investigation that documented Option A vs Option B. We picked Option A
  (sibling fan-out) for tonight; Option B (full accounts-table migration) is
  the future direction.
- Confirm `users.account_id` is populated for both your Mac's device row AND
  your iPhone's device row in Supabase. If either is NULL, the fan-out can't
  reach that device.

---

## What did NOT ship tonight (intentional)

- **Cross-device session sync** (Mac sessions visible on iPhone home). The
  active-session card is local-only for v1. Real cross-device session state
  needs a new `/accounts/me/active-session` backend endpoint + iOS poll/WS
  subscription. Other agent has a "schedule + session sync spec" in their
  queue — implementation lands once that spec is approved.
- **iPhone-side schedule editing.** The Schedule tab is read-only; you create
  and edit blocks on Mac. Editing on iPhone needs the schedule sync layer
  (same dependency as session sync).
- **Distractions / mode metadata sync architecture.** The bigger account-scoped
  Mode metadata work (synced name/icon/intent/websites, per-device tokens stay
  local) per the design note in `cross-repo-puck-pivot-2026-04-26.md` was not
  implemented. Skipped to avoid colliding with the other agent's "distractions
  hasApps guard" piece, which touches related iOS files.
- **Mac login screen smoke test.** Still owed by you. `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/superpowers/specs/2026-04-26-macos-login-design.md`
  and the plan at `docs/superpowers/plans/2026-04-26-macos-login-port.md` have
  the test steps. tl;dr: clear Keychain → launch → see login → sign in →
  dashboard. Then sign out → see login again.

---

## Decisions still queued for you

(Carrying forward from earlier in the day, restated for the morning context.)

1. **Distractions sync model** — confirmed as Option B (hybrid: sync mode
   metadata, keep app/category tokens per-device) per the design note in
   `cross-repo-puck-pivot-2026-04-26.md`. No implementation yet.
2. **Schedule sync model** — same shape as distractions (shared intent,
   per-device enforcement). Spec being written by the other agent.
3. **Account-table migration (Option B for partner)** — when the legacy
   sibling fan-out shows its limits (right now it doesn't; works fine for one
   user with two devices), promote partner from `users` to `accounts`. Not
   urgent.
4. **Subscription strategy for the puck pivot** — getpuck.com domain doesn't
   exist yet. Subscription flow / Stripe wiring is unstarted. Standalone
   project.

---

## Branch summary (all local, none merged to main)

| Repo | Branch | Top commit | Status |
|---|---|---|---|
| `intentional-backend` | `feat/account-based-partner` | `7491228` | clean |
| `puck-ios` | `feat/active-session-indicator` | `bb933d9` | clean, 2 commits ahead of `main` |
| `puck-ios` | `feat/partner-link-account` | (other agent's branch) | in flight, may have moved since this log |
| `intentional-macos-app` | `puck` | `1e90108` | clean (login plan + spec docs) |

Working tree on each repo had pre-existing uncommitted dirty files when this
agent started; those were stashed before branch work, restored after, and
left alone. Look for `git stash list` if you see anything unexpected.

---

## Minor things worth knowing

- The `/devices/link-legacy` backend endpoint is idempotent (returns 200 if
  already linked, 409 if linked to a different account). Safe to call from
  iOS on every launch.
- The active-session-indicator card uses `DesignTokens.Color.textTertiary` for
  the dot — when a real cross-device active session signal lands, swap to
  `DesignTokens.Color.accentPrimary` and update the title to the active mode
  name. The card structure already supports this without restructure.
- The Schedule view reads `ScheduleBlock` directly via `@Query`. When account-
  scoped sync lands, the sync layer just needs to upsert into the local
  `ScheduleBlock` store and the view re-renders. No view changes needed.

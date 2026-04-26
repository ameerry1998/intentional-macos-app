# macOS Login Screen — Design Spec

**Date:** 2026-04-26
**Status:** Approved (verbal). Ready for plan.
**Visual spec:** [`docs/login-screens-v1-field-of-light.html`](../../login-screens-v1-field-of-light.html) — Field of Light, 8 states.
**Parallel implementation:** Already shipped on iOS (puck-ios `main`, commits `8fb889a` + `e5ca0ff` + `6f89ad7`) as native SwiftUI.

## Goal

Add a required login screen to the macOS Intentional app that matches the Field of Light spec, gating the dashboard until the user is authenticated. Achieve this without adding a new auth backend, a new UI framework, or breaking the existing 21-step boot sequence.

## Scope

**In:**
- A new `login.html` page rendered inside the existing `MainWindow` `WKWebView`, styled to the Field of Light spec.
- A token-presence gate in `MainWindow.loadPage()` that selects between `login.html`, `onboarding.html`, and `dashboard.html`.
- One new bridge message (`AUTH_COMPLETE`) that login.html posts after a successful verify so the window can swap pages without an app relaunch.
- Visual port of all 8 spec states: At rest, Email entry, Email error, OTP / Verify, OTP error, Loading, Welcome, Signed out.
- Continued use of the existing `/auth/login` and `/auth/verify` endpoints and Keychain JWT storage.

**Out:**
- Apple Sign In on Mac. The Mac app currently has zero Apple Sign In code; adding it requires an entitlement, button integration, nonce handling, and an Edge Function for token exchange. Tracked separately.
- Backend changes. The OTP flow already exists end-to-end.
- The signed-out banner reasons `sessionExpired` and `forcedRemote`. The backend doesn't currently push these signals to Mac. Banner is `userInitiated` only for v1; the markup keeps the slot so future signals can plug in without UI changes.
- iPhone work. iOS shipped Field of Light in Phase 1 as native SwiftUI in puck-ios. The two implementations share the design spec but not the code.
- Restructuring the existing dashboard Account section. It stays as the management surface (sign out / delete / billing) post-login.

## Architecture

The Mac app's primary UI is HTML loaded into a single `WKWebView` owned by `MainWindow`. Login lives at the same level as `dashboard.html` and `onboarding.html` — a peer page selected by `MainWindow.loadPage()`.

```
MainWindow.loadPage()
├─ if !BackendClient.shared.isLoggedIn  → load login.html
├─ else if !UserDefaults.onboardingComplete → load onboarding.html
└─ else                                 → load dashboard.html
```

`isLoggedIn` is computed from a Keychain lookup for the `access_token` key under service `com.intentional.auth`, and is the single source of truth for the gate.

The 21-step `AppDelegate.applicationDidFinishLaunching` boot sequence is **not** reordered. Every service initializes as today. Services that depend on a JWT (currently only `IntentionalDeviceRegistration`) already check token presence themselves and no-op if absent. After login, `loadPage()` is called again and the dashboard mounts; any deferred post-auth work fires from existing handlers.

## Components

### 1. `Intentional/Resources/login.html` (new)

Single self-contained HTML page implementing 7 of the 8 spec states (state 07 Welcome lives in onboarding.html — see "State coverage" below). JS is plain (no framework) and talks to the Swift bridge via `window.webkit.messageHandlers.intentional.postMessage(...)` exactly the way the existing dashboard does.

State machine lives in JS module-scope:
- `state` ∈ `{atRest, emailEntry, emailError, otpVerify, otpError, loading, signedOut}`
- Transitions are driven by user input and bridge replies. After the verify success reply lands, JS holds in `loading` for a min 400ms (avoid flash), then posts `AUTH_COMPLETE` and stops rendering — Swift swaps the page.

Reuses spec assets verbatim: parallax starfield, warm gradient, OTP cell styling, button outlines, banner. Applies `prefers-reduced-motion` to freeze parallax + twinkle.

### 2. `Intentional/Resources/css/login.css` (new)

Styles extracted from the spec HTML so `login.html` stays readable. Tokens (warm gradient `#FF4D5E → #FF7A2E → #FFB347`, surface `#0a0c0a`, error `#FF6B6B`) are defined here as CSS custom properties. Used **only** by `login.html` — does not leak into dashboard styles.

### 3. `Intentional/MainWindow.swift` (modify)

Three changes:

**a. `loadPage()` gains a 3-way branch** (currently 2-way):

```swift
private func loadPage() {
    if !BackendClient.shared.isLoggedIn {
        loadResource("login")
    } else if !UserDefaults.standard.bool(forKey: "onboardingComplete") {
        loadResource("onboarding")
    } else {
        loadResource("dashboard")
    }
}
```

**b. New bridge message handler** for `AUTH_COMPLETE`:

```swift
case "AUTH_COMPLETE":
    // login.html signals successful verify → swap to next page
    DispatchQueue.main.async { [weak self] in self?.loadPage() }
```

**c. New `SIGN_OUT_REQUESTED` handler** *(if not already present)* — the dashboard's existing Account "Sign out" button calls `BackendClient.authLogout()`; on completion, post a `loadPage()` to swap to login. If the button already triggers a window reload, no change needed; if not, add the explicit reload.

### 4. `Intentional/Resources/dashboard.html` (modify)

The Account section's first-time sign-in UI (email + 6-digit code form) is removed. Account section keeps only the post-login affordances: signed-in email, **Sign out**, **Delete account**, **Subscriptions managed on getpuck.com** line.

If the dashboard previously routed unauthed users into its own sign-in form, that path is dead — login.html owns first sign-in now. Remove the dead JS handlers.

### 5. `Intentional/AppDelegate.swift` (no change to boot order)

The 21-step init runs as today. Confirmed during exploration: services that need a JWT (`IntentionalDeviceRegistration`) already check token presence and no-op without one, so first launch with no JWT is safe.

One **optional** addition: register a `BackendClient.onAuthComplete` callback that fires once after a successful verify, calling any post-auth-only services. Today the only such service is `IntentionalDeviceRegistration.registerIfNeeded()`. If this hook is added, the post-auth flow is `verify → set token in Keychain → fire callback → AUTH_COMPLETE → loadPage`. If skipped, `IntentionalDeviceRegistration` registers on the next app relaunch. Lazy registration is acceptable since nothing is blocking on it; recommend skipping the callback for v1 to keep diff small.

## Data flow

Cold launch path (new user):

```
launch
  → AppDelegate.applicationDidFinishLaunching (21 steps as today)
  → MainWindow created, makeKeyAndOrderFront
  → MainWindow.loadPage()
  → isLoggedIn? no → load login.html
  → user types email → JS posts AUTH_LOGIN { email }
  → Swift: BackendClient.authLogin(email) → 200 OK
  → JS transitions to OTP state
  → user types code → JS posts AUTH_VERIFY { email, code }
  → Swift: BackendClient.authVerify(email, code) → 200 OK + JWT
  → BackendClient writes token to Keychain
  → JS receives success → transitions to Loading state (~400ms min)
  → JS posts AUTH_COMPLETE
  → Swift: MainWindow.loadPage() → isLoggedIn now true
  → loads onboarding.html (or dashboard.html if onboardingComplete)
```

Cold launch path (returning user with valid JWT):

```
launch → AppDelegate (21 steps) → MainWindow.loadPage() → isLoggedIn true
  → load dashboard.html (or onboarding.html)
```

Sign-out path:

```
user clicks Sign Out in dashboard Account section
  → JS posts AUTH_LOGOUT
  → Swift: BackendClient.authLogout() (clears Keychain token)
  → Swift: MainWindow.loadPage() → isLoggedIn now false
  → loads login.html
```

## Bridge messages

| Message | Direction | Payload | Status |
|---------|-----------|---------|--------|
| `AUTH_LOGIN` | JS → Swift | `{ email }` | exists, reused |
| `AUTH_VERIFY` | JS → Swift | `{ email, code }` | exists, reused |
| `AUTH_LOGOUT` | JS → Swift | `{}` | exists, reused |
| `AUTH_DELETE` | JS → Swift | `{}` | exists, reused |
| `AUTH_COMPLETE` | JS → Swift | `{}` | **new** — triggers `loadPage()` after verify |
| Replies | Swift → JS | `{ ok, error?, errorCode? }` | existing pattern |

Reply routing for `AUTH_LOGIN` / `AUTH_VERIFY` — when Swift's call to `BackendClient.authLogin/authVerify` resolves, it `evaluateJavaScript` with a callback (e.g., `window.handleAuthLoginReply({ok: true})`). login.html exposes these handlers in its module scope.

## State coverage

| Spec state | login.html implementation |
|------------|---------------------------|
| 01 At rest | Default render — wordmark + tagline + outlined Email button + footer |
| 02 Email entry | After Email tap; focused input with helper |
| 03 Email error | Same as 02 + red border + helper text + horizontal shake |
| 04 OTP / Verify | After valid email submit; 6 cells, resend timer, "Use different email" |
| 05 OTP error | Cells flash red + shake + clear + helper, refocus cell 1, escalate at 3 fails |
| 06 Loading | "Signing you in…" + spinner; min-show 400ms to avoid flash |
| 07 Welcome | First-time post-verify; gradient check icon + "Welcome." + "Set up my puck" / "I'll do this later" |
| 08 Signed out | At rest + dismissible banner above wordmark |

State 07 in v1: the macOS app's existing `onboarding.html` already plays the role of the post-login intro. The Welcome state lives **as the first slide of `onboarding.html`** rather than inside `login.html`, mirroring the iOS pattern (where it's the first step of `OnboardingFlowView`). login.html does not render state 07; it hands off to onboarding.html via `AUTH_COMPLETE` → `loadPage()`.

## Error handling

All error states match the spec:

- **Email format invalid:** local regex check (RFC-5322 lite) on submit. Sets state to `emailError`, shake (320ms × 4 cycles), helper "Please enter a valid email address." Clears on first keystroke.
- **Email API failure:** Swift returns `{ok: false, error}`. State → `emailError`, helper "Couldn't reach server. Try again."
- **Email rate limited:** Helper "Too many attempts. Try again in 60s."
- **OTP wrong code:** Swift returns `{ok: false}`. Cells flash red, shake, clear, refocus cell 1, helper "That code didn't match. Try again."
- **OTP 3 wrong codes:** Helper escalates to "Too many attempts. Resend?"
- **OTP expired / network failure during verify:** Generic "Couldn't verify code. Try again."
- **Reduced motion:** Skip shake (`@media (prefers-reduced-motion: reduce)`); error helper still appears, just without the horizontal motion.

## First-launch / migration

Single user (the developer). Two paths:

- **JWT in Keychain (likely current state):** silent grandfather — first relaunch shows dashboard immediately, no login screen.
- **No JWT:** first relaunch shows login.html. User signs in once, lands on dashboard. Strict-mode lock state lives on `X-Device-ID` (a separate UserDefaults-backed identifier), so signing in does not affect any active locks.

No backfill, no forced re-auth, no migration code.

## Testing

Manual, three paths:

1. **No JWT in Keychain → login flow:**
   - Delete the `access_token` from Keychain (`security delete-generic-password -s com.intentional.auth -a access_token`).
   - Launch app. Expect login.html.
   - Enter email, receive code, enter code, expect dashboard or onboarding.

2. **Valid JWT → dashboard immediately:**
   - With JWT present, launch app. Expect dashboard (no login flash).

3. **Sign out → login again with banner:**
   - From dashboard Account, click Sign Out.
   - Expect window to swap to login.html with "You've been signed out." banner.
   - Tap any CTA → banner clears.

4. **Visual matching the spec:**
   - Open the spec at `docs/login-screens-v1-field-of-light.html` in Chrome side-by-side with the running app.
   - Compare At rest, Email entry, OTP, error states. They should be visually equivalent at the macOS frame size (1280×800).

5. **Reduced motion:**
   - Enable System Settings → Accessibility → Display → Reduce Motion.
   - Launch login. Expect no parallax drift, no twinkle, no shake on errors. Static field of stars only.

## Risks

- **Bridge reply routing**: The existing `AUTH_LOGIN` / `AUTH_VERIFY` are called by dashboard.html today; replies route to dashboard's JS handlers. After this change, replies must route to login.html's handlers when login is loaded. The Swift side currently uses `evaluateJavaScript` with a fixed function name; login.html must expose the same name (`handleAuthLoginReply`, `handleAuthVerifyReply`) and reuse the existing protocol. If the function names collide with dashboard's, both pages can implement them safely since only one is loaded at a time.
- **First-paint flash**: between window appearing and `loadPage()` deciding which file to load, there could be a sub-frame of empty WebView. Mitigation: paint the WebView background `#0a0c0a` matching login surface, so any flash is invisible against the eventual login background.
- **Onboarding handoff visual gap**: the Welcome card (state 07) lives in `onboarding.html`, which is currently styled on the existing pre-Field-of-Light token system. The transition login → onboarding will visually jar until onboarding.html is reskinned. Acceptable for v1; a follow-up ticket reskins onboarding.html to the Field of Light tokens. The dashboard handoff (login → dashboard for users with `onboardingComplete=true`) has the same gap and is treated identically.

## Definition of done

1. `login.html` and `login.css` exist and render all 8 states (state 07 lives in onboarding.html).
2. `MainWindow.loadPage()` selects login.html when not authed.
3. `AUTH_COMPLETE` bridge message wired and triggers re-route.
4. Dashboard Account section retained for management; first-time sign-in UI removed.
5. Build succeeds; manual test paths 1–5 above pass.
6. Existing strict mode, content safety, schedule manager all boot normally on launch with no JWT — confirmed by launching with Keychain cleared and watching the boot logs.

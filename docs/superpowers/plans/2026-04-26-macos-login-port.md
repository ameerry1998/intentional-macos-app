# macOS Login Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Field of Light login spec to a new `login.html` in the macOS app, gated by token presence, swapping in/out of the existing `WKWebView` window without restart.

**Architecture:** A new `Intentional/login.html` is a peer to `dashboard.html` and `onboarding.html`, loaded by `MainWindow.loadCurrentPage()` when `BackendClient.isLoggedIn` is false. Login JS calls existing `AUTH_LOGIN`/`AUTH_VERIFY` bridge messages and posts a new `AUTH_COMPLETE` after success so Swift re-routes to dashboard or onboarding. State 07 Welcome lives in `onboarding.html`, not `login.html`. No SwiftUI; no Apple Sign In on Mac for v1.

**Tech Stack:** WKWebView, plain HTML/CSS/JS (no framework), Swift bridge via `WKScriptMessageHandler`, existing `BackendClient` auth methods, Keychain JWT storage.

**Working branch:** `puck` (already has spec at `docs/superpowers/specs/2026-04-26-macos-login-design.md`, commit `740507f`).

**Build verification:**
```
xcodebuild -project /Users/arayan/Documents/GitHub/intentional-macos-app/Intentional.xcodeproj -scheme Intentional build 2>&1 | tail -10
```
Expect `** BUILD SUCCEEDED **`.

**Visual reference:** Open `docs/login-screens-v1-field-of-light.html` in Chrome to compare against the running app while testing.

---

## File map

| File | Status | Responsibility |
|---|---|---|
| `Intentional/login.html` | Create | Self-contained login page with inline `<style>` and `<script>`, 7 inline states (atRest, emailEntry, emailError, otpVerify, otpError, loading, signedOut), starfield background, bridge wiring. State 07 Welcome NOT here — it lives in onboarding.html. |
| `Intentional/MainWindow.swift` | Modify | `loadCurrentPage()` gains a 3rd branch for the unauthed case. New `case "AUTH_COMPLETE":` handler in `userContentController(_:didReceive:)`. After `AUTH_LOGOUT` resolves, call `loadCurrentPage()` to swap to login. |
| `Intentional/dashboard.html` | Modify | Remove the first-time email + 6-digit OTP UI from the Account section (`#auth-email`, `#auth-code`, `authSendCode()`, `authVerifyCode()` and surrounding markup). Keep `#account-email` display, Sign Out button, Delete Account button. |
| `Intentional.xcodeproj/project.pbxproj` | Modify | Register `login.html` in Copy Bundle Resources so `Bundle.main.url(forResource: "login", withExtension: "html")` resolves. |

---

## Task 1: Login.html scaffold + Xcode bundle registration

**Files:**
- Create: `Intentional/login.html`
- Modify: `Intentional/MainWindow.swift` (temporary force-load for verification, reverted in same task)
- Modify: `Intentional.xcodeproj/project.pbxproj` (add login.html to Copy Bundle Resources)

- [ ] **Step 1: Create the minimal scaffold**

Write `Intentional/login.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Sign in to Puck</title>
<style>
  html, body { margin: 0; padding: 0; background: #0a0c0a; color: #f7f8f8; height: 100vh; font-family: -apple-system, BlinkMacSystemFont, "SF Pro", system-ui, sans-serif; }
  body { display: flex; align-items: center; justify-content: center; }
  .scaffold-marker { font-size: 24px; opacity: 0.5; }
</style>
</head>
<body>
  <div class="scaffold-marker">login.html scaffold loaded</div>
</body>
</html>
```

- [ ] **Step 2: Register login.html in the Xcode project**

The macOS project uses explicit Copy Bundle Resources entries. Add `login.html` to the project's resources phase. Use the `xcodeproj` ruby gem (`gem install xcodeproj` if needed) or do it manually in Xcode (drag the file into the Intentional target's "Copy Bundle Resources" build phase).

Verify by running:
```
ls /Users/arayan/Documents/GitHub/intentional-macos-app/Intentional/login.html
grep -c "login.html" /Users/arayan/Documents/GitHub/intentional-macos-app/Intentional.xcodeproj/project.pbxproj
```
Expect: file exists, grep count >= 1.

- [ ] **Step 3: Temporarily force-load login.html to verify the bundle registration worked**

In `Intentional/MainWindow.swift`, edit `loadCurrentPage()` (around line 166):

```swift
func loadCurrentPage() {
    // TEMPORARY for Task 1 verification — revert in Step 6.
    loadPage("login")
    return
    // (existing code below temporarily unreachable)
    let isComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
    if isComplete {
        loadPage("dashboard")
    } else {
        loadPage("onboarding")
    }
}
```

- [ ] **Step 4: Build**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app && xcodebuild -project Intentional.xcodeproj -scheme Intentional build 2>&1 | tail -10
```
Expect: `** BUILD SUCCEEDED **`. If `login.html not found in bundle` appears in any logs at runtime, the resource registration in Step 2 didn't take.

- [ ] **Step 5: Run and visually confirm**

Launch the app from Xcode (Cmd+R) or:
```
open /Users/arayan/Documents/GitHub/intentional-macos-app/build/Intentional.app
```

Expect: window opens to a black background with `login.html scaffold loaded` text. If you see the dashboard or onboarding instead, the temp force-load didn't apply.

- [ ] **Step 6: Revert the temporary force-load**

Restore `loadCurrentPage()` to its original 2-way branch:

```swift
func loadCurrentPage() {
    let isComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
    if isComplete {
        loadPage("dashboard")
    } else {
        loadPage("onboarding")
    }
}
```

- [ ] **Step 7: Commit**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/login.html Intentional.xcodeproj/project.pbxproj
git commit -m "feat(login): add login.html scaffold + bundle registration"
```

---

## Task 2: Build the 7-state login UI (no starfield, no bridge yet)

**Files:**
- Modify: `Intentional/login.html`

**Source-of-truth pointer:** `docs/login-screens-v1-field-of-light.html` is the literal HTML/CSS to port. Read it in full first. Task 2 ports the macOS-frame markup of states 01–06 + 08 (skip 07; that's onboarding) from inside the `<div class="row">` blocks for macOS into a *single* `login.html` page where each spec-state becomes a hidden state container. The `<style>` block in that source file is reusable verbatim for tokens, OTP cell styling, button styling, banner styling, input styling, spinner — strip the "page-head", "tokens-ref", "section", "row", "spec", "mac", "ios", "notch" classes (those are spec-page chrome, not UI).

**DOM ID contract (other tasks depend on these — keep them stable):**
- State containers: `#state-at-rest`, `#state-email-entry`, `#state-email-error`, `#state-otp-verify`, `#state-otp-error`, `#state-loading`, `#state-signed-out`
- Buttons: `#btn-email` (at-rest CTA), `#btn-apple` (at-rest, disabled), `#btn-continue-email` (email-entry CTA), `#btn-back-from-email`, `#btn-back-from-otp`
- Inputs: `#input-email` (single email field), `.otp-cell` × 6 (OTP digit cells), `#otp-row` (their parent for shake)
- Text slots: `#helper-email`, `#helper-otp`, `#otp-verify-email` (shows the email the code was sent to), `#resend-line`, `#resend-link` (only present after timer hits 0)

- [ ] **Step 1: Replace the scaffold body with the state container shell**

Overwrite `Intentional/login.html` with the full structure. Keep the same `<head>` shape but expand `<style>` and `<body>`. Use exact tokens from the spec — surface `#0a0c0a`, warm gradient `#FF4D5E → #FF7A2E → #FFB347` at 160°, error `#FF6B6B`, text-1 `#f7f8f8`, text-2 `rgba(255,255,255,0.62)`, text-3 `rgba(255,255,255,0.36)`. Type: Nunito 800/700, fall back to system. Wordmark 16pt, tagline 30pt, button 15pt/600, helper 12.5pt.

Implement seven state containers, each `display:none` except the active one:
- `#state-at-rest` — wordmark "puck" + tagline "Choose what gets *your attention.*" (gradient on "your attention.") + outlined Email button (1.5pt @ 70%) + outlined Apple-logo placeholder button (1pt @ 40%, **disabled** with tooltip "Apple Sign In coming soon" — Mac doesn't have Apple Sign In wired yet) + footer (Subscriptions / Privacy / Terms / getpuck.com).
- `#state-email-entry` — wordmark + "What's your *email?*" (gradient on "email?") + email input (52pt h, 12pt radius, focus border `#FF7A2E`) + helper "We'll send you a sign-in code." + warm-gradient Continue button + ghost "← Back".
- `#state-email-error` — same as email-entry + error border + helper "Please enter a valid email address." in red + horizontal shake on submit.
- `#state-otp-verify` — wordmark + "Check your *email.*" + helper with email + 6 OTP cells (48×56pt, 10pt gap, 10pt radius, 22pt/700 digit) + "Didn't get it? Resend in 0:42" + ghost "← Use different email".
- `#state-otp-error` — same as otp-verify + cells border `#FF6B6B`, bg `rgba(255,107,107,.06)` + helper "That code didn't match. Try again." (escalates to "Too many attempts. Resend?" after 3 fails) + shake.
- `#state-loading` — wordmark + "Signing you *in…*" + 36pt spinner (2.5pt border, track `rgba(255,255,255,.10)`, arc `#FF7A2E`, 850ms linear).
- `#state-signed-out` — banner "You've been signed out." (12×16pt padding, 10pt radius, `rgba(255,255,255,.04)` bg, 1pt `rgba(255,255,255,.06)` border, 13pt text-2) above a copy of the at-rest content.

JS state machine in module scope:

```html
<script>
const State = {
  AT_REST: 'at-rest',
  EMAIL_ENTRY: 'email-entry',
  EMAIL_ERROR: 'email-error',
  OTP_VERIFY: 'otp-verify',
  OTP_ERROR: 'otp-error',
  LOADING: 'loading',
  SIGNED_OUT: 'signed-out',
};

let currentState = State.AT_REST;
let pendingEmail = '';
let otpCode = '';
let otpFailCount = 0;
let resendTimerEnd = 0;

function setState(next) {
  document.querySelectorAll('[id^="state-"]').forEach(el => el.style.display = 'none');
  const target = document.getElementById('state-' + next);
  if (target) target.style.display = 'flex';
  currentState = next;
}

// Local-only transitions for this task — bridge wiring comes in Task 4.
document.getElementById('btn-email').addEventListener('click', () => setState(State.EMAIL_ENTRY));
document.getElementById('btn-back-from-email').addEventListener('click', () => setState(State.AT_REST));
document.getElementById('btn-back-from-otp').addEventListener('click', () => setState(State.EMAIL_ENTRY));
document.getElementById('btn-continue-email').addEventListener('click', () => {
  const email = document.getElementById('input-email').value.trim();
  if (!isValidEmail(email)) { setState(State.EMAIL_ERROR); shake('input-email'); return; }
  pendingEmail = email;
  setState(State.LOADING);
  // Task 4 will replace this with a real bridge call.
  setTimeout(() => setState(State.OTP_VERIFY), 600);
});

function isValidEmail(s) {
  return /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(s);
}

function shake(elementId) {
  const el = document.getElementById(elementId);
  if (!el) return;
  el.classList.remove('shake');
  void el.offsetWidth;
  el.classList.add('shake');
}

setState(State.AT_REST);
</script>
```

CSS for the shake animation:
```css
@keyframes shake { 0%,100% { transform: translateX(0); } 25% { transform: translateX(-4px); } 50% { transform: translateX(4px); } 75% { transform: translateX(-4px); } }
.shake { animation: shake 320ms ease-out; }
@media (prefers-reduced-motion: reduce) { .shake { animation: none; } }
```

OTP-cell input behavior is local-only for this task: typing in the cells advances focus; backspace retreats. Implement with 6 single-char inputs and an `input` listener that auto-focuses the next cell when full. Submit on the 6th digit transitions to `LOADING` then back to `AT_REST` after 800ms (placeholder; real verify in Task 4).

- [ ] **Step 2: Build**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app && xcodebuild -project Intentional.xcodeproj -scheme Intentional build 2>&1 | tail -5
```
Expect: `** BUILD SUCCEEDED **`. (HTML changes don't affect compilation but builds confirm bundle copy succeeded.)

- [ ] **Step 3: Visually verify all 7 states render**

Add a temporary debug helper at the bottom of the `<script>` so you can flip states from the WebView console:
```js
window.__loginDebugState = setState;
```

Force-load login.html again by re-applying the temp force-load from Task 1 Step 3 (don't commit this), launch the app, then in the Web Inspector console (Develop → Show Web Inspector if `WebKitDeveloperExtras` is enabled, otherwise via Safari's Develop menu pointing at the app) run:
```js
__loginDebugState('email-entry')
__loginDebugState('email-error')
__loginDebugState('otp-verify')
__loginDebugState('otp-error')
__loginDebugState('loading')
__loginDebugState('signed-out')
__loginDebugState('at-rest')
```

For each, visually compare to the corresponding macOS frame in `docs/login-screens-v1-field-of-light.html` (open in Chrome). Tokens, sizes, copy must match.

Then revert the temp force-load.

- [ ] **Step 4: Remove the debug helper**

Delete the `window.__loginDebugState = setState;` line.

- [ ] **Step 5: Commit**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/login.html
git commit -m "feat(login): build 7 inline states with Field of Light styling"
```

---

## Task 3: Add Field of Light starfield background

**Files:**
- Modify: `Intentional/login.html`

- [ ] **Step 1: Add the background DOM**

Insert at the top of `<body>`, before any state container:
```html
<div class="bg-field" aria-hidden="true">
  <div class="stars layer-far"></div>
  <div class="stars layer-near"></div>
</div>
```

- [ ] **Step 2: Add CSS for the background and parallax layers**

In `<style>`, add (before the state-container styles so it sits behind):
```css
.bg-field {
  position: fixed; inset: 0; z-index: 0;
  background: radial-gradient(ellipse at center, #0c0a08 0%, #050505 100%);
  overflow: hidden;
  pointer-events: none;
}
/* No warm radial overlay — looked like an orange blob in the middle of the screen.
   The stars + dark vignette do all the atmosphere we need. */
.bg-field .stars { position: absolute; inset: 0; }
.bg-field .stars i {
  position: absolute; border-radius: 50%;
  animation: starTwinkle 4s ease-in-out infinite;
}
.bg-field .layer-near { animation: parallaxNear 32s ease-in-out infinite; }
.bg-field .layer-far  { animation: parallaxFar  56s ease-in-out infinite; }
@keyframes parallaxNear { 0%,100% { transform: translate(0,0); } 50% { transform: translate(-12px,-6px); } }
@keyframes parallaxFar  { 0%,100% { transform: translate(0,0); } 50% { transform: translate(6px,3px); } }
@keyframes starTwinkle { 0%,100% { opacity: 0.3; transform: scale(1); } 50% { opacity: 1; transform: scale(1.3); } }
@media (prefers-reduced-motion: reduce) {
  .bg-field .stars i, .bg-field .layer-near, .bg-field .layer-far { animation: none !important; }
}

/* Auth content sits above the background */
[id^="state-"] { position: relative; z-index: 1; }
```

- [ ] **Step 3: Add the JS that spawns stars (~140 for the macOS frame size)**

At the top of the existing `<script>`:
```js
(function spawnStarfield() {
  const TINTS = [
    { p: 0.60, rgba: '255,200,150' },
    { p: 0.85, rgba: '255,160,100' },
    { p: 1.00, rgba: '255,230,200' }
  ];
  const pickTint = () => {
    const r = Math.random();
    for (const t of TINTS) if (r <= t.p) return t.rgba;
    return TINTS[0].rgba;
  };
  function fillLayer(el, count) {
    let html = '';
    for (let i = 0; i < count; i++) {
      const x = (Math.random() * 100).toFixed(2);
      const y = (Math.random() * 100).toFixed(2);
      const size = (Math.random() * 1.2 + 0.6).toFixed(2);
      const opacity = (Math.random() * 0.5 + 0.3).toFixed(2);
      const delay = (Math.random() * 4).toFixed(2);
      const dur = (Math.random() * 3 + 3).toFixed(2);
      const tint = pickTint();
      html += `<i style="left:${x}%;top:${y}%;width:${size}px;height:${size}px;background:rgba(${tint},${opacity});box-shadow:0 0 ${(size*3).toFixed(1)}px rgba(${tint},${(opacity*0.7).toFixed(2)});animation-delay:${delay}s;animation-duration:${dur}s;"></i>`;
    }
    el.innerHTML = html;
  }
  document.querySelectorAll('.bg-field').forEach((bg) => {
    const w = window.innerWidth || bg.clientWidth;
    const h = window.innerHeight || bg.clientHeight;
    const total = Math.round((w * h) / 6500);
    const nearCount = Math.round(total * 0.6);
    const farCount  = total - nearCount;
    const near = bg.querySelector('.layer-near');
    const far  = bg.querySelector('.layer-far');
    if (near) fillLayer(near, nearCount);
    if (far)  fillLayer(far, farCount);
  });
})();
```

- [ ] **Step 4: Build**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app && xcodebuild -project Intentional.xcodeproj -scheme Intentional build 2>&1 | tail -5
```
Expect: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Visually verify (force-load login.html again, do not commit)**

Force-load login.html, launch app. Expect:
- ~140 small warm-tinted dots scattered across the window
- Subtle drift over ~30s (near layer) and ~56s (far layer) in opposing directions
- Random twinkle on each dot
- Side-by-side with `docs/login-screens-v1-field-of-light.html` in Chrome (Variant: Field of Light · macOS frame), the surfaces look like the same scene

Toggle System Settings → Accessibility → Display → Reduce Motion → on. Reload login.html. Expect: stars are visible but completely static (no twinkle, no parallax).

Revert the temp force-load.

- [ ] **Step 6: Commit**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/login.html
git commit -m "feat(login): add Field of Light starfield + parallax + reduced-motion gate"
```

---

## Task 4: Wire login.html to the Swift bridge

**Files:**
- Modify: `Intentional/login.html`

- [ ] **Step 1: Add the bridge helpers**

At the top of the `<script>` (just after the starfield IIFE):
```js
function postBridge(type, payload) {
  if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.intentional) {
    console.warn('Bridge unavailable: ' + type);
    return;
  }
  window.webkit.messageHandlers.intentional.postMessage(Object.assign({ type }, payload || {}));
}
```

- [ ] **Step 2: Replace the placeholder Continue handler with a real AUTH_LOGIN call**

Replace the existing `btn-continue-email` listener body with:
```js
document.getElementById('btn-continue-email').addEventListener('click', () => {
  const email = document.getElementById('input-email').value.trim();
  if (!isValidEmail(email)) {
    setState(State.EMAIL_ERROR);
    document.getElementById('helper-email').textContent = 'Please enter a valid email address.';
    shake('input-email');
    return;
  }
  pendingEmail = email;
  setState(State.LOADING);
  postBridge('AUTH_LOGIN', { email });
});

window._authLoginResult = function(result) {
  if (result.success) {
    setState(State.OTP_VERIFY);
    document.getElementById('otp-verify-email').textContent = pendingEmail;
    startResendTimer();
    focusOtpCell(0);
  } else {
    setState(State.EMAIL_ERROR);
    const msg = result.message || "Couldn't reach server. Try again.";
    document.getElementById('helper-email').textContent = msg;
    shake('input-email');
  }
};
```

- [ ] **Step 3: Wire the OTP cell input → AUTH_VERIFY**

When all 6 cells are filled, collect the code and post AUTH_VERIFY:
```js
function onOtpComplete(code) {
  otpCode = code;
  setState(State.LOADING);
  postBridge('AUTH_VERIFY', { email: pendingEmail, code });
}

window._authVerifyResult = function(result) {
  if (result.success) {
    // Hold on LOADING for at least 400ms total to avoid flash, then hand off.
    setTimeout(() => {
      postBridge('AUTH_COMPLETE');
      // Swift will swap pages; nothing more to render here.
    }, 250);
  } else {
    otpFailCount += 1;
    setState(State.OTP_ERROR);
    const msg = otpFailCount >= 3
      ? 'Too many attempts. Resend?'
      : (result.message || "That code didn't match. Try again.");
    document.getElementById('helper-otp').textContent = msg;
    shake('otp-row');
    // Clear cells, refocus first.
    otpCode = '';
    document.querySelectorAll('.otp-cell').forEach(c => c.value = '');
    setTimeout(() => focusOtpCell(0), 350);
  }
};
```

Wire the cell `input` listener to call `onOtpComplete` when length === 6 (the listener should already be in place from Task 2, just route the completion event to `onOtpComplete`).

- [ ] **Step 4: Add the resend timer + resend handler**

```js
function startResendTimer() {
  resendTimerEnd = Date.now() + 60000;
  const tick = () => {
    const ms = resendTimerEnd - Date.now();
    if (ms <= 0) {
      document.getElementById('resend-line').innerHTML =
        'Didn’t get it? <a href="#" id="resend-link">Resend code</a>';
      document.getElementById('resend-link').addEventListener('click', (e) => {
        e.preventDefault();
        if (!pendingEmail) return;
        postBridge('AUTH_LOGIN', { email: pendingEmail });
        startResendTimer();
      });
      return;
    }
    const s = Math.ceil(ms / 1000);
    const mm = Math.floor(s / 60), ss = s % 60;
    document.getElementById('resend-line').textContent =
      'Didn’t get it? Resend in ' + mm + ':' + (ss < 10 ? '0' + ss : ss);
    setTimeout(tick, 250);
  };
  tick();
}
```

- [ ] **Step 5: Build**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app && xcodebuild -project Intentional.xcodeproj -scheme Intentional build 2>&1 | tail -5
```
Expect: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/login.html
git commit -m "feat(login): wire AUTH_LOGIN/VERIFY/COMPLETE bridge calls + resend timer"
```

(Smoke test of the full bridge flow happens in Task 6 after the Swift gate is in place.)

---

## Task 5: Wire MainWindow gate + AUTH_COMPLETE handler

**Files:**
- Modify: `Intentional/MainWindow.swift`

- [ ] **Step 1: Update `loadCurrentPage()` to a 3-way branch**

Find `loadCurrentPage()` near line 166 and replace with:
```swift
func loadCurrentPage() {
    if appDelegate?.backendClient?.isLoggedIn == false {
        loadPage("login")
        return
    }
    let isComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
    if isComplete {
        loadPage("dashboard")
    } else {
        loadPage("onboarding")
    }
}
```

Note: `appDelegate?.backendClient?.isLoggedIn` returns an optional `Bool?`. The `== false` form ensures that a nil backendClient (transient at very early launch) does NOT trigger the login screen — only a confirmed not-logged-in state does. If backendClient is nil at launch (rare), the user falls through to dashboard/onboarding as today; that's safe because the dashboard's own auth-aware code will catch the missing token.

- [ ] **Step 2: Add the AUTH_COMPLETE handler**

Find the bridge message switch in `userContentController(_:didReceive:)` (around line 349) and add a new case alongside the existing `AUTH_LOGIN` / `AUTH_VERIFY` / `AUTH_LOGOUT` / `AUTH_DELETE`:
```swift
case "AUTH_COMPLETE":
    appDelegate?.postLog("✅ AUTH_COMPLETE received — swapping page")
    DispatchQueue.main.async { [weak self] in
        self?.loadCurrentPage()
    }
```

- [ ] **Step 3: Add post-logout reload**

Find the existing `AUTH_LOGOUT` handler (around line 1969-1975). After the `_authLogoutResult` callback, add a `loadCurrentPage()` call so the user returns to the login screen:
```swift
case "AUTH_LOGOUT":
    Task { [weak self] in
        _ = await self?.appDelegate?.backendClient?.authLogout()
        await MainActor.run { [weak self] in
            self?.callJS("window._authLogoutResult && window._authLogoutResult({ success: true })")
            self?.loadCurrentPage()  // swap to login
        }
    }
```

(Match the existing surrounding async/await pattern. If the existing handler uses a different async style, preserve it and just append the `loadCurrentPage()` call inside the same MainActor block.)

- [ ] **Step 4: Build**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app && xcodebuild -project Intentional.xcodeproj -scheme Intentional build 2>&1 | tail -5
```
Expect: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/MainWindow.swift
git commit -m "feat(login): gate dashboard on isLoggedIn + AUTH_COMPLETE handler + post-logout reload"
```

---

## Task 6: Dashboard cleanup + smoke test

**Files:**
- Modify: `Intentional/dashboard.html`

- [ ] **Step 1: Locate and remove the first-time sign-in UI from the Account section**

Open `Intentional/dashboard.html`. Read the block around lines 4670-4710 first to understand the structure — there's a "not-signed-in" sub-block (with `#auth-email`, `#auth-send-btn`, `#auth-code`, `#auth-verify-btn`, `#auth-code-email`) and a "signed-in" sub-block (with `#account-email`, Sign Out, Delete Account).

Remove the entire "not-signed-in" sub-block markup. Keep only the post-login affordances. The page is gated behind login.html now, so dashboard.html is only ever loaded for an authenticated user — there's no need for the page to handle the unauthed case at all.

After the edit, grep to confirm cleanup:
```
grep -n "auth-email\|auth-code\|auth-send-btn\|auth-verify-btn\|auth-code-email" Intentional/dashboard.html
```
Expect: zero matches. If any remain, finish removing them.

- [ ] **Step 2: Remove the now-dead JS handlers**

In the same file, find and delete:
- `function authSendCode() { ... }` (around line 7761)
- `function authVerifyCode() { ... }` (around line 7789)
- The helper that toggles between email-entry and code-entry within the Account section (e.g., `authBackToEmail()` if present)

Keep `authSignOut()` and `authDeleteAccount()` — those are the post-login affordances.

- [ ] **Step 3: Build**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app && xcodebuild -project Intentional.xcodeproj -scheme Intentional build 2>&1 | tail -5
```
Expect: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Smoke test — Path 1 (cold launch with no JWT → login → success)**

Clear the Keychain entry:
```
security delete-generic-password -s com.intentional.auth -a access_token 2>/dev/null
security delete-generic-password -s com.intentional.auth -a refresh_token 2>/dev/null
```

Launch the app. Expect: login.html loads (Field of Light starfield, "puck" wordmark, tagline, Continue with email button).

- Tap "Continue with email" → email-entry state appears.
- Enter your email, tap Continue → loading spinner → after the backend processes, OTP-verify state appears.
- Enter the 6-digit code from your email → loading spinner → window swaps to dashboard (or onboarding if `onboardingComplete=false`).

Expect: no app restart, no flicker beyond the WebView swap. Side-by-side with `docs/login-screens-v1-field-of-light.html` in Chrome, surfaces should match.

- [ ] **Step 5: Smoke test — Path 2 (cold launch with valid JWT → dashboard immediately)**

JWT is now in Keychain from Path 1. Quit and relaunch the app. Expect: dashboard loads directly, no login flash.

- [ ] **Step 6: Smoke test — Path 3 (sign out → return to login with banner)**

In the dashboard's Account section, click Sign Out. Expect: window swaps to login.html with the "You've been signed out." banner above the wordmark.

Tap the Email button → banner clears, email-entry state appears.

(The banner-on-sign-out is informational only on Mac for v1. The exact trigger — passing a query param or setting a flag — can be a follow-up if it doesn't already work via the existing `lastSignOutReason` infrastructure on iOS. If it doesn't show on Mac yet, that's acceptable for v1; track as a polish item.)

- [ ] **Step 7: Smoke test — Path 4 (reduced motion)**

System Settings → Accessibility → Display → Reduce Motion → on. Sign out, relaunch. Login should show the static starfield (no parallax drift, no twinkle, no shake on errors).

- [ ] **Step 8: Boot-order regression check**

With Reduce Motion off again. Clear Keychain (Step 4 commands). Launch the app. Watch the macOS Console.app or Xcode logs for the boot sequence — expect normal initialization of:
- BackendClient
- Permissions monitor
- WebsiteBlocker
- Strict mode
- TimeTracker
- ScheduleManager
- FocusMonitor
- ContentSafetyMonitor
- IntentionalDeviceRegistration (this one should NO-OP on first launch — it checks for token presence and skips registration; that's the expected behavior pre-login)

Expect: no crashes, no hung services, login.html visible. After signing in, `IntentionalDeviceRegistration` should fire on next app relaunch (lazy registration is fine for v1).

- [ ] **Step 9: Commit**

```
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/dashboard.html
git commit -m "feat(login): remove dashboard first-time sign-in UI; login.html owns it now"
```

---

## Self-review checklist (run before declaring done)

- [ ] All 7 inline states render correctly when forced into them (matched against docs/login-screens-v1-field-of-light.html).
- [ ] Real flow (no force, no Keychain) works end-to-end on a fresh sign-in.
- [ ] Dashboard loads instantly when JWT is present.
- [ ] Sign out → login swap works without app restart.
- [ ] Reduce-motion freezes parallax, twinkle, shake.
- [ ] Boot sequence not broken (no crash, no hung service) for both no-JWT and JWT-present launches.
- [ ] No first-time email/OTP form left in dashboard.html Account section.
- [ ] Apple button on at-rest state is disabled with a tooltip ("Apple Sign In coming soon"); doesn't crash if tapped.

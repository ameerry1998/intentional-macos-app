# Intentional — Launch Readiness Checklist

## P0: Someone Can Download & Run the App

These block anyone other than you from using the product.

- [ ] **Developer ID Application certificate** — Required for macOS Gatekeeper. You have Apple Development (local-only). Go to developer.apple.com/account/resources/certificates → + → Developer ID Application. Need CSR from Keychain Access.
- [ ] **Code sign with Developer ID** — Change signing identity from "Apple Development" to "Developer ID Application" in Xcode or via `xcodebuild`. Hardened Runtime already enabled.
- [ ] **Notarize the app** — Submit signed app to Apple's notary service via `xcrun notarytool submit`. Required for macOS 10.15+ or users get "app is damaged" / Gatekeeper block. Takes 2-10 min. Use `scripts/build-dmg.sh`.
- [ ] **Create .dmg installer** — Install `create-dmg` (`brew install create-dmg`), run `scripts/build-dmg.sh`. Notarize the DMG too.
- [ ] **Store notarization credentials** — One-time: `xcrun notarytool store-credentials "intentional-notary"` with Apple ID + app-specific password (generate at appleid.apple.com → App-Specific Passwords).
- [ ] **Extension sideloading instructions** — Write a page explaining: download zip, chrome://extensions, Developer Mode on, Load unpacked. No Chrome Web Store review needed.
- [ ] **Fix extension ID in native messaging** — `com.intentional.social.json` has `YOUR_EXTENSION_ID_HERE`. For sideloading, each user gets a unique ID — need install script that accepts it, or publish to Chrome Web Store for a fixed ID.

## P1: App Works End-to-End for a New User

Even if installed, a fresh user needs these to actually use the product.

- [ ] **Test fresh install flow** — Verify what a new user sees on first launch. Does the dashboard load? Can they create a schedule? Does the extension detect the app? Test on a clean macOS account.
- [ ] **Onboarding walkthrough** — Guided first-run: install extension → set up schedule → configure platforms → optional partner setup. Currently the dashboard exists but no "welcome" funnel.
- [ ] **Schedule setup for new users** — Verify a user with no existing schedule can create one from scratch and the enforcement starts working.
- [ ] **Extension ↔ App connection verification** — First-time user needs clear feedback: "Connected" vs "App not found". The app-required overlay exists but test it from scratch.
- [ ] **ML model loading on first use** — Extension downloads DistilBERT/CLIP on first session. Verify this works, show progress, handle failure gracefully.

## P2: Ready for Real Users (Before Sharing Widely)

- [ ] **Privacy Policy** — Required for Chrome Web Store. Host at `https://intentional.social/privacy`. Needed even for sideloading since the app monitors browsing activity, sends data to backend, and processes content with ML models.
- [ ] **Terms of Service** — Legal foundation before users rely on the product.
- [ ] **Error handling for backend outages** — What happens if `api.intentional.social` is down? App should degrade gracefully (offline mode for earned browse, schedule still works locally).
- [ ] **App Sandbox re-enable** — Currently `com.apple.security.app-sandbox = false` in entitlements. Direct distribution doesn't strictly require it, but it's a security best practice. May need additional entitlements (network.server for SocketRelayServer, files.read-write for settings).
- [ ] **Chrome Web Store submission** — Store account ($5 one-time), 1-5 screenshots (1280x800+), description, privacy policy URL, category. Takes 1-3 days for review.

## P3: Before First Paying User

- [ ] **Payment integration** — Stripe or RevenueCat for subscriptions. No payment code exists anywhere. Need: pricing page, checkout flow, webhook handler in backend, receipt validation.
- [ ] **Feature gating by subscription tier** — Define Free vs Pro. Enforce in backend (check subscription status) + macOS app (gate features) + extension (respect tier).
- [ ] **Account creation UI in app** — Backend has email OTP auth (`POST /auth/login` → 6-digit code → JWT), but there's NO login UI in the macOS app or extension. Users currently use anonymous device IDs. Need login screen for: payments, cross-device sync, account management.
- [ ] **Auto-update mechanism (Sparkle)** — Without this, users are stuck on whatever version they downloaded. Sparkle is the standard for non-App-Store macOS apps. Need: integrate Sparkle framework, host appcast.xml with update info.
- [ ] **Production error logging** — Sentry or Datadog for crash reporting + error tracking. Currently zero visibility into user-side failures.

## P4: Scale & Polish

- [ ] **CI/CD pipeline** — GitHub Actions for automated build → sign → notarize → DMG → release. Currently fully manual.
- [ ] **GDPR compliance** — Data export endpoint, right to deletion (backend has account deletion but no data export), data processing agreement.
- [ ] **Global rate limiting** — Protect API endpoints from abuse (backend).
- [ ] **Admin dashboard** — Internal tool for user management, metrics, support tickets.
- [ ] **OAuth login (Google/Apple)** — Frictionless signup alternative to email OTP.
- [ ] **Windows / Linux support** — Cross-platform companion app or web-based alternative.
- [ ] **i18n / localization** — Multi-language support.
- [ ] **Accessibility** — ARIA labels, keyboard navigation, VoiceOver support.
- [ ] **Status page / uptime monitoring** — Public-facing service health page.

## Current Infrastructure

| Component | Status | Location |
|-----------|--------|----------|
| Backend API | Running | `https://api.intentional.social` (Railway + Supabase) |
| Email service | Running | Resend (partner emails, OTP codes) |
| Auth system | Backend done, no UI | Email OTP → JWT (in `auth.py`) |
| macOS app | Dev builds only | Xcode project, `Apple Development` cert |
| Chrome extension | Dev sideload only | MV3, not on Chrome Web Store |
| Payment | Zero implementation | No Stripe/RevenueCat anywhere |
| Error tracking | None | No Sentry/Datadog |
| CI/CD | None | Manual builds only |
| Auto-update | None | No Sparkle integration |

## Build & Release

Run `scripts/build-dmg.sh` after one-time setup:
1. Install Developer ID Application cert from developer.apple.com
2. Store notary credentials: `xcrun notarytool store-credentials "intentional-notary"`
3. Install create-dmg: `brew install create-dmg`
4. Run: `./scripts/build-dmg.sh`

Output: `build/Intentional-{version}.dmg` — signed, notarized, ready to distribute.

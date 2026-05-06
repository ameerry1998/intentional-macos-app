# App Store Strategy — 2026-05-05

**Status:** Direction approved. iOS will ship as sign-in-only, US App Store first.
**Affects:** puck-ios, intentional-backend (entitlements API).

---

## TL;DR

Ship the iOS app sign-in-only with a "Subscribe at intentional.app" link on the sign-in screen. No IAP, no in-app pricing, no in-app trial UI. Backend entitlements API tells the app whether the user is paid. This is now legal in the US as of May 2025 — Apple lost the Epic appeal and updated guidelines to allow external links and CTAs.

---

## What changed in May 2025

After Epic v Apple was finalized in April 2025 (Judge Gonzalez Rogers ruled Apple violated the 2021 injunction), Apple was forced to update App Review Guidelines for the US storefront:

- **3.1.3(a) "External Link Account" entitlement is no longer required** for US apps to include buttons, links, or calls to action pointing to the web for payment.
- **3.1.3(b) "Multiplatform Services"** still allows access to web-purchased subscriptions provided the app does what's expected of cross-platform clients (sign-in pattern).
- **The 27% commission Apple tried to impose on external purchases was rejected** by the court.

This is a major loosening. Until April 2025, mentioning a website was a rejection. Now you can put a "Subscribe on the web" button on the sign-in screen.

Outside the US: anti-steering still applies. EU has its own DMA-based regime that's even more permissive in some ways. Rest of world is stricter. **Launch US-only first**, expand later.

---

## What we're building

### iOS app (sign-in-only, no IAP)

- Sign-in screen with email + magic link / password
- "No account? Subscribe at intentional.app →" — **direct link, legal in US**
- After sign-in: backend `GET /me/entitlements` returns `{tier, trial_ends_at, plan}`
- App unlocks features based on entitlement
- Non-subscribers see a "sign in or subscribe to continue" gate

### Backend changes required

- `GET /me/entitlements` endpoint
- Stripe webhook handlers for: `customer.subscription.trial_will_end`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.payment_succeeded`, `invoice.payment_failed`
- `users.subscription_tier` column (`none / trialing / active / past_due / canceled`)
- `users.trial_ends_at`, `users.current_period_ends_at`

### Mac app

Distributed as PKG outside Mac App Store — **zero Apple involvement**. No review, no commission, no rules. Same entitlements API.

---

## What to AVOID in iOS app

| Don't | Why |
|---|---|
| Show in-app pricing ("$79/yr") | 3.1.1 risk — looks like IAP avoidance |
| Show a trial countdown ("4 days left") | Looks like circumventing IAP trial flow |
| Have a "Subscribe" button that opens to checkout | Different from sign-in-and-link pattern; could trip 3.1.1 |
| Collect any payment info in-app | Categorically forbidden |
| Show "$5 cheaper on web!" or comparable language | Anti-steering, even post-2025 |

| Do | Why |
|---|---|
| "Subscribe at intentional.app" as a plain link | Legal in US post-May 2025 |
| "Sign in to use Puck" gate for non-subscribers | Standard SaaS pattern |
| Backend-verified entitlement display | "Active subscription · 11 months left" |
| Account management link to web | Standard, allowed everywhere |

---

## Risk profile

| Risk | Likelihood | Mitigation |
|---|---|---|
| Apple rejects sign-in-only app | Low | Match Slack/Notion/Spotify pattern exactly |
| Apple rejects "Subscribe on web" link | Low for US | Submit to US storefront only at launch |
| Featured-app placement penalty | N/A | Indie productivity apps don't get featured anyway at launch |
| Ranking demotion | None | Not a formal Apple mechanism |
| Promotion limits | None | Apple doesn't rank-suppress non-IAP apps |

---

## Sequence

1. **Backend first**: `GET /me/entitlements` endpoint + Stripe webhooks → user table updates
2. **iOS second**: strip any pricing/trial UI, add sign-in flow + entitlement check, add "Subscribe at intentional.app" link on sign-in screen
3. **Mac alongside**: same entitlement check, no UI changes since it's not App Store
4. **Submit to US App Store**: typical 1-3 day review for a clean sign-in app

---

## Open questions

1. Magic link or password for iOS sign-in? (Recommend: magic link — lower friction, no password reset flows.)
2. What's the gated experience for free users on iOS? (Recommend: a single "sign in to start using Puck" screen with website link. No teaser content.)
3. How does the Mac app handle a lapsed subscriber? (Recommend: warn for 14 days, then disable enforcement; user can still use the app as a planner without enforcement.)

---

## Sources

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [9to5Mac: Apple updates App Store Guidelines to allow external links (May 2025)](https://9to5mac.com/2025/05/01/apple-app-store-guidelines-external-links/)
- [Michael Tsai: App Review Guidelines Updated for Epic Anti-Steering (May 2025)](https://mjtsai.com/blog/2025/05/02/app-review-guidelines-updated-for-epic-anti-steering/)
- [AppleInsider: Apple's App Store Guidelines updated for court order](https://appleinsider.com/articles/25/05/02/apples-app-store-guidelines-updated-to-reflect-court-order-over-external-purchases)

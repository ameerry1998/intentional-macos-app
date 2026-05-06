# Pricing & Puck Strategy — 2026-05-05

**Status:** Direction approved 2026-05-05. Implementation not yet started.
**Affects:** puck-site, intentional-backend, intentional-macos-app, puck-ios.

---

## The shift

| | Old | New |
|---|---|---|
| Model | Hardware-first, $99 one-time | Subscription with 7-day free trial |
| Required for product | Physical Puck device | Just the app |
| Puck role | The product | Free hardware bonus for annual subscribers |
| Funnel result over 5 weeks | 210 visits → 5 checkouts → **0 sales** | TBD |

## Why this is the right move

- **Funnel data is unusable at current volume.** 42 visitors/week + $99 hardware = no sample sizes large enough to learn from. Sub model converts 5–10× higher per visitor → faster signal at small traffic.
- **Hardware-first kills cold traffic.** ADHD impulse-buyers (the ICP) won't drop $99 on a focus device they've never tried. A 7-day trial converts the same visitors at much higher rates.
- **Puck unit cost is $2.** Hardware stops being a product to sell and starts being a marketing/retention tool. Free Puck with annual is a $12 customer acquisition spend (Puck + shipping). That's the cheapest CAC available.
- **Removes shipping logistics from the launch.** No more "Ships April 20" credibility problems. Ship Pucks only to people who've already paid annual after a refund window.

---

## The two SKUs

| Plan | Price | What they get |
|---|---|---|
| **Monthly** | $12.99/mo | App + 7-day free trial, no Puck |
| **Annual** | $79/yr | App + 7-day free trial + free Puck shipped after day 14 |

### Math on annual

- Revenue: $79
- Puck cost: $2
- Shipping cost: ~$10
- **Net first year: $67**
- Net renewal years: $79 (no second Puck shipped)

If a customer signs up for annual, gets Puck shipped, then cancels: out $12 + lost annual revenue. Acceptable risk — that customer was a real prospect, $12 is a steal as a CAC.

### Math on monthly

- Revenue: $12.99 × N months
- Cost: ~$0 (no hardware)
- Average user stays N months → revenue is N × $12.99

The economics favor pushing annual hard. Annual is the obvious upgrade path because of the free Puck.

---

## Trial mechanics

- **Card required up front.** ($0 charged today.) Card-required trials convert ~3–5× higher than no-card trials at the end of the trial period. This matters more for ADHD impulse-buyers who won't come back to enter card details a week later.
- **Plan chosen at signup.** "Monthly" or "Annual" — trial reflects that plan. On day 8, the chosen plan's price is charged.
- **Cancel anytime in 7 days = $0 charge.** In-app and on-site cancellation buttons.
- **Day 14 = Puck ships** (annual only). 14-day window covers trial + 7 days of grace, gives time for genuine refund requests before hardware logistics start.

## Refund policy

| Scenario | Outcome |
|---|---|
| Cancel during 7-day trial | $0 charged, no obligation |
| Cancel monthly mid-month | App access continues until end of period, no refund |
| Cancel annual within 14 days | Full refund, Puck not yet shipped |
| Cancel annual after day 14 | App access until end of year, no refund. **Customer keeps the Puck.** |

No returns policy. Don't deal with reverse logistics.

---

## What happens to existing Puck inventory

Three options, ranked:

1. **(Recommended) "Founding 100" promo.** First 100 annual subscribers get a Puck regardless. Real scarcity (replaces the current fake "13/250 claimed"), clears existing stock, creates a launch story. Once 100 sold, transition to "free Puck with annual" as the standing offer.
2. **Just use as +Puck SKU stock.** No promo, just standard inventory.
3. **One-off sale to existing waitlist.** $29 flash to existing email list. Captures non-subscribers, generates one-shot revenue, but doesn't help fix the subscription funnel.

Recommendation: #1 → #2 transition. Existing waitlist gets first crack at "Founding 100" — turns dead leads into paying ones.

---

## Implementation surface (cross-repo)

### puck-site (priority 1)

- Rewrite `PricingSectionV4.tsx` → two-card layout (Monthly / Annual w/ free Puck)
- Cut from main page flow: WakeUpAlarmV2, MacAppSection, AICoachSection, ContentSafetySection, UnbreakableSection, WhatMakesPuckDifferentV3
- Move cut sections to `/features` route (one long page, linkable from FAQ + footer)
- Update HeroSectionV3 copy: lead with trial offer, not with hardware
- Update AnnouncementBarV3: "Free Puck with annual. Founding 100 launching soon." (or similar — rotates)
- Fix stale "Ships April 20" date and fake "13 of 250" scarcity in current pricing component
- Stripe: configure two new price IDs with 7-day trial periods (monthly + annual)
- `/api/checkout/route.ts`: handle two plan types, set up trial period, attach Puck-shipping metadata for annual
- Klaviyo flows: trial-day-1, trial-day-5, trial-day-7-converted, trial-day-7-canceled, annual-puck-shipped

### intentional-backend (priority 2)

- Subscription model: `users.plan` (`monthly`/`annual`/`none`), `users.subscription_status` (`trial`/`active`/`canceled`/`lapsed`), `users.trial_ends_at`, `users.current_period_ends_at`
- Stripe webhooks: `customer.subscription.trial_will_end`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.payment_succeeded`, `invoice.payment_failed`
- Entitlements endpoint: app calls `GET /me/entitlements` → `{tier, trial_ends_at, features_unlocked}`
- Puck-shipping queue: when `customer.subscription.created` fires for annual after day 14, mark user as ready-to-ship; manual fulfillment for now (could automate later via Shippo/EasyPost)

### intentional-macos-app + puck-ios (priority 3)

- Audit for Puck-required gates. Most likely: iOS onboarding NFC pairing screen.
- Make Puck pairing skippable. Add "Skip — I don't have a Puck" path.
- Visible app state for "no Puck paired" (don't show grayed-out NFC button as the only way to use the app).
- Mac side: probably already Puck-optional; audit to confirm.
- Entitlement enforcement: app calls `/me/entitlements` on launch + foreground; gates premium features behind `tier != none`.
- Trial vs paid UX: small "Trial — 4 days left" banner during trial period. After trial: either confirmed paid (no banner) or lapsed (lock).

---

## Decisions still open

1. **Founding 100 promo vs standing offer first?** Recommendation: Founding 100. Real urgency replaces fake scarcity.
2. **Trial duration: 7 days vs 14?** Recommendation: 7. Shorter trials convert better; ICP makes commitment decisions emotionally, not analytically.
3. **Should monthly subscribers be able to add Puck for $29 one-time later?** Probably yes, but ship later. Not v1.
4. **What about the existing $99 buyers (if any)?** Grandfather them with a free year of annual. Goodwill move.
5. **Pricing page layout: stacked vs side-by-side cards?** Side-by-side on desktop, stacked on mobile. Annual gets the visual emphasis ("Best value" badge, brighter color).
6. **Free trial without card OR with?** Recommendation: with card. Higher overall paid conversion despite lower trial activation. Industry standard for productivity apps.

---

## Recommended sequence

**Week 1 (this week)**
- [ ] Stripe configuration: new price IDs, 7-day trial periods
- [ ] Backend: subscription model + Stripe webhooks
- [ ] Pricing page rewrite (puck-site)
- [ ] Hero + announcement bar copy update

**Week 2**
- [ ] App entitlement enforcement (Mac + iOS) — read `/me/entitlements`, gate features
- [ ] iOS Puck-optional onboarding
- [ ] Cut sections moved to `/features` page
- [ ] Klaviyo flows updated

**Week 3**
- [ ] End-to-end trial test (sign up → trial → convert → Puck ships)
- [ ] Founding 100 launch announcement (waitlist email + Instagram)
- [ ] Soft launch

**Week 4+**
- Measure new funnel against old (same traffic source). Goal: ≥5% visitor → trial conversion, ≥30% trial → paid conversion.

---

## Success criteria

A working version of this means:
- A new visitor on Instagram lands on the page, hits "Try free 7 days," enters card, uses the app for 7 days, gets charged.
- An annual subscriber gets their Puck in the mail without manual intervention from you.
- The app/Mac/iOS all work without the Puck for someone who skipped the founding promo.
- Funnel conversion at every stage is measurable in PostHog.

---

**TL;DR:** Move from $99 hardware sales to subscription with 7-day free trial. Two plans: $12.99/mo or $79/yr (annual gets a free Puck). Puck cost is $2 + shipping, so it's a $12 marketing tool, not a product. Existing inventory clears via "Founding 100" promo. Implementation spans 4 repos, ~3 weeks of work, sequenced as: Stripe + pricing page first, then entitlements + apps, then launch.

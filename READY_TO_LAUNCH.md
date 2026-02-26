# Intentional — Launch Readiness Checklist

## Must-Have (Blocks Launch)

- [ ] **Payment integration** — Stripe or RevenueCat for subscriptions (backend + macOS app)
- [ ] **Feature gating by subscription tier** — Free vs Pro features enforced in backend + extension
- [ ] **Privacy Policy & Terms of Service** — Legal review, hosted pages, linked from app + extension
- [ ] **Onboarding flow for first-time users** — Guided setup in macOS app (install extension, set partner, configure platforms)
- [ ] **macOS requirement stated in Chrome Web Store listing** — Clear description that companion app is required
- [ ] **ML model failure error handling** — Graceful fallback when DistilBERT/CLIP fail to load or inference errors occur

## Should-Have (Before First Paying User)

- [ ] **Schedule UX improvements** — Zoom, right-click delete, history navigation, empty state
- [ ] **Production logging** — Sentry or Datadog for error tracking (backend + macOS app)
- [ ] **Global rate limiting** — Protect API endpoints from abuse (backend)
- [ ] **CI/CD pipeline with tests** — Automated build, lint, test for all repos
- [ ] **App auto-update mechanism** — Sparkle or similar for macOS app updates
- [ ] **GDPR compliance** — Data export endpoint, right to deletion, data processing agreement (backend)

## Nice-to-Have (Post-Launch)

- [ ] **Windows / Linux support** — Cross-platform companion app or web-based alternative
- [ ] **i18n / localization** — Multi-language support for extension + macOS app
- [ ] **Accessibility** — ARIA labels, keyboard navigation, VoiceOver support
- [ ] **Admin dashboard** — Internal tool for user management, metrics, support
- [ ] **Status page / uptime monitoring** — Public-facing service health page

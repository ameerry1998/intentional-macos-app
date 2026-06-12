# Cross-repo: Landing page rebrand Puck → Intentional (2026-06-11)

Repo: `puck-site` · Branch: `intentional-rebrand` (NOT pushed, NOT deployed, main untouched)
Worktree used: `/Users/arayan/Documents/GitHub/puck-site-intentional` (left in place; `git worktree remove` when done)

## What changed (5 commits on `intentional-rebrand`)

| Commit | Scope |
|---|---|
| `1d05507` | Chrome rebrand: layout.tsx metadata ("Intentional — A blocker you can't cheat"), AnnouncementBarV3 (free/no-card messages), NavigationV3 (brand + links + "Get Intentional" CTA), EmailPopupV3 (15%-off popup → free-download popup, coupon/SMS step deleted) |
| `97c77f3` | HeroSectionV3 rewritten to approved copy (eyebrow/H1/sub/CTA/friction line; physical puck image + tap demo removed). New ProblemSectionV3 ("…That was 40 minutes ago.") + ReasonWhySection ("you held the keys."). Wired into page.tsx |
| `0663325` | BrainRotBudget → 3 mechanism cards (No off switch / It knows when you're faking / Scrolling isn't banned, you earn it). New FounderNote ("I built this because I couldn't stop."). PricingSectionV4 → "Free." statement, checkout calls removed. StickyCTA → single free anchor bar, plan drawer deleted |
| `e0fee30` | FAQSectionV3 → fit/not-fit disqualify block + 8 free-Mac-app FAQs (incl. "I'll just uninstall it."). FooterV3 → discount capture removed, CTA repeat, "Intentional — A blocker you can't cheat." |
| `0a46332` | Drop em dashes from announcement bar + sticky CTA per house copy rules |

Page order now: Hero → Problem → ReasonWhy → Mechanism → Founder → Free → FAQ (with disqualify) → Footer. Dark/light alternation per DESIGN.md preserved; one orange accent kept; no redesign, copy/rebrand only.

## Verified

- `npm run build` passes (needed `.env.local` copied from the main checkout — Stripe webhook route requires keys at build; copied, gitignored).
- Scoped grep for `puck|getpuck` across page.tsx, layout.tsx, and all 14 in-scope/new components: **zero hits**. (204 hits remain in unused archive components — HeroSection v1, PuckModel, WakeUpAlarm, etc. — none imported by the homepage.)
- ESLint on changed files: clean (one pre-existing Meta-pixel `<img>` warning in layout).

## Notes / deviations

- **Branch base is `staging` (bd0c6e8), not `main`.** The task's component list (incl. StickyCTA, the 5-section homepage) only exists on staging; main's homepage is the older hardware-device page and lacks StickyCTA. Main was not touched either way.
- Two new section components were created (ProblemSectionV3, ReasonWhySection, FounderNote) because the approved problem/reason-why/founder copy had no existing home on the page. They follow the existing V3 visual system.
- FAQ's "full feature list" link to `/features` was removed — that page is still Puck-branded (phase 2).

## What's left (follow-up)

1. **Download URL is a placeholder.** Every CTA points at `href="#download"` (anchor on the Free section). No installer URL exists in the repo. Replace before launch (`PricingSectionV4.tsx` has the TODO; also hero, nav, sticky bar, popup, footer).
2. **Deploy decision.** Branch is local-only. Path per repo rules: push to `staging` → Vercel preview → user approval → merge to main. Also decide the domain cutover (getpuck.com → intentional.social) — no getpuck.com references existed in src, so this is DNS/Vercel config, not code.
3. **Quiz funnel = phase 2.** `src/app/quiz/` (untracked WIP in the main checkout) and `/features` page still Puck-branded; v2/v3/v4 archive pages untouched by design.
4. **Email popup promises "Email me the link"** via the existing Klaviyo subscribe endpoint. A Klaviyo flow that actually sends the download link must exist before deploy, or soften that copy.
5. Checkout/Stripe API routes still exist (unreferenced from the homepage). Retire when the paid funnel is officially dead.

# Project State — 2026-06-11 (READ FIRST after /clear)

Authoritative "where we are" for the Intentional Mac app. A fresh session should read this + the auto-loaded memory (MEMORY.md) before doing anything. Persistent memory survives /clear; this doc is the human-readable companion.

## Product in one line
macOS (+iOS "Puck") focus app. AI scores whether you're on-task; you EARN screen-time "allowance" by focusing; an accountability partner (friend now, parent later) holds you to commitments. **Name = "Intentional"** (decided + trademark-cleared 2026-06-11). **Launching THIS WEEK.**

## Locked product decisions (see memory files for detail)
- **ICP:** design self-help-first (mid-20s ADHD impulse-scroller w/ friend-partners), keep parent-teen as a configuration layer. Don't hard-commit copy to parent-teen. [[icp-and-commitment-direction]]
- **Core loop (v1.1, not built):** morning commitment → app witnesses the day → end-of-day email (user-consented per-type) rating adherence. Commitment = witnessed promise, not a cage; opt-in 🔒 "locked" tier for hard commitment; stakes scale via the existing strictness dial.
- **Pill is the primary surface** (commitment lives there). **Planning must be guided** ("planning coach"). Sidebar trimmed. Jargon aimed at 15-yo + parent.
- **Sidebar:** Today / Goals / Rules / Accountability / Settings.
- **Allowance** (was "leisure pool"): one shared daily pool, base 15 min + earn 5:1 by focusing, 60-min rollover cap; at zero, limited sites hard-block with "focus to earn more" wall.

## DONE this session (all committed unless noted)
1. Dead-code cleanup (ProcessMonitor, BlockRitualController deleted; GrayscaleOverlayController→RedShiftController rename — it's the live red-tint-on-distraction feature, NOT dead).
2. Goal-link bug fixed + verified live (scheduled sessions now enforce the goal's own rules + feed AI intent; correct backend attribution).
3. **GUI-testing superpower** built: `.claude/skills/verifier-intentional-gui` + `scripts/dev-tools/click.swift` + DEBUG ui-test hook (`/tmp/intentional-uitest-cmd.json` → evaluateJavaScript → result file).
4. Calm-down pass: minimal defaults (free-time nag + stage-1 prompt OFF), Esc escape-hatch on overlays, global Gentle/Standard/Strict strictness dial (replaced 14 toggles), locks collapsed, AI-scoring made always-on.
5. NSFW false-positives fixed: threshold pinned 0.99, sensitivity slider deleted.
6. Settings consolidation: 4→5-tab sidebar, AI Scoring page killed (Qwen hardcoded), Sensitive Content moved into Settings, Focus Mode page merged into Strictness, Account email fix.
7. **Rules consolidation R1-R6 COMPLETE** (the big one): one Rules tab (block/limit/allow + schedule), one backend `rules` table synced Mac+iOS, enforcement unified (one precedence, site allow-lists fixed, page-state==enforced-state), allowance earn engine rebuilt + verified live (earn on session end, spend metering, pill balance, zero-wall), real-data migration done with backup. Backend DEPLOYED (migrations 027+028 in Supabase; merged to main + pushed; Railway live).
8. Strict-mode lock-bypass security hole closed.
9. **Projects kill B2-B6 COMPLETE:** ProjectStore deleted, goal pages show real session history + focus-%, Mac sends focus_score on session stop (derived from relevance_log).
10. **Polish wave** (branch `polish-wave-2026-06-11`, 5 commits A-D2, DONE — NEEDS build-verify + merge to main): design-system unification, sidebar cleanup, goal-shuffle bug fixed, 22 jargon P0s rewritten, login.html rebranded.

## IN FLIGHT / INFRASTRUCTURE
- **Test VM ready:** Tart VM `intentional-test` (~/Applications/tart.app/.../tart; `tart ip intentional-test` → ssh admin@IP pw admin, sshpass installed). App installed, permissions granted, controllable headlessly. Build on host → re-stage into VM (ad-hoc re-sign, strip provisioning profile + 4 entitlements). CANNOT test network-filter or NSFW in VM (entitlements need device provisioning); those need short real-Mac bursts. **Use VM for all other GUI testing — off the user's screen.**
- Polish wave branch needs: `xcodebuild` verify → merge to main.

## NEXT — LAUNCH CHECKLIST (this week)
Distribution = BOTH (direct download + App Store); surface = Mac + iPhone; pricing = FREE. Realistic: Mac direct-download + landing + IG go live now; App Store + iOS submitted, live on Apple's clock.
1. ~~Merge polish wave to main~~ DONE (merged + final tidy ae5925f).
2. ~~Rebrand pass~~ DONE (056ff31): login.html getpuck billing line + footer link removed; dashboard "Ship Puck" placeholder + dead puckOnly option removed. Verified live: VM login screen (fresh build, signed-out) shows only Intentional branding; host dashboard DOM contains zero "puck". NOTE: the onboarding.html "puck wordmark ×3" cold-walk finding was the OLD build — source onboarding.html is clean; login.html (pre-signup surface) was the real culprit, now fixed. Remaining "puck" = code comments + wire-protocol values only.
3. **Onboarding redesign** (designed, not built — see below): value-before-commitment first-run.
4. **Cold fresh-install test in VM** — real notarized installer, fresh signup → first session, end to end. Highest-risk unknown (never tested by a non-Ameer user).
5. Notarized PKG/DMG build (`scripts/build-pkg.sh`) verified on clean machine.
6. Landing page + buy getintentional.ai (+ defensive .com). @getintentional/@intentionalai taken on IG → need alt handle.
7. iOS (puck-ios repo) store-readiness: rebrand, cold first-run, listing, submit. Riskiest — skipped this work cycle.

## ONBOARDING DESIGN (agreed direction, not built)
For a mid-20s person arriving emotionally fired-up from an IG video, motivation evaporating. **Value before commitment.** Flow: (1) land the punch / mirror the brainrot, no lecture; (2) name the enemy — tap your distracting apps (seeds Rules); (3) aha — reveal the allowance deal + catch them live on their own app; (4) FORCE the first 25-min session inside onboarding; (5) add accountability partner AFTER the win, opt-in; (6) permissions just-in-time (Accessibility/Screen-Recording at the moment magic needs it, with privacy promise — NOT upfront). Open Q: does first session happen in onboarding (strong rec: yes). Need to cold-walk the CURRENT onboarding (only seen to email screen) before building.

## POST-LAUNCH v1.1 (designed/queued, don't build before launch)
- Planning coach (guided day-planning; weekly goals as motivation; partner can require plan+commit).
- Commitment loop + daily parent/partner email (focus_score data foundation now exists).
- Auto time-tracking timeline (no VLM — sampler + existing signals).
- Task-commit mechanic, pill quick-capture, weekly-review rebuild. Drafts: docs/superpowers/specs/drafts/2026-06-10-future-features-exploration.md.
- Pill redesign (commitment-centric). Context-switch overlay → tab-only.
- Backend cleanup: drop dormant 023 distraction_budget_* tables + /budget endpoints.

## Audit docs to mine for fixes
docs/jargon-audit-2026-06-11.md · docs/design-debt-audit-2026-06-11.md · docs/blocks-consolidation-research-2026-06-11.md

## Gotchas
- Model auto-switches Fable→Opus on security-adjacent content (code-signing, TCC, SIP, "lock/bypass" vocab) — it's a harness classifier; pin via /config. Work isn't affected.
- User has NO sudo on host (Caity admin). Use dev-launch.sh; dev runs alongside prod. VM admin DOES have sudo.
- WKWebView: alert()/confirm() now WORK (delegate added); only prompt() no-ops. Prefer .ns-modal anyway.
- After ANY user-visible change: verify live (VM or real) per verifier-intentional-gui. Never claim done without evidence.

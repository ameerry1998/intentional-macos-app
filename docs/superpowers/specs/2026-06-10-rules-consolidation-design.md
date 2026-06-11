# Rules — Unified Blocking/Limits/Allow Design

**Date:** 2026-06-10 · **Status:** spec for user review · **Mandate:** planned deeply per user order; no half-working controls. **Research basis:** docs/blocks-consolidation-research-2026-06-10.md (read it before implementing — it documents the 5 storage systems, the enforcement traps, and a ~35-control wiring inventory).

## Concept

One sidebar tab **Rules** (sidebar: Today / Goals / **Rules** / Accountability / Settings). A **rule** = target (site domain or app) + **treatment** + optional schedule window:

| Treatment | Meaning |
|---|---|
| 🚫 Blocked | Never usable (optionally only within schedule windows) |
| ⏳ Limited | Usable against the shared daily leisure pool (renamed: allowance, 2026-06-11) |
| ✅ Allowed | Never blocked, never swept |

Per-goal lists (Intention.macWebsites/allow*) are NOT rules — they stay on goals ("blocked during this goal"). "Distractions" as a word dies.

## Decisions (all user-approved 2026-06-10)

1. **Pool model: ONE shared pool.** (renamed: allowance, 2026-06-11) Single daily leisure balance spendable on any ⏳ app/site. Pill shows it: "⏳ 20 min".
2. **Base + earn:** pool = daily base (default 15 min) + earned. **Any** focus session earns (AI scoring polices quality) at default **5:1** focused:leisure (renamed: allowance, 2026-06-11).
3. **Zero balance = wall + earn path.** Block page shows "Focus 30 min to earn 6 more — [Start a session]". No override, no partner-beg flow.
4. **Daily reset, rollover cap:** base refreshes daily; unspent earned minutes roll over, bank capped at 60 min.
5. **Partner lock semantics (asymmetric):** tightening always free; loosening (delete/disable a 🚫, raise base/rate/bank-cap, demote 🚫→⏳/✅) partner-gated when Strict Mode on. Locks apply to the REAL store (research: current locks guard a settings mirror).
6. **Migration: automatic.** Existing block rules → 🚫 (schedules preserved); AlwaysAllowedStore + per-account always_blocked/distraction rows → ✅/🚫 rules. Nothing auto-becomes ⏳ (limits are opt-in). Old stores left as .legacy files; Settings rows (Always Blocked / Always Allowed / Distractions) removed the same release.
7. **Cross-device:** one backend `rules` table (account-scoped), Mac+iOS sync, survives reinstall. Site rules sync fully; app rules sync by name/bundle where resolvable — iOS opaque tokens stay per-platform (research §iOS).
8. **Rate/base/bank-cap configurable** on the Rules page (partner-gated per #5).

## Enforcement unification (the invisible half — from research findings)

- **One precedence, same for sites and apps:** per-goal allow > ✅ rule > 🚫 rule / ⏳ gate > goal blocklist > default. (Today: allow protects apps but not sites — WebsiteBlocker consults no allow list.)
- **Page state == enforced state:** session-start must respect rule `enabled` + snoozes (today `applyDefaultBlockingProfile` ignores both); the sweep honors snoozes too.
- ⏳ spend metering: TimeTracker usage (AppleScript path) decrements the pool while a limited target is foreground/active tab; at zero the 🚫 wall (with earn path) engages. Spending during an active focus session: limited targets behave as 🚫 during sessions (focus time is focus time); pool spends only in free time.
- Earned-browse engine: REBUILD (old EarnedBrowseManager is feature-flagged off with a dead feed). Reuse backend /budget endpoints where they fit; one source of truth for the pool on the backend, cached locally.

## Out of scope

Per-goal list editing UI changes · Tasks layer · bedtime · iOS UI work beyond consuming synced site rules (separate slice).

## Verification bar (per user mandate)

Every control on the Rules page click-verified (use the DEBUG ui-test hook + verifier-intentional-gui); enforcement verified live per treatment (blocked site closes, ✅ site survives sweep+session, ⏳ decrements pool and walls at zero with earn-path copy); migration verified against the user's real data (backup first); locks verified by attempting loosening with Strict Mode on; cross-device verified via backend table inspection + iPhone pull. Before/after evidence for the enforcement-trap fixes.

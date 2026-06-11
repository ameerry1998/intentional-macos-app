# Intentional macOS App - Development Guide

## Docs discipline (MANDATORY)

When you change a feature's behavior, file references, or architecture: update its doc at `docs/features/<slug>.md` in the SAME commit OR mark `status: wip` in the frontmatter. PRs that change feature code without doc updates require explicit waiver in the PR description.

- Every feature has one doc at `docs/features/<slug>.md`
- Doc frontmatter MUST include `last_verified` (ISO date) and `files:` (array of relative paths that implement the feature, resolvable from repo root)
- `scripts/check-docs.sh` lints all docs — run it before any feature PR; errors on missing files
- The site renders via `/Users/arayan/Library/Python/3.9/bin/mkdocs serve` (local) or `mkdocs build` (production); `docs_dir` is `docs/features/`
- New feature? Copy `docs/features/_TEMPLATE.md` and fill it in. Set `status: design` while implementing, `status: wip` during active changes, `status: shipping` once live.

---

## Cross-repo / Overnight Work — Single Source of Truth (MANDATORY)

When a task spans multiple repos (e.g. Puck integration touches `intentional-backend` + `puck-ios` + this repo) OR is an overnight autonomous run:

- **Final progress log always lives in THIS repo** at `docs/overnight-run-YYYY-MM-DD.md` (or `docs/cross-repo-<feature>-YYYY-MM-DD.md` for non-overnight multi-repo features).
- That file is the authoritative hand-off: what was completed, what was blocked, what's in which PR, what the user needs to do tomorrow morning.
- Before starting a multi-repo or overnight task, check `docs/` for an existing log to append to.
- When handing off to a subagent for multi-repo work, explicitly point them at this convention.
- Sibling repos live at `/Users/arayan/Documents/GitHub/intentional-backend`, `/Users/arayan/Documents/GitHub/puck-ios`, `/Users/arayan/Documents/GitHub/puck-partner-dashboard`.

---

## Live GUI Verification (MANDATORY)

After implementing any user-visible change: drive the REAL running app and prove the behavior with screenshots before claiming done. Use the project skill `verifier-intentional-gui` (.claude/skills/) — it covers launching the dev build, live coordinate lookup (windows move!), real CGEvent clicks via `scripts/dev-tools/click.swift`, screenshot-verified steps, focus restore, and safety rules (the user shares this machine). Plan the manual test cases BEFORE implementing; for bug fixes capture before/after evidence. Background clicking the dashboard does not work (verified 2026-06-10) — foreground bursts with focus restore only.

---

## Use Superpowers Skills at the Appropriate Times (MANDATORY)

Every non-trivial task on this repo must route through the right skill — this is not optional:
- **Before designing a new feature or behaviour change:** invoke `superpowers:brainstorming` to align on intent, scope, and trade-offs. Don't skip this even on "simple" changes.
- **Before writing implementation code:** invoke `superpowers:writing-plans` once the design is approved. The plan goes to `docs/superpowers/plans/` and gets reviewed before code moves.
- **Before debugging a bug, test failure, or unexpected behaviour:** invoke `superpowers:systematic-debugging` — do NOT guess at fixes without root-cause analysis.
- **When executing a written plan:** invoke `superpowers:subagent-driven-development` — don't ask which execution mode to use, just start.
- **Before claiming work is done:** invoke `superpowers:verification-before-completion` — evidence before assertions, always.

Violating the letter of this process violates the spirit of the development approach. Use the skills.

---

## Documentation Maintenance (MANDATORY)

After completing any code changes, assess whether this CLAUDE.md or the relevant `docs/` file needs updating. Update if any of the following changed:
- Changes to RuleStore, TimeTracker, or ScheduleManager state/APIs
- New features or significant behavior changes
- Changes to focus enforcement, blocking, or overlay logic
- New Swift files or significant restructuring
- Dashboard UI changes that affect user-visible behavior

Keep updates minimal and precise — just add/modify the relevant sections. Do not rewrite sections that haven't changed.

---

## Don't stop. Keep going. (MANDATORY)

When the user is in execution mode (asked you to ship N slices, or "keep going," or any equivalent), **do not stop to check in.** Per `superpowers:subagent-driven-development`: "Continuous execution: Do not pause to check in with your human partner between tasks. Execute all tasks from the plan without stopping."

Specifically:
- Do NOT say "should I continue?" or "want me to keep going?" between slices
- Do NOT ship a "status update" and then wait for permission
- Do NOT recommend stopping just because the work is hard or the context is large
- Do NOT estimate work in "days" or "weeks" if the user has explicitly said "today" — push as far as actually-possible-today and only stop when genuinely blocked
- Do NOT claim a task will produce "mediocre quality" as a reason to stop — ship it, the user will tell you if quality is bad

The ONLY valid reasons to stop:
1. BLOCKED — you literally cannot proceed without info from the user
2. Ambiguity in the spec that genuinely prevents progress on the current task
3. All tasks in the explicit plan are complete
4. The user explicitly said stop in the most recent message

Status updates are FINE if they're terse. Asking permission is NOT FINE. The user trusts you to ship. Ship.

---

## Plain-English TL;DR at end of every response (MANDATORY)

The user is non-technical-leaning and skims. Long technical responses lose them. **At the end of EVERY response — no matter how short or long — append a TL;DR section in plain English.**

**Format:**

```
---

**TL;DR:** [1–3 plain sentences. No file paths, no commit hashes, no jargon.
            Cover whichever apply: what I just did, and what I need from you.]
```

**Examples:**

- *After making changes:* `**TL;DR:** Fixed the calendar tap bug. Install the new PKG to test it. Nothing else needed from you right now.`
- *After asking a question:* `**TL;DR:** Want strictness to live on the Intention only, or also as a per-block override?`
- *After giving info / a recommendation:* `**TL;DR:** Three reasonable options; I'd pick A. Tell me which and I'll move.`
- *After research / explanation:* `**TL;DR:** Perplexity's main idea is "make bypassing slow + visible + social." We can add three of their specific suggestions later if you want.`

**Rules:**

- Always at the END, after the full technical answer. Never replace the technical content — append.
- Maximum 3 sentences. If it doesn't fit in 3, the answer is too complex; restructure.
- No code, no file paths, no commit hashes, no jargon the user wouldn't say themselves.
- If the response is purely a one-liner answer, the TL;DR can be skipped (the answer IS the TL;DR).
- "What I want from you" should be explicit when it applies — *"Tell me X / approve Y / wait for Z."*

**Why:** the user has gotten lost in 2-page responses repeatedly. The TL;DR is the failsafe. They can ignore the body if the TL;DR tells them what they need.

---

## Documentation Patterns: Markdown vs HTML (MANDATORY)

This project uses a **two-layer documentation system**. Use the right format for the job.

**The entry point** is [`docs/index.html`](docs/index.html) — open it in Chrome to see the curated index of every doc, dated reports, and design mockups. Always update the index when you add a new doc that should be discoverable.

| Layer | Format | Filename pattern | What it's for |
|---|---|---|---|
| **Reference** | Markdown | `docs/SUBSYSTEM_NAME.md` (UPPER_SNAKE_CASE) | Evergreen source of truth — updated when behavior changes. Renders on GitHub. Source for "how does this work right now." |
| **Snapshot** | HTML | `docs/topic-YYYY-MM-DD.html` (kebab-case + ISO date) | Point-in-time visual report — audits, run logs, decision docs, sprint plans. **Never edit an old one** — write a new one with a new date if state has changed. |
| **Mockup** | HTML | `docs/topic-vN-variant.html` (versioned, no date) | Visual design exploration. May or may not be the chosen direction. Reference, not normative. |

**Decision rules — when writing a new doc, ask:**
- "Will this still be true in 6 months?" Yes → Markdown. No → dated HTML.
- "Should this get diffed in PRs?" Yes → Markdown. No → HTML.
- "Will I want to skim this in Chrome?" Yes → HTML. No → Markdown.

**HTML reports are most useful when they're dense.** Use status pills, color-coded tables, ranked lists. Save the prose for Markdown. Match the existing visual style (see `docs/feature-parity-2026-04-25.html` and `docs/index.html` for the CSS pattern — coral/gold accent, dark surface, pill components).

**When you create a new HTML report:**
1. Save as `docs/<topic>-YYYY-MM-DD.html` using today's date.
2. Add a card to `docs/index.html` in the appropriate section (Reports & audits, Cross-repo, or Design mockups).
3. Reuse the CSS variables and pill classes from existing pages — keep visual consistency.
4. Don't update old dated reports. Write a new one and link from the old.

**For cross-repo / overnight runs:** the Markdown log at `docs/overnight-run-YYYY-MM-DD.md` is the authoritative hand-off (per the cross-repo convention above). The Markdown is the source of truth; an accompanying HTML report is optional but helpful for visual summaries.

---

## Product Vision — Deep Work as a Service (MANDATORY READ)

**The brain is sequential. The computer makes task-switching almost free. Friction is backwards.**

Intentional is not a "site blocker." It is the structural enforcement of the Deep Work protocol the cognitive-psych literature (Cal Newport, Sophie Leroy on "attention residue", Nicholas Carr's *The Shallows*, Nir Eyal's *Indistractable*) already recommends but that ADHD impulse-scrollers cannot self-administer.

Every feature should ladder up to one of five stages of a focus session. If a feature you're about to build doesn't, it probably doesn't belong:

1. **Enter** — forced declaration of intent (voice transcript, 100–300 words, "what + what done looks like + what's NOT allowed").
2. **Prepare** — "close the noise." One-click sweep of tabs/apps not relevant to declared intent. *(Missing today — biggest current gap.)*
3. **Engage** — session runs. AI scoring against the transcript. Pill, red tint, in-pill nudges.
4. **Defend** — three tiers of friction when the user drifts: notify → soft-close in 5s → hard-block (Strict Mode).
5. **Exit** — review every tab/app opened during the session: keep / close all / mark for tomorrow. *Inbox-zero for attention.* *(Missing today.)*

**Canonical spec:** [`docs/superpowers/specs/2026-05-18-deep-work-protocol.md`](docs/superpowers/specs/2026-05-18-deep-work-protocol.md). Read it before changing enforcement logic, session lifecycle, or AI scoring. It contains the philosophical grounding, the five-stage breakdown, the open questions, and the naming clarity ("TimeBlock" = scheduled session, "StandingRule" = always-on rule — two different concepts that were overloading "block").

Default copy for the unscheduled-time overlay (when the user is in free time with no session declared): *"You're not in a focus session. Pick something to work on so you don't end up with 30 tabs open and three half-finished tasks."* Naming the mechanism (multitasking → tab pile-up) is more motivating than naming the abstraction ("plan your day").

---

## Hard-Won Lessons (banked 2026-05-18)

These principles emerged from grinding on the Close-the-Noise sweep. Apply them to every future feature.

### 1. Agency > automation for the ADHD ICP. Default to user-confirms-first for any destructive action.

The ICP is paying us to be their **external executive function**, not a replacement that decides for them. Auto-closing tabs / auto-quitting apps / auto-deleting data / auto-sending messages without a confirmation step violates the product framing — even when the AI gets it 95% right. The 5% feels catastrophic and burns trust permanently.

**Default pattern for any destructive feature:** AI suggests → user reviews → user confirms → app acts. The user clicks the button that closes the thing, not the app. Reserve auto-actions for cases the user has explicitly opted into per-action (e.g., "always close YouTube during work blocks" via a Standing Rule the user wrote).

**Counter-example we lived through:** the v1 close-the-noise sweep auto-stashed 22 tabs and closed 5 of the user's real work tabs (Cloudflare DNS, Resend, Supabase, Railway, Claude Code article). Spent 6 hours iterating on AI accuracy from 73% → 86% with diminishing returns before the user pointed out the right move was to pivot to review-and-confirm. **When you find yourself grinding accuracy past 85%, the question is no longer "can we be smarter" but "should this be auto at all".**

### 2. Build a benchmark with ground-truth labels BEFORE iterating on AI/scoring/classification.

Variance is real. The same prompt + same model + same temperature can give different verdicts run-to-run (the user's "5 false-stashes" live run vs the benchmark's 2 false-stashes on identical inputs). Without a benchmark you're chasing noise, can't tell what changes helped, and rely on the user's anecdotes.

Build the eval harness FIRST. Test cases live in `IntentionalTests/sweep-test-cases/*.json` and include ground-truth labels per item. `SweepBenchmark.swift` is the template — Codable test cases, a runner that reports accuracy + false-positive + false-negative + per-error details, model-swap support for A/B comparisons. Mirror this pattern for any future scoring feature (Stage 3 AI scoring of active tabs, Stage 4 defend-tier classification, content-safety thresholding).

**Set `temperature=0` for classification tasks.** Non-determinism is pure noise when the right answer is unambiguous.

### 3. Encode asymmetric error costs in the decision rule, not just the metric.

For the close-the-noise sweep, **false-stash (closed a relevant tab) burns user trust ~5x harder than false-keep (left noise around).** The rule must reflect that:

```swift
// asymmetric stash gate — stash ONLY when high-confidence off-task
let highConfidenceStash = !v.relevant && v.confidence >= 65
```

Not `keep iff (relevant && conf >= 50)` (symmetric — wrong). Same pattern applies whenever you're designing a classification gate: figure out which error costs more, then make the rule favor the cheaper error explicitly.

### 4. Intent-capture modals need worked examples, not just labels.

Users restate the question back at you instead of answering it. When we asked "What's allowed in this session — and what's not?" the user wrote "what's not allowed is any distraction website" — a non-answer that gave Qwen zero positive signal. Any modal asking the user to articulate intent needs:
- Strong placeholder text showing a useful answer
- One or two inline examples ("e.g. 'coding Intentional in Cursor + GitHub + Stack Overflow; not allowed: Twitter, YouTube'")
- Maybe a "show me an example" affordance for first-time users

### 5. Specific technical gotchas from this build

- **MLX model IDs:** Qwen3-4B uses `mlx-community/Qwen3-4B-Instruct-2507-4bit`, Qwen3-8B uses plain `mlx-community/Qwen3-8B-4bit` (no "Instruct-2507" suffix). Don't assume parallel naming. Cache lives flat at `~/Library/Caches/models/mlx-community/<name>/`. Pre-download via `huggingface_hub.snapshot_download(local_dir=...)` to that path so first-run latency doesn't include the download.
- **AppleScript multi-line `if (a or b or c) then`** doesn't parse without explicit `¬` continuation markers. Use `if targetList contains x then` instead — build the list as a literal, check membership.
- **MLX-Swift batch inference** doesn't auto-await the lazy model load. Mirror `scoreRelevance`'s pattern — `await loadMLXModelIfNeeded()` at the top of any new scoring entry point or your first call returns empty.
- **String matching against user intent** is a footgun. Domain stems like `jobs` (from `jobs.lever.co`), `docs`, `developer`, `status`, `support` are also common English words and will auto-keep huge categories of unrelated tabs. Either drop stem matching entirely (use full-domain matches only) or maintain an explicit stoplist of common-word collisions. Curated tool allowlists are safer than open-ended stem extraction.

---

## Product Overview

Intentional is a macOS focus enforcement app. The Puck physical device provides a simple on/off toggle for blocking mode. Setting an intention upgrades blocking from dumb (block all distracting sites) to smart (AI scores relevance). See [docs/PUCK_SPEC.md](docs/PUCK_SPEC.md) for full product vision and blocking modes.

**Architecture Principle: Logic + Sensing both live in the Mac app.** All enforcement logic, overlays, timers, behavioral features AND browser-tab sensing run in this macOS app. AppleScript is the sole interface to browsers (Chrome, Arc, Safari, Comet, Brave, Edge, Vivaldi). The Chrome extension integration was removed 2026-05-21 — Firefox / Tor are not supported. See `docs/archive/EXTENSION_PROTOCOL.md` for historical reference and `docs/cross-repo-extension-removal-2026-05-21.md` for the deletion summary.

**Architecture Principle: Backend is Source of Truth for Cross-Device State.** Focus session state (`is the user focused right now`) lives canonically in `focus_sessions` on the backend. Each client (Mac, iPhone) treats its local representation as a cache. Mac polls `/focus/active` every 2s via `X-Device-ID` auth (no JWT TTL pain). iPhone reconciles on foreground/boot. Backend rows have `expires_at` TTL safety net so sessions where no client ever sent stop self-expire after 12h. See `docs/cross-repo-focus-sync-2026-04-28.md` for the full architecture, why it changed, and what's still follow-up.

---

## Intentions (Spec 1, May 2026) — ACTIVE

The Mac no longer treats Projects as a local-only concept. They are now backend-resident, account-scoped, cross-device-synced **Intentions** (`intentions` table in `intentional-backend`, see migration 018). Each Intention owns its own `mac_websites` + `mac_bundle_ids` lists directly.

- **`IntentionStore`** is the actor + cache. Pull on launch / app foreground / 60s timer. Local cache at `~/Library/Application Support/Intentional/intentions.json`.
- **`BlockingProfileManager` is NOT removed in Spec 1.** The named-profiles UI in the dashboard still uses it. Project blocklists migrated by *resolving* profile references into the new Intention's own lists. Profiles UI to be removed in a future cleanup PR.
- **Projects are DEAD (projects kill Step B, 2026-06-11).** `ProjectStore`, `IntentionMigration`, and `AppDelegate.activeProjectSession` (+ all set/clear/ensure plumbing) are deleted. The active session's goal lives in `FocusModeController.currentPeriod.intentionId`; per-goal enforcement flows exclusively through `AppDelegate.refreshIntentionEnforcement` via the `onStateChanged` fanout. Session history is backend-permanent (`focus_sessions` incl. `focus_score`, sent by the Mac on stop, derived from relevance_log assessments — see `SessionFocusScore.swift`); goal editor renders it via `GET_GOAL_SESSIONS` → `_goalSessions` with cache `session_history.json`. Learned sites: `LearnedSitesStore` (local, keyed by intentionId; one-shot migrate from `projects.legacy.json`, receipt `migration_learned_sites_v1.json`); `PROMOTE_LEARNED_SITE` promotes + appends to the goal's `allow_websites`. `projects.json`/`projects.legacy.json` left on disk. Log: `docs/cross-repo-projects-kill-2026-06-11.md`.
- **Manual session start** now POSTs `/focus/toggle` with `intention_id`. Backend pushes silent APNs to peer iOS devices for ≤5s cross-device propagation.
- **Day-1 default**: server seeds a "Focus" intention with curated default Mac blocklist for fresh accounts (no setup gate).
- **Bridge messages**: dashboard ↔ Mac uses `GET_INTENTIONS`, `GET_INTENTION`, `CREATE_INTENTION`, `UPDATE_INTENTION`, `DELETE_INTENTION`, `START_INTENTION_SESSION`, `GET_GOAL_SESSIONS`. Legacy `*_PROJECT_*` messages are no-op aliases (remove after 2026-07).

Spec: `docs/superpowers/specs/2026-05-03-intentions-spec1-design.md`
Plan: `docs/superpowers/plans/2026-05-03-intentions-spec1-plan-b-mac.md`
Cross-repo log: `docs/overnight-run-2026-05-03.md`

---

## Weekly + Monthly Goals (May 14, 2026) — ACTIVE

Intentions are surfaced to users as "Weekly Goals." The underlying Swift type (`Intention`) and DB table (`intentions`, which is a SQL view over `focus_modes` post-migration 022) keep their names. Each Intention/Weekly Goal carries new fields the prototype editor exposes:

- `outcome` (done-looks-like text)
- `status` enum (planned | in_progress | done | slipped | dropped)
- `weeklyTargetHours`
- `intentText` (≤140 chars; drives AI scoring when `aiScoringEnabled`)
- `aiScoringEnabled` (bool, default true)
- `allowWebsites` + `allowBundleIds` (per-goal Allow list — but **globally-active Time Blocks override these** per §17b.7 of requirements doc)
- `monthlyGoalId` (FK → MonthlyGoal; nullable for "unlinked" goals)
- `weekOf` (ISO Monday date; nullable = unscheduled)

New top-level type `MonthlyGoal` (`Intentional/MonthlyGoal.swift`) + actor `MonthlyGoalStore`. Cache at `~/Library/Application Support/Intentional/monthly_goals.json`. Sync pattern mirrors `IntentionStore` (pull on launch + foreground + 60s timer).

**One-shot migration:** `IntentTextMigration.runIfNeeded` copies `Intention.description` → `intentText` for goals that don't have it yet. Idempotent via receipt at `migration_intent_text_v1.json`. Runs after first IntentionStore pull on launch.

**New bridge messages (dashboard ↔ Mac):**
- `GET_MONTHLY_GOALS`, `GET_MONTHLY_GOAL`, `CREATE_MONTHLY_GOAL`, `UPDATE_MONTHLY_GOAL`, `DELETE_MONTHLY_GOAL`
- `LINK_WEEKLY_TO_MONTHLY` (set/clear `monthly_goal_id` on an Intention)
- `START_GOAL_SESSION` (alias of `START_INTENTION_SESSION`; carries optional `monthly_goal_id` for future analytics — currently ignored)
- `intentionToDict` extended with the 9 new fields → `_intentionsList` receiver
- `monthlyGoalToDict` → `_monthlyGoalsList` / `_monthlyGoalDetail` / `_monthlyGoalCreated` / `_monthlyGoalUpdated` / `_monthlyGoalDeleted` receivers

**Backend:** migration 026 (`intentional-backend`) adds 9 columns to `focus_modes` (refreshes the `intentions` view), creates `monthly_goals` table + indexes + RLS + triggers. CRUD endpoints at `/monthly_goals`. Extended `/intentions` POST + PUT round-trips the new fields. `GET /intentions?week=YYYY-MM-DD` filters by week.

**Theme toggle: OUT OF SCOPE** for this ship (§10 + §17b.12 of requirements doc). Dark-only.

Brief: `docs/prototype-to-production-2026-05-14.md`
Requirements: `docs/requirements-2026-05-14.md` (§17b authoritative for resolved Q&A)
Plans: `docs/superpowers/plans/2026-05-14-prototype-to-production-plan-{a,b,c}.md`
Cross-repo log: `docs/overnight-run-2026-05-14.md`

---

## Rules + Allowance (Rules Consolidation, June 2026) — ACTIVE

One sidebar tab **Rules** owns everything block/limit/allow. Sidebar is 5 items: Today / Goals / Rules / Accountability / Settings. A **rule** = target (site domain or app bundle id) + treatment (🚫 blocked / ⏳ limited / ✅ allowed) + optional schedule blob `{start:"HH:MM", end:"HH:MM", days:[1..7]}` (ISO, Mon=1). Account-scoped on the backend (`rules` table, migration 028, `/rules` CRUD with X-Device-ID auth — DEPLOYED). ⏳ targets spend the shared daily **allowance** (`/allowance/*`; base + earned at 5:1, 60-min bank cap; ⏳ behaves as 🚫 in-session and at zero balance).

- **Source of truth:** `RuleStore` actor (cache `rules.json` + `allowance.json`, pull launch/foreground/60s) → `RuleEnforcementMirror` + `AllowanceBalance` for the synchronous enforcement hot paths. `EnforcementResolver` is THE precedence: per-goal allow > ✅ > 🚫/⏳gate > goal blocklist > default lists — same for sites and apps; consumed by WebsiteBlocker (0.5s sweep), FocusMonitor (evaluateApp + out-of-session 🚫-app pre-gate), and the close-the-noise sweep (✅ never swept, 🚫/⏳ auto-stash inputs).
- **R6 (2026-06-11):** one-shot `RulesMigration` (receipt `migration_rules_v1.json`) moved BlockingProfile block rules → 🚫, AlwaysAllowedStore → ✅, backend always_blocked/distractions rows → 🚫. Originals backed up + renamed `*.legacy.json`; the live stores were written EMPTY (don't repopulate them — `BlockingProfileManager.removeAllProfilesForMigration` exists precisely so the default profile doesn't re-seed). **EarnedBrowseManager is DELETED** (`BlockFocusStats` survives standalone as the celebration data carrier); the Settings list pages (Distractions / Always Blocked / Always Allowed / Budget) and the Today "Blocks" sub-tab are gone. Their bridge messages are one-cycle no-op aliases — remove after 2026-07. `BlockingProfileManager` + `BlockRuleEnforcer` code remains (resolver still reads their layers) but their stores are empty; removal is a later slice. Backend `always_blocked`/`distractions` tables + endpoints still exist (unread) — retire later.
- **Strict-mode (asymmetric):** tightening free; loosening (delete/disable 🚫, demote treatment, raise base/cap, lower rate) partner-gated — JS gate in dashboard + real-store gate in MainWindow (`blockRulesLockEngaged`, reads the DAEMON strict flag, not the JS mirror).
- Docs: `docs/features/rules.md` (authoritative) · spec `docs/superpowers/specs/2026-06-10-rules-consolidation-design.md` · cross-repo log `docs/cross-repo-rules-2026-06-11.md`.

---

## Parallel Development (Worktree Workflow)

This repo uses git worktrees for parallel feature development. Multiple Claude Code agents may be working on different features simultaneously in separate worktrees.

**How it works:**
- `main` branch has the latest stable code
- Each feature gets its own worktree + branch under `.claude/worktrees/` or a sibling directory
- Each agent works in its own worktree — no file conflicts during development
- Features merge to main one at a time; the second feature rebases onto the updated main

**If you are in a worktree:**
- Run `git log --oneline main..HEAD` to see what other branches have been merged since you branched
- Before finishing, rebase onto main: `git fetch && git rebase main`

**Cross-repo coordination:** Features often span the Mac app + backend (and sometimes the Puck iOS app). When changing API contracts, document the wire format in your commit message so the other agent (working on the other repo's worktree) can match it.

**Active worktrees:** Run `git worktree list` to see all active worktrees and their branches.

---

## Initialization Order (AppDelegate)

Order matters. Components have dependencies that must be wired in sequence.

```
1.  BackendClient           → API client
2.  MainWindow (WKWebView)  → Dashboard/onboarding UI
3.  Menu bar icon
4.  PermissionManager       → Accessibility permission monitoring
5.  SleepWakeMonitor
6.  WebsiteBlocker          → AppleScript tab blocking
7.  BrowserMonitor          → Protection status (references WebsiteBlocker)
8.  Backend: registerDevice, sync lock/partner state
9.  Strict mode init        → Reads `strictModeEnabled` from UserDefaults → login item, watchdog, flag file
10. TimeTracker             → Cross-browser usage aggregation
11. (EarnedBrowseManager DELETED in R6, June 2026 — replaced by the shared daily allowance: RuleStore + backend /allowance/*)
11a. (ProjectStore + IntentionMigration DELETED in projects kill Step B, 2026-06-11 — IntentionStore is the goal store; LearnedSitesStore holds learned sites, one-shot migrated from projects.legacy.json)
11b. RuleStore               → Unified rules + allowance (pull on launch + foreground + 60s; cache rules.json/allowance.json; publishes to RuleEnforcementMirror + AllowanceBalance for the sync enforcement hot paths)
12. (TimeTracker→EarnedBrowse wiring removed in R6 — ⏳ spend metering lives in FocusMonitor's allowance meter)
13. ScheduleManager         → Load schedule, recalculateState
14. RelevanceScorer         → AI model initialization
15. FocusMonitor            → Desktop monitoring (refs: ScheduleManager, RelevanceScorer)
15a. FocusModeController    → Single source of truth for is-app-enforcing (3 states: off/focus/bedtime). Replaces IntentionalModeController + FocusSessionManager. Persists state to disk on every notify(); rehydrates on init so app-restart doesn't briefly show "off" while a session is active.
15b. (BlockRitualController deleted 2026-06-10 — start ritual lives in the pill, DeepWorkTimerController .startRitual)
15c. BlockEndRitualController → Wired to FocusMonitor.endRitualController
15d. ContentSafetyMonitor     → Load enabled from settings, start if enabled
15e. SwitchInterventionCoordinator + SwitchOverlayController → Gate now reads FocusModeController.isOn
16. Wire ScheduleManager.onBlockChanged → FocusModeController.activate / .deactivate / .activateBedtime
17. Manual activeBlockId sync + initial Focus Mode activation if a block is currently active
18. Heartbeat timer (2 min interval)
19. FocusStatePoller       → Polls /focus/active every 2s with X-Device-ID auth. On state transition, drives FocusModeController.activate/.deactivate. Backend-as-master cross-device sync; no JWT-expiry pain.
20. (boot reconcile)       → If FocusModeController.state == .focus from disk restore, applyDefaultBlockingProfile() + focusMonitor?.onBlockChanged() to re-engage enforcement.
21. RulesMigration (R6)    → One-shot, fire-and-forget Task after blockingProfileManager + ruleStore exist: BlockingProfile block rules → 🚫, AlwaysAllowedStore → ✅, backend always_blocked/distractions rows → 🚫. Receipt migration_rules_v1.json; backs originals up to a timestamped dir, renames them *.legacy.json + writes EMPTY stores (prevents default re-seed) only after every create lands. Env INTENTIONAL_RULES_MIGRATION_DRY_RUN=1 = plan+log only.
```

### Critical Callback Wiring

```swift
// ScheduleManager.onBlockChanged → triggers Focus Mode transitions
scheduleManager.onBlockChanged = { block, state in
    switch state {
    case .focus:    focusModeController.activate(intention: block?.title, source: .schedule)
    case .bedtime:  focusModeController.activateBedtime(source: .bedtimeSchedule)
    case .off:      focusModeController.deactivate(source: .schedule)
    }
    // Domain logic (project sessions, celebration display) preserved separately
}

// FocusModeController.onStateChanged → fans out enforcement
focusModeController.onStateChanged = { old, new, period in
    relevanceScorer.clearCache()
    focusMonitor.onBlockChanged()
    mainWindow.pushScheduleUpdate()
    mainWindow.pushFocusModeUpdate(state: new)
    if new == .off { switchCoordinator.reset() }
}
// (R6: the earnedBrowseManager.onBlockChanged-before-focusMonitor ordering
// invariant and the TimeTracker.onSocialMediaTimeRecorded wiring are GONE
// with EarnedBrowseManager. Allowance earn posts on .focus→.off via
// AppDelegate.postAllowanceEarn; ⏳ spend metering is FocusMonitor's
// 5s allowance meter.)
```

---

## Known Bug Fixes

1. **activeBlockId nil on startup**: *(retired in R6 with EarnedBrowseManager — the manual post-wiring sync now only re-pokes `focusMonitor.onBlockChanged()` for the mid-block-startup pill.)*

2. **Callback execution order**: *(retired in R6 — `recordWorkTick`/`activeBlockId` deleted with EarnedBrowseManager; `focusMonitor.onBlockChanged` is the only consumer in the fanout now.)*

3. **MLX parse error fail-open**: Changed from fail-open (relevant=true on error) to fail-closed (relevant=false, confidence=0). Prevents broken AI from silently allowing all content.

4. **Chrome blocked by WebsiteBlocker with extension active**: `BrowserMonitor` now cross-checks socket connection status (definitive) with file-based detection, instead of immediately marking browser as unprotected on socket disconnect. *Resolved 2026-05-21 by removing the extension entirely — `BrowserMonitor` now reports protection from AppleScript-only detection.*

5. **Extension-launched process killing the app**: Chrome SIGTERMs then SIGKILLs native messaging hosts. Fixed by relay architecture: extension-launched processes are always thin relays, primary app is launched independently via `NSWorkspace`. *Resolved 2026-05-21 by removing the extension entirely — the app is no longer launched as a native-messaging child of any browser process.*

6. **Settings 800ms debounce losing changes**: `onSettingChange()` in dashboard.html uses an 800ms debounce before calling `saveAllSettings()`. If the user quits the app within 800ms of toggling, settings are lost. Fixed for Content Safety toggle (now saves immediately). Consider fixing for all toggles.

7. **PKG build re-signs with Developer ID Application + Developer ID provisioning profile.** The archive is signed with Apple Development, then re-signed inside-out (FilterExtension → frameworks → main app) with Developer ID Application using transformed entitlements. The `sensitivecontentanalysis.client` entitlement is stripped from PKG builds because Apple doesn't support it for Developer ID distribution — the app falls back to OpenNSFW for NSFW detection. The `content-filter-provider` value is changed to `content-filter-provider-systemextension` for Developer ID. The source entitlements file is NOT modified.

8. **NEVER strip or remove entitlements from the source file.** All entitlements exist for a reason. The build script handles transforming them for Developer ID signing. Do not modify `Intentional.entitlements` to remove capabilities.

9. **Whole-app UI freeze from AppleScript on main queue.** `WebsiteBlocker.appleScriptQueue` was declared as `DispatchQueue.main`, and a 0.5s timer fired `NSAppleScript.executeAndReturnError` on it for every active browser. Each call blocks on `mach_msg` waiting for the browser's Apple Event reply (200–600ms). Result: menu bar, pill, and dashboard all sluggish; dashboard `fps=14–23` with `longTasks=0` (the stall was on the native main thread, not in JS). Fixed by moving `appleScriptQueue` to a background serial queue (`DispatchQueue(label: "com.intentional.applescript", qos: .userInitiated)`). Apple Event Manager spins up its own nested `CFRunLoop` for reply delivery on whatever thread calls `AESendMessage`, so background execution is safe. **Rule: never dispatch synchronous AppleScript, Apple Events, or sync XPC to `DispatchQueue.main`. Use a background serial queue.**

10. **(RESOLVED by deletion, 2026-06-11.)** ~~Queued project session does not auto-activate when its block becomes current.~~ The Project session model was deleted in the projects kill (Step B); scheduled sessions activate via `ScheduleManager.onBlockChanged → FocusModeController.activate(intentionId:)` and the backend records the session. See `docs/archive/PROJECTS.md`.

11a. **Partner cache desync across devices (April 30, 2026).** Backend's `POST /partner` already wrote `partner_email`/`partner_name` to every sibling user row sharing an `account_id`, and `GET /partner/status` already fell back to siblings on empty rows. But the iOS client only read partner from `@AppStorage("partnerName")` (UserDefaults) and the Mac dashboard only fetched on navigation to the "pending" view. So a Mac signed into the same account as an iPhone never picked up a partner that was set + confirmed via the iPhone. Fix: `PartnerSyncService` on each platform fetches `/partner/status` on launch + foreground/`didBecomeActive` + every 60s while active, writes the result to UserDefaults (iOS) / settings JSON + dashboard (Mac), and reuses the existing `_partnerStatusResult` JS receiver for live updates. iOS clears cache on logout via `authStateDidChange`; Mac has no in-app sign-out so no cache wipe needed. See `docs/cross-repo-partner-sync-2026-04-30.md` and `docs/superpowers/plans/2026-04-29-partner-cross-device-sync.md`.

11. **Tangled focus state (April 2026 consolidation).** Nine overlapping concepts — Focus Gate, Intentional Mode, Focus Session, Always-Active Blocking, TimeState (7 cases), etc. — caused recurring desync bugs (screen red on YouTube without a session, focus gate not engaging on cross-device signal, phantom sessions, focus session active on phone but Mac doesn't know). Consolidated into `FocusModeController` with three states (OFF/FOCUS/BEDTIME). Schedule + cross-device WS + manual toggle + puck all flow through the same controller. Enforcement components (`FocusMonitor`, `SwitchInterventionCoordinator`) read `focusModeController.isOn`. `IntentionalModeController` and `FocusSessionManager` deleted (~700 lines net). See `docs/FOCUS_CONCEPTS_SIMPLIFICATION.md` and `docs/superpowers/plans/2026-04-27-focus-mode-consolidation.md`.

11b. **Bedtime config desync between Mac and iPhone (April 30, 2026).** Each device read its own local `bedtime_settings.json`; a toggle on iPhone never reached the Mac and vice versa. Backend already had `GET/PUT /bedtime/config` keyed by account_id, but the lock-loop branch was forked before the original `BedtimeConfigSync` shipped on `feat/bedtime-lockdown` — so the production PKG that included it lived elsewhere. Fix: ported `BedtimeConfigSync` (pull on launch + didBecomeActive + 60s timer; push on user edit via `MainWindow.handleSaveBedtimeSettings → BackendClient.putBedtimeConfig`). Last-write-wins via backend upsert on `account_id`. One-time migration of legacy local file → backend. See `docs/superpowers/plans/2026-04-29-partner-cross-device-sync.md` (sibling-sync architecture is identical pattern).

12. **Bedtime full-screen overlay replaced by lock-loop (April 2026).** `BedtimeOverlayView` (the full-screen blanket NSWindow) was easy to dismiss / route around and didn't actually prevent the user from operating the Mac. Replaced with `BedtimeLockLoop` which fires the OS lock screen every 10s while bedtime is `.locked`. Apps + downloads + music keep running; user re-enters via password / Touch ID; 10s gives enough room for partner-code entry without locking mid-keystroke. State machine simplified to `inactive | windDown(t30/t15/t5/t1) | locked | released`. Removed `forceSleep` (pmset), `snoozeUsedTonight`, `BedtimeOverlayView`, the wind-down redShift/grayscale phases. Wind-down cascade now lives in `BedtimeWindDownController` as native macOS notifications (`.timeSensitive`, bypasses DND) at T-30 / T-15 / T-10 / T-5 / T-1. Pill gains `.bedtimeWindDown` and `.bedtimeLocked` modes; pill also snaps to top-right on every `show()` so users don't lose it off-screen. Partner unlock now duration-limited via slider (15/30/60/120 min or until wake) with once-per-night cap. See `docs/cross-repo-bedtime-lock-loop-2026-04-29.md` and `docs/superpowers/plans/2026-04-29-bedtime-lock-loop-and-duration-extensions.md`.

   **Lock primitive (April 30, 2026 fix):** original implementation invoked the lock screen via AppleScript `keystroke "q" using {command down, control down}`. On machines where "Require password X after sleep" is set to a delay (5min/1hr), macOS interpreted this as Sleep Display, so wake-from-sleep didn't require a password. Subsequent ticks also no-op'd silently because System Events can't deliver keystrokes to a loginwindow-locked context. **Fix:** `dlopen` + `dlsym` on `/System/Library/PrivateFrameworks/login.framework/Versions/A/login` and call `SACLockScreenImmediate()` directly — same primitive Apple's "Lock Screen" menu item uses, always forces password regardless of the `password-after-sleep` delay. AppleScript remains as fallback if dlopen ever fails on a future macOS. Also added `RunLoop.main.add(timer, forMode: .common)` and `timer.tolerance = 0.5s` to harden the 10s cadence. **Rule: don't lock the screen via AppleScript keystroke. Use SACLockScreenImmediate via dlopen.**

13. **iPhone scheduled blocks via DeviceActivityMonitor (April 30, 2026).** Puck iPhone now has a Schedule tab ("Blocks") where users create recurring Deep Work / Focus Hours blocks. At the scheduled time, `PuckBedtimeMonitor` (the DeviceActivity extension) applies a per-block `ManagedSettingsStore` shield — even with the app closed. The extension dispatches on `DeviceActivityName` prefix: `"bedtime"` → existing bedtime path unchanged; `"schedule_<8 hex chars>"` → per-block path reads blocklist from App Group UserDefaults (`BedtimeSharedStorage.loadBlockBlocklist(blockId:)`). Block timing is authoritative on the backend at `/schedule/blocks` (4 commits on `intentional-backend:feat/schedule-blocks`); per-device app blocklists are local-only. Mac does NOT yet read this endpoint — the Mac has its own schedule format. See `docs/cross-repo-iphone-schedule-2026-04-30.md` and `docs/superpowers/plans/2026-04-30-iphone-schedule-tab.md`.

14. **Scheduled Intentions Redesign (May 2026).** Block editor's "Blocking Profiles" chips are gone — replaced by an Intention picker dropdown sourced from `IntentionStore`. Block editor also drops the Block Type segmented control (Free Time = absence of block per Spec 2). New active-days pill row (Mon–Sun, default `[1..5]`). Each Intention now has a `strictnessPreset` (Strict / Standard / Soft) edited from the Intentions tab. Tightening is instant; softening Standard→Soft has a 24h cool-down (server-side cron, cancellable, warm-tone D15 confirm copy); softening from Strict requires a partner unlock code (reuses generalized `BedtimeUnlockRequestView` with `UnlockRequestKind.intentionStrictness`). Strictness control greys out during an active Session of that Intention (D6). Sidebar restructured to 8 items: Today / Intentions / Schedule / Distractions / Sensitive Content / Weekly Planning / Accountability / Settings *(historical — since Rules Consolidation R3/R6, June 2026, the sidebar is 5 items: Today / Goals / Rules / Accountability / Settings, and Settings' list pages are gone — see the Rules section below)*. Sensitive Content promoted from Settings to its own page; Weekly Planning is a placeholder for the deferred budgets feature (D9 schema prep landed; behavior deferred). Bedtime + Wake render as solid bands on the calendar (deep navy `#3B2459` bottom, warm coral `#F38B5C` top, no gradients per D11). Calendar gestures (drag-to-create / edge-resize / move) explicitly DEFERRED to v1.5 per D13. One-shot migration `BlockingProfilesToIntentionsMigration` rebinds existing block→profile bindings to block→intention idempotently with a receipt at `~/Library/Application Support/Intentional/migration_profiles_to_intentions_v1.json`. Per D14, `BlockingProfileManager` and its data file are NOT removed in this redesign — only the chips UI is hidden. Cleanup (Profiles tab + dashboard handlers + `BlockingProfileManager`) deferred to a follow-up spec after ≥2 weeks of stability.

   **Architecture key points:**
   - `Intention.strictnessPreset` + `pendingStrictnessChange` + `weeklyBudgetHours` + `budgetEnforcement` fields decode tolerantly so older payloads still parse.
   - New `BackendClient` methods: `updateIntentionStrictness`, `getPendingStrictnessChange`, `cancelPendingStrictnessChange`, `requestIntentionStrictnessUnlock`, `verifyIntentionStrictnessUnlock`. Backend endpoints actually deployed: `PUT /intentions/{id}/strictness`, `GET /intentions/{id}/strictness/pending`, `POST /intentions/{id}/strictness/cancel`. Partner-unlock endpoints (`POST /intention_strictness_unlock_requests`, `POST /intention_strictness_unlock_requests/{id}/verify`) are referenced by Mac + iOS clients but **DEFERRED on backend** (Plan A "What this plan does NOT do"). Strict-step-down softening will throw a runtime error in the UI dialog until the backend endpoints land — request stage fails with "Couldn't reach partner". Tightening + Standard→Soft cool-down both work end-to-end.
   - New `MainWindow` bridge messages: `UPDATE_INTENTION_STRICTNESS`, `CANCEL_PENDING_STRICTNESS_CHANGE`, `OPEN_INTENTION_STRICTNESS_UNLOCK_SHEET`, `OPEN_INTENTION_EDITOR`. Intentions list payload now includes `strictness_preset`, `pending_strictness_change`, `weekly_budget_hours`, `budget_enforcement`.
   - `BedtimeUnlockRequestView` gains `kind: UnlockRequestKind` enum (`.bedtime` vs `.intentionStrictness(intentionId, toPreset, intentionName)`); duration slider hidden when not bedtime.
   - Block editor JS: Intention picker dropdown sources from `intentionsCache` (populated by `_intentionsList` receiver). Change handler `onEditorIntentionChange` either binds the picked Intention or opens the slide-in `+ Create new Intention` mini-editor. Active-days pills mutate `block.activeDays` directly (defaults to `[1..5]`).

---

## Build & Distribution

### Development (Xcode)
Standard `xcodebuild` or Xcode IDE. Debug builds run directly from DerivedData. Uses Apple Development signing with automatic provisioning.

### Running a fresh build on the user's locked-down Mac (MANDATORY READ)

**Use the script:** `./scripts/dev-launch.sh` (or `./scripts/dev-launch.sh --no-build` to skip rebuild). It handles all of the below automatically and auto-diagnoses the failure mode if the new instance dies. The rest of this section explains *why* it works so you can debug if it ever breaks.

**Critical fact: the user is `arayan`, NOT an admin. Caity is the admin. The user has NO sudo access.** That means anything starting with `sudo`, `! sudo`, `pkill -9` against `/Applications/Intentional.app`, etc. **will fail with "operation not permitted"** — the production binary runs as user `caity` (not `arayan`), so even non-sudo `pkill` can't signal it. Do not suggest sudo workflows to the user; the answer is always "use `dev-launch.sh`, the dev instance runs alongside the production one."

**Two-user split-brain consequence (important):**
- Production `/Applications/Intentional.app` runs as user `caity` (via the system LaunchDaemon). It owns its own menubar / pill in caity's GUI session.
- Dev build from DerivedData runs as user `arayan`. It owns the menubar / pill in arayan's GUI session.
- Both processes coexist after `dev-launch.sh`. The takeover code (`main.swift:159 → kill(existingPID, SIGTERM)`) **silently fails** when the existing PID belongs to caity — `arayan` cannot signal caity's processes. The new arayan-owned dev instance launches anyway; the production caity-owned one keeps running.
- The user is logged in as arayan, so they only see arayan's menubar — clicking it lands on the dev build. That's the intended path; you don't need to kill the caity-owned process.

**Sweep / state caveat:** `FocusModeController` persists state to disk on every transition. If a session is already active when the dev build launches, the new instance rehydrates `state=focus` and re-engages enforcement via the "boot reconcile" branch — **without going through `onStateChanged`**, so anything wired to the `.off → .focus` *transition* (the close-the-noise sweep, for example) **does not fire on app restart mid-session**. To exercise transition-driven code paths during dev, end the active session from the dashboard / menubar before testing, then start a fresh one. Puck-triggered sessions are also ignored by `FocusStatePoller` on Mac per current spec (`puck = alarm only`), so use the **Mac dashboard manual toggle** to drive a `.off → .focus` transition.

The user's Mac has Strict Mode + tamper-protection daemon installed. `open <bundle>` does not work. `sudo installer ... .pkg` works but the user does not have sudo, so this is moot. This is the procedure that actually runs a fresh build against the daemon-managed install — **follow it exactly**, none of the obvious alternatives work:

**Why the obvious paths fail:**
- ❌ `open /tmp/intentional-pkg-build/Intentional.app` → LaunchServices ignores your path and starts the registered `/Applications/Intentional.app` (the OLD one).
- ❌ Exec the PKG-built binary at `/tmp/intentional-pkg-build/Intentional.app/Contents/MacOS/Intentional` directly → AMFI SIGKILLs it silently. PKG output is Developer ID signed; cannot run standalone outside the installer. Log shows splash lines then nothing — exit code 137, no crash report.
- ❌ Exec the DerivedData Debug binary plainly (`nohup .../Intentional &`) → main.swift's single-instance check sees the daemon-launched process, takes the "duplicate launch — exit silently" branch (line ~169 of `Intentional/main.swift`), your new instance disappears within 1s.
- ❌ Reading `docs/dev-build-and-launch.md` and pasting its DerivedData hash → that hash drifts. The doc's `Intentional-cjpaicwfawcwqgepfrsxstqebhev` is stale. Always discover the current hash at runtime.

**The procedure that works:**

```bash
# 1. Build Debug (NOT a PKG — PKG-signed binaries get AMFI-killed standalone).
#    Run from the worktree root (or main repo root if not in a worktree).
xcodebuild -project Intentional.xcodeproj -scheme Intentional -configuration Debug build 2>&1 | tail -5

# 2. Discover the current DerivedData hash dynamically. There are typically
#    multiple Intentional-* folders; pick the one with the newest Debug binary.
DERIVED_DIR=$(ls -dt /Users/arayan/Library/Developer/Xcode/DerivedData/Intentional-*/Build/Products/Debug 2>/dev/null | head -1)
DERIVED_BINARY="$DERIVED_DIR/Intentional.app/Contents/MacOS/Intentional"
ls -la "$DERIVED_BINARY"  # sanity check + mtime confirms fresh build

# 3. CRITICAL: set __XCODE_BUILT_PRODUCTS_DIR_PATHS before exec'ing the binary.
#    This is the env var Xcode sets when running from the Run button. main.swift
#    keys off this to take the "Xcode launch — kill the existing PID, take over,
#    bootout the LaunchAgent + Login Item so the daemon won't immediately
#    relaunch the OLD version" branch (see main.swift:106 and 113-168).
#    Without it, your launch silently exits as a "duplicate" — no error, no log.
nohup env __XCODE_BUILT_PRODUCTS_DIR_PATHS="$DERIVED_DIR" "$DERIVED_BINARY" \
  &> /tmp/intentional-fresh.log &
NEW_PID=$!
echo "Launched PID $NEW_PID"
sleep 5

# 4. Verify the new instance survived. If pgrep returns DerivedData paths, the
#    takeover worked. If it returns only /Applications paths, the takeover
#    failed — check /tmp/intentional-fresh.log for the reason.
pgrep -lf "DerivedData.*Intentional.app/Contents/MacOS" | head -3
tail -15 /tmp/intentional-fresh.log
```

**Expected log signature when takeover works:**
```
🚀🚀🚀 MAIN.SWIFT EXECUTING - PID: <new>
... <env vars, launch time> ...
🏗️ Creating NSApplication and AppDelegate...
✅ AppDelegate assigned, calling NSApplicationMain...
=== applicationDidFinishLaunching CALLED ===
[DaemonXPC] Connection established to com.intentional.daemon.xpc
```

If the log stops after the PID line with no `🏗️ Creating NSApplication` — AMFI killed it (you ran the PKG binary, not the Debug binary).
If the log gets to `applicationDidFinishLaunching` but the process dies — single-instance check exited as duplicate (the env var wasn't set).

**To roll back to the daemon-managed `/Applications` build:**
Just quit the dev instance — the LaunchAgent + watchdog will respawn `/Applications/Intentional.app` within seconds (the takeover bootouts them but the system-level LaunchDaemon at `/Library/LaunchDaemons/com.intentional.watchdog.plist` survives a logout/login cycle and will reload them).

**When this procedure isn't enough:** if you need the dock icon (the persistent click target) or the watchdog respawn to point at the new build, you do have to physically replace `/Applications/Intentional.app`. That requires sudo and is documented in `docs/dev-build-and-launch.md`.

### Production (PKG Installer)
**Build command:** `./scripts/build-pkg.sh`
**Skip notarization:** `NOTARIZE=0 ./scripts/build-pkg.sh`
**Output:** `/tmp/intentional-pkg-build/Intentional-{VERSION}.pkg`

**CRITICAL:** Never re-sign the app binary after Xcode archives it. This causes AMFI Error 163 (SIGKILL, exit code 137, no crash report). See [docs/PKG_BUILD_GUIDE.md](docs/PKG_BUILD_GUIDE.md).

**CRITICAL:** Never strip or remove entitlements from `Intentional.entitlements`. The build script transforms them for Developer ID signing. Fix signing/profile config instead.

> Full build guide: [docs/PKG_BUILD_GUIDE.md](docs/PKG_BUILD_GUIDE.md)

---

## Reference Documentation

Detailed docs for each subsystem live in `docs/`. Read the relevant doc when working on that feature area.

| Doc | What's in it |
|-----|-------------|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Project structure, architecture diagram, process model (relay/primary), state machine, persistence files, backend API |
| [PUCK_SPEC.md](docs/PUCK_SPEC.md) | Product vision, Puck integration, blocking modes, new systems (April 2026) |
| [FOCUS_ENFORCEMENT.md](docs/FOCUS_ENFORCEMENT.md) | FocusMonitor enforcement timelines (Deep Work vs Focus Hours), block start/end rituals, pill widget, overlays, distracting apps, always-allowed apps |
| [EARNED_BROWSE_SYSTEM.md](docs/EARNED_BROWSE_SYSTEM.md) | **SUPERSEDED (R6, June 2026)** — engine deleted; see [docs/features/rules.md](docs/features/rules.md) (allowance) |
| [AI_SCORING.md](docs/AI_SCORING.md) | Relevance scorer pipeline (keyword→cache→LLM), Qwen3-4B / Apple FM models, fail-closed policy |
| [CONTENT_SAFETY_MONITOR.md](docs/CONTENT_SAFETY_MONITOR.md) | On-device NSFW detection, two-pass capture, OpenNSFW for Developer ID builds, partner notification |
| [CS_TESTING_WINDOW_PLAYBOOK.md](docs/CS_TESTING_WINDOW_PLAYBOOK.md) | How to pause CS emails + enforcement constraint for a debugging window, and how to fully reverse it. Paired scripts in `intentional-backend/scripts/` (`pause_cs_constraint.py` / `resume_cs_constraint.py`) + env var `CS_EMAILS_PAUSED_UNTIL` |
| [CONTEXT_SWITCHING_OVERLAY.md](docs/CONTEXT_SWITCHING_OVERLAY.md) | Non-skippable countdown on app/tab switches during a work block. Coordinator, overlay, tier math, grace periods |
| [archive/PROJECTS.md](docs/archive/PROJECTS.md) | ARCHIVED 2026-06-11 (projects kill) — historical reference for the deleted Project/ProjectStore model. Weekly Goals (Intentions) own goals now |
| [STRICT_MODE.md](docs/STRICT_MODE.md) | App persistence, partner-gated enable/disable, Cmd+Q behavior, watchdog, edge cases |
| [PRIORITY_TODOS.md](docs/PRIORITY_TODOS.md) | Implementation backlog: Intentional Mode, permission monitoring, NE integration, anti-tamper hardening |
| [PKG_BUILD_GUIDE.md](docs/PKG_BUILD_GUIDE.md) | PKG build pipeline, signing details, daemon relaunch strategy, testing checklist |
| [ROADMAP.md](docs/ROADMAP.md) | Product roadmap, psychology research, feature priorities (P0-P3), coaching language overhaul |
| [EARN_YOUR_BROWSE_IMPLEMENTATION.md](docs/EARN_YOUR_BROWSE_IMPLEMENTATION.md) | **SUPERSEDED (R6, June 2026)** — engine deleted; see [docs/features/rules.md](docs/features/rules.md) (allowance) |
| [CALENDAR_BLOCK_RULES.md](docs/CALENDAR_BLOCK_RULES.md) | Block manipulation rules (past locked, active limited, future editable) |
| [BLOCK_TYPE_ENFORCEMENT_SETTINGS.md](docs/BLOCK_TYPE_ENFORCEMENT_SETTINGS.md) | Per-block enforcement toggles (6 mechanisms per block type) |

---

## Reminder: Use Superpowers Skills at the Appropriate Times

Second placement because this is load-bearing and easy to skip. Before any meaningful work:
- Non-trivial change? → `superpowers:brainstorming` first, then `superpowers:writing-plans`, then `superpowers:subagent-driven-development`.
- Bug / unexpected behaviour? → `superpowers:systematic-debugging` before touching code.
- About to say "done"? → `superpowers:verification-before-completion` first — run the thing, confirm output.

Skipping these because a task "feels simple" is exactly when you get burned. Route through the skill.

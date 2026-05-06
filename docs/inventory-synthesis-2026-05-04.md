# Cross-Repo Product Inventory — Synthesis (2026-05-04)

**Source documents:**
- `docs/inventory-mac-2026-05-04.md` — 627 lines, 24 surfaces, 67 bridge messages, 44 BackendClient methods, 19 dead-code candidates
- `docs/inventory-ios-2026-05-04.md` — 758 lines, 6 tabs, 12 SwiftData models, 2 auth modes
- `docs/inventory-backend-2026-05-04.md` — 479 lines, 57 routes + WS, 21 tables, 2 in-process schedulers + 2 cron endpoints

**Purpose of this doc:** crisp summary of cross-cutting themes for use in a fresh product-brainstorming session. The three inventory files are the source of truth; this is the entry point.

---

## 1. Vocabulary is fragmented across the stack

The same concept has different names depending on which layer you're looking at:

| Layer | What it's called |
|---|---|
| Backend table | `intentions` |
| Backend route | `/intentions` |
| Mac code | `Intention` struct, `IntentionStore` |
| Mac sidebar UI | "Focus Modes" |
| Mac block-editor UI | "Intention" picker |
| iOS code | `Intention` struct, `IntentionStore` |
| iOS tab UI | "Focus Modes" (tab) backed by `IntentionsTabView` |
| User's verbal usage | "intents" / "focus modes" / interchangeable |

**Pick a canonical vocabulary.** The user's last instruction was "keep name focus modes" — backend should rename `intentions` table or surfaces should rename to "Intentions" everywhere. Right now: the JSON shape from backend is `intention_id`/`intention_name`/etc, while the user-facing string is "Focus Mode."

---

## 2. "Focus Mode" naming collision — there are FOUR

The Mac inventory found a fourth one we hadn't named yet:

| # | What it actually is | Where |
|---|---------------------|-------|
| 1 | State machine: `.off / .focus / .bedtime` | `FocusModeController.swift` |
| 2 | Sidebar page = list of Intentions | dashboard.html sidebar |
| 3 | Settings → Focus Mode toggle (**dead**) | dashboard.html Settings page |
| 4 | Today page Focus Mode toggle (the "wrapper" the user wants to call **Focus Lock**) | dashboard.html Today page |

The user has already verbally declared the intent: rename #4 to **Focus Lock**, kill #3, leave #1 as a pure technical concept, possibly rename #2 to **Intentions** (or stay "Focus Modes" if vocabulary in §1 lands there).

---

## 3. Three "show-stopper" bugs confirmed by all three inventories

| Bug | Mac evidence | iOS evidence | Backend evidence |
|-----|--------------|--------------|------------------|
| **Strict → softer partner unlock fails 404** | `BackendClient.requestIntentionStrictnessUnlock` exists | (TBD whether iOS calls it) | `intention_strictness_unlock_requests` endpoints not implemented; scheduler explicitly skips strict-source rows |
| **Today-page Focus Mode toggle has no partner lock** | toggle calls `handleFocusModeToggle` directly with no unlock gate | n/a | n/a — local-only switch |
| **Force-a-plan deleted but UI still pretends to enable it** | `FocusMonitor.swift:1634` has TODO admitting deletion | n/a | n/a |

**Net:** the user's mental model "Focus Lock = force plan + limiter, partner-locked" doesn't match reality on any of the three pieces.

---

## 4. Mac-vs-iOS feature asymmetry — not yet a product

The Mac is a full focus-enforcement OS layer; the iOS app is mostly a thin remote control. Brainstorm needs to decide what the iOS app *is*.

| Feature | Mac | iOS | Backend |
|---------|-----|-----|---------|
| Intentions CRUD | ✅ | ✅ | ✅ |
| Focus session start/stop | ✅ | ✅ | ✅ (canonical) |
| Bedtime config + lock loop | ✅ | ✅ | ✅ |
| Partner pairing + unlock | ✅ | ✅ | ✅ |
| Schedule blocks | ✅ (local format) | ✅ (backend `/schedule/blocks`) | ✅ |
| Distracting sites blocklist | ✅ | partial (per-Intention) | ✅ |
| Per-app shields (DeviceActivity) | n/a (browser only) | ✅ | n/a |
| Earned Browse / earn-your-browse | ✅ pipeline (UI hidden) | ❌ | ❌ |
| AI relevance scoring (Qwen) | ✅ | ❌ | ❌ |
| Content Safety NSFW | ✅ | ❌ | partial (batch upload) |
| Strict mode (anti-tamper) | ✅ | ❌ | ✅ |
| Pill / floating widget | ✅ | n/a (iOS has no equivalent) | n/a |
| NFC Puck pairing | n/a | ✅ | ✅ |
| Alarms (wake/bedtime) | n/a (Mac doesn't wake you up) | ✅ | ❌ (local-only on iOS) |

**Asymmetric items that need product calls:**
- Earned Browse: surface on iOS too, or keep desktop-only (because that's where the distractions live)?
- Per-app time budget for distractions: which device enforces? Must agree on per-device behavior or it'll diverge.
- Content Safety on iOS: shipping a Screen Time→Family Sharing parental approach, or skipping?

---

## 5. Cross-device sync — what's tight, what isn't

| Domain | Sync mechanism | Status |
|--------|----------------|--------|
| Intentions | `/intentions` GET on launch + 60s + on edit | ✅ (Spec 1) |
| Focus state (active/inactive) | `/focus/active` 2s poll on Mac, APNs to iOS | ✅ |
| Bedtime config | `/bedtime/config` GET on launch + 60s | ✅ |
| Partner config | `/partner/status` GET on launch + 60s | ✅ |
| Schedule blocks | Mac local file vs iOS `/schedule/blocks` table | ❌ — different formats, no sync |
| Distracting sites (default) | Per-Intention list synced via Intentions, but per-device "default" list is local | ⚠️ partial |
| Earned Browse pool | Local file on Mac, no backend table | ❌ — Mac-only state |
| Alarms | iOS SwiftData only | ❌ — local-only |
| Strict mode state | Mac local + backend, iOS none | ⚠️ partial |
| Content Safety enabled | Mac via `/enforcement` constraints | ✅ via constraint |
| `BlockingProfileManager` (Mac) | local only | ❌ — Spec 1 D14 deferred |

**Schedule unification is the biggest gap.** Mac and iOS literally maintain separate concepts of "today's schedule." Same block can't show on both devices because they don't share storage.

---

## 6. Cleanup backlog (consolidated)

### Backend (from §8 of backend inventory)
- `/partner/dashboard/*` — 4 routes, zero callers across all client repos (incl. partner-dashboard Next.js app)
- `/ws/focus` — built but Mac uses polling, iOS doesn't connect
- `/schedule/blocks` 301 redirects from old paths — period elapsed
- Migration 020 columns: `weekly_budget_hours`, `budget_enforcement`, `derived_from_budget` — schema-prep with no readers/writers (D9 deferred)
- `users.display_name` — read once, never written
- CORS `allow_origins=["*"]` + `allow_credentials=True` — invalid combination (Mac/iOS not browsers, but flag for hygiene)
- Cron secrets passed as query params — visible in logs

### Mac (from §9 of mac inventory)
- `BlockRitualController` — full-screen ritual controller, never instantiated
- `IntentionalModeController` references (deleted in TimeState consolidation, references remain)
- Settings → Focus Mode toggle JS (UserDefault wiped on launch)
- Force-a-plan code paths (TODO admits deletion)
- 14 still-active "legacy" branches in dashboard.html Intentions tab
- Legacy `*_PROJECT_*` bridge handlers (one cycle aliasing period elapsed)
- 14 more candidates in inventory

### iOS (from §9 of ios inventory)
- `RoutineView` (replaced by ScheduleTabView; PuckTab.routine enum case alias remains)
- `HabitGoalCreationView`, `WeeklyReportSheet`, `CalendarTimelineView`, `QuickBlockButton`
- `ScheduleBlockEditSheet`, `ScheduleBlockDetailSheet`
- `NetworkClient` (superseded by IntentionalAPIClient)
- `ModePickerSheet` — never wired
- SwiftData `PuckSchedule`, `ScheduleBlock`, `IntentionalBlock` — migration-only

**Probably 1–2 days of focused cleanup PRs.** Don't bundle with new feature work.

---

## 7. Local-only stragglers on multi-device accounts (= silent desync risk)

These are the things that make the product feel "off" when the user opens iPhone or restarts Mac:

| State | Where it lives | Why it's a problem |
|-------|----------------|--------------------|
| `BlockingProfileManager` profiles | Mac local file | Per Spec 1 D14, kept for one cycle. Cycle is over — pull or formalize. |
| Earned Browse pool | Mac local file | If user gets a new Mac, pool is reset. If they have 2 Macs, they double-earn. |
| iOS Alarms (`PuckAlarm`) | iOS SwiftData | iPhone replacement = lost alarms. |
| iOS per-block app blocklists | iOS App Group UserDefaults | Can't be edited from Mac. |
| Mac per-app distracting list defaults | Mac local | If you add per-app budgeting, this needs to be backend-resident. |
| Strict mode enabled state | Mac local (+ partial backend) | iOS has no view on this. |

If the product direction is "phone is a real device, not a remote," every row above becomes a backend table.

---

## 8. Brainstorm questions to bring to tomorrow's session

These are *product* questions, not implementation. They want to be answered before we touch code.

### Vocabulary
- A1. Final canonical name for the user-facing thing: "Intention" or "Focus Mode"? (Backend table can rename or stay; the question is what the user sees.)
- A2. Final canonical name for the Today-page enforcement wrapper: "Focus Lock" was your latest? Confirm and apply.

### Focus Lock (the wrapper)
- B1. What does the wrapper turn on when ON? Force-a-plan + limiter + default blocking + AI scoring + content safety + strict mode? Or only some? Each as a sub-toggle, or all coupled?
- B2. What does "force-a-plan" mean concretely — block screen until plan exists, full-screen overlay, persistent pill, or auto-open dashboard? What is "a plan" — at least one Time Block scheduled? Specific minutes? Any Intention attached?
- B3. Partner lock: required for OFF only, or required for OFF *and* dropping any sub-toggle? What's the unlock UX (current bedtime-style request, code, what)?
- B4. Does Focus Lock state itself sync cross-device? Or is it per-device (= my Mac has Focus Lock on but my iPhone doesn't)?

### Distractions / Earned Browse v2
- C1. Per-app budget vs overall budget? (Earlier you leaned per-app — confirm.)
- C2. Daily reset, weekly reset, or rolling-window?
- C3. Earning rate: replicate existing EarnedBrowseManager (focus minutes × multiplier × intent bonus), or rethink?
- C4. Out-of-budget behavior: hard block, soft warning, escalating overlay? Same on Mac and iOS?
- C5. Per-app budget configured where — in Distractions tab on Mac? Per-Intention? Global to account? Cross-device sync?
- C6. Does the Mac Earned Browse UI (currently hidden) get re-surfaced or replaced?

### Schedule unification
- D1. One schedule format across Mac + iOS, or keep them divergent? If unified: backend `/schedule/blocks` as canonical, Mac migrates off local format?
- D2. Time blocks edit-from-iPhone, sync to Mac (+ vice versa)?
- D3. Calendar drag-to-create (deferred in v1) — still deferred, or now?

### iOS scope
- E1. Does iPhone ever get full enforcement (Earned Browse, AI scoring), or stays "remote control + bedtime + per-app shield"?
- E2. Alarms — promote to backend table or kill?
- E3. Content Safety on iOS via Screen Time / Family Sharing — pursue or skip?

### Cleanup hard calls
- F1. `BlockingProfileManager` — formally delete or formally promote?
- F2. Weekly Planning page — kill (currently placeholder) or commit to building budgets?
- F3. `/ws/focus` WebSocket — kill or migrate Mac to it from polling?
- F4. `/partner/dashboard/*` — kill all four endpoints?

---

## 9. Recommended brainstorm sequence

1. Read this doc top-to-bottom (~10 min)
2. Spot-check the three inventory files on the parts that surprised you
3. Open a new conversation. Paste this synthesis + your ICP statement (auto memory has it: "ADHD impulse-scroller who can't pre-plan; needs an external executive function he can't override")
4. Run `superpowers:brainstorming` against the §8 question list. Vocabulary first (A1/A2), then Focus Lock (B1–B4), then Distractions (C1–C6), then Schedule (D1–D3), then iOS scope (E1–E3), then cleanup hard calls (F1–F4)
5. Out of that brainstorm, get a single design doc in `docs/superpowers/specs/2026-05-05-…-design.md`
6. From the design doc, plan + execute via `superpowers:writing-plans` + `subagent-driven-development`

This synthesis is the input artifact for step 3. Don't try to brainstorm in the same conversation that produced this doc — start fresh so the new conversation isn't dragging implementation context.

---

**TL;DR:** Three inventories (~1860 lines total) are saved. This synthesis surfaces 4 themes: vocabulary collision, the four "Focus Mode" concepts, three end-to-end bugs (strict-unlock, partner-lock-OFF, force-a-plan), and Mac↔iOS asymmetry. §8 has 21 questions to bring to a fresh brainstorm session. §9 explains how to run that session.

# Close the Noise — Stage 2 of the Deep Work Protocol

**Status:** Approved design. Brainstormed 2026-05-18 with the user. Next step: implementation plan via `superpowers:writing-plans`.

**Parent vision:** [`docs/superpowers/specs/2026-05-18-deep-work-protocol.md`](2026-05-18-deep-work-protocol.md) — read that first if you haven't.

**One-liner:** When a focus session starts, the app automatically stashes browser tabs and hides apps that don't match the user's declared session scope. The point is to eliminate the multitasking trap that starts BEFORE the session — `"while waiting for X, open Y, end up with 30 tabs"`.

---

## Why this is the next stage to build

From the vision doc, the five stages are: Enter → **Prepare** → Engage → Defend → Exit. Stages 3 (Engage) and 4 (Defend) are partially built today. Stage 2 (Prepare / Close the noise) is **the biggest current gap and the user's explicit instinct for what's missing.** Without it, sessions start with the user already drowning in 30 tabs from the prior hour — the rest of the protocol is fighting a losing battle.

## Decisions banked from the brainstorming session

| # | Question | Decision |
|---|---|---|
| 1 | Source of truth for "what's on-scope this session?" | **Hybrid.** Goal-anchored sessions: Intention's saved context (`intentText`, `outcome`) + voice intent additions. Ad-hoc sessions: voice intent only. |
| 2 | What does the sweep DO to off-scope stuff? | **Stash, not close.** Browser tabs → saved to a bookmarks folder. Native apps → `Cmd+H` (hide). No state loss. |
| 3 | When does the sweep fire? | **Automatic at session-start.** No confirmation modal. 30-second toast with one-click "Restore everything" for last-second regret. |
| 4 | What's spared from the sweep regardless? | **Global Always-Allowed list** (lives in Settings, NOT per-Intention). Ships with sensible defaults: 1Password, Apple Music, Spotify, Messages, Calendar, System Settings. User-editable. |
| 5 | Native apps vs browser tabs treatment | **Browser tabs: stash to bookmarks. Native apps: `Cmd+H` (hide, app stays running).** No quitting. |
| 6 | Does the frontmost app get auto-allowed? | **No.** The frontmost app gets no special treatment. If the user starts a session while Twitter is foreground, Twitter gets swept. Resolved scope alone decides. |
| 7 | Per-tab AI judgment vs blanket close-all | **AI per-tab in batch.** Cheap text-Qwen scores all tabs in one batched call against the voice intent. Three-tier decision flow (always-allowed → standing rule → AI). |
| 8 | Standing Rules (existing Block Rules) interaction | **Standing Rules override AI.** If user has Twitter in a block rule, Twitter gets stashed regardless of what the AI thinks. |
| 9 | Stash retention | **3 days, then auto-purge.** Keeps the bookmarks folder from becoming a graveyard. |
| 10 | Toast duration | **30 seconds.** Enough for last-second "wait, restore that" without lingering. |

---

## Architecture

### Data model changes

**New: `Settings.alwaysAllowed`** — global allowlist:
```swift
struct AlwaysAllowedList: Codable {
    var bundleIds: Set<String>   // e.g. ["com.apple.systempreferences", "com.spotify.client", ...]
    var domains: Set<String>     // e.g. ["1password.com", "music.apple.com", ...]
}
```

Lives at `~/Library/Application Support/Intentional/always_allowed.json`. Settings UI under a new section: `Settings → Always Allowed`. Ships with sensible defaults (listed above) populated on first launch.

**Migration:** existing `Intention.allowWebsites` and `Intention.allowBundleIds` values get unioned into the new global list on first launch (one-shot, idempotent receipt at `migration_always_allowed_v1.json`). Then the per-Intention fields are deprecated (kept readable for backwards compat, no longer written). Removed entirely in a follow-up cleanup PR after ≥2 weeks of stability.

**New: `SessionStash`** — what got swept this session:
```swift
struct SessionStash: Codable {
    let sessionId: String
    let createdAt: Date
    let bookmarksFolderId: String?   // Browser bookmarks folder name + browser type
    let hiddenBundleIds: [String]    // Apps that were hidden via Cmd+H
    let stashedTabs: [StashedTab]    // Mirror of what's in bookmarks, for the inspector UI
}

struct StashedTab: Codable {
    let title: String
    let url: String
    let browserBundleId: String      // com.google.Chrome, company.thebrowser.Browser (Arc), etc.
    let originalWindow: Int          // Window index for restore ordering
    let originalIndex: Int           // Tab position within window
}
```

Lives at `~/Library/Application Support/Intentional/session_stashes/<sessionId>.json`. Auto-purge: any stash older than 3 days deleted on app launch + on session-end.

### Scope resolution

```swift
struct ResolvedScope {
    var domains: Set<String>      // Hostnames the sweep should keep
    var bundleIds: Set<String>    // App bundle IDs the sweep should keep
    var voiceIntent: String       // Full transcript, for the AI per-tab call
}

func resolveScope(session: Session) -> ResolvedScope {
    // Start empty.
    var scope = ResolvedScope(domains: [], bundleIds: [], voiceIntent: session.transcript ?? "")

    // Goal-anchored sessions inherit the Intention's saved context. Ad-hoc
    // sessions get no carry-over — voice intent is everything.
    if let intentionId = session.intentionId,
       let intention = IntentionStore.shared.intention(id: intentionId) {
        // intentText + outcome already carry the user's persistent context for the goal.
        // We DON'T re-import the deprecated allowWebsites/allowBundleIds here — those
        // got migrated into the global Always-Allowed list at first launch.
    }

    // Voice intent extras parsed at session start (cheap text-Qwen call):
    //   "I'll be in Cursor + terminal + Chrome (dashboard)" → adds those.
    let extras = parseVoiceIntentForScope(session.transcript ?? "")
    scope.domains.formUnion(extras.domains)
    scope.bundleIds.formUnion(extras.bundleIds)

    return scope
}
```

The global Always-Allowed list is consulted SEPARATELY in the per-tab decision flow — it's not merged into scope, so it can't be accidentally lost or shadowed.

### Sweep algorithm (pseudocode)

```swift
func sweepAtSessionStart(session: Session) {
    let scope = resolveScope(session)
    let alwaysAllowed = SettingsStore.alwaysAllowed
    let activeBlockRules = BlockRuleManager.activeRules

    // 1. Browser tabs
    var allTabs: [(BrowserTab, browserBid: String)] = []
    for browserBid in ["com.google.Chrome", "company.thebrowser.Browser", "com.apple.Safari"] {
        allTabs += readAllTabs(forBrowser: browserBid).map { ($0, browserBid) }
    }
    let tabDecisions = decideTabsBatched(allTabs, scope: scope, voiceIntent: session.transcript,
                                          alwaysAllowed: alwaysAllowed, blockRules: activeBlockRules)
    let toStash = tabDecisions.filter { $0.decision == .stash }
    persistTabStash(toStash, sessionId: session.id)
    closeTabsByURL(toStash.map { $0.tab.url })

    // 2. Native apps
    let runningApps = NSWorkspace.shared.runningApplications.filter { !$0.activationPolicy.isSystem }
    let appDecisions = runningApps.map { app -> (NSRunningApplication, AppDecision) in
        if alwaysAllowed.bundleIds.contains(app.bundleIdentifier ?? "") { return (app, .keep) }
        if activeBlockRules.matches(bundleId: app.bundleIdentifier) { return (app, .hide) }
        if scope.bundleIds.contains(app.bundleIdentifier ?? "") { return (app, .keep) }
        // Voice intent didn't name this app — AI not used for apps at sweep time; default to hide
        return (app, .hide)
    }
    persistAppStash(appDecisions, sessionId: session.id)
    hideApps(appDecisions.filter { $0.1 == .hide }.map { $0.0 })

    // 3. Toast
    showToast(stashedTabCount: toStash.count, hiddenAppCount: appDecisions.filter { $0.1 == .hide }.count,
              undoWindowSeconds: 30, sessionId: session.id)
}
```

### Decision logic per tab (three-tier flow)

```
For each open tab:
  if tab is pinned                                          → keep
  if domain in alwaysAllowed.domains                        → keep
  if domain matches a BlockRule that is currently enforcing → stash (overrides AI)
  if domain in scope.domains                                → keep
  otherwise → batch into AI call
```

"Currently enforcing" means the BlockRule's toggle is ON AND (if it has a schedule) we're inside its scheduled window. Inactive / snoozed rules don't trigger the sweep.

The AI call is a single text-Qwen prompt that contains:
- Voice intent transcript (~100–300 words)
- A JSON array of tabs: `[{ "title": "...", "url": "..." }, ...]`
- Instruction: *"For each tab, return `{relevant: bool, confidence: 0-100}`. Use only the user's intent and the tab's title/URL to decide."*

Output parsed back into per-tab verdicts. `relevant: true` keeps the tab; `relevant: false` stashes it; unparseable / unsure → default-stash (recoverable).

**Performance:** ~30 tabs in one call = ~3–5s on Qwen3-4B-text. Acceptable for a once-per-session operation. If batching breaks down at very high N (>100 tabs), split into multiple batches of 30.

### Browser tab stashing via AppleScript

For each browser we already do `readActiveTabInfo` — extend to:
- **Read all tabs across all windows** (existing API: `tell application "Google Chrome" to get every tab of every window`).
- **Save to bookmarks**: each browser supports an AppleScript dictionary call to create a bookmark folder and add entries (`make new bookmark folder ... with properties {name: "Intentional / Stash 2026-05-18 14:30"}`).
- **Close tabs by URL**: AppleScript loop to close any tab whose URL matches the stashed list.

### Native app hiding

`NSRunningApplication.hide()` is the public API. Equivalent to Cmd+H. App stays running, state preserved, recoverable via Cmd+Tab.

### Toast UX

`DeepWorkTimerController` already manages a floating pill. Add a transient toast mode:
- Position: top-right, below the pill if one is showing
- Duration: 30s with countdown ring
- Buttons: `[View stash]` → small inspector window; `[Restore everything]` → reverses the sweep
- Auto-dismisses after 30s; "Restore everything" still possible from Stage 5 review at session-end

### Settings page: Always Allowed

New section in `dashboard.html` Settings sidebar item, between "Distractions" and "Sensitive Content":
- Two lists: **Apps** (paginated app picker + delete) and **Websites** (text input for domain, delete).
- Pre-populated with defaults on first launch.
- Search box at top.
- Per-row: app icon / favicon, name, "Remove" button.

Wired to `SAVE_ALWAYS_ALLOWED` bridge message (write) + `GET_ALWAYS_ALLOWED` (read).

---

## What's out of scope for this spec

These belong to OTHER specs/brainstorming sessions, not this one:

- **Stage 1 voice recording UX** (forced declaration of intent) — separate spec, currently deferred per user.
- **Stage 3 AI scoring cadence** (every 3s, every 10s, etc.) — separate spec, in progress.
- **Stage 4 Defend tiers** (notify / soft-close / hard-block during the session) — depends on this spec landing first since they reuse the resolved-scope concept.
- **Stage 5 Exit review** (the tab graveyard at session-end) — separate spec; partial preview in this doc just for the "restore" UX integration.
- **Google Calendar sync** for ad-hoc-mode (employee user shape) — follow-up after v1.
- **Cross-device propagation** of the always-allowed list — local-only for v1, syncs follow.

## Open questions (resolve in implementation plan, not this spec)

- **Browser support for v1**: ship with Chrome + Arc only (the two we already have AppleScript working for), or also Safari + Firefox + Edge? Recommendation: Chrome + Arc only for v1; Safari is the next-easiest add but it has stricter sandboxing.
- **Per-window vs per-tab decision**: the AI call gets `(title, url)` per tab. If a browser window has 20 tabs and 19 are scored as "stash", do we close the whole window? Recommendation: tab-level only; window stays open if any tab survives.
- **Sweep timing relative to ritual**: when does the sweep run — before or after the existing block start ritual? Recommendation: AFTER the ritual completes, BEFORE the timer starts, so user has consciously chosen to start before their tabs get swept.

These get resolved during writing-plans, not now.

---

## Success criteria

The implementation is done when:

1. User starts a focus session (any source — schedule, manual, voice-declared)
2. Within 5 seconds of session start, all off-scope browser tabs are stashed to a dated bookmarks folder
3. Within 5 seconds, all off-scope non-allowed native apps are hidden
4. A toast appears for 30s with "View stash" + "Restore everything" actions, both functional
5. Always-allowed list never gets touched
6. Standing Rules (active block rules) always stash regardless of AI verdict
7. End of session: stash list visible in Stage 5 review (or in `Settings → Stash History` if Stage 5 isn't built yet)
8. After 3 days, old stashes get auto-purged from disk
9. Existing `Intention.allowWebsites` / `allowBundleIds` data is preserved by being migrated into the global list once

All testable manually + via Playwright/E2E once integrated.

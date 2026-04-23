# Projects (Intention-Driven Sessions)

## Overview

Projects are the user's durable intention containers — a named project carries an intention string, an optional per-project allow-list, a set of referenced blocklists, and a history of focus sessions with a 14-day minutes sparkline. A project session is a FocusBlock that the app tags with `activeProjectId` so that downstream scorers and enforcement can reason about "is this content related to what the user said they'd work on". This PR1 scope delivers the data model, the dashboard UI, and start-session wiring (immediate / queued / refused). **PR2 wires the relevance scorer** to consult `project.allowed` / `project.learned` / `LearnedSite.isPromoted` and to side-effect `hitCount` on score-misses.

## Data Model

Defined in `Intentional/ProjectStore.swift` (see line numbers for the source of truth).

| Type | Purpose |
|------|---------|
| `Project` (L40) | Top-level record: `id`, `name`, `intention`, `accent`, `allowed`, `learned`, `blocklistIds`, `allowSearchEnginesForThisProject`, `createdAt`, `updatedAt`, `lastUsedAt`, `sessions`, `weekMinutes`, `weeklyAnchor` |
| `HostItem` (L7) | Per-project allow-list entry: `id`, `kind` (`.domain` or `.appBundleId`), `value`, optional `note` |
| `SessionEntry` (L14) | One focus session: `id`, `startedAt`, `endedAt`, `durationSec`, `focusScore`, `blockId` |
| `LearnedSite` (L23) | Candidate allow-list site discovered during scoring: `id`, `host`, `hitCount`, `lastSeenAt`, `isPromoted` |
| `ProjectSummary` (L61) | Read-model for the Index grid. Adds `humanLastUsed` and `totalHours` derived from `sessions` |
| `ProjectPatch` (L74) | Partial-update struct passed to `update(id:patch:)` |

**Caps and invariants:**
- `intention` is truncated to `intentionCap = 140` chars on create/update.
- `sessions` is capped at the last `sessionsCap = 20` entries after each `recordSessionStart`.
- `weekMinutes` has exactly `weekLength = 14` entries; index 13 is today. On `recordSessionEnd`, `advanceWeekly(_:from:to:)` lazily shifts the window based on the calendar-day delta between `weeklyAnchor` and now, then the finished session's minutes are added to slot 13. Gaps ≥ 14 days zero the whole window.
- `accent` is drawn at create time from `accentPalette = ["#E87461", "#F0B060", "#8ea0b8", "#7fb39a"]` via `projects.count % palette.count`.
- `blocklistIds` is deduplicated on both `create` and `update` via `dedupe(_:)`.

## Persistence

- File: `~/Library/Application Support/Intentional/projects.json`
- Encoding: pretty-printed JSON with sorted keys, `.iso8601` dates on **both** encode and decode. (The prior-revision bug was an asymmetric strategy — don't repeat it.)
- Writes are atomic (`Data.write(to:options:.atomic)`).
- Decode failure falls back to an empty array and logs, so a corrupt file doesn't prevent app launch.

## Actor API (`ProjectStore`)

All methods are `async` because `ProjectStore` is an `actor`.

| Method | Purpose |
|--------|---------|
| `list()` | All `Project` records |
| `listSummary()` | `[ProjectSummary]` for the Index grid |
| `get(id:)` | One project or nil |
| `projectsReferencing(blocklistId:)` | Projects whose `blocklistIds` contains the given UUID — used by the blocklist-delete guard |
| `create(name:intention:allowed:blocklistIds:allowSearchEngines:)` | Create, assign accent, persist, return new `Project` |
| `update(id:patch:)` | Apply a `ProjectPatch`, bump `updatedAt`, persist, return updated `Project` |
| `delete(id:)` | Remove by id, persist |
| `recordSessionStart(projectId:blockId:)` | Append an open `SessionEntry`, cap to 20, bump `lastUsedAt`, return session id |
| `recordSessionEnd(projectId:sessionId:focusScore:)` | Finalize the session, shift the weekly window, bucket minutes into slot 13 |
| `recordLearnedHit(projectId:host:)` | Upsert a `LearnedSite` (increments `hitCount`, refreshes `lastSeenAt`) |
| `promoteLearnedSite(projectId:host:)` | Flip `isPromoted = true` and append a `.domain` `HostItem` to `allowed` if not already present |

## Bridge Messages (Dashboard ↔ Swift)

All routed through `MainWindow.handleMessage` (switch cases at `MainWindow.swift` L464–L499). Handlers live under `// MARK: - Projects Handlers` starting at L2245. Responses are delivered via `callJS` onto `window.on*` callbacks.

| Message (JS → Swift) | Payload | Response callback |
|----------------------|---------|-------------------|
| `GET_PROJECTS` | — | `window.onProjectsList([ProjectSummary])` |
| `GET_PROJECT_DETAIL` | `{id}` | `window.onProjectDetail(Project)` (or `null` if missing) |
| `CREATE_PROJECT` | `{name, intention, allowed[], blocklistIds[], allowSearchEngines}` | `window.onProjectDetail(Project)` |
| `UPDATE_PROJECT` | `{id, patch: {name?, intention?, accent?, allowed?, blocklistIds?, allowSearchEngines?}}` | `window.onProjectDetail(Project)` |
| `DELETE_PROJECT` | `{id}` | `window.onProjectsList([ProjectSummary])` (refreshed index) |
| `PROMOTE_LEARNED_SITE` | `{id, host}` | `window.onProjectDetail(Project)` |
| `START_PROJECT_SESSION` | `{id, durationMins}` (bounded 1–240) | `window.onProjectSessionResult({status, blockId?, projectId?, startMinutes?, endMinutes?, reason?})` |

JSON serialization for the detail/list payloads uses `projectsJSONEncoder()` (`MainWindow.swift` L2483) with `.iso8601` dates — matches `ProjectStore` persistence.

## Start-Session Semantics (Queue / Immediate / Refuse)

`handleStartProjectSession` (`MainWindow.swift` L2361) computes a proposed `[proposedStart, proposedEnd)` window in minutes-from-midnight, then branches:

1. **Immediate.** No `currentBlock` → `proposedStart = nowMinutes`. The app inserts a new `focusHours` FocusBlock titled `"Project: {name}"` with `description = project.intention`, awaits `ProjectStore.recordSessionStart` (so a persistence failure doesn't silently leak a `started` response), then calls `appDelegate.setActiveProjectSession(projectId:blockId:)` and emits `{status: "started", blockId, projectId, startMinutes, endMinutes}`.
2. **Queued.** A `currentBlock` exists → `proposedStart = currentBlock.endMinutes`. If no collision and not past midnight, the new block is inserted via `scheduleManager.addBlock` but no active session is set (the session will be activated when the block becomes current — see *Known Deferrals*). Emits `{status: "queued", …}`.
3. **Refused.** Returned with a `reason` string when: invalid payload (missing id or duration outside 1–240), project not found, `proposedEnd > 24*60` (past midnight), or a future scheduled block starts before `proposedEnd` (collision). No state is mutated.

The immediate vs queued decision does not consider the block's `blockType` — any active block defers the new session.

## Blocklist Deletion Guard

`handleDeleteBlockingProfile` (`MainWindow.swift` L2225) asks `ProjectStore.projectsReferencing(blocklistId:)` before calling `BlockingProfileManager.deleteProfile`. If any project references the blocklist, deletion is refused and the dashboard is notified via `window.onBlockingProfileDeleteRefused({id, referencedBy: [name]})` so the UI can surface which projects need to be edited first. Only when `referencing` is empty does deletion proceed.

## AppDelegate Wiring

Declared in `AppDelegate.swift`:
- `var projectStore: ProjectStore?` — the actor, initialized at init slot **11a**, right after `EarnedBrowseManager`.
- `private(set) var activeProjectSession: (projectId: UUID, blockId: String)?` — single tuple so the pair can't drift.
- `func setActiveProjectSession(projectId:blockId:)` / `clearActiveProjectSession()` — the only way to mutate it.
- `var activeProjectId: UUID?` — computed convenience for readers that only need the project id.

Transient state lives on the delegate (not as a field on `FocusBlock`) because a session's project identity is a runtime binding, not part of the persisted schedule. `FocusBlock`s are edited, duplicated, and resurfaced across dashboard round-trips; hanging project identity off the delegate keeps the schedule storage pure.

**Clearing rule.** Inside `scheduleManager.onBlockChanged`, when the active block's id no longer matches `activeProjectSession?.blockId`, the tuple is cleared via `clearActiveProjectSession()`. This covers natural block end, user-edited schedule, and skipped transitions.

## Known Deferrals / Follow-ups

1. **Queued-block activation.** `handleStartProjectSession` inserts the FocusBlock for a queued session but never activates the project when that block later becomes current — `activeProjectSession` stays nil and no `SessionEntry` is created. The fix is to register the pending `(projectId, blockId)` pair and, on `ScheduleManager.onBlockChanged`, call `setActiveProjectSession` + `ProjectStore.recordSessionStart`.
2. **PR2 — relevance scorer integration.** The scorer does not yet consult `project.allowed`, `project.learned`, or `LearnedSite.isPromoted` when `activeProjectId` is set. PR2 scope: on a score-miss for an active project, call `recordLearnedHit(projectId:host:)` so the site accumulates a `hitCount` and can surface in the UI for manual promotion; on a score-pass, favor hosts already present in `allowed` before hitting the LLM path. See `docs/AI_SCORING.md` for the pipeline this plugs into.
3. **Session end.** `recordSessionEnd` is defined but not yet called by the FocusBlock lifecycle. It lands in PR2 alongside scorer integration so `focusScore` has a value to carry.

## UI Structure (Brief)

The dashboard Projects page lives in `Intentional/dashboard.html` and is driven by a `ProjectsController` IIFE.

- **Sidebar entry.** ◎ glyph, routes to the Projects page.
- **Three sub-views.**
  - *Index grid* — one card per `ProjectSummary` with accent stripe, intention, last-used, weekly sparkline, and a start-session button.
  - *Setup form* — new/edit, fields for name, intention (140-char capped), per-project allowed hosts, blocklist multi-select, `allowSearchEnginesForThisProject` toggle.
  - *Project Dashboard* — full-detail view with the 14-bucket sparkline, sessions history, and learned-site promotion chips.
- **Accent palette.** `["#E87461", "#F0B060", "#8ea0b8", "#7fb39a"]`. Assigned on create; editable via `ProjectPatch.accent`.
- **Sparkline.** 14 buckets aligned to the 14-element `weekMinutes`; the lazy-shift logic in `ProjectStore.advanceWeekly` ensures index 13 is always "today" on the next `recordSessionEnd`, so the JS side never has to reason about calendar rollovers.

## Related Docs

- [AI_SCORING.md](AI_SCORING.md) — where `project.allowed` / `project.learned` plug in (PR2).
- [EXTENSION_PROTOCOL.md](EXTENSION_PROTOCOL.md) — dashboard-bridge message style this doc's tables follow.
- [CALENDAR_BLOCK_RULES.md](CALENDAR_BLOCK_RULES.md) — constraints on inserting/editing the FocusBlock a project session creates.

# Prototype → Production — Mac Implementation Plan (Plan B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the May 2026 prototype's Weekly-Goal-vocab + Monthly-Goal hierarchy + Plan tab to the production Mac app. Extends `IntentionStore` with new fields (no rename), creates a new `MonthlyGoalStore` actor that mirrors the same pattern, wires new `MainWindow` bridge handlers, and orchestrates the embedded React Plan tab + new Today goal cards + new full-page Weekly Goal editor on the dashboard side.

**Architecture:** The Swift type `Intention` and store `IntentionStore` keep their names internally; we just extend them with the new wire fields from Plan A migration 026. A NEW `MonthlyGoalStore` actor (parallel implementation of `IntentionStore`) handles monthly goals: cache at `~/Library/Application Support/Intentional/monthly_goals.json`, sync on launch / didBecomeActive / 60s timer, push silent APNs handled server-side. `MainWindow` gains 5 new bridge messages (`GET_MONTHLY_GOALS`, `CREATE_MONTHLY_GOAL`, `UPDATE_MONTHLY_GOAL`, `DELETE_MONTHLY_GOAL`, `LINK_WEEKLY_TO_MONTHLY`) plus extends `emitIntentionsList` to ship the new fields. `START_GOAL_SESSION` is an alias of the existing `START_INTENTION_SESSION` with optional `monthly_goal_id` for analytics. **Plan tab (Cloud Design React app from `docs/unified-design-2026-05-13/app.html`) is embedded verbatim into `dashboard.html` — no SwiftUI work.**

**Tech Stack:** Swift 5.9+, AppKit, WKWebView, actor-based stores, URLSession, JSON `Date` decoding via existing patterns.

**Source-of-truth brief:** `docs/prototype-to-production-2026-05-14.md`.

**Worktree:** `/Users/arayan/Documents/GitHub/intentional-macos-app/.claude/worktrees/prototype-to-production` on branch `feat/prototype-to-production` from `main` (or current dev integration branch — verify with user during Task 0).

**Backend dependency:** Sibling Plan A in `intentional-backend`. Schema + endpoints must be deployed to staging before Phase 3 of this plan ships. Phases 1–2 (model + store skeletons) can land first behind unused code paths.

**Cross-repo log:** `docs/cross-repo-prototype-to-production-2026-05-14.md` (Task 0 creates).

---

## Open questions for the user (consolidated — shared with Plans A + C)

These do NOT block start, but inform Phase 3 acceptance:

1. **Drag-from-Plan-into-Today day target.** If user drags a weekly goal from the Plan-tab Timeline strip onto an hour, does the session create on **today's date** or **the date the Plan-tab is viewing**? Default in this plan: **today** (matches prototype's "Today · Wednesday" subhead).
2. **Goal → session strictness binding.** When `start_intention_session` carries a `monthly_goal_id`, is monthly-goal strictness ignored (weekly goal owns strictness) or aggregated? Default: **weekly goal owns strictness; monthly_goal_id is analytics-only**.
3. **AI scoring fallback.** When `ai_scoring_enabled=false` on the active intention, does `RelevanceScorer` skip entirely (treat all as relevant) or fall back to keyword-only? Default: **skip entirely → all activity is treated as relevant during that goal's session**.
4. **Allow-list override of global blocks.** When a goal's `allow_websites` contains a site that a globally-active Time Block would block, does the allow-list win during that goal's session? Default: **yes — allow wins** (matches prototype copy).
5. **Migration of existing `description` field.** Old Intention.description is used for AI scoring globally. New `intent_text` is per-goal. On first launch post-upgrade, do we copy `description` → `intent_text`? Default: **yes, one-time copy** if `intent_text` is empty; gated by a migration receipt file.

---

## What this plan does NOT do

- Does not rename the `Intention` Swift type or `IntentionStore` actor.
- Does not change `FocusModeController` / `FocusMonitor` / `BlockingProfileManager`.
- Does not implement block-conflict warning popup (brief item E — deferred).
- Does not implement calendar drag-to-create / edge-resize / move (still deferred per CLAUDE.md #14).
- Does not implement cross-week goal carry-over.
- Does not implement AI-scoring-toggle wiring into `RelevanceScorer` — the toggle persists, but Phase 3 of this plan ships the UI without enforcement plumbing; a follow-up "AI scoring enable/disable wire-up" plan lands separately (call it out in the dashboard so user knows it's a setting that will activate next ship).
- Does not implement budget enforcement (D9 fields still un-enforced).
- Does not change the existing `/focus/active` polling, FocusStatePoller, or session/state ownership.

---

## File map

| File | Op | Purpose |
|---|---|---|
| `Intentional/Intention.swift` | MODIFY | Add 9 new fields: `outcome`, `status`, `weeklyTargetHours`, `intentText`, `aiScoringEnabled`, `allowWebsites`, `allowBundleIds`, `monthlyGoalId`, `weekOf`. Extend tolerant decoder. Update CreatePayload + UpdatePayload. |
| `Intentional/MonthlyGoal.swift` | CREATE | New `MonthlyGoal` struct + Create/Update payloads + List response — mirrors `Intention.swift` pattern. |
| `Intentional/MonthlyGoalStore.swift` | CREATE | Actor + cache mirroring `IntentionStore`. Disk cache at `monthly_goals.json`. Pull/create/update/delete via `BackendClient`. 60s sync timer + didBecomeActive trigger. |
| `Intentional/BackendClient.swift` | MODIFY | Add `getMonthlyGoals`, `getMonthlyGoal`, `createMonthlyGoal`, `updateMonthlyGoal`, `deleteMonthlyGoal`, `linkWeeklyToMonthly`. Extend existing intention create/update to send new fields. Add `?week=` param to `getIntentions`. |
| `Intentional/IntentionStore.swift` | MODIFY | Pass-through of new fields on create/update. No new methods needed (just round-trip). |
| `Intentional/MainWindow.swift` | MODIFY | Bridge handlers: `GET_MONTHLY_GOALS`, `GET_MONTHLY_GOAL`, `CREATE_MONTHLY_GOAL`, `UPDATE_MONTHLY_GOAL`, `DELETE_MONTHLY_GOAL`, `LINK_WEEKLY_TO_MONTHLY`. Update `intentionToDict` + `emitIntentionsList` to ship new fields. Add `START_GOAL_SESSION` as alias. Push `_monthlyGoalsList` to dashboard on sync. |
| `Intentional/AppDelegate.swift` | MODIFY | Initialize `MonthlyGoalStore.shared` after `intentionStore`. Wire `MainWindow.monthlyGoalStore`. Start sync timer. One-time `intent_text` migration (description → intent_text) gated by receipt file. |
| `Intentional/IntentTextMigration.swift` | CREATE | One-shot migration copying `Intention.description` → `intentText` when `intentText.isEmpty`. Idempotent via receipt at `~/Library/Application Support/Intentional/migration_intent_text_v1.json`. |
| `Intentional/dashboard.html` | MODIFY | See Plan C (companion). This file lists the Swift-side bridge contracts; the JS-side rendering lives in Plan C. |
| `CLAUDE.md` | MODIFY | New section under "Intentions (Spec 1, May 2026)": "Weekly Goal / Monthly Goal model (May 14, 2026)". Document new fields + new store + new bridge messages. |

Approximate change footprint: ~700 lines net added across Swift + dashboard glue.

---

## Phase 0: Worktree + cross-repo log

### Task 0: Worktree + initial commit + cross-repo log

- [ ] **Step 0.1: Create worktree**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git fetch
git worktree add -b feat/prototype-to-production .claude/worktrees/prototype-to-production main
cd .claude/worktrees/prototype-to-production
git status
git log --oneline -5
```

If `main` is not the right base (e.g. an integration branch is more up-to-date), confirm with user before proceeding. Expected: clean worktree.

- [ ] **Step 0.2: Build to verify base health**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`. If not, stop and fix the base before continuing.

- [ ] **Step 0.3: Create cross-repo log**

Create `docs/cross-repo-prototype-to-production-2026-05-14.md` with the standard cross-repo template (mirror `docs/cross-repo-scheduled-intentions-redesign-2026-05-04.md`). Sections: Goal, Scope, Plans (A backend / B Mac / C dashboard), Status, Decisions, Follow-ups.

- [ ] **Step 0.4: Initial commit**

```bash
git add docs/cross-repo-prototype-to-production-2026-05-14.md
git commit -m "feat(goals): start prototype-to-production work

Per docs/prototype-to-production-2026-05-14.md and Plans A/B/C dated 2026-05-14."
```

---

## Phase 1: Model + payload extensions (independently mergable — fields ride existing Spec 3 tolerant decoder)

### Task 1: Extend `Intention.swift` with 9 new fields

**Files:**
- Modify: `Intentional/Intention.swift` (struct `Intention` and the payload structs)

- [ ] **Step 1.1: Add fields to `Intention`**

After the existing Spec 3 properties (`budgetEnforcement` at ~line 64), add:

```swift
    // May 2026 prototype → production (weekly-goal vocab):
    /// "Done looks like" — free text. Stored on backend; surfaced in editor.
    var outcome: String?
    /// Lifecycle status. `planned | in_progress | done | slipped | dropped`.
    var status: GoalStatus
    /// Weekly hour target. Surfaced in editor + Plan-tab cards.
    var weeklyTargetHours: Double?
    /// Per-goal AI-scoring text (≤140 chars). Drives `RelevanceScorer` when
    /// `aiScoringEnabled` is true.
    var intentText: String?
    /// Per-goal AI-scoring toggle.
    var aiScoringEnabled: Bool
    /// Per-goal Allow list (sites). Wins against globally-active blocks
    /// during this goal's sessions (per brief D / open Q 4 default).
    var allowWebsites: [String]
    /// Per-goal Allow list (app bundle ids).
    var allowBundleIds: [String]
    /// Optional FK → MonthlyGoal. Nullable for "unlinked" weekly goals.
    var monthlyGoalId: UUID?
    /// ISO date string (Monday) the goal belongs to. Nullable = unscheduled.
    var weekOf: String?
```

Add an enum near the top of the file (next to `StrictnessPreset`):

```swift
/// Lifecycle status of a weekly goal. Single enum is reused for monthly goals.
enum GoalStatus: String, Codable, Equatable {
    case planned
    case inProgress = "in_progress"
    case done
    case slipped
    case dropped
}
```

Append the 9 fields to the `CodingKeys`:

```swift
        case outcome
        case status
        case weeklyTargetHours = "weekly_target_hours"
        case intentText = "intent_text"
        case aiScoringEnabled = "ai_scoring_enabled"
        case allowWebsites = "allow_websites"
        case allowBundleIds = "allow_bundle_ids"
        case monthlyGoalId = "monthly_goal_id"
        case weekOf = "week_of"
```

- [ ] **Step 1.2: Extend the memberwise `init`**

Add all 9 parameters to the existing `init(...)` (defaults: `outcome: nil`, `status: .planned`, `weeklyTargetHours: nil`, `intentText: nil`, `aiScoringEnabled: true`, `allowWebsites: []`, `allowBundleIds: []`, `monthlyGoalId: nil`, `weekOf: nil`). Assign each.

- [ ] **Step 1.3: Extend the tolerant `init(from:)`**

In the custom decoder (currently ends at line 138 with `budgetEnforcement`), append:

```swift
        self.outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        self.status = try c.decodeIfPresent(GoalStatus.self, forKey: .status) ?? .planned
        self.weeklyTargetHours = try c.decodeIfPresent(Double.self, forKey: .weeklyTargetHours)
        self.intentText = try c.decodeIfPresent(String.self, forKey: .intentText)
        self.aiScoringEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiScoringEnabled) ?? true
        self.allowWebsites = try c.decodeIfPresent([String].self, forKey: .allowWebsites) ?? []
        self.allowBundleIds = try c.decodeIfPresent([String].self, forKey: .allowBundleIds) ?? []
        // monthly_goal_id arrives as String? from JSON; UUID conversion is lenient.
        if let s = try c.decodeIfPresent(String.self, forKey: .monthlyGoalId), let u = UUID(uuidString: s) {
            self.monthlyGoalId = u
        } else {
            self.monthlyGoalId = nil
        }
        self.weekOf = try c.decodeIfPresent(String.self, forKey: .weekOf)
```

- [ ] **Step 1.4: Mirror to `IntentionCreatePayload`**

In the same file, find `struct IntentionCreatePayload` (line 142). Append the same 9 fields. Use the same defaults. Use the same `CodingKeys` snake-case mappings. Note: `monthlyGoalId` serializes as `String?` (UUID `.uuidString`).

- [ ] **Step 1.5: Mirror to `IntentionUpdatePayload`**

Same — append 9 fields to `struct IntentionUpdatePayload` (line 163). Keep `version: Int` required.

- [ ] **Step 1.6: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/Intention.swift
git commit -m "feat(goals): extend Intention with weekly-goal fields"
```

Expected: `BUILD SUCCEEDED`. If a callsite to the memberwise `init` breaks (defaults should prevent this), fix the callsite with explicit defaults.

**Acceptance criteria:**
- All 9 new fields decode from a server payload that includes them.
- A server payload without any of them still decodes (defaults applied).
- Existing callsites compile without modification.

---

### Task 2: Create `MonthlyGoal.swift`

**Files:**
- Create: `Intentional/MonthlyGoal.swift`

- [ ] **Step 2.1: Write the model file**

```swift
// MonthlyGoal.swift
//
// Cross-device account-scoped monthly goal. Companion to Intention (weekly
// goal). Goals are user-defined targets for the calendar month. Weekly goals
// link to one monthly goal (nullable FK).
//
// Server: monthly_goals table (migration 026). Sibling-shared via account_id.
//
// JSON shape on wire matches backend snake_case via CodingKeys.

import Foundation

struct MonthlyGoal: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var outcome: String?
    var colorHex: String?
    /// ISO date (first-of-month), e.g. `2026-05-01`. Authoritative month anchor.
    var monthOf: String
    var status: GoalStatus
    var version: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, title, outcome, version
        case colorHex = "color_hex"
        case monthOf = "month_of"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    init(id: UUID, title: String, outcome: String? = nil, colorHex: String? = nil,
         monthOf: String, status: GoalStatus = .planned, version: Int = 1,
         createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.title = title; self.outcome = outcome
        self.colorHex = colorHex; self.monthOf = monthOf; self.status = status
        self.version = version; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        self.colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        self.monthOf = try c.decode(String.self, forKey: .monthOf)
        self.status = try c.decodeIfPresent(GoalStatus.self, forKey: .status) ?? .planned
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

struct MonthlyGoalCreatePayload: Codable, Equatable {
    var title: String
    var outcome: String?
    var colorHex: String?
    var monthOf: String  // YYYY-MM-01
    var status: GoalStatus = .planned

    private enum CodingKeys: String, CodingKey {
        case title, outcome, status
        case colorHex = "color_hex"
        case monthOf = "month_of"
    }
}

struct MonthlyGoalUpdatePayload: Codable, Equatable {
    var title: String
    var outcome: String?
    var colorHex: String?
    var monthOf: String
    var status: GoalStatus
    var version: Int

    private enum CodingKeys: String, CodingKey {
        case title, outcome, status, version
        case colorHex = "color_hex"
        case monthOf = "month_of"
    }
}

struct MonthlyGoalListResponse: Codable {
    let monthlyGoals: [MonthlyGoal]
    private enum CodingKeys: String, CodingKey { case monthlyGoals = "monthly_goals" }
}
```

- [ ] **Step 2.2: Add the file to the Xcode project**

Open `Intentional.xcodeproj` in Xcode and add `MonthlyGoal.swift` to the `Intentional` target.

- [ ] **Step 2.3: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/MonthlyGoal.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(goals): MonthlyGoal model + payloads"
```

---

## Phase 2: Store + backend client (independently mergable — no UI consumer yet)

### Task 3: `BackendClient` — extend `getIntentions` + create/update; add MonthlyGoal CRUD

**Files:**
- Modify: `Intentional/BackendClient.swift`

- [ ] **Step 3.1: Add `?week=` parameter to `getIntentions`**

Find the existing `getIntentions(includeDeleted:)` method. Add an optional `week: String? = nil` parameter. If non-nil, append `&week=YYYY-MM-DD` to the URL.

- [ ] **Step 3.2: Extend create/update payload encoding**

Since `IntentionCreatePayload` + `IntentionUpdatePayload` already carry the new fields via Task 1, no method change needed — verify the existing JSON encoder serializes them.

- [ ] **Step 3.3: Add 5 MonthlyGoal methods**

Append to the file:

```swift
// MARK: - Monthly Goals (May 2026)

extension BackendClient {
    func getMonthlyGoals(month: String? = nil) async -> [MonthlyGoal]? {
        var url = baseURL.appendingPathComponent("monthly_goals")
        if let m = month {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.queryItems = [URLQueryItem(name: "month", value: m)]
            if let u = c?.url { url = u }
        }
        var req = URLRequest(url: url)
        addAuthHeaders(&req)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try Self.jsonDecoder.decode(MonthlyGoalListResponse.self, from: data)
            return decoded.monthlyGoals
        } catch {
            return nil
        }
    }

    func getMonthlyGoal(id: UUID) async -> MonthlyGoal? {
        let url = baseURL.appendingPathComponent("monthly_goals/\(id.uuidString)")
        var req = URLRequest(url: url)
        addAuthHeaders(&req)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try Self.jsonDecoder.decode(MonthlyGoal.self, from: data)
        } catch { return nil }
    }

    func createMonthlyGoal(_ payload: MonthlyGoalCreatePayload) async throws -> MonthlyGoal {
        let url = baseURL.appendingPathComponent("monthly_goals")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        addAuthHeaders(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.jsonEncoder.encode(payload)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw IntentionError.network("Create monthly goal failed: \(resp)")
        }
        return try Self.jsonDecoder.decode(MonthlyGoal.self, from: data)
    }

    func updateMonthlyGoal(id: UUID, payload: MonthlyGoalUpdatePayload) async throws -> MonthlyGoal {
        let url = baseURL.appendingPathComponent("monthly_goals/\(id.uuidString)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        addAuthHeaders(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.jsonEncoder.encode(payload)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw IntentionError.network("Update monthly goal: bad response")
        }
        if http.statusCode == 409 {
            // version conflict — surface with current server version like Intention path
            let body = try? Self.jsonDecoder.decode([String: String].self, from: data)
            throw IntentionError.versionConflict(currentServerVersion: 0) // we don't parse from msg yet; refresh-then-retry pattern
        }
        guard http.statusCode == 200 else {
            throw IntentionError.network("Update monthly goal failed: \(http.statusCode)")
        }
        return try Self.jsonDecoder.decode(MonthlyGoal.self, from: data)
    }

    func deleteMonthlyGoal(id: UUID) async -> Bool {
        let url = baseURL.appendingPathComponent("monthly_goals/\(id.uuidString)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        addAuthHeaders(&req)
        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return http.statusCode == 204
        } catch { return false }
    }
}
```

(`addAuthHeaders`, `baseURL`, `session`, `jsonEncoder`, `jsonDecoder` are already on `BackendClient` — verify names match the existing pattern. If `Self.jsonDecoder`/`jsonEncoder` aren't statics, switch to the instance properties.)

- [ ] **Step 3.4: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/BackendClient.swift
git commit -m "feat(goals): BackendClient MonthlyGoal CRUD + Intention week filter"
```

---

### Task 4: `MonthlyGoalStore.swift` (actor mirroring `IntentionStore`)

**Files:**
- Create: `Intentional/MonthlyGoalStore.swift`

- [ ] **Step 4.1: Read `IntentionStore` for the pattern**

```bash
head -100 Intentional/IntentionStore.swift
```

Copy the structure (singleton, `wire(backend:appDelegate:)`, on-disk cache, `pull()`, `startSyncTimer()`).

- [ ] **Step 4.2: Write the actor**

```swift
// MonthlyGoalStore.swift
//
// Actor-isolated store for MonthlyGoal records, backed by local disk cache and
// the backend's /monthly_goals endpoints. Mirrors IntentionStore.

import Foundation

actor MonthlyGoalStore {
    static let shared = MonthlyGoalStore()

    private weak var backend: BackendClient?
    private weak var appDelegate: AppDelegate?
    private var byId: [UUID: MonthlyGoal] = [:]
    private var syncTimer: Timer?

    private let fileURL: URL = {
        let support = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Intentional", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("monthly_goals.json")
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private init() {
        loadFromDisk()
    }

    func wire(backend: BackendClient, appDelegate: AppDelegate) {
        self.backend = backend
        self.appDelegate = appDelegate
    }

    func active() -> [MonthlyGoal] {
        byId.values.filter { $0.deletedAt == nil }.sorted { $0.monthOf < $1.monthOf }
    }

    func goal(id: UUID) -> MonthlyGoal? { byId[id] }

    func pull() async {
        guard let backend else { return }
        guard let remote = await backend.getMonthlyGoals() else { return }
        for g in remote { byId[g.id] = g }
        // Remove tombstoned-locally-but-missing-from-remote? No — server is source of truth;
        // tombstoned rows stay until next full refresh.
        saveToDisk()
        notifyDashboardUpdated()
    }

    func create(_ payload: MonthlyGoalCreatePayload) async throws -> MonthlyGoal {
        guard let backend else { throw BackendClient.IntentionError.network("No backend") }
        let created = try await backend.createMonthlyGoal(payload)
        byId[created.id] = created
        saveToDisk()
        notifyDashboardUpdated()
        return created
    }

    func update(id: UUID, payload: MonthlyGoalUpdatePayload) async throws -> MonthlyGoal {
        guard let backend else { throw BackendClient.IntentionError.network("No backend") }
        let updated = try await backend.updateMonthlyGoal(id: id, payload: payload)
        byId[id] = updated
        saveToDisk()
        notifyDashboardUpdated()
        return updated
    }

    func delete(id: UUID) async -> Bool {
        guard let backend else { return false }
        let ok = await backend.deleteMonthlyGoal(id: id)
        if ok {
            byId[id] = nil
            saveToDisk()
            notifyDashboardUpdated()
        }
        return ok
    }

    func startSyncTimer() {
        syncTimer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.pull() }
        }
        syncTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let cached = try? Self.decoder.decode([MonthlyGoal].self, from: data) else { return }
        for g in cached { byId[g.id] = g }
    }

    private func saveToDisk() {
        let snapshot = Array(byId.values)
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func notifyDashboardUpdated() {
        // Post a notification; AppDelegate observes it and asks MainWindow to push.
        NotificationCenter.default.post(name: .monthlyGoalsUpdated, object: nil)
    }
}

extension Notification.Name {
    static let monthlyGoalsUpdated = Notification.Name("com.intentional.monthlyGoalsUpdated")
}
```

- [ ] **Step 4.3: Add to Xcode target + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/MonthlyGoalStore.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(goals): MonthlyGoalStore actor + disk cache + 60s sync timer"
```

---

## Phase 3: Bridge wiring + AppDelegate init (depends on Phase 1+2 + backend deploy)

### Task 5: AppDelegate — init MonthlyGoalStore + wire migration

**Files:**
- Modify: `Intentional/AppDelegate.swift` (find the existing `IntentionStore` init at ~line 560)
- Create: `Intentional/IntentTextMigration.swift`

- [ ] **Step 5.1: Add `monthlyGoalStore` property to AppDelegate**

Near the existing `var intentionStore: IntentionStore?` (line 77), add:

```swift
    var monthlyGoalStore: MonthlyGoalStore?
```

- [ ] **Step 5.2: Init the store after `intentionStore` is wired (~line 581)**

After `intentionStore?.startSyncTimer()`, insert:

```swift
        // May 2026 prototype → production — MonthlyGoalStore (cross-device monthly goals)
        monthlyGoalStore = MonthlyGoalStore.shared
        Task {
            await monthlyGoalStore?.wire(backend: backendClient!, appDelegate: self)
            await monthlyGoalStore?.pull()
        }
        monthlyGoalStore?.startSyncTimer()
        postLog("📅 MonthlyGoalStore wired and pulling")
```

- [ ] **Step 5.3: Write `IntentTextMigration.swift`**

```swift
// IntentTextMigration.swift
//
// One-shot migration: when first seen, for each Intention with empty
// `intentText`, copy its `description` into `intentText`. Idempotent via
// receipt at `~/Library/Application Support/Intentional/migration_intent_text_v1.json`.

import Foundation

enum IntentTextMigration {
    private static var receiptURL: URL {
        let support = try! FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Intentional", isDirectory: true)
        return dir.appendingPathComponent("migration_intent_text_v1.json")
    }

    /// Returns true iff the migration ran. Idempotent — repeated calls are no-ops.
    @discardableResult
    static func runIfNeeded(intentionStore: IntentionStore,
                            backend: BackendClient) async -> Bool {
        if FileManager.default.fileExists(atPath: receiptURL.path) { return false }
        let all = await intentionStore.active()
        for i in all where (i.intentText ?? "").isEmpty && (i.description ?? "").isEmpty == false {
            // Build an update payload that carries the new field; preserve all others.
            var payload = IntentionUpdatePayload(
                name: i.name,
                description: i.description,
                colorHex: i.colorHex,
                icon: i.icon,
                macWebsites: i.macWebsites,
                macBundleIds: i.macBundleIds,
                iosAppTokensB64: i.iosAppTokensB64,
                iosCategoryTokensB64: i.iosCategoryTokensB64,
                version: i.version
            )
            payload.intentText = i.description
            payload.outcome = i.outcome
            payload.status = i.status
            payload.weeklyTargetHours = i.weeklyTargetHours
            payload.aiScoringEnabled = i.aiScoringEnabled
            payload.allowWebsites = i.allowWebsites
            payload.allowBundleIds = i.allowBundleIds
            payload.monthlyGoalId = i.monthlyGoalId
            payload.weekOf = i.weekOf
            do {
                _ = try await intentionStore.update(id: i.id, payload: payload)
            } catch {
                // best effort — continue with other intentions
            }
        }
        // Write receipt
        let receipt: [String: Any] = [
            "ran_at": ISO8601DateFormatter().string(from: Date()),
            "version": 1,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: receipt) {
            try? data.write(to: receiptURL, options: .atomic)
        }
        return true
    }
}
```

- [ ] **Step 5.4: Wire migration in AppDelegate after first pull**

After the new `monthlyGoalStore?.startSyncTimer()` block, append:

```swift
        Task {
            // One-shot migration: copy Intention.description → intent_text for goals
            // that don't have intent_text set. Idempotent. Runs after first intention pull.
            await intentionStore?.pull()
            await IntentTextMigration.runIfNeeded(
                intentionStore: intentionStore!,
                backend: backendClient!
            )
        }
```

- [ ] **Step 5.5: Add to Xcode target + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/AppDelegate.swift Intentional/IntentTextMigration.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat(goals): MonthlyGoalStore init + IntentTextMigration"
```

**Acceptance criteria:**
- App launches without crash; logs `📅 MonthlyGoalStore wired and pulling`.
- After first launch on an account with existing intentions, the receipt file `migration_intent_text_v1.json` exists.
- Re-launching does not re-run the migration (receipt blocks).

---

### Task 6: MainWindow — extend `intentionToDict` + add 6 bridge handlers

**Files:**
- Modify: `Intentional/MainWindow.swift`

- [ ] **Step 6.1: Extend `intentionToDict` (line 3314) to include new fields**

In `Self.intentionToDict`, append to the dict:

```swift
        dict["outcome"] = i.outcome ?? ""
        dict["status"] = i.status.rawValue
        dict["weekly_target_hours"] = i.weeklyTargetHours as Any? ?? NSNull()
        dict["intent_text"] = i.intentText ?? ""
        dict["ai_scoring_enabled"] = i.aiScoringEnabled
        dict["allow_websites"] = i.allowWebsites
        dict["allow_bundle_ids"] = i.allowBundleIds
        dict["monthly_goal_id"] = i.monthlyGoalId?.uuidString as Any? ?? NSNull()
        dict["week_of"] = i.weekOf ?? NSNull()
```

- [ ] **Step 6.2: Add `monthlyGoalToDict` static helper**

Near `intentionToDict`:

```swift
    static func monthlyGoalToDict(_ g: MonthlyGoal) -> [String: Any] {
        var d: [String: Any] = [
            "id": g.id.uuidString,
            "title": g.title,
            "outcome": g.outcome ?? "",
            "color_hex": g.colorHex ?? "",
            "month_of": g.monthOf,
            "status": g.status.rawValue,
            "version": g.version,
            "created_at": ISO8601DateFormatter().string(from: g.createdAt),
            "updated_at": ISO8601DateFormatter().string(from: g.updatedAt),
        ]
        if let d2 = g.deletedAt {
            d["deleted_at"] = ISO8601DateFormatter().string(from: d2)
        }
        return d
    }
```

- [ ] **Step 6.3: Add 6 bridge handlers**

In the message routing `switch` (line 326 onwards), add cases (after the existing `OPEN_INTENTION_EDITOR` at line 675):

```swift
        // May 2026 — Monthly Goals
        case "GET_MONTHLY_GOALS":
            handleGetMonthlyGoals()

        case "GET_MONTHLY_GOAL":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) {
                handleGetMonthlyGoal(id: id)
            }

        case "CREATE_MONTHLY_GOAL":
            if let body = message.body as? [String: Any] {
                handleCreateMonthlyGoal(body)
            }

        case "UPDATE_MONTHLY_GOAL":
            if let body = message.body as? [String: Any] {
                handleUpdateMonthlyGoal(body)
            }

        case "DELETE_MONTHLY_GOAL":
            if let body = message.body as? [String: Any],
               let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) {
                handleDeleteMonthlyGoal(id: id)
            }

        case "LINK_WEEKLY_TO_MONTHLY":
            // Body: {intention_id: UUID, monthly_goal_id: UUID? (nil = unlink)}
            if let body = message.body as? [String: Any] {
                handleLinkWeeklyToMonthly(body)
            }

        case "START_GOAL_SESSION":
            // Alias for START_INTENTION_SESSION that may carry monthly_goal_id for analytics.
            // For now, ignore monthly_goal_id (open Q 2 default) and route to existing handler.
            if let body = message.body as? [String: Any] {
                handleStartIntentionSession(body)
            }
```

Also extend the message-type filter at line 326:

```swift
        if type.contains("INTENTION") || type.contains("PROJECT") ||
           type.contains("MONTHLY_GOAL") || type == "UPDATE_INTENTION_STRICTNESS" ||
           type == "LINK_WEEKLY_TO_MONTHLY" || type == "START_GOAL_SESSION" {
```

- [ ] **Step 6.4: Add 6 handler method bodies**

Add as a new MARK section near the existing Intention handlers:

```swift
    // MARK: - Monthly Goals (May 2026)

    private func handleGetMonthlyGoals() {
        guard let store = appDelegate?.monthlyGoalStore else {
            emitMonthlyGoalsList([])
            return
        }
        Task {
            let goals = await store.active()
            let items = goals.map { Self.monthlyGoalToDict($0) }
            await MainActor.run { self.emitMonthlyGoalsList(items) }
        }
    }

    private func handleGetMonthlyGoal(id: UUID) {
        guard let store = appDelegate?.monthlyGoalStore else { return }
        Task {
            if let g = await store.goal(id: id) {
                let dict = Self.monthlyGoalToDict(g)
                await MainActor.run { self.emitMonthlyGoalDetail(dict) }
            } else {
                await MainActor.run { self.emitMonthlyGoalDetail(["error":"Not found"]) }
            }
        }
    }

    private func handleCreateMonthlyGoal(_ body: [String: Any]) {
        guard let store = appDelegate?.monthlyGoalStore else { return }
        let title = (body["title"] as? String) ?? "Untitled"
        let monthOf = (body["month_of"] as? String) ?? ""
        let statusRaw = body["status"] as? String ?? "planned"
        let payload = MonthlyGoalCreatePayload(
            title: title,
            outcome: body["outcome"] as? String,
            colorHex: body["color_hex"] as? String,
            monthOf: monthOf,
            status: GoalStatus(rawValue: statusRaw) ?? .planned
        )
        Task {
            do {
                let created = try await store.create(payload)
                let dict = Self.monthlyGoalToDict(created)
                await MainActor.run { self.emitMonthlyGoalCreated(dict) }
            } catch {
                await MainActor.run {
                    self.emitMonthlyGoalCreated(["error":"\(error)"])
                }
            }
        }
    }

    private func handleUpdateMonthlyGoal(_ body: [String: Any]) {
        guard let store = appDelegate?.monthlyGoalStore,
              let idStr = body["id"] as? String,
              let id = UUID(uuidString: idStr),
              let version = body["version"] as? Int else { return }
        let payload = MonthlyGoalUpdatePayload(
            title: (body["title"] as? String) ?? "Untitled",
            outcome: body["outcome"] as? String,
            colorHex: body["color_hex"] as? String,
            monthOf: (body["month_of"] as? String) ?? "",
            status: GoalStatus(rawValue: body["status"] as? String ?? "planned") ?? .planned,
            version: version
        )
        Task {
            do {
                let updated = try await store.update(id: id, payload: payload)
                let dict = Self.monthlyGoalToDict(updated)
                await MainActor.run { self.emitMonthlyGoalUpdated(dict) }
            } catch {
                await MainActor.run { self.emitMonthlyGoalUpdated(["error":"\(error)"]) }
            }
        }
    }

    private func handleDeleteMonthlyGoal(id: UUID) {
        guard let store = appDelegate?.monthlyGoalStore else { return }
        Task {
            let ok = await store.delete(id: id)
            await MainActor.run {
                self.callJS("window._monthlyGoalDeleted && window._monthlyGoalDeleted({id: '\(id.uuidString)', ok: \(ok)})")
            }
        }
    }

    private func handleLinkWeeklyToMonthly(_ body: [String: Any]) {
        guard let store = appDelegate?.intentionStore,
              let intentionIdStr = body["intention_id"] as? String,
              let intentionId = UUID(uuidString: intentionIdStr) else { return }
        let monthlyGoalId: UUID? = (body["monthly_goal_id"] as? String).flatMap(UUID.init)
        Task {
            guard let i = await store.intention(id: intentionId) else { return }
            var payload = IntentionUpdatePayload(
                name: i.name, description: i.description, colorHex: i.colorHex, icon: i.icon,
                macWebsites: i.macWebsites, macBundleIds: i.macBundleIds,
                iosAppTokensB64: i.iosAppTokensB64, iosCategoryTokensB64: i.iosCategoryTokensB64,
                version: i.version
            )
            // round-trip all new fields too so we don't accidentally clear them
            payload.outcome = i.outcome
            payload.status = i.status
            payload.weeklyTargetHours = i.weeklyTargetHours
            payload.intentText = i.intentText
            payload.aiScoringEnabled = i.aiScoringEnabled
            payload.allowWebsites = i.allowWebsites
            payload.allowBundleIds = i.allowBundleIds
            payload.weekOf = i.weekOf
            payload.monthlyGoalId = monthlyGoalId
            do {
                let updated = try await store.update(id: intentionId, payload: payload)
                let dict = Self.intentionToDict(updated)
                await MainActor.run {
                    self.callJS("window._intentionUpdated && window._intentionUpdated(\(self.jsonString(dict)))")
                }
            } catch {
                await MainActor.run {
                    self.callJS("window._intentionUpdated && window._intentionUpdated({error: 'link failed'})")
                }
            }
        }
    }
```

- [ ] **Step 6.5: Add emit helpers**

```swift
    private func emitMonthlyGoalsList(_ items: [[String: Any]]) {
        callJS("window._monthlyGoalsList && window._monthlyGoalsList(\(jsonString(items)))")
    }
    private func emitMonthlyGoalDetail(_ dict: [String: Any]) {
        callJS("window._monthlyGoalDetail && window._monthlyGoalDetail(\(jsonString(dict)))")
    }
    private func emitMonthlyGoalCreated(_ dict: [String: Any]) {
        callJS("window._monthlyGoalCreated && window._monthlyGoalCreated(\(jsonString(dict)))")
    }
    private func emitMonthlyGoalUpdated(_ dict: [String: Any]) {
        callJS("window._monthlyGoalUpdated && window._monthlyGoalUpdated(\(jsonString(dict)))")
    }

    /// Small helper if not already present — JSON-encode dict/array as String.
    /// (If MainWindow already has one, use that and skip this.)
    private func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }
```

- [ ] **Step 6.6: Observe `.monthlyGoalsUpdated` notification + push to dashboard**

In `MainWindow.init` or wherever observers are registered:

```swift
        NotificationCenter.default.addObserver(forName: .monthlyGoalsUpdated, object: nil, queue: .main) { [weak self] _ in
            self?.handleGetMonthlyGoals()
        }
```

- [ ] **Step 6.7: Build + commit**

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/MainWindow.swift
git commit -m "feat(goals): bridge handlers for monthly goals + extended intention dict"
```

**Acceptance criteria:**
- From the WKWebView devtools, calling `window.webkit.messageHandlers.bridge.postMessage({type:'GET_MONTHLY_GOALS'})` returns an empty list (assuming no server data).
- Calling `CREATE_MONTHLY_GOAL` with `{title:'Test', month_of:'2026-05-01'}` returns a created row + the goal shows up on the next `GET_MONTHLY_GOALS`.

---

## Phase 4: Dashboard handoff + final commit

### Task 7: Update `CLAUDE.md` with new architecture section

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 7.1: Add a new section under "Intentions (Spec 1, May 2026) — ACTIVE"**

After the existing Spec 1 block, add:

```markdown
## Weekly + Monthly Goals (May 14, 2026) — ACTIVE

Intentions now carry the "weekly goal" vocabulary in copy. The underlying
Swift type and DB table stay `Intention`/`intentions`. Each Intention gains:
- `outcome` (done-looks-like text)
- `status` (planned | in_progress | done | slipped | dropped)
- `weeklyTargetHours`
- `intentText` (≤140 chars; drives AI scoring when `aiScoringEnabled`)
- `aiScoringEnabled` (bool)
- `allowWebsites` + `allowBundleIds` (per-goal allow list)
- `monthlyGoalId` (FK)
- `weekOf` (ISO date, Monday)

New top-level type `MonthlyGoal` (`Intentional/MonthlyGoal.swift`) + actor
`MonthlyGoalStore.shared`. Cache at
`~/Library/Application Support/Intentional/monthly_goals.json`. Sync pattern
mirrors `IntentionStore` (pull on launch + foreground + 60s timer).

New bridge messages:
- `GET_MONTHLY_GOALS`, `GET_MONTHLY_GOAL`, `CREATE_MONTHLY_GOAL`,
  `UPDATE_MONTHLY_GOAL`, `DELETE_MONTHLY_GOAL`, `LINK_WEEKLY_TO_MONTHLY`
- `START_GOAL_SESSION` (alias of `START_INTENTION_SESSION` carrying optional
  `monthly_goal_id` — currently ignored, future analytics hook)

Dashboard side: see `docs/superpowers/plans/2026-05-14-prototype-to-production-plan-c-dashboard.md`.
```

- [ ] **Step 7.2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): document weekly + monthly goals architecture"
```

---

### Task 8: Open PR

- [ ] **Step 8.1: Push + open PR**

```bash
git push -u origin feat/prototype-to-production
gh pr create --title "feat(goals): weekly + monthly goal Mac client" --body "$(cat <<'EOF'
## Summary
- Extends `Intention` with 9 new wire-format fields (Weekly-Goal vocab from prototype).
- New `MonthlyGoal` model + `MonthlyGoalStore` actor + 5 BackendClient methods.
- 6 new dashboard bridge handlers + extended `_intentionsList` payload.
- One-shot `description` → `intent_text` migration (idempotent receipt).

## Test plan
- [ ] `xcodebuild build` clean.
- [ ] Launch app on account with existing intentions — logs `📅 MonthlyGoalStore wired`.
- [ ] Receipt `migration_intent_text_v1.json` appears after first launch.
- [ ] WKWebView `GET_MONTHLY_GOALS` returns server data.
- [ ] Playwright run of `app.html` Today + Plan tabs (companion Plan C).

Per docs/prototype-to-production-2026-05-14.md.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 8.2: Update cross-repo log**

Append a "Mac (Plan B)" section to `docs/cross-repo-prototype-to-production-2026-05-14.md` with PR link, files touched, and the one open follow-up: AI-scoring-toggle wire-up.

---

## Migration / rollback summary

- **Forward (Mac side):** ship Plan B after Plan A's migration 026 is live on staging. The one-shot `IntentTextMigration` runs on first launch only.
- **Rollback:** revert the PR; `MonthlyGoalStore` becomes inert (no callers), receipt file orphan is benign. New columns on `intentions` stay (server-side rollback handled in Plan A).
- **Compatibility:** Mac client decodes server payloads tolerantly — running old Mac against new server is fine (new fields ignored). Running new Mac against old server is also fine (defaults applied).

---

## Self-review checklist

- [x] **Spec coverage:** Brief sections B/D map to Tasks 1, 5–6. Section C (Plan tab) handed off to Plan C. Section A (sidebar restructure) handed off to Plan C.
- [x] **No placeholders.** All Swift method bodies are written. Helpers (`jsonString`, `addAuthHeaders`) reference existing utilities — verify names in Task 3.3 / 6.5.
- [x] **Type consistency.** `GoalStatus` enum is the single status type. `monthlyGoalId: UUID?` consistent across Intention, payloads, and bridge body parsing.
- [x] **Rollback path documented** (above).

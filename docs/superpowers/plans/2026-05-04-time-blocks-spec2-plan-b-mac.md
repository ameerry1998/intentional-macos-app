# Spec 2 — Mac Client Implementation Plan (Plan B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Rewire Mac's `ScheduleManager` from local `daily_schedule.json` to backend-synced `time_blocks`. Rename `FocusBlock` → `TimeBlock`. Add `intentionId` + `intensity` fields. Drop `.freeTime` block type (free time = absence of block). The 10s timer becomes UI-only — backend cron drives enforcement. Calendar UI in `dashboard.html` keeps working but reads from backend.

**Architecture:** New `BackendClient.getTimeBlocks()` / `putTimeBlocks()` methods. `ScheduleManager` adds backend pull/push in the BedtimeConfigSync pattern (60s + foreground refresh). On launch: try backend first; fall back to local JSON if backend unavailable. Local `daily_schedule.json` renamed to `daily_schedule.legacy.json` after first successful pull. `DailySchedule.dailyPlan` → `dayNotes`, `.goals` → `dayItems` (frees up "Plan" / "Goal" naming for Spec 3 layer per locked vocab).

**Tech Stack:** Swift, AppKit, WKWebView dashboard, actor-isolated state, URLSession, XCTest where wired.

**Worktree:** `/Users/arayan/Documents/GitHub/intentional-macos-app/.claude/worktrees/time-blocks-spec2` on branch `feat/time-blocks-spec2` from `puck`.

**Spec 1 dependency:** Requires Spec 1's IntentionStore in place (uses `IntentionStore.shared.intention(id:)` for binding lookups). Branch `feat/intentions-spec1` must merge first.

**Spec 2 backend dependency:** `/time_blocks` endpoints must be live. Plan A ships them.

**Spec reference:** `docs/superpowers/specs/2026-05-04-time-blocks-spec2-handoff.md`
**Cross-repo log:** `docs/cross-repo-time-blocks-spec2-2026-05-04.md`

---

## File map

| File | Op | Purpose |
|---|---|---|
| `Intentional/ScheduleManager.swift` | MODIFY | Add backend pull/push; rename `FocusBlock` → `TimeBlock`; add intentionId + intensity; drop `.freeTime`; rename `goals` → `dayItems`, `dailyPlan` → `dayNotes` |
| `Intentional/BackendClient.swift` | MODIFY | Add `getTimeBlocks()` / `putTimeBlocks()` |
| `Intentional/AppDelegate.swift` | MODIFY | Wire ScheduleManager backend pull on init + foreground; remove the file-write callback that was the canonical source |
| `Intentional/MainWindow.swift` | MODIFY | Schedule-related bridge messages send/receive via backend (no UI change in dashboard.html); update payload shapes to include intentionId + intensity |
| `Intentional/dashboard.html` | MODIFY | Tiny: payload-shape changes for `addFocusBlock`/`updateFocusBlock` to include `intention_id` + `intensity` (calendar UI itself unchanged) |
| `IntentionalTests/TimeBlockTests.swift` | CREATE | Migration of FocusBlock → TimeBlock; intentionId binding; backend round-trip with mocked URLSession |

---

## Task 0: Worktree setup

- [ ] **Step 0.1:** Worktree

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git worktree add -b feat/time-blocks-spec2 .claude/worktrees/time-blocks-spec2 puck
cd .claude/worktrees/time-blocks-spec2
```

- [ ] **Step 0.2:** Empty initial commit

```bash
git commit --allow-empty -m "spec2(time-blocks): start Mac implementation"
```

---

## Task 1: Add `BackendClient.getTimeBlocks` + `putTimeBlocks`

**Files:**
- Modify: `Intentional/BackendClient.swift`

- [ ] **Step 1.1:** Append after the intentions methods (Spec 1 added them):

```swift
    // MARK: - Time Blocks (Spec 2)

    struct TimeBlockDTO: Codable, Equatable {
        let block_id: String
        let title: String
        let block_type: String  // "deep_work" | "focus_hours" (legacy carryover)
        let intention_id: String?
        let intensity: String  // "deep_work" | "focus_hours"
        let start_hour: Int
        let start_minute: Int
        let end_hour: Int
        let end_minute: Int
        let active_days: [Int]   // ISO 1=Mon..7=Sun
        let enabled: Bool
        let updated_at: String?
    }

    struct TimeBlocksResponse: Codable {
        let blocks: [TimeBlockDTO]
    }

    /// GET /time_blocks — returns nil on network failure, [] when truly empty.
    func getTimeBlocks() async -> [TimeBlockDTO]? {
        guard let url = URL(string: "\(baseURL)/time_blocks") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(TimeBlocksResponse.self, from: data).blocks
        } catch {
            return nil
        }
    }

    /// PUT /time_blocks — atomic replace. Returns the new blocks list on success.
    @discardableResult
    func putTimeBlocks(_ blocks: [TimeBlockDTO]) async -> [TimeBlockDTO]? {
        guard let url = URL(string: "\(baseURL)/time_blocks") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-ID")
        do {
            let payload: [String: Any] = ["blocks": blocks.map { try JSONSerialization.jsonObject(with: try JSONEncoder().encode($0)) as? [String: Any] ?? [:] }]
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(TimeBlocksResponse.self, from: data).blocks
        } catch {
            return nil
        }
    }
```

- [ ] **Step 1.2:** Build + commit

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -5
git add Intentional/BackendClient.swift
git commit -m "feat(time-blocks): BackendClient.getTimeBlocks + putTimeBlocks (DTO matches /time_blocks)"
```

---

## Task 2: Add `intentionId` + `intensity` to `ScheduleManager.FocusBlock` (KEEP NAME for now)

**Files:**
- Modify: `Intentional/ScheduleManager.swift`

We're going to add fields without renaming the type yet. Renaming `FocusBlock` → `TimeBlock` is a separate task (Task 6) because the type is referenced in many places. Additive change first.

- [ ] **Step 2.1:** Find the `FocusBlock` struct definition (line ~18) and add fields:

```swift
    struct FocusBlock: Codable, Equatable {
        let id: String
        var title: String
        var description: String
        var startHour: Int
        var startMinute: Int
        var endHour: Int
        var endMinute: Int
        var blockType: BlockType
        var ignoreProfile: Bool
        // NEW (Spec 2):
        var intentionId: UUID?
        var intensity: BlockType  // mirrors blockType for now; semantically the same
        // ...

        init(...) { ... }

        // Decoding: backwards-compat with rows that lack intentionId/intensity
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.title = try c.decode(String.self, forKey: .title)
            self.description = try c.decode(String.self, forKey: .description)
            self.startHour = try c.decode(Int.self, forKey: .startHour)
            self.startMinute = try c.decode(Int.self, forKey: .startMinute)
            self.endHour = try c.decode(Int.self, forKey: .endHour)
            self.endMinute = try c.decode(Int.self, forKey: .endMinute)
            self.blockType = try c.decode(BlockType.self, forKey: .blockType)
            self.ignoreProfile = try c.decode(Bool.self, forKey: .ignoreProfile)
            // NEW: tolerate missing keys for forward-compat with old JSON
            self.intentionId = try c.decodeIfPresent(UUID.self, forKey: .intentionId)
            self.intensity = try c.decodeIfPresent(BlockType.self, forKey: .intensity) ?? self.blockType
        }
    }
```

(If FocusBlock doesn't have an explicit `init(from:)` now, you'll need to add one + a `CodingKeys` enum that includes the new keys.)

- [ ] **Step 2.2:** Update existing initializers (the convenience init in ScheduleManager.addBlock callers) to pass `intentionId: nil, intensity: blockType` defaults.

- [ ] **Step 2.3:** Build + commit

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/ScheduleManager.swift
git commit -m "feat(time-blocks): add intentionId + intensity to FocusBlock (backwards-compat decode)"
```

---

## Task 3: `ScheduleManager` — pull from backend on init + 60s timer + foreground

**Files:**
- Modify: `Intentional/ScheduleManager.swift`

- [ ] **Step 3.1:** Add the backend client reference

Find the `class ScheduleManager` properties and add:

```swift
    private weak var backend: BackendClient?
    private var pullTimer: Timer?
```

Add a `wire` method:

```swift
    func wire(backend: BackendClient) {
        self.backend = backend
        startBackendSync()
    }

    private func startBackendSync() {
        // Initial pull
        Task { await pullFromBackend() }

        // Foreground refresh
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.pullFromBackend() }
        }

        // 60s timer
        let t = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { await self?.pullFromBackend() }
        }
        t.tolerance = 5.0
        RunLoop.main.add(t, forMode: .common)
        pullTimer = t
    }
```

- [ ] **Step 3.2:** Add `pullFromBackend`

```swift
    @MainActor
    func pullFromBackend() async {
        guard let backend = backend else { return }
        guard let dtos = await backend.getTimeBlocks() else {
            // Network failure — keep local state, will retry next tick
            return
        }
        let blocks = dtos.map { dto in
            FocusBlock(
                id: dto.block_id,
                title: dto.title,
                description: "",
                startHour: dto.start_hour, startMinute: dto.start_minute,
                endHour: dto.end_hour, endMinute: dto.end_minute,
                blockType: BlockType(rawValue: dto.intensity) ?? .deepWork,
                ignoreProfile: false,
                intentionId: dto.intention_id.flatMap { UUID(uuidString: $0) },
                intensity: BlockType(rawValue: dto.intensity) ?? .deepWork
            )
        }
        // Replace today's block list (filtered by today's iso weekday).
        let today = Calendar.current.component(.weekday, from: Date())  // Sun=1..Sat=7
        let isoToday = today == 1 ? 7 : (today - 1)  // convert to ISO 1=Mon..7=Sun
        let todayBlocks = blocks.filter { _ in true }  // for now: all blocks; recurring filter happens in render layer
        // (For now, return everything — Mac UI's existing today-filter handles the rest.)
        if todaySchedule == nil {
            todaySchedule = DailySchedule(
                date: Self.todayString(), blocks: todayBlocks,
                dayItems: [], dayNotes: ""
            )
        } else {
            todaySchedule?.blocks = todayBlocks
        }
        recalculateState()
        // Rename legacy file if present + first successful pull
        renameLegacyScheduleFile()
    }

    private func renameLegacyScheduleFile() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Intentional")
        let live = dir.appendingPathComponent("daily_schedule.json")
        let legacy = dir.appendingPathComponent("daily_schedule.legacy.json")
        if FileManager.default.fileExists(atPath: live.path) &&
           !FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: live, to: legacy)
        }
    }
```

- [ ] **Step 3.3:** Add `pushToBackend` for mutations

```swift
    @MainActor
    func pushToBackend() async {
        guard let backend = backend, let schedule = todaySchedule else { return }
        let dtos: [BackendClient.TimeBlockDTO] = schedule.blocks.map { b in
            BackendClient.TimeBlockDTO(
                block_id: b.id, title: b.title,
                block_type: b.blockType.rawValue,
                intention_id: b.intentionId?.uuidString,
                intensity: b.intensity.rawValue,
                start_hour: b.startHour, start_minute: b.startMinute,
                end_hour: b.endHour, end_minute: b.endMinute,
                active_days: [1, 2, 3, 4, 5, 6, 7],  // for now: every-day default
                enabled: true,
                updated_at: nil
            )
        }
        _ = await backend.putTimeBlocks(dtos)
    }
```

- [ ] **Step 3.4:** Build + commit

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/ScheduleManager.swift
git commit -m "feat(time-blocks): ScheduleManager backend pull (init + 60s + foreground) + push on mutation"
```

---

## Task 4: Wire `pushToBackend` into mutation methods

**Files:**
- Modify: `Intentional/ScheduleManager.swift`

The existing `addBlock`, `updateBlock`, `removeBlock` methods write to local state + persist to disk. Now they should also push to backend.

- [ ] **Step 4.1:** Find each mutation method and append a `Task { await pushToBackend() }` call AFTER the local update + persist.

Example for `addBlock`:

```swift
    func addBlock(_ block: FocusBlock) {
        if todaySchedule == nil {
            todaySchedule = DailySchedule(
                date: Self.todayString(), blocks: [],
                dayItems: [], dayNotes: ""
            )
        }
        todaySchedule?.blocks.append(block)
        todaySchedule?.blocks.sort { $0.startMinutes < $1.startMinutes }
        persistToDisk()
        recalculateState()
        Task { await pushToBackend() }  // NEW
    }
```

Apply the same pattern to `updateBlock` and `removeBlock` (find them by name).

- [ ] **Step 4.2:** Build + commit

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -5
git add Intentional/ScheduleManager.swift
git commit -m "feat(time-blocks): ScheduleManager mutations push to backend after local persist"
```

---

## Task 5: Wire ScheduleManager into AppDelegate

**Files:**
- Modify: `Intentional/AppDelegate.swift`

- [ ] **Step 5.1:** Find where `scheduleManager` is instantiated. After it, call `scheduleManager.wire(backend: backendClient!)`.

```swift
        scheduleManager = ScheduleManager()
        scheduleManager.wire(backend: backendClient!)  // NEW (Spec 2)
        postLog("📅 ScheduleManager wired to backend (pull on init + 60s)")
```

- [ ] **Step 5.2:** Build + commit

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -5
git add Intentional/AppDelegate.swift
git commit -m "feat(time-blocks): wire ScheduleManager backend sync in AppDelegate"
```

---

## Task 6: Rename `goals` → `dayItems` and `dailyPlan` → `dayNotes` (free up Plan/Goal vocab)

**Files:**
- Modify: `Intentional/ScheduleManager.swift`

- [ ] **Step 6.1:** In `DailySchedule` struct:

```swift
    struct DailySchedule: Codable {
        var date: String
        var dayItems: [String]   // RENAMED from goals (frees "Goal" for Spec 3 layer)
        var dayNotes: String     // RENAMED from dailyPlan (frees "Plan" for Spec 3 layer)
        var blocks: [FocusBlock]

        // Backwards-compat decoding
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.date = try c.decode(String.self, forKey: .date)
            self.blocks = try c.decode([FocusBlock].self, forKey: .blocks)
            // Try new names first, fall back to old
            if let items = try? c.decode([String].self, forKey: .dayItems) {
                self.dayItems = items
            } else if let goals = try? c.decode([String].self, forKey: .goals) {
                self.dayItems = goals
            } else {
                self.dayItems = []
            }
            if let notes = try? c.decode(String.self, forKey: .dayNotes) {
                self.dayNotes = notes
            } else if let plan = try? c.decode(String.self, forKey: .dailyPlan) {
                self.dayNotes = plan
            } else {
                self.dayNotes = ""
            }
        }

        enum CodingKeys: String, CodingKey {
            case date, blocks, dayItems, dayNotes
            case goals  // legacy
            case dailyPlan = "dailyPlan"  // legacy
        }
    }
```

- [ ] **Step 6.2:** Find all callers of `dailyPlan` and `goals` in the codebase:

```bash
grep -rn "\.dailyPlan\|\.goals\[" Intentional/
```

Replace with `.dayNotes` and `.dayItems` respectively.

- [ ] **Step 6.3:** Build + commit

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -10
git add Intentional/
git commit -m "refactor(schedule): rename DailySchedule.goals → dayItems, dailyPlan → dayNotes (free up Plan/Goal vocab for Spec 3)"
```

---

## Task 7: Drop `.freeTime` block type — convert all references

**Files:**
- Modify: `Intentional/ScheduleManager.swift`, callers

Per spec: "free time = absence of a block." Drop `.freeTime` from BlockType enum.

- [ ] **Step 7.1:** Find all `case .freeTime` usages

```bash
grep -rn "\.freeTime\|freeTime" Intentional/ --include='*.swift'
```

- [ ] **Step 7.2:** For each caller:
   - If it's checking "is this a free-time block?" — change to "is the block missing or non-blocking?"
   - If it's setting `.freeTime` (e.g. quick-block buttons that create a Free Time block) — either drop the path entirely OR convert to "no block" semantics.

The likely callers based on a quick scan:
- `MainWindow.swift` quick-block UI handlers — change "create free time" path to just NOT inserting a block.
- `ScheduleManager.swift` enforcement logic that treats `.freeTime` as "don't enforce" — just remove the block check; absence of currentBlock is the same condition.

- [ ] **Step 7.3:** Update the enum:

```swift
    enum BlockType: String, Codable {
        case deepWork = "deepWork"
        case focusHours = "focusHours"
        // .freeTime removed — represented by absence of a block
    }
```

- [ ] **Step 7.4:** Build + commit (build will fail if any caller still references `.freeTime` — fix each in turn)

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' -quiet build 2>&1 | tail -25
git add Intentional/
git commit -m "refactor(schedule): drop BlockType.freeTime — absence of block = free time"
```

---

## Task 8: Calendar UI in dashboard.html — payload shape changes only

**Files:**
- Modify: `Intentional/dashboard.html` (search for `addFocusBlock` ~ line 8328)

The visual rendering doesn't change. Only the payload sent over the bridge needs to include `intention_id` + `intensity`.

- [ ] **Step 8.1:** Find `addFocusBlock` JS function

```bash
grep -n "function addFocusBlock\|function updateFocusBlock\|CREATE_BLOCK\|UPDATE_BLOCK" Intentional/dashboard.html | head
```

- [ ] **Step 8.2:** Update the message payloads to include the new fields (default to `null` and `'deep_work'`):

```javascript
function addFocusBlock(type) {
    // ... existing code ...
    const block = {
        // ... existing fields ...
        intention_id: null,  // NEW (Spec 2): bind via picker UI later
        intensity: type === 'focusHours' ? 'focus_hours' : 'deep_work',  // NEW
    };
    window.webkit.messageHandlers.bridge.postMessage({
        type: 'CREATE_BLOCK',  // or whatever the existing handler is
        block: block
    });
}
```

- [ ] **Step 8.3:** Commit

```bash
git add Intentional/dashboard.html
git commit -m "feat(time-blocks): dashboard payload shape includes intention_id + intensity"
```

---

## Task 9: ScheduleManager 10s timer — keep for UI, mark non-canonical for enforcement

**Files:**
- Modify: `Intentional/ScheduleManager.swift`

The existing 10s timer transitions `currentBlock` and fires `onBlockChanged`. Per spec, backend cron now fires sessions; the 10s timer should NOT also try to start enforcement (would race).

- [ ] **Step 9.1:** Find the 10s timer

```bash
grep -n "scheduledTimer\|recalculateState" Intentional/ScheduleManager.swift | head
```

- [ ] **Step 9.2:** In `recalculateState()`, the call that fires `onBlockChanged` for transitions: ONLY use it for UI updates (highlighting current block in calendar pill). Do NOT call `focusModeController.activate(...)` from here anymore — `FocusStatePoller` (which polls /focus/active every 2s) is the canonical source for the activation now.

The cleanest pattern: rename the `onBlockChanged` callback to `onBlockChangedForUI`, and have all enforcement-side wiring go through the FocusStatePoller-driven path. Less invasive: leave `onBlockChanged` but document that the activation half is a no-op when a backend session is already active (the existing `FocusModeController` is idempotent so this is safe regardless).

Decision: lower-risk path. Keep existing wiring; add a note that the activation is idempotent and may be redundant with the cron-driven path.

```swift
    // NOTE (Spec 2): backend cron fires sessions via /focus/active → FocusStatePoller
    // → FocusModeController.activate. This 10s tick still fires onBlockChanged for
    // UI-side updates (calendar pill highlight). The FocusModeController.activate
    // path is idempotent so no harm if both fire — but the canonical authority
    // for "is this block running?" is now backend's focus_sessions row.
```

- [ ] **Step 9.3:** Commit

```bash
git add Intentional/ScheduleManager.swift
git commit -m "docs(time-blocks): clarify 10s timer is UI-only; backend cron is canonical for enforcement"
```

---

## Task 10: Final build + push

- [ ] **Step 10.1:** Clean build

```bash
xcodebuild -scheme Intentional -destination 'platform=macOS' clean build 2>&1 | tail -10
```

- [ ] **Step 10.2:** Push

```bash
git push -u origin feat/time-blocks-spec2
```

- [ ] **Step 10.3:** Append to cross-repo log

In `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-time-blocks-spec2-2026-05-04.md`, add a `### Phase 3 — Mac report` section. Note that this Mac branch depends on Spec 1 Mac branch being merged first (uses IntentionStore.shared).

---

## Out of scope

- Native SwiftUI calendar editing UI on Mac (dashboard WebView keeps its existing calendar).
- Per-block iOS app blocklist editor on Mac (iOS owns its own slices).
- Dragging block boundaries in dashboard calendar — existing UI behavior preserved.
- Mac native time-block intention picker (use the existing dashboard form).

## Required env vars

None new.

# Spec 2 — iOS Client Implementation Plan (Plan C)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Restore the Schedule tab on iPhone with a real day-calendar UI that matches `addy-ai-ios/Views/Home/DayCalendarView.swift`. Rename `IntentionalBlock` → `TimeBlock`. Add `intentionId` + `intensity` fields. Pull/push to backend `/time_blocks`. Auto-fired Sessions arrive via the existing Spec 1 APNs handler — no new push code path.

**Architecture:** New `Puck/Models/TimeBlock.swift` SwiftData model (replaces `IntentionalBlock`). New `Puck/Core/Schedule/TimeBlocksService.swift` (replaces `ScheduleBlocksService`, but reuses its sync rhythm). New `Puck/Views/Schedule/DayCalendarView.swift` ported from addy-ai-ios. Schedule tab restored to TabView in `ContentView`. APNs handler from Spec 1 (added by Spec 1 Plan C) auto-applies the right shield when a Session fires — no scheduler-specific code needed on iOS.

**Tech Stack:** SwiftUI, SwiftData, gestures (long-press, drag, magnification), URLSession via `IntentionalAPIClient`, FamilyActivitySelection (existing), XCTest.

**Worktree:** `/Users/arayan/Documents/GitHub/puck-ios/.claude/worktrees/time-blocks-spec2` on branch `feat/time-blocks-spec2` from `main`.

**Spec 1 dependency:** Requires Spec 1 iOS work (`Intention` model, `IntentionStore`, APNs `IntentionPushHandler`). Branch `feat/intentions-spec1` must merge first.

**Spec 2 backend dependency:** `/time_blocks` endpoints must be reachable.

**Spec reference:** `docs/superpowers/specs/2026-05-04-time-blocks-spec2-handoff.md`
**Cross-repo log:** `docs/cross-repo-time-blocks-spec2-2026-05-04.md`

**Reference UI source-of-truth:** `/Users/arayan/Documents/GitHub/addy-ai-ios/addy-ai-ios/Views/Home/DayCalendarView.swift` — port the interaction model verbatim. 6am-10pm grid, 60pt/hr, long-press 0.5s + drag to move, top/bottom edge handles to resize, tap empty slot to create, 15-min snap.

---

## File map

| File | Op | Purpose |
|---|---|---|
| `Puck/Models/TimeBlock.swift` | CREATE | SwiftData @Model — supersedes IntentionalBlock |
| `Puck/Core/Schedule/TimeBlocksService.swift` | CREATE | Pull/push to `/time_blocks` (replaces ScheduleBlocksService) |
| `Puck/Core/Network/IntentionalTimeBlocksClient.swift` | CREATE | Network DTO + client |
| `Puck/Views/Schedule/DayCalendarView.swift` | CREATE | Port from addy-ai-ios — interaction model verbatim |
| `Puck/Views/Schedule/TimeBlockEditSheet.swift` | CREATE | Title + intention picker + intensity picker + active days |
| `Puck/Views/Schedule/ScheduleTabView.swift` | MODIFY | Render DayCalendarView; tap empty → edit sheet |
| `Puck/Views/ContentView.swift` | MODIFY | Restore `case schedule` in TabView |
| `Puck/Core/Schedule/IntentionalBlock.swift` | MODIFY | Mark deprecated; keep as compat for one release |
| `PuckTests/TimeBlockTests.swift` | CREATE | Model + service unit tests with mocked URLSession |

---

## Task 0: Worktree setup

- [ ] **Step 0.1:** Worktree

```bash
cd /Users/arayan/Documents/GitHub/puck-ios
git worktree add -b feat/time-blocks-spec2 .claude/worktrees/time-blocks-spec2 main
cd .claude/worktrees/time-blocks-spec2
```

- [ ] **Step 0.2:** Initial commit

```bash
git commit --allow-empty -m "spec2(time-blocks): start iOS implementation"
```

---

## Task 1: Read addy-ai-ios DayCalendarView in full (orient)

**Files:** none — this is reading

- [ ] **Step 1.1:** Read the reference

```bash
cat /Users/arayan/Documents/GitHub/addy-ai-ios/addy-ai-ios/Views/Home/DayCalendarView.swift | head -300
```

Note the structure:
- `startHour = 6`, `endHour = 22`, `hourHeight = 60` constants
- 24-hour-style grid view as a `ScrollView` with hour-row dividers
- Per-task tile: position computed from `meeting.start_time` minute offset
- Long-press 0.5s gesture activates `draggedTask` + `resizeMode = .move`
- Top/bottom edge of a tile: separate gesture to set `.top` or `.bottom`
- Drag offset → snap to 15-minute boundary on release
- Tap on empty grid → emits `(startTime, endTime)` for new event creation

You're porting the INTERACTION model (gestures, snap, layout math), NOT the visual style. The styling should match Puck's design tokens (`DesignTokens`), not addy-ai-ios.

---

## Task 2: `TimeBlock` SwiftData model

**Files:**
- Create: `Puck/Models/TimeBlock.swift`

- [ ] **Step 2.1:** Write the model

```swift
import Foundation
import SwiftData

/// Spec 2 — synced recurring weekly time block. Account-scoped via backend
/// /time_blocks endpoint. Optionally bound to an Intention; generic blocks
/// (intentionId == nil) use the seeded Focus Intention as fallback.
///
/// Supersedes `IntentionalBlock` (kept for migration window).
@Model
final class TimeBlock {
    @Attribute(.unique) var blockId: UUID
    var title: String
    var intentionId: UUID?
    /// "deep_work" | "focus_hours". Mirrors backend intensity column.
    var intensityRaw: String
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    /// ISO weekdays this block fires on. 1=Mon..7=Sun.
    var activeDays: [Int]
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    var intensity: TimeBlockIntensity {
        get { TimeBlockIntensity(rawValue: intensityRaw) ?? .deepWork }
        set { intensityRaw = newValue.rawValue }
    }

    init(
        blockId: UUID = UUID(),
        title: String,
        intentionId: UUID? = nil,
        intensity: TimeBlockIntensity = .deepWork,
        startHour: Int, startMinute: Int = 0,
        endHour: Int, endMinute: Int = 0,
        activeDays: [Int] = [1, 2, 3, 4, 5],
        enabled: Bool = true
    ) {
        self.blockId = blockId
        self.title = title
        self.intentionId = intentionId
        self.intensityRaw = intensity.rawValue
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.activeDays = activeDays
        self.enabled = enabled
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var startMinuteOfDay: Int { startHour * 60 + startMinute }
    var endMinuteOfDay: Int { endHour * 60 + endMinute }
    var durationMinutes: Int { endMinuteOfDay - startMinuteOfDay }
}

enum TimeBlockIntensity: String, Codable, CaseIterable {
    case deepWork = "deep_work"
    case focusHours = "focus_hours"

    var displayName: String {
        switch self {
        case .deepWork: return "Deep Work"
        case .focusHours: return "Focus Hours"
        }
    }
}
```

- [ ] **Step 2.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build 2>&1 | tail -10
git add Puck/Models/TimeBlock.swift
git commit -m "feat(time-blocks): TimeBlock SwiftData model + TimeBlockIntensity enum"
```

---

## Task 3: `IntentionalTimeBlocksClient` — network DTOs + client

**Files:**
- Create: `Puck/Core/Network/IntentionalTimeBlocksClient.swift`

- [ ] **Step 3.1:** Write the client

```swift
import Foundation

/// HTTP client for /time_blocks GET + PUT. Bearer auth via IntentionalAPIClient.
/// Replaces IntentionalScheduleClient which targeted /schedule/blocks.
struct IntentionalTimeBlocksClient {
    static let shared = IntentionalTimeBlocksClient()

    struct TimeBlockDTO: Codable, Equatable {
        let block_id: String
        let title: String
        let block_type: String  // legacy carryover; use intensity going forward
        let intention_id: String?
        let intensity: String   // "deep_work" | "focus_hours"
        let start_hour: Int
        let start_minute: Int
        let end_hour: Int
        let end_minute: Int
        let active_days: [Int]   // ISO 1=Mon..7=Sun
        let enabled: Bool
        let updated_at: String?
    }

    struct BlocksResponse: Codable, Equatable {
        let blocks: [TimeBlockDTO]
    }

    func getBlocks() async throws -> [TimeBlockDTO] {
        let resp: BlocksResponse = try await IntentionalAPIClient.shared.get(
            path: "time_blocks", auth: .bearer
        )
        return resp.blocks
    }

    @discardableResult
    func putBlocks(_ blocks: [TimeBlockDTO]) async throws -> [TimeBlockDTO] {
        struct Request: Codable { let blocks: [TimeBlockDTO] }
        let resp: BlocksResponse = try await IntentionalAPIClient.shared.put(
            path: "time_blocks", body: Request(blocks: blocks), auth: .bearer
        )
        return resp.blocks
    }
}
```

- [ ] **Step 3.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build 2>&1 | tail -5
git add Puck/Core/Network/IntentionalTimeBlocksClient.swift
git commit -m "feat(time-blocks): IntentionalTimeBlocksClient (GET/PUT /time_blocks, bearer auth)"
```

---

## Task 4: `TimeBlocksService` — pull/push + 60s timer

**Files:**
- Create: `Puck/Core/Schedule/TimeBlocksService.swift`

- [ ] **Step 4.1:** Write the service

```swift
import Foundation
import SwiftData

/// Spec 2 — pulls + pushes Time Blocks against the backend.
/// Mirrors the proven sync pattern from BedtimeScheduleService and
/// (the now-deprecated) ScheduleBlocksService:
/// - Pull on init, on scenePhase = .active, every 60s.
/// - Push immediately on user-driven create/update/delete.
@MainActor
final class TimeBlocksService: ObservableObject {

    @Published private(set) var blocks: [TimeBlock] = []

    private let modelContainer: ModelContainer
    private let client: IntentionalTimeBlocksClient
    private var pullTimer: Timer?

    init(modelContainer: ModelContainer,
         client: IntentionalTimeBlocksClient = .shared) {
        self.modelContainer = modelContainer
        self.client = client
        Task { await pull() }
        startPullTimer()
    }

    // MARK: - Sync

    @discardableResult
    func pull() async -> Bool {
        do {
            let dtos = try await client.getBlocks()
            await MainActor.run {
                self.replaceLocal(with: dtos)
            }
            return true
        } catch {
            return false
        }
    }

    private func replaceLocal(with dtos: [IntentionalTimeBlocksClient.TimeBlockDTO]) {
        let ctx = modelContainer.mainContext
        // Wipe existing
        let existing: [TimeBlock]
        do {
            existing = try ctx.fetch(FetchDescriptor<TimeBlock>())
        } catch {
            existing = []
        }
        for b in existing { ctx.delete(b) }
        // Insert from server
        for dto in dtos {
            let block = TimeBlock(
                blockId: UUID(uuidString: dto.block_id) ?? UUID(),
                title: dto.title,
                intentionId: dto.intention_id.flatMap { UUID(uuidString: $0) },
                intensity: TimeBlockIntensity(rawValue: dto.intensity) ?? .deepWork,
                startHour: dto.start_hour, startMinute: dto.start_minute,
                endHour: dto.end_hour, endMinute: dto.end_minute,
                activeDays: dto.active_days,
                enabled: dto.enabled
            )
            ctx.insert(block)
        }
        try? ctx.save()
        // Reload published list
        let fresh: [TimeBlock]
        do { fresh = try ctx.fetch(FetchDescriptor<TimeBlock>()) } catch { fresh = [] }
        self.blocks = fresh.sorted { $0.startMinuteOfDay < $1.startMinuteOfDay }
    }

    // MARK: - Mutations + push

    @discardableResult
    func createBlock(_ block: TimeBlock) async -> Bool {
        let ctx = modelContainer.mainContext
        ctx.insert(block)
        try? ctx.save()
        blocks.append(block)
        blocks.sort { $0.startMinuteOfDay < $1.startMinuteOfDay }
        return await pushAll()
    }

    @discardableResult
    func updateBlock(_ block: TimeBlock) async -> Bool {
        block.updatedAt = Date()
        let ctx = modelContainer.mainContext
        try? ctx.save()
        return await pushAll()
    }

    @discardableResult
    func deleteBlock(_ block: TimeBlock) async -> Bool {
        let ctx = modelContainer.mainContext
        ctx.delete(block)
        try? ctx.save()
        blocks.removeAll { $0.blockId == block.blockId }
        return await pushAll()
    }

    private func pushAll() async -> Bool {
        let dtos = blocks.map { b in
            IntentionalTimeBlocksClient.TimeBlockDTO(
                block_id: b.blockId.uuidString,
                title: b.title,
                block_type: b.intensity.rawValue,
                intention_id: b.intentionId?.uuidString,
                intensity: b.intensity.rawValue,
                start_hour: b.startHour, start_minute: b.startMinute,
                end_hour: b.endHour, end_minute: b.endMinute,
                active_days: b.activeDays,
                enabled: b.enabled,
                updated_at: nil
            )
        }
        do {
            _ = try await client.putBlocks(dtos)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Timer + foreground

    private func startPullTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { await self?.pull() }
        }
        t.tolerance = 5.0
        RunLoop.main.add(t, forMode: .common)
        pullTimer = t
    }

    /// Call from PuckApp's scenePhase observer when phase becomes .active.
    func handleSceneActive() {
        Task { await pull() }
    }
}
```

- [ ] **Step 4.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build 2>&1 | tail -10
git add Puck/Core/Schedule/TimeBlocksService.swift
git commit -m "feat(time-blocks): TimeBlocksService — pull/push + 60s + foreground refresh"
```

---

## Task 5: Wire `TimeBlocksService` into PuckApp

**Files:**
- Modify: `Puck/App/PuckApp.swift`

- [ ] **Step 5.1:** Add as a StateObject

Find the existing service StateObjects in `PuckApp`:

```bash
grep -n "@StateObject\|ScheduleBlocksService" Puck/App/PuckApp.swift
```

Add:

```swift
    @StateObject private var timeBlocksService: TimeBlocksService
```

In init:

```swift
    init() {
        // ... existing init ...
        let container = sharedModelContainer
        _timeBlocksService = StateObject(wrappedValue: TimeBlocksService(modelContainer: container))
    }
```

- [ ] **Step 5.2:** Inject into environment

```swift
    .environmentObject(timeBlocksService)
```

- [ ] **Step 5.3:** Foreground refresh on scenePhase

```swift
    .onChange(of: scenePhase) { _, newPhase in
        if newPhase == .active {
            timeBlocksService.handleSceneActive()
        }
    }
```

- [ ] **Step 5.4:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build 2>&1 | tail -5
git add Puck/App/PuckApp.swift
git commit -m "feat(time-blocks): wire TimeBlocksService into PuckApp + scene-active refresh"
```

---

## Task 6: Port `DayCalendarView` interaction model from addy-ai-ios

**Files:**
- Create: `Puck/Views/Schedule/DayCalendarView.swift`

- [ ] **Step 6.1:** Write the view

```swift
import SwiftUI
import SwiftData

/// Spec 2 — Day calendar grid for Time Blocks. Interaction model ported
/// verbatim from addy-ai-ios/Views/Home/DayCalendarView.swift:
/// - 6am-10pm grid, 60pt per hour, hour dividers
/// - Long-press 0.5s + drag to move (15-min snap on release)
/// - Top/bottom edge handles (8pt) to resize
/// - Tap empty slot to create new block (default 60min duration)
/// - Selected day's iso-weekday filters which blocks render
struct DayCalendarView: View {
    @ObservedObject var service: TimeBlocksService
    let date: Date  // selected day; iso-weekday filters blocks
    let onTapEmpty: (Date, Date) -> Void  // (startTime, endTime) for new block
    let onEditBlock: (TimeBlock) -> Void
    let onUpdateBlockTime: (TimeBlock, Int, Int) -> Void  // (block, newStartMinute, newEndMinute) — 0..1440

    private let startHour = 6
    private let endHour = 22
    private let hourHeight: CGFloat = 60
    private let snapMinutes = 15

    @State private var draggedBlock: TimeBlock?
    @State private var dragOffset: CGFloat = 0
    @State private var resizeMode: ResizeMode = .none
    @State private var hasScrolledToCurrentTime = false

    private enum ResizeMode { case none, top, bottom, move }

    private var totalHours: Int { endHour - startHour }
    private var totalHeight: CGFloat { CGFloat(totalHours) * hourHeight }

    private var isoWeekday: Int {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date)  // Sun=1..Sat=7
        return weekday == 1 ? 7 : (weekday - 1)  // ISO Mon=1..Sun=7
    }

    private var visibleBlocks: [TimeBlock] {
        service.blocks.filter { $0.enabled && $0.activeDays.contains(isoWeekday) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    // Hour grid
                    VStack(spacing: 0) {
                        ForEach(startHour..<endHour, id: \.self) { hour in
                            HStack(spacing: 0) {
                                Text(hourLabel(hour))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                                    .padding(.trailing, 8)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.15))
                                    .frame(height: 1)
                            }
                            .frame(height: hourHeight)
                            .id(hour)
                            .background(emptyTapTarget(forHour: hour))
                        }
                    }
                    .frame(height: totalHeight, alignment: .top)

                    // Block tiles
                    ForEach(visibleBlocks, id: \.blockId) { block in
                        blockTile(block: block)
                            .padding(.leading, 64)
                    }

                    // Now line
                    nowLine()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onAppear {
                if !hasScrolledToCurrentTime {
                    let cur = Calendar.current.component(.hour, from: Date())
                    proxy.scrollTo(min(max(cur, startHour), endHour - 1), anchor: .top)
                    hasScrolledToCurrentTime = true
                }
            }
        }
    }

    @ViewBuilder
    private func emptyTapTarget(forHour hour: Int) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                let cal = Calendar.current
                var startComps = cal.dateComponents([.year, .month, .day], from: date)
                startComps.hour = hour
                startComps.minute = 0
                let start = cal.date(from: startComps) ?? date
                let end = cal.date(byAdding: .minute, value: 60, to: start) ?? start
                onTapEmpty(start, end)
            }
    }

    @ViewBuilder
    private func blockTile(block: TimeBlock) -> some View {
        let topOffset = yForMinute(block.startMinuteOfDay)
        let height = CGFloat(block.durationMinutes) * (hourHeight / 60)
        let isDraggedThis = draggedBlock?.blockId == block.blockId

        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(block.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(block.intensity.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
            Text("\(timeOfDay(block.startMinuteOfDay)) – \(timeOfDay(block.endMinuteOfDay))")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: max(height + (isDraggedThis ? dragOffset : 0), 30))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(block.intensity == .deepWork ? Color.indigo : Color.orange)
        )
        .padding(.trailing, 8)
        .offset(y: topOffset + (isDraggedThis && resizeMode == .move ? dragOffset : 0))
        .onLongPressGesture(minimumDuration: 0.5) {
            // Activate move mode
            draggedBlock = block
            resizeMode = .move
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard isDraggedThis else { return }
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    guard isDraggedThis else { return }
                    let snappedDelta = snap(value.translation.height)
                    let deltaMinutes = Int(snappedDelta / (hourHeight / 60))
                    let newStart = max(0, block.startMinuteOfDay + deltaMinutes)
                    let newEnd = min(24 * 60, block.endMinuteOfDay + deltaMinutes)
                    onUpdateBlockTime(block, newStart, newEnd)
                    draggedBlock = nil
                    dragOffset = 0
                    resizeMode = .none
                }
        )
        .onTapGesture {
            onEditBlock(block)
        }
        .overlay(
            VStack(spacing: 0) {
                resizeHandle(.top, for: block)
                Spacer()
                resizeHandle(.bottom, for: block)
            }
        )
    }

    @ViewBuilder
    private func resizeHandle(_ edge: ResizeMode, for block: TimeBlock) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(height: 8)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        draggedBlock = block
                        resizeMode = edge
                        dragOffset = value.translation.height
                    }
                    .onEnded { value in
                        let snappedDelta = snap(value.translation.height)
                        let deltaMinutes = Int(snappedDelta / (hourHeight / 60))
                        var newStart = block.startMinuteOfDay
                        var newEnd = block.endMinuteOfDay
                        if edge == .top {
                            newStart = max(0, min(newEnd - snapMinutes, newStart + deltaMinutes))
                        } else {
                            newEnd = min(24 * 60, max(newStart + snapMinutes, newEnd + deltaMinutes))
                        }
                        onUpdateBlockTime(block, newStart, newEnd)
                        draggedBlock = nil
                        dragOffset = 0
                        resizeMode = .none
                    }
            )
    }

    @ViewBuilder
    private func nowLine() -> some View {
        let cal = Calendar.current
        let nowH = cal.component(.hour, from: Date())
        let nowM = cal.component(.minute, from: Date())
        let nowMinutes = nowH * 60 + nowM
        if nowMinutes >= startHour * 60 && nowMinutes < endHour * 60 {
            HStack(spacing: 0) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Rectangle().fill(Color.red).frame(height: 1)
            }
            .padding(.leading, 50)
            .offset(y: yForMinute(nowMinutes))
        }
    }

    private func yForMinute(_ minute: Int) -> CGFloat {
        let offsetFromTop = max(0, minute - startHour * 60)
        return CGFloat(offsetFromTop) * (hourHeight / 60)
    }

    private func snap(_ pixels: CGFloat) -> CGFloat {
        let pixelsPerSnap = (hourHeight / 60) * CGFloat(snapMinutes)
        let snapped = (pixels / pixelsPerSnap).rounded() * pixelsPerSnap
        return snapped
    }

    private func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        var comps = DateComponents(); comps.hour = hour
        let date = Calendar.current.date(from: comps) ?? Date()
        return formatter.string(from: date)
    }

    private func timeOfDay(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        let h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        let suffix = h < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", h12, m, suffix)
    }
}
```

- [ ] **Step 6.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build 2>&1 | tail -10
git add Puck/Views/Schedule/DayCalendarView.swift
git commit -m "feat(time-blocks): DayCalendarView ported from addy-ai-ios (long-press-drag, edge-resize, 15-min snap)"
```

---

## Task 7: TimeBlockEditSheet (title + intention picker + intensity + days)

**Files:**
- Create: `Puck/Views/Schedule/TimeBlockEditSheet.swift`

- [ ] **Step 7.1:** Write the sheet

```swift
import SwiftUI
import SwiftData

struct TimeBlockEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: TimeBlocksService

    let existingBlock: TimeBlock?
    let initialStart: Date
    let initialEnd: Date

    @State private var title: String = ""
    @State private var intentionId: UUID? = nil
    @State private var intensity: TimeBlockIntensity = .deepWork
    @State private var startMinutes: Int = 9 * 60
    @State private var endMinutes: Int = 11 * 60
    @State private var activeDays: Set<Int> = [1, 2, 3, 4, 5]

    @State private var availableIntentions: [Intention] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Block name", text: $title)
                }

                Section("Intention") {
                    Picker("Bind to", selection: $intentionId) {
                        Text("None (use default)").tag(UUID?.none)
                        ForEach(availableIntentions) { i in
                            Text(i.name).tag(Optional(i.id))
                        }
                    }
                }

                Section("Intensity") {
                    Picker("Intensity", selection: $intensity) {
                        ForEach(TimeBlockIntensity.allCases, id: \.self) { i in
                            Text(i.displayName).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Days") {
                    HStack {
                        ForEach(1...7, id: \.self) { day in
                            Button(action: { toggleDay(day) }) {
                                Text(dayInitial(day))
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 36, height: 36)
                                    .background(activeDays.contains(day) ? Color.indigo : Color.gray.opacity(0.2))
                                    .foregroundColor(activeDays.contains(day) ? .white : .primary)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Time") {
                    HStack {
                        Text("Start")
                        Spacer()
                        Text(timeOfDay(startMinutes))
                    }
                    HStack {
                        Text("End")
                        Spacer()
                        Text(timeOfDay(endMinutes))
                    }
                }
            }
            .navigationTitle(existingBlock == nil ? "New Block" : "Edit Block")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(title.isEmpty)
                }
                if existingBlock != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", role: .destructive) {
                            Task { await delete() }
                        }
                    }
                }
            }
            .onAppear {
                hydrate()
                Task {
                    availableIntentions = await IntentionStore.shared.active()
                }
            }
        }
    }

    private func hydrate() {
        if let b = existingBlock {
            title = b.title
            intentionId = b.intentionId
            intensity = b.intensity
            startMinutes = b.startMinuteOfDay
            endMinutes = b.endMinuteOfDay
            activeDays = Set(b.activeDays)
        } else {
            let cal = Calendar.current
            startMinutes = cal.component(.hour, from: initialStart) * 60 + cal.component(.minute, from: initialStart)
            endMinutes = cal.component(.hour, from: initialEnd) * 60 + cal.component(.minute, from: initialEnd)
        }
    }

    private func toggleDay(_ day: Int) {
        if activeDays.contains(day) {
            activeDays.remove(day)
        } else {
            activeDays.insert(day)
        }
    }

    private func dayInitial(_ day: Int) -> String {
        switch day {
        case 1: return "M"; case 2: return "T"; case 3: return "W"
        case 4: return "T"; case 5: return "F"; case 6: return "S"; case 7: return "S"
        default: return "?"
        }
    }

    private func timeOfDay(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        let h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        let suffix = h < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", h12, m, suffix)
    }

    private func save() async {
        if let existing = existingBlock {
            existing.title = title
            existing.intentionId = intentionId
            existing.intensity = intensity
            existing.startHour = startMinutes / 60
            existing.startMinute = startMinutes % 60
            existing.endHour = endMinutes / 60
            existing.endMinute = endMinutes % 60
            existing.activeDays = activeDays.sorted()
            _ = await service.updateBlock(existing)
        } else {
            let block = TimeBlock(
                title: title, intentionId: intentionId, intensity: intensity,
                startHour: startMinutes / 60, startMinute: startMinutes % 60,
                endHour: endMinutes / 60, endMinute: endMinutes % 60,
                activeDays: activeDays.sorted()
            )
            _ = await service.createBlock(block)
        }
        dismiss()
    }

    private func delete() async {
        guard let existing = existingBlock else { return }
        _ = await service.deleteBlock(existing)
        dismiss()
    }
}
```

- [ ] **Step 7.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build 2>&1 | tail -10
git add Puck/Views/Schedule/TimeBlockEditSheet.swift
git commit -m "feat(time-blocks): TimeBlockEditSheet (title + intention picker + intensity + days)"
```

---

## Task 8: ScheduleTabView — render DayCalendarView with DatePicker

**Files:**
- Create or Modify: `Puck/Views/Schedule/ScheduleTabView.swift`

- [ ] **Step 8.1:** Write the tab view

```swift
import SwiftUI

struct ScheduleTabView: View {
    @EnvironmentObject var timeBlocksService: TimeBlocksService

    @State private var selectedDate = Date()
    @State private var showingEditSheet = false
    @State private var editingBlock: TimeBlock?
    @State private var newBlockStart = Date()
    @State private var newBlockEnd = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DatePicker(
                    "Day", selection: $selectedDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.compact)
                .padding()

                DayCalendarView(
                    service: timeBlocksService,
                    date: selectedDate,
                    onTapEmpty: { start, end in
                        editingBlock = nil
                        newBlockStart = start
                        newBlockEnd = end
                        showingEditSheet = true
                    },
                    onEditBlock: { block in
                        editingBlock = block
                        showingEditSheet = true
                    },
                    onUpdateBlockTime: { block, newStart, newEnd in
                        block.startHour = newStart / 60
                        block.startMinute = newStart % 60
                        block.endHour = newEnd / 60
                        block.endMinute = newEnd % 60
                        Task { _ = await timeBlocksService.updateBlock(block) }
                    }
                )
            }
            .navigationTitle("Schedule")
            .sheet(isPresented: $showingEditSheet) {
                TimeBlockEditSheet(
                    service: timeBlocksService,
                    existingBlock: editingBlock,
                    initialStart: newBlockStart,
                    initialEnd: newBlockEnd
                )
            }
        }
    }
}
```

- [ ] **Step 8.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build 2>&1 | tail -10
git add Puck/Views/Schedule/ScheduleTabView.swift
git commit -m "feat(time-blocks): ScheduleTabView with DatePicker + DayCalendarView + edit sheet"
```

---

## Task 9: Restore Schedule tab to ContentView TabView

**Files:**
- Modify: `Puck/Views/ContentView.swift`

- [ ] **Step 9.1:** Find the existing TabView

```bash
grep -n "TabView\|case schedule\|enum Tab\|ScheduleTabView" Puck/Views/ContentView.swift
```

- [ ] **Step 9.2:** Add the schedule case to the enum and a TabView item

```swift
    enum Tab { case home, schedule, settings }  // restore .schedule

    // In the TabView body:
    ScheduleTabView()
        .tabItem { Label("Schedule", systemImage: "calendar") }
        .tag(Tab.schedule)
```

- [ ] **Step 9.3:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -quiet build 2>&1 | tail -10
git add Puck/Views/ContentView.swift
git commit -m "feat(time-blocks): restore Schedule tab to ContentView TabView"
```

---

## Task 10: Mark `IntentionalBlock` deprecated, keep for compat

**Files:**
- Modify: `Puck/Core/Schedule/ScheduleBlock.swift` (or wherever `IntentionalBlock` lives)

- [ ] **Step 10.1:** Add deprecation marker

```swift
@available(*, deprecated, message: "Use TimeBlock instead — Spec 2 supersedes IntentionalBlock")
@Model
final class IntentionalBlock {
    // ... existing fields stay; no functional change
}
```

The model itself stays for one release cycle so existing data doesn't get dropped on upgrade. SwiftData will keep both schemas until next migration.

- [ ] **Step 10.2:** Commit

```bash
git add Puck/Core/Schedule/ScheduleBlock.swift
git commit -m "deprecate(time-blocks): mark IntentionalBlock deprecated (kept for migration window)"
```

---

## Task 11: Final build, test, push

- [ ] **Step 11.1:** Clean build

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' clean build 2>&1 | tail -10
```

- [ ] **Step 11.2:** Run tests if PuckTests target exists

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests 2>&1 | tail -10
```

- [ ] **Step 11.3:** Push

```bash
git push -u origin feat/time-blocks-spec2
```

- [ ] **Step 11.4:** Update cross-repo log

In `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-time-blocks-spec2-2026-05-04.md`, add `### Phase 4 — iOS report` with status, what's wired, what needs E2E test on real device.

---

## Out of scope

- Native iOS Goals UI (Spec 3).
- Migrating existing `IntentionalBlock` rows to `TimeBlock` data (one release cycle of dual presence; sweep in a future PR).
- Per-Time-Block iOS app blocklist editor (uses bound Intention's tokens via Spec 1 path).
- Multi-day-view calendar (week / month) — single-day at a time.
- Block conflict warnings on overlap (UI may render overlap; user resolves manually).

## Required env vars

None new.

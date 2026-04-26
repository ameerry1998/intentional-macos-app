# Focus Mode Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add blocking profiles (reusable block lists of apps + sites), on-demand focus sessions with a full-screen start overlay, mock Puck trigger (Cmd+Shift+P), and Intentional Mode adaptation that hides free time during Puck focus.

**Architecture:** New `BlockingProfileManager` handles CRUD + merging of profiles. New `FocusSessionManager` owns start/stop/restore of focus sessions with disk persistence. New `FocusStartOverlay` is the SwiftUI picker shown on focus trigger. All wire into existing `WebsiteBlocker`, `FilterManager`, and `FocusMonitor` via AppDelegate. `IntentionalModeController` modified to hide free time when Puck session active.

**Tech Stack:** Swift, SwiftUI, AppKit (NSWindow, NSEvent.addGlobalMonitorForEvents), Foundation (JSON persistence)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Intentional/BlockingProfileManager.swift` | Create | CRUD for blocking profiles, merging multiple profiles into one block list, persistence |
| `Intentional/FocusSessionManager.swift` | Create | Start/stop/restore focus sessions, disk persistence, enforcement wiring |
| `Intentional/FocusStartOverlay.swift` | Create | SwiftUI overlay for picking profiles + typing intention on focus start |
| `IntentionalTests/BlockingProfileTests.swift` | Create | Tests for profile CRUD, merging, default profile |
| `IntentionalTests/FocusSessionTests.swift` | Create | Tests for session start/stop/restore, Puck vs app-triggered |
| `Intentional/AppDelegate.swift` | Modify | Instantiate managers, wire Puck hotkey, add menu bar focus toggle |
| `Intentional/IntentionalModeController.swift` | Modify | Hide free time option when Puck session active |
| `Intentional/MainWindow.swift` | Modify | Add profile management message handlers |
| `Intentional/WebsiteBlocker.swift` | Modify (minor) | Accept merged block list from FocusSessionManager |

---

## Task 1: BlockingProfileManager — Data Model + CRUD (TDD)

**Files:**
- Create: `Intentional/BlockingProfileManager.swift`
- Create: `IntentionalTests/BlockingProfileTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// IntentionalTests/BlockingProfileTests.swift
import Foundation

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b { passed += 1 }
    else { failed += 1; print("  FAIL (\(file):\(line)): expected \(b), got \(a). \(msg)") }
}

func test(_ name: String, _ body: () -> Void) { print("  ▸ \(name)"); body() }

@main
struct BlockingProfileTests {
    static func main() {
        print("\n🧪 BlockingProfileTests\n")

        test("default profile exists on init") {
            let mgr = BlockingProfileManager(settingsDir: "/tmp/bp-test-\(UUID())")
            assertEqual(mgr.profiles.count, 1)
            assertEqual(mgr.profiles[0].isDefault, true)
            assertEqual(mgr.profiles[0].name, "Distracting Apps & Sites")
        }

        test("default profile has social media domains") {
            let mgr = BlockingProfileManager(settingsDir: "/tmp/bp-test-\(UUID())")
            let defaults = mgr.profiles[0]
            assertEqual(defaults.blockedDomains.contains("reddit.com"), true)
            assertEqual(defaults.blockedDomains.contains("youtube.com"), true)
            assertEqual(defaults.blockedDomains.contains("twitter.com"), true)
        }

        test("create custom profile") {
            let mgr = BlockingProfileManager(settingsDir: "/tmp/bp-test-\(UUID())")
            let profile = mgr.createProfile(name: "Writing", domains: ["news.ycombinator.com"], appBundleIds: ["com.spotify.client"])
            assertEqual(mgr.profiles.count, 2)
            assertEqual(profile.name, "Writing")
            assertEqual(profile.blockedDomains, ["news.ycombinator.com"])
            assertEqual(profile.blockedAppBundleIds, ["com.spotify.client"])
            assertEqual(profile.isDefault, false)
        }

        test("delete custom profile") {
            let mgr = BlockingProfileManager(settingsDir: "/tmp/bp-test-\(UUID())")
            let profile = mgr.createProfile(name: "Test", domains: [], appBundleIds: [])
            assertEqual(mgr.profiles.count, 2)
            let deleted = mgr.deleteProfile(id: profile.id)
            assertEqual(deleted, true)
            assertEqual(mgr.profiles.count, 1)
        }

        test("cannot delete default profile") {
            let mgr = BlockingProfileManager(settingsDir: "/tmp/bp-test-\(UUID())")
            let defaultId = mgr.profiles[0].id
            let deleted = mgr.deleteProfile(id: defaultId)
            assertEqual(deleted, false)
            assertEqual(mgr.profiles.count, 1)
        }

        test("merge multiple profiles into one block list") {
            let mgr = BlockingProfileManager(settingsDir: "/tmp/bp-test-\(UUID())")
            let p2 = mgr.createProfile(name: "Extra", domains: ["news.ycombinator.com", "reddit.com"], appBundleIds: ["com.spotify.client"])
            let defaultId = mgr.profiles[0].id
            let merged = mgr.mergedBlockList(profileIds: [defaultId, p2.id])
            // reddit.com should appear once (deduped)
            assertEqual(merged.domains.filter { $0 == "reddit.com" }.count, 1)
            // news.ycombinator.com from p2
            assertEqual(merged.domains.contains("news.ycombinator.com"), true)
            // spotify from p2
            assertEqual(merged.appBundleIds.contains("com.spotify.client"), true)
        }

        test("merge with unknown profile ID ignores it") {
            let mgr = BlockingProfileManager(settingsDir: "/tmp/bp-test-\(UUID())")
            let defaultId = mgr.profiles[0].id
            let merged = mgr.mergedBlockList(profileIds: [defaultId, UUID()])
            assertEqual(merged.domains.contains("reddit.com"), true)
        }

        test("update profile domains") {
            let mgr = BlockingProfileManager(settingsDir: "/tmp/bp-test-\(UUID())")
            let p = mgr.createProfile(name: "Test", domains: ["a.com"], appBundleIds: [])
            mgr.updateProfile(id: p.id, domains: ["a.com", "b.com"], appBundleIds: ["com.test"])
            let updated = mgr.profiles.first { $0.id == p.id }!
            assertEqual(updated.blockedDomains, ["a.com", "b.com"])
            assertEqual(updated.blockedAppBundleIds, ["com.test"])
        }

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed > 0 ? 1 : 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/arayan/Documents/GitHub/intentional-macos-app && swiftc -o /tmp/bp-test Intentional/BlockingProfileManager.swift IntentionalTests/BlockingProfileTests.swift && /tmp/bp-test`
Expected: Compile error — `BlockingProfileManager` not defined

- [ ] **Step 3: Write minimal implementation**

```swift
// Intentional/BlockingProfileManager.swift
import Foundation

struct BlockingProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var blockedDomains: [String]
    var blockedAppBundleIds: [String]
    var isDefault: Bool
}

struct MergedBlockList {
    let domains: [String]
    let appBundleIds: [String]
}

class BlockingProfileManager {
    private(set) var profiles: [BlockingProfile] = []
    private let settingsDir: String

    private var fileURL: URL {
        URL(fileURLWithPath: settingsDir).appendingPathComponent("blocking_profiles.json")
    }

    init(settingsDir: String? = nil) {
        if let dir = settingsDir {
            self.settingsDir = dir
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Intentional").path
            self.settingsDir = appSupport
            try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        }
        load()
        if profiles.isEmpty {
            profiles = [Self.makeDefaultProfile()]
            save()
        }
    }

    static func makeDefaultProfile() -> BlockingProfile {
        BlockingProfile(
            id: UUID(),
            name: "Distracting Apps & Sites",
            blockedDomains: [
                "reddit.com", "twitter.com", "x.com", "youtube.com",
                "instagram.com", "facebook.com", "tiktok.com",
                "twitch.tv", "discord.com", "snapchat.com"
            ],
            blockedAppBundleIds: [
                "com.spotify.client", "tv.twitch.app",
                "com.hnc.Discord", "com.valvesoftware.steam"
            ],
            isDefault: true
        )
    }

    func createProfile(name: String, domains: [String], appBundleIds: [String]) -> BlockingProfile {
        let profile = BlockingProfile(id: UUID(), name: name, blockedDomains: domains, blockedAppBundleIds: appBundleIds, isDefault: false)
        profiles.append(profile)
        save()
        return profile
    }

    func deleteProfile(id: UUID) -> Bool {
        guard let idx = profiles.firstIndex(where: { $0.id == id }), !profiles[idx].isDefault else { return false }
        profiles.remove(at: idx)
        save()
        return true
    }

    func updateProfile(id: UUID, name: String? = nil, domains: [String]? = nil, appBundleIds: [String]? = nil) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        if let name = name { profiles[idx].name = name }
        if let domains = domains { profiles[idx].blockedDomains = domains }
        if let appBundleIds = appBundleIds { profiles[idx].blockedAppBundleIds = appBundleIds }
        save()
    }

    func mergedBlockList(profileIds: [UUID]) -> MergedBlockList {
        var domains = Set<String>()
        var apps = Set<String>()
        for id in profileIds {
            guard let profile = profiles.first(where: { $0.id == id }) else { continue }
            profile.blockedDomains.forEach { domains.insert($0) }
            profile.blockedAppBundleIds.forEach { apps.insert($0) }
        }
        return MergedBlockList(domains: Array(domains).sorted(), appBundleIds: Array(apps).sorted())
    }

    func profile(for id: UUID) -> BlockingProfile? {
        profiles.first { $0.id == id }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([BlockingProfile].self, from: data) else { return }
        profiles = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/arayan/Documents/GitHub/intentional-macos-app && swiftc -o /tmp/bp-test Intentional/BlockingProfileManager.swift IntentionalTests/BlockingProfileTests.swift && /tmp/bp-test`
Expected: All 8 tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/BlockingProfileManager.swift IntentionalTests/BlockingProfileTests.swift
git commit -m "feat: add BlockingProfileManager with CRUD, merging, and default profile (TDD)"
```

---

## Task 2: FocusSessionManager — Session Lifecycle (TDD)

**Files:**
- Create: `Intentional/FocusSessionManager.swift`
- Create: `IntentionalTests/FocusSessionTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// IntentionalTests/FocusSessionTests.swift
import Foundation

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b { passed += 1 }
    else { failed += 1; print("  FAIL (\(file):\(line)): expected \(b), got \(a). \(msg)") }
}

func test(_ name: String, _ body: () -> Void) { print("  ▸ \(name)"); body() }

@main
struct FocusSessionTests {
    static func main() {
        print("\n🧪 FocusSessionTests\n")

        let dir = "/tmp/fs-test-\(UUID())"

        test("no active session initially") {
            let mgr = FocusSessionManager(settingsDir: dir + "/1")
            assertEqual(mgr.activeSession == nil, true)
            assertEqual(mgr.isActive, false)
        }

        test("start session creates active session") {
            let mgr = FocusSessionManager(settingsDir: dir + "/2")
            let profileId = UUID()
            mgr.startSession(profileIds: [profileId], intention: "writing blog", aiEnabled: true, triggeredByPuck: false)
            assertEqual(mgr.isActive, true)
            assertEqual(mgr.activeSession?.activeProfileIds.count, 1)
            assertEqual(mgr.activeSession?.intention, "writing blog")
            assertEqual(mgr.activeSession?.aiScoringEnabled, true)
            assertEqual(mgr.activeSession?.triggeredByPuck, false)
        }

        test("stop session clears active session") {
            let mgr = FocusSessionManager(settingsDir: dir + "/3")
            mgr.startSession(profileIds: [UUID()], intention: nil, aiEnabled: false, triggeredByPuck: false)
            assertEqual(mgr.isActive, true)
            mgr.stopSession()
            assertEqual(mgr.isActive, false)
            assertEqual(mgr.activeSession == nil, true)
        }

        test("session persists to disk") {
            let testDir = dir + "/4"
            let mgr1 = FocusSessionManager(settingsDir: testDir)
            let profileId = UUID()
            mgr1.startSession(profileIds: [profileId], intention: "coding", aiEnabled: false, triggeredByPuck: true)

            // New instance should restore session
            let mgr2 = FocusSessionManager(settingsDir: testDir)
            assertEqual(mgr2.isActive, true)
            assertEqual(mgr2.activeSession?.intention, "coding")
            assertEqual(mgr2.activeSession?.triggeredByPuck, true)
        }

        test("stop session deletes file from disk") {
            let testDir = dir + "/5"
            let mgr = FocusSessionManager(settingsDir: testDir)
            mgr.startSession(profileIds: [UUID()], intention: nil, aiEnabled: false, triggeredByPuck: false)
            mgr.stopSession()

            let mgr2 = FocusSessionManager(settingsDir: testDir)
            assertEqual(mgr2.isActive, false)
        }

        test("puck-triggered session flag persists") {
            let testDir = dir + "/6"
            let mgr = FocusSessionManager(settingsDir: testDir)
            mgr.startSession(profileIds: [UUID()], intention: nil, aiEnabled: false, triggeredByPuck: true)
            assertEqual(mgr.activeSession?.triggeredByPuck, true)
        }

        test("session without intention or profiles is valid if at least one provided") {
            let mgr = FocusSessionManager(settingsDir: dir + "/7")
            mgr.startSession(profileIds: [UUID()], intention: nil, aiEnabled: false, triggeredByPuck: false)
            assertEqual(mgr.isActive, true)
        }

        test("session with only intention is valid") {
            let mgr = FocusSessionManager(settingsDir: dir + "/8")
            mgr.startSession(profileIds: [], intention: "thinking about architecture", aiEnabled: true, triggeredByPuck: false)
            assertEqual(mgr.isActive, true)
        }

        print("\n\(passed) passed, \(failed) failed\n")
        exit(failed > 0 ? 1 : 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/arayan/Documents/GitHub/intentional-macos-app && swiftc -o /tmp/fs-test Intentional/FocusSessionManager.swift IntentionalTests/FocusSessionTests.swift && /tmp/fs-test`
Expected: Compile error — `FocusSessionManager` not defined

- [ ] **Step 3: Write minimal implementation**

```swift
// Intentional/FocusSessionManager.swift
import Foundation

struct FocusSession: Codable {
    let startedAt: Date
    let activeProfileIds: [UUID]
    let intention: String?
    let aiScoringEnabled: Bool
    let triggeredByPuck: Bool
}

class FocusSessionManager {
    private(set) var activeSession: FocusSession?
    private let settingsDir: String

    var isActive: Bool { activeSession != nil }

    private var fileURL: URL {
        URL(fileURLWithPath: settingsDir).appendingPathComponent("focus_session.json")
    }

    init(settingsDir: String? = nil) {
        if let dir = settingsDir {
            self.settingsDir = dir
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Intentional").path
            self.settingsDir = appSupport
        }
        restore()
    }

    func startSession(profileIds: [UUID], intention: String?, aiEnabled: Bool, triggeredByPuck: Bool) {
        let session = FocusSession(
            startedAt: Date(),
            activeProfileIds: profileIds,
            intention: intention,
            aiScoringEnabled: aiEnabled,
            triggeredByPuck: triggeredByPuck
        )
        activeSession = session
        persist()
    }

    func stopSession() {
        activeSession = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        guard let session = activeSession,
              let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: fileURL),
              let session = try? JSONDecoder().decode(FocusSession.self, from: data) else { return }
        activeSession = session
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/arayan/Documents/GitHub/intentional-macos-app && swiftc -o /tmp/fs-test Intentional/FocusSessionManager.swift IntentionalTests/FocusSessionTests.swift && /tmp/fs-test`
Expected: All 8 tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/FocusSessionManager.swift IntentionalTests/FocusSessionTests.swift
git commit -m "feat: add FocusSessionManager with session lifecycle and disk persistence (TDD)"
```

---

## Task 3: FocusStartOverlay — SwiftUI Picker View

**Files:**
- Create: `Intentional/FocusStartOverlay.swift`

- [ ] **Step 1: Create the SwiftUI overlay view**

The overlay has two modes:
- **App-triggered:** "What are you working on?" — pick profiles, type intention, Start Focus
- **Puck-triggered:** "Distractions blocked. Want to plan?" — default profile already active, "Just block" or "Plan my session"

```swift
// Intentional/FocusStartOverlay.swift
import SwiftUI
import AppKit

class FocusStartOverlayViewModel: ObservableObject {
    @Published var availableProfiles: [BlockingProfile] = []
    @Published var selectedProfileIds: Set<UUID> = []
    @Published var intentionText: String = ""
    @Published var aiScoringEnabled: Bool = false
    @Published var isPuckTriggered: Bool = false
    @Published var showPlanner: Bool = false

    var onStartFocus: ((_ profileIds: [UUID], _ intention: String?, _ aiEnabled: Bool) -> Void)?
    var onCancel: (() -> Void)?

    var canStart: Bool {
        !selectedProfileIds.isEmpty || !intentionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct FocusStartOverlayView: View {
    @ObservedObject var viewModel: FocusStartOverlayViewModel

    var body: some View {
        ZStack {
            // Dark background
            LinearGradient(
                colors: [Color(white: 0.06), Color(white: 0.03)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 28) {
                Spacer()

                if viewModel.isPuckTriggered && !viewModel.showPlanner {
                    // Puck mode: quick choice
                    puckQuickView
                } else {
                    // Full planner (app-triggered or Puck "Plan my session")
                    plannerView
                }

                Spacer()
                    .frame(height: 60)
            }
            .padding(.horizontal, 80)
        }
        .ignoresSafeArea()
    }

    // MARK: - Puck Quick View

    private var puckQuickView: some View {
        VStack(spacing: 24) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 56))
                .foregroundColor(Color(white: 0.5))

            Text("Distractions Blocked")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(Color(white: 0.75))

            Text("Your default blocking list is active.")
                .font(.system(size: 20))
                .foregroundColor(Color(white: 0.4))

            VStack(spacing: 14) {
                Button(action: {
                    viewModel.onStartFocus?(Array(viewModel.selectedProfileIds), nil, false)
                }) {
                    Text("Just Block Distractions")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Color(white: 0.8))
                        .frame(width: 320, height: 52)
                        .background(Color(white: 0.1))
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(white: 0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.showPlanner = true }) {
                    Text("Plan My Session")
                        .font(.system(size: 16))
                        .foregroundColor(Color(white: 0.45))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Planner View

    private var plannerView: some View {
        VStack(spacing: 24) {
            Text("What are you working on?")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(Color(white: 0.75))

            // Blocking profiles
            VStack(alignment: .leading, spacing: 10) {
                Text("BLOCKING PROFILES")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.4))
                    .tracking(1.5)

                FlowLayout(spacing: 10) {
                    ForEach(viewModel.availableProfiles) { profile in
                        let isSelected = viewModel.selectedProfileIds.contains(profile.id)
                        Button(action: {
                            if isSelected { viewModel.selectedProfileIds.remove(profile.id) }
                            else { viewModel.selectedProfileIds.insert(profile.id) }
                        }) {
                            HStack(spacing: 6) {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                Text(profile.name)
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundColor(isSelected ? .white : Color(white: 0.6))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(isSelected ? Color.blue.opacity(0.3) : Color(white: 0.1))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isSelected ? Color.blue.opacity(0.5) : Color(white: 0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // AI Intention
            VStack(alignment: .leading, spacing: 8) {
                Text("AI FOCUS (OPTIONAL)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(white: 0.4))
                    .tracking(1.5)

                TextField("Describe your task for AI scoring...", text: $viewModel.intentionText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundColor(Color(white: 0.8))
                    .padding(16)
                    .background(Color(white: 0.08))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.15), lineWidth: 1))
            }

            // Start button
            HStack(spacing: 16) {
                if viewModel.isPuckTriggered {
                    Button("Back") { viewModel.showPlanner = false }
                        .font(.system(size: 16))
                        .foregroundColor(Color(white: 0.4))
                        .buttonStyle(.plain)
                } else {
                    Button("Cancel") { viewModel.onCancel?() }
                        .font(.system(size: 16))
                        .foregroundColor(Color(white: 0.4))
                        .buttonStyle(.plain)
                }

                Button(action: {
                    let intention = viewModel.intentionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.onStartFocus?(
                        Array(viewModel.selectedProfileIds),
                        intention.isEmpty ? nil : intention,
                        viewModel.aiScoringEnabled && !intention.isEmpty
                    )
                }) {
                    Text("Start Focus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(viewModel.canStart ? .white : Color(white: 0.3))
                        .frame(width: 200, height: 50)
                        .background(viewModel.canStart ? Color.blue : Color(white: 0.1))
                        .cornerRadius(14)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canStart)
            }
            .padding(.top, 8)
        }
    }
}

// Simple flow layout for profile chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? 0, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, point) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: width, height: y + rowHeight), positions)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/arayan/Documents/GitHub/intentional-macos-app && swiftc -typecheck -target arm64-apple-macos14 -sdk $(xcrun --show-sdk-path) Intentional/FocusStartOverlay.swift Intentional/BlockingProfileManager.swift 2>&1 | head -10`
Expected: Clean compile (or only warnings, no errors)

- [ ] **Step 3: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/FocusStartOverlay.swift
git commit -m "feat: add FocusStartOverlay with profile picker and AI intention field"
```

---

## Task 4: Wire Everything into AppDelegate

**Files:**
- Modify: `Intentional/AppDelegate.swift`
- Modify: `Intentional.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add properties to AppDelegate**

Near the other controller properties (around line 44-48), add:

```swift
var blockingProfileManager: BlockingProfileManager?
var focusSessionManager: FocusSessionManager?
private var focusStartOverlayWindows: [NSWindow] = []
private var focusStartOverlayViewModel: FocusStartOverlayViewModel?
private var puckHotkeyMonitor: Any?
```

- [ ] **Step 2: Initialize managers in applicationDidFinishLaunching**

After the BedtimeEnforcer initialization block, add:

```swift
// Blocking Profiles & Focus Sessions
blockingProfileManager = BlockingProfileManager()
focusSessionManager = FocusSessionManager()

// Restore active focus session if app restarted mid-focus
if let session = focusSessionManager?.activeSession {
    postLog("🎯 Restoring active focus session from disk")
    applyFocusSession(session)
}

// Mock Puck trigger: Cmd+Shift+P global hotkey
puckHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
    // Cmd+Shift+P
    if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 35 {
        DispatchQueue.main.async { self?.togglePuckFocus() }
    }
}
// Also monitor local events (when app is focused)
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
    if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 35 {
        DispatchQueue.main.async { self?.togglePuckFocus() }
        return nil
    }
    return event
}

postLog("🎯 BlockingProfileManager + FocusSessionManager initialized")
```

- [ ] **Step 3: Add focus session methods to AppDelegate**

```swift
// MARK: - Focus Session Control

func togglePuckFocus() {
    if focusSessionManager?.isActive == true {
        endFocusSession()
    } else {
        showFocusStartOverlay(isPuckTriggered: true)
    }
}

func showFocusStartOverlay(isPuckTriggered: Bool) {
    guard focusStartOverlayWindows.isEmpty else { return }

    let vm = FocusStartOverlayViewModel()
    vm.availableProfiles = blockingProfileManager?.profiles ?? []
    vm.isPuckTriggered = isPuckTriggered
    vm.aiScoringEnabled = UserDefaults.standard.bool(forKey: "aiScoringEnabled")

    // Pre-select default profile for Puck
    if isPuckTriggered, let defaultProfile = blockingProfileManager?.profiles.first(where: { $0.isDefault }) {
        vm.selectedProfileIds = [defaultProfile.id]
    }

    vm.onStartFocus = { [weak self] profileIds, intention, aiEnabled in
        self?.startFocusSession(profileIds: profileIds, intention: intention, aiEnabled: aiEnabled, triggeredByPuck: isPuckTriggered)
        self?.dismissFocusStartOverlay()
    }
    vm.onCancel = { [weak self] in
        self?.dismissFocusStartOverlay()
    }
    self.focusStartOverlayViewModel = vm

    for screen in NSScreen.screens {
        let view = FocusStartOverlayView(viewModel: vm)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = screen.frame

        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        focusStartOverlayWindows.append(window)
    }
    postLog("🎯 Focus start overlay shown (puck=\(isPuckTriggered))")
}

func dismissFocusStartOverlay() {
    for window in focusStartOverlayWindows { window.close() }
    focusStartOverlayWindows.removeAll()
    focusStartOverlayViewModel = nil
}

func startFocusSession(profileIds: [UUID], intention: String?, aiEnabled: Bool, triggeredByPuck: Bool) {
    focusSessionManager?.startSession(profileIds: profileIds, intention: intention, aiEnabled: aiEnabled, triggeredByPuck: triggeredByPuck)

    guard let session = focusSessionManager?.activeSession else { return }
    applyFocusSession(session)
    postLog("🎯 Focus session started (profiles=\(profileIds.count), intention=\(intention ?? "none"), puck=\(triggeredByPuck))")
}

func applyFocusSession(_ session: FocusSession) {
    // Merge block lists from selected profiles
    let merged = blockingProfileManager?.mergedBlockList(profileIds: session.activeProfileIds)
    
    // Update WebsiteBlocker with merged domains
    websiteBlocker?.updateDistractingSites(merged?.domains ?? [])
    
    // Update FilterManager for network-level blocking
    filterManager?.updateBlocklist(merged?.domains ?? [])
    filterManager?.updateFilterState(blockingEnabled: true)
    
    // Set intention on FocusMonitor for AI scoring
    if let intention = session.intention, !intention.isEmpty {
        // FocusMonitor uses the current block's title as the intention for scoring
        // Create an ad-hoc deep work block
        let now = Date()
        let cal = Calendar.current
        let endOfDay = cal.date(bySettingHour: 23, minute: 59, of: now) ?? now
        let block = ScheduleManager.FocusBlock(
            id: UUID().uuidString,
            title: intention,
            description: "",
            startHour: cal.component(.hour, from: now),
            startMinute: cal.component(.minute, from: now),
            endHour: cal.component(.hour, from: endOfDay),
            endMinute: cal.component(.minute, from: endOfDay),
            blockType: .deepWork
        )
        scheduleManager?.injectFocusSessionBlock(block)
    }
    
    // Trigger enforcement
    focusMonitor?.onBlockChanged()
}

func endFocusSession() {
    focusSessionManager?.stopSession()
    
    // Restore original distraction list from settings
    let settingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Intentional").appendingPathComponent("onboarding_settings.json")
    if let data = try? Data(contentsOf: settingsURL),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let sites = json["distractingSites"] as? [String] {
        websiteBlocker?.updateDistractingSites(sites)
    }
    
    // Clear filter
    filterManager?.updateFilterState(blockingEnabled: false)
    
    // Clear injected block
    scheduleManager?.clearInjectedFocusSessionBlock()
    
    // Stop enforcement
    focusMonitor?.stop()
    focusMonitor?.start()  // Restart with normal schedule
    
    postLog("🎯 Focus session ended")
}
```

- [ ] **Step 4: Add `injectFocusSessionBlock` and `clearInjectedFocusSessionBlock` to ScheduleManager**

In `Intentional/ScheduleManager.swift`, add:

```swift
// MARK: - Focus Session Block Injection

private var injectedFocusBlock: FocusBlock?

/// Inject an ad-hoc focus block from FocusSessionManager (overrides schedule)
func injectFocusSessionBlock(_ block: FocusBlock) {
    injectedFocusBlock = block
    recalculateState()
}

/// Clear the injected focus block (session ended)
func clearInjectedFocusSessionBlock() {
    injectedFocusBlock = nil
    recalculateState()
}

// In the existing currentBlock computed property or recalculateState(),
// check injectedFocusBlock first:
// if let injected = injectedFocusBlock { return injected }
```

- [ ] **Step 5: Add new files to project.pbxproj**

Add `BlockingProfileManager.swift`, `FocusSessionManager.swift`, `FocusStartOverlay.swift` following the existing pattern (A700000X, A800000X, A900000X IDs).

- [ ] **Step 6: Add menu bar focus toggle**

In `setupMenuBar()` (AppDelegate.swift line 629-666), add before the Quit item:

```swift
menu.addItem(NSMenuItem.separator())
let focusItem = NSMenuItem(title: "Toggle Focus (⌘⇧P)", action: #selector(menuToggleFocus), keyEquivalent: "")
menu.addItem(focusItem)
```

Add the selector:

```swift
@objc func menuToggleFocus() {
    togglePuckFocus()
}
```

- [ ] **Step 7: Build full project**

Run: `cd /Users/arayan/Documents/GitHub/intentional-macos-app && xcodebuild build -target Intentional -destination 'platform=macOS,arch=arm64' 2>&1 | grep "error:" | grep -v "mlx-swift\|swift-transformers\|Info.plist" | head -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/AppDelegate.swift Intentional/ScheduleManager.swift Intentional.xcodeproj/project.pbxproj
git commit -m "feat: wire focus sessions into AppDelegate with Puck hotkey and menu bar toggle"
```

---

## Task 5: Adapt IntentionalModeController — Hide Free Time During Puck

**Files:**
- Modify: `Intentional/IntentionalModeController.swift`

- [ ] **Step 1: Add Puck session awareness**

In `IntentionalModeController`, add a property to check Puck state:

```swift
/// Whether a Puck-triggered focus session is active (hides free time option)
var isPuckFocusActive: Bool {
    appDelegate?.focusSessionManager?.activeSession?.triggeredByPuck == true
}
```

- [ ] **Step 2: Hide free time in the overlay**

In `IntentionalModeOverlayView` (the SwiftUI view inside IntentionalModeController.swift), find the block type buttons (around line 485-491):

```swift
HStack(spacing: 0) {
    blockTypeButton(.deepWork, label: "Deep Work", icon: "flame.fill")
    dividerLine
    blockTypeButton(.focusHours, label: "Focus", icon: "eye.fill")
    if !viewModel.hideFreeTime {
        dividerLine
        blockTypeButton(.freeTime, label: "Free Time", icon: "cup.and.saucer.fill")
    }
}
```

Add `hideFreeTime` to the ViewModel:

```swift
@Published var hideFreeTime: Bool = false
```

Wire in `showOverlay()`:

```swift
vm.hideFreeTime = isPuckFocusActive
```

- [ ] **Step 3: Add "Continue with default blocking" option**

When Puck is active and user picks no specific block, add a dismiss button:

```swift
if viewModel.hideFreeTime {
    Button(action: { viewModel.onStartBlock("Focus", 60, .deepWork) }) {
        Text("Continue with Default Blocking")
            .font(.system(size: 15))
            .foregroundColor(Color(white: 0.45))
    }
    .buttonStyle(.plain)
    .padding(.top, 8)
}
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/arayan/Documents/GitHub/intentional-macos-app && xcodebuild build -target Intentional -destination 'platform=macOS,arch=arm64' 2>&1 | grep "error:" | grep -v "mlx-swift\|swift-transformers\|Info.plist" | head -5`
Expected: No errors

- [ ] **Step 5: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/IntentionalModeController.swift
git commit -m "feat: hide free time option during Puck focus sessions"
```

---

## Task 6: Profile Management UI Handlers

**Files:**
- Modify: `Intentional/MainWindow.swift`

- [ ] **Step 1: Add message handlers**

In `userContentController(_:didReceive:)`, add:

```swift
case "GET_BLOCKING_PROFILES":
    handleGetBlockingProfiles()

case "CREATE_BLOCKING_PROFILE":
    if let body = message.body as? [String: Any] {
        handleCreateBlockingProfile(body)
    }

case "UPDATE_BLOCKING_PROFILE":
    if let body = message.body as? [String: Any] {
        handleUpdateBlockingProfile(body)
    }

case "DELETE_BLOCKING_PROFILE":
    if let body = message.body as? [String: Any],
       let idStr = body["id"] as? String,
       let id = UUID(uuidString: idStr) {
        handleDeleteBlockingProfile(id: id)
    }
```

- [ ] **Step 2: Add handler functions**

```swift
// MARK: - Blocking Profile Handlers

private func handleGetBlockingProfiles() {
    let profiles = appDelegate?.blockingProfileManager?.profiles ?? []
    if let data = try? JSONEncoder().encode(profiles),
       let jsonStr = String(data: data, encoding: .utf8) {
        callJS("window.onBlockingProfiles && window.onBlockingProfiles(\(jsonStr))")
    }
}

private func handleCreateBlockingProfile(_ body: [String: Any]) {
    let name = body["name"] as? String ?? "New Profile"
    let domains = body["domains"] as? [String] ?? []
    let apps = body["appBundleIds"] as? [String] ?? []
    appDelegate?.blockingProfileManager?.createProfile(name: name, domains: domains, appBundleIds: apps)
    handleGetBlockingProfiles() // Push updated list
}

private func handleUpdateBlockingProfile(_ body: [String: Any]) {
    guard let idStr = body["id"] as? String, let id = UUID(uuidString: idStr) else { return }
    appDelegate?.blockingProfileManager?.updateProfile(
        id: id,
        name: body["name"] as? String,
        domains: body["domains"] as? [String],
        appBundleIds: body["appBundleIds"] as? [String]
    )
    handleGetBlockingProfiles()
}

private func handleDeleteBlockingProfile(id: UUID) {
    appDelegate?.blockingProfileManager?.deleteProfile(id: id)
    handleGetBlockingProfiles()
}
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/arayan/Documents/GitHub/intentional-macos-app && xcodebuild build -target Intentional -destination 'platform=macOS,arch=arm64' 2>&1 | grep "error:" | grep -v "mlx-swift\|swift-transformers\|Info.plist" | head -5`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
cd /Users/arayan/Documents/GitHub/intentional-macos-app
git add Intentional/MainWindow.swift
git commit -m "feat: add blocking profile CRUD handlers for dashboard UI"
```

---

## Verification

After all tasks:

1. Build the app: `xcodebuild build -target Intentional -destination 'platform=macOS,arch=arm64'`
2. Run the app from Xcode
3. Press `Cmd+Shift+P` → Focus start overlay should appear
4. Select a profile → click "Start Focus" → distractions should be blocked
5. Press `Cmd+Shift+P` again → focus should end, everything restored
6. Verify the menu bar shows "Toggle Focus" option
7. Test Puck mode: overlay shows "Distractions Blocked" with "Just Block" option
8. Test persistence: start focus → force-quit app → relaunch → focus should restore
9. Test Intentional Mode during Puck: free time option should be hidden

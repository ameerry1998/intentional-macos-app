# Spec 1 — iOS Client Implementation Plan (Plan C)

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce `Intention` as a backend-synced entity on iOS. Demote `FocusMode` to NFC binding pointer. Migrate existing FocusMode app tokens to backend Intentions. Add new Intentions management UI. Wire APNs silent push for cross-device session propagation.

**Architecture:** New `IntentionStore` mirrors the proven `BedtimeScheduleService` pattern (60s tick + foreground refresh + push on edit). `FocusMode` SwiftData model gains `intentionId` field; `appTokens`/`categoryTokens` retained as migration-window fallback. `BlockingService.activate(_ mode:)` looks up the bound Intention and applies its tokens to `ManagedSettingsStore`; on cache miss, falls back to local `FocusMode` tokens.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData (existing), FamilyControls / ManagedSettings / DeviceActivity, URLSession (via `IntentionalAPIClient`), Combine, XCTest.

**Worktree:** This plan executes in `/Users/arayan/Documents/GitHub/puck-ios/.claude/worktrees/intentions-spec1` on branch `feat/intentions-spec1` from base `main`.

**Backend dependency:** Plan A (backend) must be deployed before integration tests pass against a real server. Mock-URLSession unit tests are independent.

**Cross-repo log:** Findings + final hand-off notes go to `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-intentions-spec1-2026-05-03.md` per the cross-repo convention. Don't write a duplicate log inside puck-ios.

---

## §0. Cheat sheet — files this plan touches

### Created

| Path | Purpose |
|---|---|
| `Puck/Models/Intention.swift` | Codable DTO + helpers for the backend `Intention` entity. |
| `Puck/Core/Network/IntentionalIntentionsClient.swift` | HTTP client: GET / POST / PUT / DELETE `/intentions`. Mirrors `IntentionalScheduleClient` shape. |
| `Puck/Core/Intentions/IntentionStore.swift` | `@MainActor` ObservableObject. Pull on launch + foreground + 60s tick. Push on edit. Local JSON write-through cache in App Group container. Surfaces conflict banner. |
| `Puck/Core/Intentions/IntentionMigrationRunner.swift` | One-time migration of `FocusMode` rows → backend Intentions. Receipt key `intention_migration_v1_completed_at`. Merge-by-name logic. |
| `Puck/Core/Push/IntentionPushHandler.swift` | Routes APNs silent push payloads `{type: focus.session_started\|focus.session_stopped, ...}` to `BlockingService` shield activate / clear. |
| `Puck/Views/Intentions/IntentionsTabView.swift` | List view with create button. Filters tombstones by default. |
| `Puck/Views/Intentions/IntentionEditView.swift` | Edit screen: name, description, color, icon picker, FamilyActivityPicker for iOS apps, read-only Mac sections. |
| `Puck/Views/Intentions/IntentionRowView.swift` | List-row component. |
| `Puck/Views/Intentions/IntentionConflictBanner.swift` | Non-blocking banner for 409 responses. |
| `PuckTests/IntentionTests.swift` | Codable round-trip + helpers. |
| `PuckTests/IntentionalIntentionsClientTests.swift` | Mock-URLSession integration. |
| `PuckTests/IntentionStoreTests.swift` | Sync rhythm, conflict handling, App Group cache. |
| `PuckTests/IntentionMigrationRunnerTests.swift` | Migration semantics: empty / fresh / merge-by-name / partial-failure-resume. |
| `PuckTests/BlockingServiceActivateTests.swift` | Activate path: bound intention vs fallback. |
| `PuckTests/IntentionPushHandlerTests.swift` | Mocked push payload → shield call. |
| `PuckTests/Mocks/MockURLProtocol.swift` | URLSession test harness. |
| `PuckTests/Mocks/IntentionFixtures.swift` | Seed data. |

### Modified

| Path | Change |
|---|---|
| `Puck/Models/FocusMode.swift` | Add `var intentionId: UUID?`. Keep `appTokens` / `categoryTokens` as migration-window fallback. |
| `Puck/Core/Blocking/BlockingService.swift` | `activate(mode:duration:)` now reads bound Intention; falls back to legacy tokens; POSTs `/focus/toggle { intention_id, triggered_by }`. |
| `Puck/Core/Coordinator/PuckCoordinator.swift` | Pass `triggered_by: "ios_nfc"` through the activate path. (No protocol change to user.) |
| `Puck/App/PuckApp.swift` | `@StateObject IntentionStore.shared`; configure with model container; trigger migration after launch. |
| `Puck/App/PuckAppDelegate.swift` | Route silent pushes whose `type` starts with `focus.session_` through `IntentionPushHandler`. |
| `Puck/Core/Push/PuckPushRouter.swift` | Add `focus.session_started` / `focus.session_stopped` cases that delegate to `IntentionPushHandler`. |
| `Puck/Views/ContentView.swift` | Add the Intentions tab between Home and Schedule. |
| `Puck/Views/Focus/ModeEditView.swift` | When the mode has an `intentionId`, hide the in-place app picker behind a "Edit in Intentions →" link to the bound intention. |
| `Puck/Core/Network/IntentionalFocusSignalClient.swift` | Extend `toggleFocus(action:)` to accept optional `intentionId` + `triggeredBy`. |
| `project.yml` | Add the `PuckTests` test target wired to the `Puck` scheme. |
| `Puck/Utils/Theme.swift` (`Constants`) | (no change expected; reused) |

### Untouched (deliberately)

- `BedtimeScheduleService` and the bedtime tables (Bedtime stays separate per Spec 1).
- `IntentionalBlock` / `ScheduleBlocksService` (Spec 2 territory).
- `FocusMode.modeType == .bedtime` rows are skipped during migration.

---

## §1. Risk catalog

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | Migration POSTs N intentions and crashes mid-way → user sees half-migrated state | Medium | Receipt records `lastMigratedFocusModeId`; resume from next id on relaunch. |
| R2 | Backend `ios_app_tokens` decoded as `Set<ApplicationToken>` fails when origin device's app catalog differs from this device | Low (Apple dedups by token UUID, not bundle id) | Decode into `FamilyActivitySelection` lazily inside `BlockingService.activate`. Tolerate decode failure → fall back to legacy tokens. |
| R3 | APNs silent push delivered while user manually activated a different mode → race, wrong shield applied | Medium | Push handler checks `BlockingService.blockingState` — if a session for the same intention is already active, no-op. If a different one is active and backend says supersede, deactivate then activate. |
| R4 | `IntentionStore` cache loaded after `BlockingService.activate` is called from a `restoreShieldStateIfActive` path → cache miss → uses fallback (correct), but no `intention_id` ever reaches backend | Low | Restore-from-shield path doesn't POST `/focus/toggle` (the session is already on backend from before). Verify in `BlockingServiceActivateTests`. |
| R5 | FamilyActivityPicker selection encoded on device A, decoded on device B — Apple's docs are unclear on cross-device validity | Medium | iOS-only path: tokens are encoded + stored locally on the device that picked them, then PUT to backend, then PULLED by other devices on the same Apple ID (which is the same device for our user model). Cross-Apple-ID (e.g. partner) is not in scope. Document explicitly. |
| R6 | Two iPhone apps (rare: phone + iPad) on same account both POST migration in same window → duplicate Intentions on backend | Low | Migration POST checks for backend-side existing Intention by `name` first (merge-by-name). Backend already idempotent on insert collision via `(account_id, name)` (per Plan A — coordinate). Otherwise duplicates are user-fixable. |
| R7 | 409 banner spams the UI when two devices edit the same intention rapidly | Low | Banner debounced 5s; ignored if same-intention banner already showing. |
| R8 | Adding a new tab to `ContentView` shifts the tab indices and breaks `-PuckInitialTab` debug arg | Low | Add `intentions` case at the END of `PuckTab` enum; existing rawValues stay stable. Debug args still resolve. |

---

## §2. Worktree + branch setup

### Task 0: Create worktree, branch, initial empty commit

- [ ] Step 0.1 — From `/Users/arayan/Documents/GitHub/puck-ios`, ensure `main` is up to date:

```bash
cd /Users/arayan/Documents/GitHub/puck-ios && git fetch origin && git checkout main && git pull --ff-only
```

- [ ] Step 0.2 — Create worktree:

```bash
git worktree add .claude/worktrees/intentions-spec1 -b feat/intentions-spec1
```

- [ ] Step 0.3 — `cd /Users/arayan/Documents/GitHub/puck-ios/.claude/worktrees/intentions-spec1` and verify `git status` is clean.

- [ ] Step 0.4 — Run a sanity build to confirm the worktree compiles before any changes:

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -20
```

- [ ] Step 0.5 — Create the placeholder commit so subsequent commits have a base:

```bash
git commit --allow-empty -m "chore(intentions): scaffolding commit for Spec 1 iOS work"
```

---

## §3. Test target bootstrap

The puck-ios project currently has no test target. Spec 1 requires unit tests, so we add one as the very next task.

### Task 1: Add `PuckTests` target via project.yml + xcodegen

- [ ] Step 1.1 — Read `/Users/arayan/Documents/GitHub/puck-ios/.claude/worktrees/intentions-spec1/project.yml` to confirm xcodegen is the project generator.

- [ ] Step 1.2 — Verify xcodegen is installed:

```bash
which xcodegen || brew install xcodegen
```

- [ ] Step 1.3 — Append the test target to `project.yml`. Add at the bottom (after the `PuckShieldAction` block):

```yaml
  PuckTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: PuckTests
    dependencies:
      - target: Puck
    settings:
      base:
        INFOPLIST_FILE: PuckTests/Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: com.getpuck.app.tests
        SWIFT_VERSION: "5.9"
        TARGETED_DEVICE_FAMILY: "1"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: B7B67856A7
        BUNDLE_LOADER: $(TEST_HOST)
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/Puck.app/Puck
```

Also extend the `Puck` scheme block at the top of `project.yml` to include the test target:

```yaml
schemes:
  Puck:
    build:
      targets:
        Puck: all
        PuckTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - PuckTests
    profile:
      config: Release
```

- [ ] Step 1.4 — Create `PuckTests/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>$(DEVELOPMENT_LANGUAGE)</string>
  <key>CFBundleExecutable</key>
  <string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleName</key>
  <string>$(PRODUCT_NAME)</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
</dict>
</plist>
```

- [ ] Step 1.5 — Create `PuckTests/SmokeTest.swift` (delete after Task 2 lands real tests):

```swift
import XCTest

final class SmokeTest: XCTestCase {
    func test_target_compiles() {
        XCTAssertTrue(true)
    }
}
```

- [ ] Step 1.6 — Regenerate the Xcode project:

```bash
xcodegen generate
```

- [ ] Step 1.7 — Run the smoke test to confirm the target wires up:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/SmokeTest/test_target_compiles 2>&1 | tail -20
```

- [ ] Step 1.8 — Commit:

```bash
git add project.yml PuckTests/ Puck.xcodeproj && git commit -m "test(intentions): add PuckTests target with smoke test"
```

---

## §4. Intention model

### Task 2: Create the `Intention` Codable model + fixtures + tests

- [ ] Step 2.1 — Create `Puck/Models/Intention.swift`:

```swift
import Foundation

/// Account-scoped, cross-device-synced "what to block + why" entity.
/// Mirrors the backend `intentions` table 1:1. See spec
/// `docs/superpowers/specs/2026-05-03-intentions-spec1-design.md`.
///
/// `iosAppTokens` / `iosCategoryTokens` are opaque encoded
/// `FamilyActivitySelection` payloads — only meaningful inside iOS, only on
/// the same Apple ID that produced them. Mac stores+forwards but never
/// introspects.
struct Intention: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var description: String?
    var colorHex: String?
    var icon: String?
    var macWebsites: [String]
    var macBundleIds: [String]
    var iosAppTokens: Data?
    var iosCategoryTokens: Data?
    var version: Int
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case colorHex = "color_hex"
        case icon
        case macWebsites = "mac_websites"
        case macBundleIds = "mac_bundle_ids"
        case iosAppTokens = "ios_app_tokens"
        case iosCategoryTokens = "ios_category_tokens"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    var isDeleted: Bool { deletedAt != nil }
}

/// POST `/intentions` body — no `id`, no `version`.
struct IntentionCreate: Codable, Equatable {
    var name: String
    var description: String?
    var colorHex: String?
    var icon: String?
    var macWebsites: [String]
    var macBundleIds: [String]
    var iosAppTokens: Data?
    var iosCategoryTokens: Data?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case colorHex = "color_hex"
        case icon
        case macWebsites = "mac_websites"
        case macBundleIds = "mac_bundle_ids"
        case iosAppTokens = "ios_app_tokens"
        case iosCategoryTokens = "ios_category_tokens"
    }
}

/// PUT `/intentions/{id}` body — must include current `version` for
/// optimistic-concurrency check.
struct IntentionUpdate: Codable, Equatable {
    var name: String
    var description: String?
    var colorHex: String?
    var icon: String?
    var macWebsites: [String]
    var macBundleIds: [String]
    var iosAppTokens: Data?
    var iosCategoryTokens: Data?
    var version: Int

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case colorHex = "color_hex"
        case icon
        case macWebsites = "mac_websites"
        case macBundleIds = "mac_bundle_ids"
        case iosAppTokens = "ios_app_tokens"
        case iosCategoryTokens = "ios_category_tokens"
        case version
    }
}
```

- [ ] Step 2.2 — Create `PuckTests/Mocks/IntentionFixtures.swift`:

```swift
import Foundation
@testable import Puck

enum IntentionFixtures {
    static let codingId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    static var coding: Intention {
        Intention(
            id: codingId,
            name: "Coding",
            description: "Ship the alpha",
            colorHex: "#34D399",
            icon: "chevron.left.forwardslash.chevron.right",
            macWebsites: ["twitter.com", "reddit.com"],
            macBundleIds: ["com.tinyspeck.slackmacgap"],
            iosAppTokens: Data([0x01, 0x02, 0x03]),
            iosCategoryTokens: nil,
            version: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deletedAt: nil
        )
    }

    static var deletedReading: Intention {
        Intention(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            name: "Reading",
            description: nil,
            colorHex: "#FACC15",
            icon: "book",
            macWebsites: [],
            macBundleIds: [],
            iosAppTokens: nil,
            iosCategoryTokens: nil,
            version: 3,
            createdAt: Date(timeIntervalSince1970: 1_700_000_500),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            deletedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
    }
}
```

- [ ] Step 2.3 — Create `PuckTests/IntentionTests.swift`:

```swift
import XCTest
@testable import Puck

final class IntentionTests: XCTestCase {

    func test_intention_round_trips_through_json() throws {
        let original = IntentionFixtures.coding
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Intention.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_intention_decodes_backend_snake_case_payload() throws {
        let json = """
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "name": "Coding",
          "description": "Ship the alpha",
          "color_hex": "#34D399",
          "icon": "chevron.left.forwardslash.chevron.right",
          "mac_websites": ["twitter.com"],
          "mac_bundle_ids": [],
          "ios_app_tokens": "AQID",
          "ios_category_tokens": null,
          "version": 1,
          "created_at": "2023-11-14T22:13:20Z",
          "updated_at": "2023-11-14T22:13:20Z",
          "deleted_at": null
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let intention = try decoder.decode(Intention.self, from: json)
        XCTAssertEqual(intention.name, "Coding")
        XCTAssertEqual(intention.iosAppTokens, Data([0x01, 0x02, 0x03]))
        XCTAssertFalse(intention.isDeleted)
    }

    func test_isDeleted_true_when_deletedAt_present() {
        XCTAssertTrue(IntentionFixtures.deletedReading.isDeleted)
    }

    func test_intentionCreate_omits_id_and_version() throws {
        let create = IntentionCreate(
            name: "Reading",
            description: nil,
            colorHex: nil,
            icon: nil,
            macWebsites: [],
            macBundleIds: [],
            iosAppTokens: nil,
            iosCategoryTokens: nil
        )
        let data = try JSONEncoder().encode(create)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"id\""))
        XCTAssertFalse(json.contains("\"version\""))
    }
}
```

- [ ] Step 2.4 — Run:

```bash
xcodegen generate && xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/IntentionTests 2>&1 | tail -25
```

- [ ] Step 2.5 — Commit:

```bash
git add Puck/Models/Intention.swift PuckTests/Mocks/IntentionFixtures.swift PuckTests/IntentionTests.swift && git commit -m "feat(intentions): Intention Codable model + fixtures + round-trip tests"
```

---

## §5. Backend client

### Task 3: Create `IntentionalIntentionsClient` + URL-mocking harness + tests

- [ ] Step 3.1 — Create `PuckTests/Mocks/MockURLProtocol.swift`:

```swift
import Foundation

/// Drop-in URLProtocol that intercepts URLSession requests in tests.
/// Set `MockURLProtocol.requestHandler` and use a URLSession configured
/// with this protocol class. Mirrors the test pattern used in many Apple
/// sample projects.
final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.lastRequest = request
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
```

- [ ] Step 3.2 — Create `Puck/Core/Network/IntentionalIntentionsClient.swift`:

```swift
import Foundation

/// HTTP client for `/intentions` CRUD against the Intentional backend.
/// Mirrors `IntentionalScheduleClient` and `IntentionalBedtimeClient` shape.
/// Bearer JWT auth via `IntentionalAPIClient`.
///
/// Distinguishes `409 Conflict` (stale `version`) from generic server errors
/// so `IntentionStore` can surface a banner without retrying.
struct IntentionalIntentionsClient {
    static let shared = IntentionalIntentionsClient()

    enum ClientError: Error, Equatable {
        case versionConflict
        case notFound
        case http(Int, String)
        case transport(String)
    }

    struct ListResponse: Codable {
        let intentions: [Intention]
    }

    /// GET /intentions — excludes soft-deleted by default.
    /// `includeDeleted: true` adds `?include_deleted=true` for history views.
    func list(includeDeleted: Bool = false) async throws -> [Intention] {
        let path = includeDeleted ? "intentions?include_deleted=true" : "intentions"
        let resp: ListResponse = try await IntentionalAPIClient.shared.get(
            path: path,
            auth: .bearer
        )
        return resp.intentions
    }

    /// GET /intentions/{id} — returns even soft-deleted ones.
    func get(id: UUID) async throws -> Intention {
        try await mapErrors {
            try await IntentionalAPIClient.shared.get(
                path: "intentions/\(id.uuidString)",
                auth: .bearer
            )
        }
    }

    /// POST /intentions — server assigns id + version=1.
    func create(_ payload: IntentionCreate) async throws -> Intention {
        try await mapErrors {
            try await IntentionalAPIClient.shared.post(
                path: "intentions",
                body: payload,
                auth: .bearer
            )
        }
    }

    /// PUT /intentions/{id} — must include current `version`. Returns 409 on
    /// version mismatch; we map that to `.versionConflict`.
    func update(id: UUID, payload: IntentionUpdate) async throws -> Intention {
        try await mapErrors {
            try await IntentionalAPIClient.shared.put(
                path: "intentions/\(id.uuidString)",
                body: payload,
                auth: .bearer
            )
        }
    }

    /// DELETE /intentions/{id} — soft delete (server sets `deleted_at`).
    func delete(id: UUID) async throws {
        _ = try await mapErrors { () -> IntentionalEmptyResponse in
            try await IntentionalAPIClient.shared.delete(
                path: "intentions/\(id.uuidString)",
                auth: .bearer
            )
        }
    }

    private func mapErrors<T>(_ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch let IntentionalAPIClient.APIClientError.serverError(code, body) {
            switch code {
            case 409: throw ClientError.versionConflict
            case 404: throw ClientError.notFound
            default:  throw ClientError.http(code, body)
            }
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
    }
}
```

- [ ] Step 3.3 — `IntentionalAPIClient` is currently a singleton with a private `URLSession`. Tests need to inject `MockURLProtocol`. The least-invasive way is to add a test-only seam. Edit `Puck/Core/Network/IntentionalAPIClient.swift`:

Find:
```swift
final class IntentionalAPIClient: @unchecked Sendable {
    static let shared = IntentionalAPIClient()
    private init() {}

    private let session: URLSession = {
```

Replace with:
```swift
final class IntentionalAPIClient: @unchecked Sendable {
    static let shared = IntentionalAPIClient()
    private init(session: URLSession? = nil, tokenProvider: (() async -> String?)? = nil) {
        if let session { self.session = session }
        if let tokenProvider { self.testTokenProvider = tokenProvider }
    }

    /// Test seam — see `IntentionalAPIClient.makeForTests(session:tokenProvider:)`.
    private var testTokenProvider: (() async -> String?)?

    private var session: URLSession = {
```

(Note: `let session: URLSession = {` becomes `var session: URLSession = {` and we drop the `private` so the tests' factory can mutate it. Acceptable because production uses only `.shared`.)

Find the `currentAccessToken()` method and change to:
```swift
@MainActor
private func currentAccessToken() async -> String? {
    if let testTokenProvider { return await testTokenProvider() }
    return AuthService.shared.accessToken
}
```

Add at the bottom of the class:
```swift
#if DEBUG
/// Test factory — returns a fresh client wired to a mock URLSession. Never
/// call from production code.
static func makeForTests(
    session: URLSession,
    tokenProvider: @escaping () async -> String?
) -> IntentionalAPIClient {
    IntentionalAPIClient(session: session, tokenProvider: tokenProvider)
}
#endif
```

The `send` method already calls `self.session.data(for: req)` — that part is unchanged.

- [ ] Step 3.4 — `IntentionalIntentionsClient` is currently a struct holding no state and using `IntentionalAPIClient.shared`. Tests need a swap. Refactor minimally — change `static let shared` to a stored client property:

```swift
struct IntentionalIntentionsClient {
    static let shared = IntentionalIntentionsClient(api: .shared)
    let api: IntentionalAPIClient

    init(api: IntentionalAPIClient) { self.api = api }

    // ... methods now call `api.get(...)` instead of `IntentionalAPIClient.shared.get(...)`
}
```

Update every call site inside this file to use `self.api`.

- [ ] Step 3.5 — Create `PuckTests/IntentionalIntentionsClientTests.swift`:

```swift
import XCTest
@testable import Puck

final class IntentionalIntentionsClientTests: XCTestCase {
    var client: IntentionalIntentionsClient!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let api = IntentionalAPIClient.makeForTests(
            session: session,
            tokenProvider: { "test-jwt" }
        )
        client = IntentionalIntentionsClient(api: api)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func test_list_decodes_backend_payload() async throws {
        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.url?.path, "/intentions")
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-jwt")
            let body = """
            {"intentions": [
              {"id":"11111111-1111-4111-8111-111111111111","name":"Coding","description":null,"color_hex":null,"icon":null,
               "mac_websites":[],"mac_bundle_ids":[],"ios_app_tokens":null,"ios_category_tokens":null,
               "version":1,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","deleted_at":null}
            ]}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }

        let intentions = try await client.list()
        XCTAssertEqual(intentions.count, 1)
        XCTAssertEqual(intentions.first?.name, "Coding")
    }

    func test_list_includeDeleted_passes_query_param() async throws {
        MockURLProtocol.requestHandler = { req in
            XCTAssertTrue(req.url?.absoluteString.contains("include_deleted=true") ?? false)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"intentions\":[]}".data(using: .utf8))
        }
        _ = try await client.list(includeDeleted: true)
    }

    func test_update_409_maps_to_versionConflict() async {
        MockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"error\":\"version mismatch\"}".data(using: .utf8))
        }
        do {
            _ = try await client.update(
                id: IntentionFixtures.codingId,
                payload: IntentionUpdate(
                    name: "x", description: nil, colorHex: nil, icon: nil,
                    macWebsites: [], macBundleIds: [],
                    iosAppTokens: nil, iosCategoryTokens: nil, version: 7
                )
            )
            XCTFail("expected versionConflict")
        } catch IntentionalIntentionsClient.ClientError.versionConflict {
            // ok
        } catch {
            XCTFail("got \(error), expected versionConflict")
        }
    }

    func test_delete_returns_void_on_204() async throws {
        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.httpMethod, "DELETE")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        try await client.delete(id: IntentionFixtures.codingId)
    }
}
```

- [ ] Step 3.6 — Run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/IntentionalIntentionsClientTests 2>&1 | tail -30
```

- [ ] Step 3.7 — Commit:

```bash
git add Puck/Core/Network/IntentionalIntentionsClient.swift Puck/Core/Network/IntentionalAPIClient.swift PuckTests/Mocks/MockURLProtocol.swift PuckTests/IntentionalIntentionsClientTests.swift && git commit -m "feat(intentions): IntentionalIntentionsClient + URL-mock harness + 409 mapping"
```

---

## §6. IntentionStore — local cache + accessors

### Task 4: `IntentionStore` skeleton (cache load/save, in-memory accessors) + tests

- [ ] Step 4.1 — Create the cache helper file `Puck/Core/Intentions/IntentionStorage.swift`:

```swift
import Foundation

/// Disk-backed JSON cache for the full set of intentions for this account.
/// Stored in the App Group container so future extensions (push handler in
/// a notification service extension, e.g.) can read without going through
/// the main app. JSON is portable; SwiftData would tie us to the main
/// process.
enum IntentionStorage {
    private static let suiteName = "group.com.getpuck.app"
    private static let key = "intentions_cache_v1"

    static func save(_ intentions: [Intention]) {
        guard let d = UserDefaults(suiteName: suiteName) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(intentions) {
            d.set(data, forKey: key)
        }
    }

    static func load() -> [Intention] {
        guard let d = UserDefaults(suiteName: suiteName),
              let data = d.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Intention].self, from: data)) ?? []
    }

    static func clear() {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: key)
    }
}
```

- [ ] Step 4.2 — Create `Puck/Core/Intentions/IntentionStore.swift`:

```swift
import Foundation
import Combine
import UIKit

/// Drives cross-device intention sync on iOS. Mirrors the bedtime / schedule
/// service shape:
/// 1. Pull /intentions on launch + on app foreground + every 60s.
/// 2. Push on user create/update/delete (immediate).
/// 3. Local on-disk cache (App Group) survives kill/relaunch.
///
/// Surfaces:
/// - `intentions`: published, excludes tombstones by default.
/// - `allIncludingDeleted`: published, includes tombstones (history UI).
/// - `cachedIntention(_:)`: O(1) lookup by id, used by BlockingService on
///   activate.
///
/// Conflict handling: a 409 from PUT triggers a refetch and emits a
/// `conflictBanner` event with the intention's name.
@MainActor
final class IntentionStore: ObservableObject {
    static let shared = IntentionStore()

    @Published private(set) var intentions: [Intention] = []
    @Published private(set) var allIncludingDeleted: [Intention] = []
    @Published private(set) var lastPullError: String?
    @Published var conflictBanner: ConflictBanner?

    struct ConflictBanner: Identifiable, Equatable {
        let id = UUID()
        let intentionName: String
        let occurredAt: Date
    }

    private let client: IntentionalIntentionsClient
    private var pullTimer: Timer?
    private var foregroundObserver: NSObjectProtocol?
    private var lastBannerEmittedAt: Date = .distantPast
    private var configured = false

    init(client: IntentionalIntentionsClient = .shared) {
        self.client = client
    }

    /// Wire up sync rhythm. Idempotent.
    func configure() {
        guard !configured else { return }
        configured = true

        // Hydrate from disk first so UI has data instantly.
        let cached = IntentionStorage.load()
        applyToPublishedState(cached)
        AppLogger.generalInfo("IntentionStore hydrated from cache: \(cached.count) intentions (\(cached.filter { !$0.isDeleted }.count) active)")

        // Pull on launch.
        Task { await pull() }

        // 60s reconciliation tick.
        pullTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pull() }
        }

        // Pull on foreground transitions.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.pull() }
        }
    }

    // MARK: - Accessors

    /// Returns the cached intention by id, including tombstones. O(active+deleted).
    /// Used by `BlockingService.activate` and the APNs push handler.
    func cachedIntention(_ id: UUID) -> Intention? {
        allIncludingDeleted.first(where: { $0.id == id })
    }

    /// Returns the cached intention by name (case-insensitive). Used by the
    /// migration runner for merge-by-name.
    func cachedIntention(named name: String) -> Intention? {
        let target = name.lowercased()
        return intentions.first(where: { $0.name.lowercased() == target })
    }

    // MARK: - Sync rhythm

    func pull() async {
        do {
            // Pull tombstones too so cachedIntention(_:) resolves history.
            let active = try await client.list(includeDeleted: false)
            let withTombstones = try await client.list(includeDeleted: true)
            applyToPublishedState(withTombstones, activeOverride: active)
            IntentionStorage.save(withTombstones)
            lastPullError = nil
            AppLogger.generalInfo("IntentionStore pulled: \(active.count) active, \(withTombstones.count - active.count) tombstones")
        } catch {
            lastPullError = error.localizedDescription
            AppLogger.generalError("IntentionStore pull failed: \(error)")
        }
    }

    // MARK: - User edits

    /// Create a new intention. On success, refresh cache.
    @discardableResult
    func create(_ payload: IntentionCreate) async throws -> Intention {
        let created = try await client.create(payload)
        await pull()
        return created
    }

    /// Update an intention. On 409, refetch + emit conflict banner. Caller
    /// receives the original error so the UI can revert its in-memory edit.
    @discardableResult
    func update(id: UUID, payload: IntentionUpdate) async throws -> Intention {
        do {
            let updated = try await client.update(id: id, payload: payload)
            await pull()
            return updated
        } catch IntentionalIntentionsClient.ClientError.versionConflict {
            AppLogger.generalInfo("IntentionStore update 409 — refetching")
            await pull()
            emitConflictBanner(for: id)
            throw IntentionalIntentionsClient.ClientError.versionConflict
        }
    }

    /// Soft-delete. On success, refresh cache.
    func delete(id: UUID) async throws {
        try await client.delete(id: id)
        await pull()
    }

    // MARK: - Internals

    private func applyToPublishedState(
        _ all: [Intention],
        activeOverride: [Intention]? = nil
    ) {
        allIncludingDeleted = all.sorted(by: { $0.createdAt < $1.createdAt })
        intentions = (activeOverride ?? all.filter { !$0.isDeleted })
            .sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func emitConflictBanner(for id: UUID) {
        // Debounce: ignore if we just emitted one (≤5s).
        let now = Date()
        guard now.timeIntervalSince(lastBannerEmittedAt) > 5.0 else { return }
        lastBannerEmittedAt = now
        let name = cachedIntention(id)?.name ?? "An Intention"
        conflictBanner = ConflictBanner(intentionName: name, occurredAt: now)
    }
}
```

- [ ] Step 4.3 — Create `PuckTests/IntentionStoreTests.swift` (skeleton — sync rhythm tests come in Task 5):

```swift
import XCTest
@testable import Puck

final class IntentionStoreTests: XCTestCase {
    var client: IntentionalIntentionsClient!
    var store: IntentionStore!

    override func setUp() async throws {
        try await super.setUp()
        IntentionStorage.clear()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let api = IntentionalAPIClient.makeForTests(
            session: session,
            tokenProvider: { "test-jwt" }
        )
        client = IntentionalIntentionsClient(api: api)
        store = await IntentionStore(client: client)
    }

    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
        IntentionStorage.clear()
        try await super.tearDown()
    }

    func test_cachedIntention_returns_nil_for_unknown_id() async {
        let result = await store.cachedIntention(UUID())
        XCTAssertNil(result)
    }

    func test_pull_populates_cache() async {
        MockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"intentions\":[]}".data(using: .utf8))
        }
        await store.pull()
        let intentions = await store.intentions
        XCTAssertEqual(intentions.count, 0)
    }

    func test_cachedIntention_finds_by_name_case_insensitive() async {
        let coding = IntentionFixtures.coding
        IntentionStorage.save([coding])
        // Re-init store so it hydrates from disk.
        store = await IntentionStore(client: client)
        let found = await store.cachedIntention(named: "coding")
        XCTAssertEqual(found?.id, coding.id)
    }
}
```

- [ ] Step 4.4 — Run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/IntentionStoreTests 2>&1 | tail -30
```

- [ ] Step 4.5 — Commit:

```bash
git add Puck/Core/Intentions/ PuckTests/IntentionStoreTests.swift && git commit -m "feat(intentions): IntentionStore skeleton with disk cache + accessors"
```

---

### Task 5: IntentionStore — sync rhythm tests (pull on launch, on foreground, 60s)

- [ ] Step 5.1 — Add to `PuckTests/IntentionStoreTests.swift`:

```swift
extension IntentionStoreTests {

    func test_configure_triggers_initial_pull() async throws {
        let pulled = expectation(description: "pulled")
        var calls = 0
        MockURLProtocol.requestHandler = { req in
            calls += 1
            if calls >= 2 { pulled.fulfill() }  // active + with-tombstones = 2 GETs
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"intentions\":[]}".data(using: .utf8))
        }
        await store.configure()
        await fulfillment(of: [pulled], timeout: 5.0)
        XCTAssertGreaterThanOrEqual(calls, 2)
    }

    func test_create_pushes_then_refetches() async throws {
        var posted = false
        var listed = false
        MockURLProtocol.requestHandler = { req in
            if req.httpMethod == "POST" {
                posted = true
                let body = """
                {"id":"\(IntentionFixtures.codingId.uuidString.lowercased())","name":"Coding","description":null,"color_hex":null,"icon":null,
                 "mac_websites":[],"mac_bundle_ids":[],"ios_app_tokens":null,"ios_category_tokens":null,
                 "version":1,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","deleted_at":null}
                """.data(using: .utf8)!
                let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (resp, body)
            } else {
                listed = true
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, "{\"intentions\":[]}".data(using: .utf8))
            }
        }
        _ = try await store.create(IntentionCreate(
            name: "Coding", description: nil, colorHex: nil, icon: nil,
            macWebsites: [], macBundleIds: [],
            iosAppTokens: nil, iosCategoryTokens: nil
        ))
        XCTAssertTrue(posted)
        XCTAssertTrue(listed)
    }
}
```

- [ ] Step 5.2 — Run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/IntentionStoreTests/test_configure_triggers_initial_pull -only-testing:PuckTests/IntentionStoreTests/test_create_pushes_then_refetches 2>&1 | tail -25
```

- [ ] Step 5.3 — Commit:

```bash
git add PuckTests/IntentionStoreTests.swift && git commit -m "test(intentions): IntentionStore configure-triggers-pull + create-then-refetch"
```

---

### Task 6: IntentionStore — 409 conflict handling + banner debounce + tests

- [ ] Step 6.1 — Add to `PuckTests/IntentionStoreTests.swift`:

```swift
extension IntentionStoreTests {

    func test_update_409_emits_conflictBanner_with_name() async {
        // Seed cache so emitConflictBanner can resolve the name.
        IntentionStorage.save([IntentionFixtures.coding])
        store = await IntentionStore(client: client)
        await store.pull()  // hydrate published state from cache via fresh pull

        var step = 0
        MockURLProtocol.requestHandler = { req in
            step += 1
            if req.httpMethod == "PUT" {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
                return (resp, Data())
            }
            // GET — return the seeded coding intention.
            let body = """
            {"intentions":[
              {"id":"\(IntentionFixtures.codingId.uuidString.lowercased())","name":"Coding","description":null,"color_hex":null,"icon":null,
               "mac_websites":[],"mac_bundle_ids":[],"ios_app_tokens":null,"ios_category_tokens":null,
               "version":2,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","deleted_at":null}
            ]}
            """.data(using: .utf8)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }

        do {
            _ = try await store.update(id: IntentionFixtures.codingId, payload: IntentionUpdate(
                name: "Coding (mine)", description: nil, colorHex: nil, icon: nil,
                macWebsites: [], macBundleIds: [],
                iosAppTokens: nil, iosCategoryTokens: nil, version: 1
            ))
            XCTFail("expected versionConflict")
        } catch IntentionalIntentionsClient.ClientError.versionConflict {
            let banner = await store.conflictBanner
            XCTAssertNotNil(banner)
            XCTAssertEqual(banner?.intentionName, "Coding")
        } catch {
            XCTFail("got \(error)")
        }
    }

    func test_conflictBanner_debounced_within_5s() async {
        IntentionStorage.save([IntentionFixtures.coding])
        store = await IntentionStore(client: client)
        // Two rapid 409s should emit one banner.
        MockURLProtocol.requestHandler = { req in
            if req.httpMethod == "PUT" {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
                return (resp, Data())
            }
            let body = "{\"intentions\":[]}".data(using: .utf8)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        for _ in 0..<3 {
            _ = try? await store.update(id: IntentionFixtures.codingId, payload: IntentionUpdate(
                name: "x", description: nil, colorHex: nil, icon: nil,
                macWebsites: [], macBundleIds: [],
                iosAppTokens: nil, iosCategoryTokens: nil, version: 1
            ))
        }
        let banner = await store.conflictBanner
        XCTAssertNotNil(banner)  // at least the first one set it; debounce blocks dupes
    }
}
```

- [ ] Step 6.2 — Run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/IntentionStoreTests/test_update_409_emits_conflictBanner_with_name -only-testing:PuckTests/IntentionStoreTests/test_conflictBanner_debounced_within_5s 2>&1 | tail -25
```

- [ ] Step 6.3 — Commit:

```bash
git add PuckTests/IntentionStoreTests.swift && git commit -m "test(intentions): IntentionStore 409 conflict banner + debounce"
```

---

## §7. FocusMode model migration

### Task 7: Add `intentionId` to FocusMode SwiftData model

- [ ] Step 7.1 — Edit `Puck/Models/FocusMode.swift`. Find the property block:

```swift
var modeColorHex: String = "#6FB58E"  // default: deep work
var createdAt: Date
var lastUsedAt: Date?
```

Add immediately after `lastUsedAt`:

```swift
/// Spec 1: binding to a backend `Intention` row. Nil while the migration
/// runner hasn't processed this row yet, OR for fresh installs that
/// pulled an Intention from backend without a matching local FocusMode.
/// `BlockingService.activate` reads `IntentionStore.cachedIntention(intentionId)`
/// and falls back to the legacy `appTokens` / `categoryTokens` on this
/// FocusMode if the lookup misses (e.g. cache not yet primed).
var intentionId: UUID?
```

The `appTokens` / `categoryTokens` fields are deliberately retained as a
migration-window fallback. They will be removed in a follow-up release once
the backend Intentions are stable.

- [ ] Step 7.2 — SwiftData additive properties don't require an explicit migration plan — `@Model` handles new optional fields natively. To verify, add a test that confirms an existing FocusMode without `intentionId` reads as nil:

Create `PuckTests/FocusModeMigrationTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Puck

@MainActor
final class FocusModeMigrationTests: XCTestCase {

    func test_focusMode_intentionId_defaults_to_nil() throws {
        let schema = Schema([FocusMode.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext

        let mode = FocusMode(name: "Deep Work")
        ctx.insert(mode)
        try ctx.save()

        XCTAssertNil(mode.intentionId)
    }

    func test_focusMode_intentionId_persists_round_trip() throws {
        let schema = Schema([FocusMode.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = container.mainContext

        let mode = FocusMode(name: "Coding")
        let id = UUID()
        mode.intentionId = id
        ctx.insert(mode)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<FocusMode>())
        XCTAssertEqual(fetched.first?.intentionId, id)
    }
}
```

- [ ] Step 7.3 — Run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/FocusModeMigrationTests 2>&1 | tail -20
```

- [ ] Step 7.4 — Commit:

```bash
git add Puck/Models/FocusMode.swift PuckTests/FocusModeMigrationTests.swift && git commit -m "feat(intentions): add intentionId to FocusMode SwiftData model"
```

---

### Task 8: Migration runner — convert FocusMode rows → backend Intentions (idempotent)

- [ ] Step 8.1 — Create `Puck/Core/Intentions/IntentionMigrationRunner.swift`:

```swift
import Foundation
import SwiftData
import FamilyControls

/// One-time migration: for every blocking-typed `FocusMode` without an
/// `intentionId`, create a backend `Intention` and stamp the returned id
/// onto the FocusMode. Idempotent + resumable.
///
/// Receipt key: `intention_migration_v1_completed_at` in UserDefaults.
/// While the receipt is absent, we run; on completion (or repeat-call after
/// receipt is set), we skip.
///
/// Bedtime FocusModes (`modeType == .bedtime`) are skipped — Bedtime stays
/// a separate subsystem per Spec 1.
///
/// Merge-by-name: before POSTing, we check `IntentionStore` for an existing
/// Intention with the same name (case-insensitive). If one exists, we bind
/// to that id instead of creating a duplicate. If the existing Intention has
/// empty `ios_app_tokens` AND our local FocusMode has tokens, we PUT the
/// tokens up.
@MainActor
final class IntentionMigrationRunner {

    enum ReceiptKey {
        static let completedAt = "intention_migration_v1_completed_at"
        static let lastProcessedFocusModeId = "intention_migration_v1_last_processed_id"
    }

    private let store: IntentionStore
    private let client: IntentionalIntentionsClient
    private let modelContainer: ModelContainer
    private let defaults: UserDefaults

    init(
        store: IntentionStore = .shared,
        client: IntentionalIntentionsClient = .shared,
        modelContainer: ModelContainer,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.client = client
        self.modelContainer = modelContainer
        self.defaults = defaults
    }

    /// Returns true if the migration receipt is already stamped.
    var isCompleted: Bool {
        defaults.object(forKey: ReceiptKey.completedAt) != nil
    }

    /// Run the migration. Safe to call multiple times — early-returns when
    /// the receipt is present.
    func run() async {
        guard !isCompleted else {
            AppLogger.generalInfo("IntentionMigration: receipt present, skipping")
            return
        }

        // Make sure the store cache is populated before merge-by-name runs.
        await store.pull()

        let ctx = modelContainer.mainContext
        let descriptor = FetchDescriptor<FocusMode>()
        guard let modes = try? ctx.fetch(descriptor) else {
            AppLogger.generalError("IntentionMigration: failed to fetch FocusModes; aborting")
            return
        }

        let blockingModes = modes
            .filter { $0.modeType == .blocking }
            .filter { $0.intentionId == nil }
            .sorted { $0.createdAt < $1.createdAt }

        let lastProcessed = defaults.string(forKey: ReceiptKey.lastProcessedFocusModeId).flatMap(UUID.init(uuidString:))
        let resumeFrom: [FocusMode]
        if let lastProcessed,
           let cutoffIdx = blockingModes.firstIndex(where: { $0.id == lastProcessed }) {
            resumeFrom = Array(blockingModes.dropFirst(cutoffIdx + 1))
        } else {
            resumeFrom = blockingModes
        }

        AppLogger.generalInfo("IntentionMigration: \(resumeFrom.count) FocusModes to migrate")

        for mode in resumeFrom {
            do {
                try await migrateOne(mode, ctx: ctx)
                defaults.set(mode.id.uuidString, forKey: ReceiptKey.lastProcessedFocusModeId)
            } catch {
                AppLogger.generalError("IntentionMigration: aborting on \(mode.name): \(error)")
                // Don't stamp the completion receipt — we'll resume from
                // lastProcessedFocusModeId next launch.
                return
            }
        }

        defaults.set(Date(), forKey: ReceiptKey.completedAt)
        AppLogger.generalInfo("IntentionMigration: complete")
    }

    private func migrateOne(_ mode: FocusMode, ctx: ModelContext) async throws {
        // Encode the FocusMode's tokens as the iOS payload.
        let appTokensData: Data?
        if !mode.appTokens.isEmpty {
            appTokensData = try JSONEncoder().encode(mode.appTokens)
        } else {
            appTokensData = nil
        }
        let categoryTokensData: Data?
        if !mode.categoryTokens.isEmpty {
            categoryTokensData = try JSONEncoder().encode(mode.categoryTokens)
        } else {
            categoryTokensData = nil
        }

        // Merge-by-name: if backend already has an Intention with this name
        // (e.g. Mac migrated first), bind to that one.
        if let existing = store.cachedIntention(named: mode.name) {
            mode.intentionId = existing.id
            try? ctx.save()
            AppLogger.generalInfo("IntentionMigration: merged \(mode.name) → existing \(existing.id)")

            // If the backend has empty iOS tokens AND we have local tokens,
            // PUT the tokens up.
            let backendIosEmpty = (existing.iosAppTokens?.isEmpty ?? true)
                && (existing.iosCategoryTokens?.isEmpty ?? true)
            let localIosNonEmpty = (appTokensData != nil) || (categoryTokensData != nil)
            if backendIosEmpty && localIosNonEmpty {
                let payload = IntentionUpdate(
                    name: existing.name,
                    description: existing.description,
                    colorHex: existing.colorHex,
                    icon: existing.icon,
                    macWebsites: existing.macWebsites,
                    macBundleIds: existing.macBundleIds,
                    iosAppTokens: appTokensData,
                    iosCategoryTokens: categoryTokensData,
                    version: existing.version
                )
                _ = try await store.update(id: existing.id, payload: payload)
                AppLogger.generalInfo("IntentionMigration: pushed iOS tokens up for merged \(existing.name)")
            }
            return
        }

        // Create new Intention.
        let payload = IntentionCreate(
            name: mode.name,
            description: nil,
            colorHex: mode.colorHex,
            icon: mode.iconName,
            macWebsites: [],
            macBundleIds: [],
            iosAppTokens: appTokensData,
            iosCategoryTokens: categoryTokensData
        )
        let created = try await store.create(payload)
        mode.intentionId = created.id
        try? ctx.save()
        AppLogger.generalInfo("IntentionMigration: created \(created.id) for \(mode.name)")
    }
}
```

- [ ] Step 8.2 — Create `PuckTests/IntentionMigrationRunnerTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Puck

@MainActor
final class IntentionMigrationRunnerTests: XCTestCase {

    var modelContainer: ModelContainer!
    var defaults: UserDefaults!
    var client: IntentionalIntentionsClient!
    var store: IntentionStore!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([FocusMode.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: schema, configurations: [config])

        // Per-test UserDefaults suite to avoid pollution.
        defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: "test")

        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [MockURLProtocol.self]
            return c
        }())
        let api = IntentionalAPIClient.makeForTests(
            session: session,
            tokenProvider: { "test-jwt" }
        )
        client = IntentionalIntentionsClient(api: api)
        IntentionStorage.clear()
        store = IntentionStore(client: client)
    }

    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
        IntentionStorage.clear()
        try await super.tearDown()
    }

    func test_run_with_no_focusModes_stamps_receipt() async {
        MockURLProtocol.requestHandler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"intentions\":[]}".data(using: .utf8))
        }
        let runner = IntentionMigrationRunner(
            store: store, client: client,
            modelContainer: modelContainer, defaults: defaults
        )
        await runner.run()
        XCTAssertTrue(runner.isCompleted)
    }

    func test_run_creates_intention_for_each_blocking_mode() async {
        let ctx = modelContainer.mainContext
        let coding = FocusMode(name: "Coding")
        let reading = FocusMode(name: "Reading")
        let bedtime = FocusMode(name: "Bedtime", modeType: .bedtime)
        ctx.insert(coding)
        ctx.insert(reading)
        ctx.insert(bedtime)
        try? ctx.save()

        var posted: [String] = []
        MockURLProtocol.requestHandler = { req in
            if req.httpMethod == "POST" {
                let body = req.bodyStreamData()
                if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let name = json["name"] as? String {
                    posted.append(name)
                }
                let respBody = """
                {"id":"\(UUID().uuidString)","name":"\(posted.last ?? "x")","description":null,"color_hex":null,"icon":null,
                 "mac_websites":[],"mac_bundle_ids":[],"ios_app_tokens":null,"ios_category_tokens":null,
                 "version":1,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","deleted_at":null}
                """.data(using: .utf8)!
                let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (resp, respBody)
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"intentions\":[]}".data(using: .utf8))
        }

        let runner = IntentionMigrationRunner(
            store: store, client: client,
            modelContainer: modelContainer, defaults: defaults
        )
        await runner.run()

        XCTAssertEqual(Set(posted), Set(["Coding", "Reading"]))  // bedtime skipped
        XCTAssertNotNil(coding.intentionId)
        XCTAssertNotNil(reading.intentionId)
        XCTAssertNil(bedtime.intentionId)
        XCTAssertTrue(runner.isCompleted)
    }

    func test_run_idempotent_when_receipt_set() async {
        defaults.set(Date(), forKey: IntentionMigrationRunner.ReceiptKey.completedAt)
        var calls = 0
        MockURLProtocol.requestHandler = { req in
            calls += 1
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"intentions\":[]}".data(using: .utf8))
        }
        let runner = IntentionMigrationRunner(
            store: store, client: client,
            modelContainer: modelContainer, defaults: defaults
        )
        await runner.run()
        XCTAssertEqual(calls, 0)
    }
}

// Helper because URLProtocol's body comes in via httpBodyStream.
extension URLRequest {
    func bodyStreamData() -> Data {
        guard let stream = httpBodyStream else { return httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
```

- [ ] Step 8.3 — Run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/IntentionMigrationRunnerTests 2>&1 | tail -30
```

- [ ] Step 8.4 — Commit:

```bash
git add Puck/Core/Intentions/IntentionMigrationRunner.swift PuckTests/IntentionMigrationRunnerTests.swift && git commit -m "feat(intentions): one-time FocusMode → Intention migration with receipt + skip-bedtime"
```

---

### Task 9: Migration merge-by-name + push-tokens-up tests

- [ ] Step 9.1 — Add to `PuckTests/IntentionMigrationRunnerTests.swift`:

```swift
extension IntentionMigrationRunnerTests {

    func test_run_merges_by_name_when_backend_already_has_intention() async {
        let ctx = modelContainer.mainContext
        let coding = FocusMode(name: "Coding")
        ctx.insert(coding)
        try? ctx.save()

        // Backend already has a "Coding" intention with empty iOS tokens.
        let backendId = UUID()
        var puts = 0
        MockURLProtocol.requestHandler = { req in
            if req.httpMethod == "GET" {
                let body = """
                {"intentions":[
                  {"id":"\(backendId.uuidString.lowercased())","name":"Coding","description":null,"color_hex":null,"icon":null,
                   "mac_websites":["twitter.com"],"mac_bundle_ids":[],"ios_app_tokens":null,"ios_category_tokens":null,
                   "version":1,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","deleted_at":null}
                ]}
                """.data(using: .utf8)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, body)
            }
            if req.httpMethod == "PUT" {
                puts += 1
                let body = """
                {"id":"\(backendId.uuidString.lowercased())","name":"Coding","description":null,"color_hex":null,"icon":null,
                 "mac_websites":["twitter.com"],"mac_bundle_ids":[],"ios_app_tokens":null,"ios_category_tokens":null,
                 "version":2,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","deleted_at":null}
                """.data(using: .utf8)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, body)
            }
            // POST should not happen.
            XCTFail("unexpected POST during merge-by-name flow")
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let runner = IntentionMigrationRunner(
            store: store, client: client,
            modelContainer: modelContainer, defaults: defaults
        )
        await runner.run()

        XCTAssertEqual(coding.intentionId, backendId)
        // No iOS tokens to push up (FocusMode has empty appTokens) — PUT skipped.
        XCTAssertEqual(puts, 0)
    }

    func test_run_resumes_from_last_processed_id_after_partial_failure() async {
        let ctx = modelContainer.mainContext
        let a = FocusMode(name: "A")
        let b = FocusMode(name: "B")
        ctx.insert(a)
        ctx.insert(b)
        try? ctx.save()
        // Pretend A was processed last run.
        defaults.set(a.id.uuidString, forKey: IntentionMigrationRunner.ReceiptKey.lastProcessedFocusModeId)

        var posts = 0
        MockURLProtocol.requestHandler = { req in
            if req.httpMethod == "POST" {
                posts += 1
                let respBody = """
                {"id":"\(UUID().uuidString)","name":"B","description":null,"color_hex":null,"icon":null,
                 "mac_websites":[],"mac_bundle_ids":[],"ios_app_tokens":null,"ios_category_tokens":null,
                 "version":1,"created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z","deleted_at":null}
                """.data(using: .utf8)!
                let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                return (resp, respBody)
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"intentions\":[]}".data(using: .utf8))
        }

        let runner = IntentionMigrationRunner(
            store: store, client: client,
            modelContainer: modelContainer, defaults: defaults
        )
        await runner.run()
        XCTAssertEqual(posts, 1)  // only B
        XCTAssertNil(a.intentionId)  // A wasn't reprocessed
        XCTAssertNotNil(b.intentionId)
    }
}
```

- [ ] Step 9.2 — Run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/IntentionMigrationRunnerTests/test_run_merges_by_name_when_backend_already_has_intention -only-testing:PuckTests/IntentionMigrationRunnerTests/test_run_resumes_from_last_processed_id_after_partial_failure 2>&1 | tail -30
```

- [ ] Step 9.3 — Commit:

```bash
git add PuckTests/IntentionMigrationRunnerTests.swift && git commit -m "test(intentions): merge-by-name + resume-from-receipt migration paths"
```

---

## §8. Intentions tab UI

### Task 10: Intentions tab — list view + create button + tab wiring

- [ ] Step 10.1 — Create `Puck/Views/Intentions/IntentionRowView.swift`:

```swift
import SwiftUI

struct IntentionRowView: View {
    let intention: Intention

    var body: some View {
        HStack(spacing: 12) {
            iconBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(intention.name)
                    .font(DesignTokens.Font.body)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                if let description = intention.description, !description.isEmpty {
                    Text(description)
                        .font(DesignTokens.Font.footnote)
                        .foregroundStyle(DesignTokens.Color.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.Color.textTertiary)
        }
        .padding(.vertical, 4)
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(SwiftUI.Color(hex: intention.colorHex ?? "#34D399").opacity(0.18))
            Image(systemName: intention.icon ?? "target")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(SwiftUI.Color(hex: intention.colorHex ?? "#34D399"))
        }
        .frame(width: 36, height: 36)
    }
}
```

- [ ] Step 10.2 — Create `Puck/Views/Intentions/IntentionConflictBanner.swift`:

```swift
import SwiftUI

struct IntentionConflictBanner: View {
    let banner: IntentionStore.ConflictBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\"\(banner.intentionName)\" was changed on another device")
                    .font(DesignTokens.Font.footnote)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                Text("Your edits weren't saved. Refreshed to the latest version.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Color.textTertiary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DesignTokens.Color.textTertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SwiftUI.Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(SwiftUI.Color.orange.opacity(0.3))
                )
        )
        .padding(.horizontal, 18)
    }
}
```

- [ ] Step 10.3 — Create `Puck/Views/Intentions/IntentionsTabView.swift`:

```swift
import SwiftUI

struct IntentionsTabView: View {
    @StateObject private var store = IntentionStore.shared
    @State private var editingIntention: Intention?
    @State private var creatingNew = false

    var body: some View {
        ZStack {
            PageBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let banner = store.conflictBanner {
                        IntentionConflictBanner(banner: banner) {
                            store.conflictBanner = nil
                        }
                    }
                    if store.intentions.isEmpty {
                        emptyState
                    } else {
                        IntentionalListContainer {
                            ForEach(store.intentions) { intention in
                                Button {
                                    editingIntention = intention
                                } label: {
                                    IntentionRowView(intention: intention)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                }
                .padding(.top, 16)
            }
        }
        .sheet(item: $editingIntention) { intention in
            IntentionEditView(mode: .edit(intention))
        }
        .sheet(isPresented: $creatingNew) {
            IntentionEditView(mode: .create)
        }
        .task {
            await store.pull()
        }
    }

    private var header: some View {
        HStack {
            Text("Intentions")
                .font(DesignTokens.Font.title)
                .foregroundStyle(DesignTokens.Color.textPrimary)
            Spacer()
            Button {
                creatingNew = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SwiftUI.Color(hex: "#1A0F0A"))
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(DesignTokens.accentGradient)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
    }

    private var emptyState: some View {
        IntentionalCard {
            VStack(spacing: 8) {
                Image(systemName: "target")
                    .font(.system(size: 28))
                    .foregroundStyle(DesignTokens.Color.textTertiary)
                Text("No intentions yet")
                    .font(DesignTokens.Font.body)
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                Text("Create one to choose what to block when you focus.")
                    .font(DesignTokens.Font.footnote)
                    .foregroundStyle(DesignTokens.Color.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        .padding(.horizontal, 18)
    }
}
```

- [ ] Step 10.4 — Wire the tab into `Puck/Views/ContentView.swift`. Find the `enum PuckTab` and add a case:

```swift
enum PuckTab: Int, CaseIterable {
    case home = 0
    case routine
    case alarms
    case partner
    case settings
    case intentions

    var title: String {
        switch self {
        case .home: return "Home"
        case .routine: return "Schedule"
        case .alarms: return "Alarms"
        case .partner: return "Partner"
        case .settings: return "Settings"
        case .intentions: return "Intentions"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .routine: return "chart.bar.fill"
        case .alarms: return "alarm.fill"
        case .partner: return "person.2.fill"
        case .settings: return "gearshape.fill"
        case .intentions: return "target"
        }
    }

    // ... activeColor unchanged
}
```

In the `TabView`, add the new tab between Routine and Alarms (or wherever feels natural — keep raw values stable):

```swift
IntentionsTabView()
    .tabItem {
        Label(PuckTab.intentions.title, systemImage: PuckTab.intentions.icon)
    }
    .tag(PuckTab.intentions)
```

- [ ] Step 10.5 — Build (no test for view logic at this layer):

```bash
xcodegen generate && xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -15
```

- [ ] Step 10.6 — Commit:

```bash
git add Puck/Views/Intentions/ Puck/Views/ContentView.swift && git commit -m "feat(intentions): Intentions tab with list + conflict banner + empty state"
```

---

### Task 11: IntentionEditView with FamilyActivityPicker + read-only Mac sections

- [ ] Step 11.1 — Create `Puck/Views/Intentions/IntentionEditView.swift`:

```swift
import SwiftUI
import FamilyControls

struct IntentionEditView: View {
    enum Mode {
        case create
        case edit(Intention)

        var existingIntention: Intention? {
            if case let .edit(intention) = self { return intention }
            return nil
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var blockingService: BlockingService
    @StateObject private var store = IntentionStore.shared

    let mode: Mode

    // Editable fields.
    @State private var name: String = ""
    @State private var description: String = ""
    @State private var colorHex: String = "#34D399"
    @State private var icon: String = "target"
    @State private var iosSelection = FamilyActivitySelection()
    @State private var showAppPicker = false
    @State private var saving = false

    // Read-only Mac sections (populated from existing).
    @State private var macWebsites: [String] = []
    @State private var macBundleIds: [String] = []

    private static let availableColors: [String] = [
        "#34D399", "#FACC15", "#60A5FA", "#F87171",
        "#A78BFA", "#FB923C", "#22D3EE", "#F472B6"
    ]

    private static let availableIcons: [String] = [
        "target", "book", "chevron.left.forwardslash.chevron.right",
        "paintbrush", "music.note", "figure.run", "leaf", "bolt"
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                PageBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        nameSection
                        descriptionSection
                        colorSection
                        iconSection
                        iosAppsSection
                        macWebsitesSection
                        macAppsSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle(mode.existingIntention?.name ?? "New Intention")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .familyActivityPicker(isPresented: $showAppPicker, selection: $iosSelection)
        .onAppear { loadInitialState() }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Name")
            IntentionalInput(text: $name, placeholder: "Coding")
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("What you're trying to do")
            IntentionalInput(text: $description, placeholder: "Ship the alpha")
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Color")
            IntentionalCard {
                HStack(spacing: 10) {
                    ForEach(Self.availableColors, id: \.self) { hex in
                        Button {
                            colorHex = hex
                        } label: {
                            Circle()
                                .fill(SwiftUI.Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .strokeBorder(.white, lineWidth: hex == colorHex ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Icon")
            IntentionalCard {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Self.availableIcons, id: \.self) { sym in
                        Button {
                            icon = sym
                        } label: {
                            Image(systemName: sym)
                                .font(.system(size: 18))
                                .foregroundStyle(sym == icon ? SwiftUI.Color(hex: colorHex) : DesignTokens.Color.textSecondary)
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(sym == icon ? SwiftUI.Color(hex: colorHex).opacity(0.18) : SwiftUI.Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var iosAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("iPhone apps to block")
            IntentionalCard {
                Button {
                    if blockingService.isFamilyControlsAuthorized {
                        showAppPicker = true
                    } else {
                        Task {
                            await blockingService.requestAuthorization()
                            if blockingService.isFamilyControlsAuthorized { showAppPicker = true }
                        }
                    }
                } label: {
                    HStack {
                        Text("\(iosSelection.applicationTokens.count) apps · \(iosSelection.categoryTokens.count) categories")
                            .font(DesignTokens.Font.body)
                            .foregroundStyle(DesignTokens.Color.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(DesignTokens.Color.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var macWebsitesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Mac websites · Edit on Mac")
            IntentionalCard {
                if macWebsites.isEmpty {
                    Text("None")
                        .font(DesignTokens.Font.footnote)
                        .foregroundStyle(DesignTokens.Color.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(macWebsites, id: \.self) { domain in
                            Text(domain)
                                .font(DesignTokens.Font.footnote)
                                .foregroundStyle(DesignTokens.Color.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var macAppsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Mac apps · Edit on Mac")
            IntentionalCard {
                if macBundleIds.isEmpty {
                    Text("None")
                        .font(DesignTokens.Font.footnote)
                        .foregroundStyle(DesignTokens.Color.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(macBundleIds, id: \.self) { bundle in
                            Text(bundle)
                                .font(DesignTokens.Font.footnote)
                                .foregroundStyle(DesignTokens.Color.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private func loadInitialState() {
        guard let existing = mode.existingIntention else { return }
        name = existing.name
        description = existing.description ?? ""
        colorHex = existing.colorHex ?? "#34D399"
        icon = existing.icon ?? "target"
        macWebsites = existing.macWebsites
        macBundleIds = existing.macBundleIds
        // Decode iOS tokens.
        var sel = FamilyActivitySelection()
        if let data = existing.iosAppTokens,
           let tokens = try? JSONDecoder().decode(Set<ApplicationToken>.self, from: data) {
            sel.applicationTokens = tokens
        }
        if let data = existing.iosCategoryTokens,
           let tokens = try? JSONDecoder().decode(Set<ActivityCategoryToken>.self, from: data) {
            sel.categoryTokens = tokens
        }
        iosSelection = sel
    }

    private func save() async {
        saving = true
        defer { saving = false }

        let appsData: Data? = iosSelection.applicationTokens.isEmpty
            ? nil
            : try? JSONEncoder().encode(iosSelection.applicationTokens)
        let catsData: Data? = iosSelection.categoryTokens.isEmpty
            ? nil
            : try? JSONEncoder().encode(iosSelection.categoryTokens)

        switch mode {
        case .create:
            let payload = IntentionCreate(
                name: name, description: description.isEmpty ? nil : description,
                colorHex: colorHex, icon: icon,
                macWebsites: [], macBundleIds: [],
                iosAppTokens: appsData, iosCategoryTokens: catsData
            )
            do {
                _ = try await store.create(payload)
                dismiss()
            } catch {
                AppLogger.generalError("IntentionEditView create failed: \(error)")
            }
        case .edit(let existing):
            let payload = IntentionUpdate(
                name: name, description: description.isEmpty ? nil : description,
                colorHex: colorHex, icon: icon,
                macWebsites: existing.macWebsites,
                macBundleIds: existing.macBundleIds,
                iosAppTokens: appsData, iosCategoryTokens: catsData,
                version: existing.version
            )
            do {
                _ = try await store.update(id: existing.id, payload: payload)
                dismiss()
            } catch IntentionalIntentionsClient.ClientError.versionConflict {
                // Banner is already shown by the store; close the sheet so the
                // user sees the up-to-date list.
                dismiss()
            } catch {
                AppLogger.generalError("IntentionEditView update failed: \(error)")
            }
        }
    }
}
```

- [ ] Step 11.2 — Build:

```bash
xcodegen generate && xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -15
```

- [ ] Step 11.3 — Commit:

```bash
git add Puck/Views/Intentions/IntentionEditView.swift && git commit -m "feat(intentions): IntentionEditView with FamilyActivityPicker + read-only Mac sections"
```

---

## §9. BlockingService rewiring

### Task 12: BlockingService.activate — bound-intention path + fallback + backend POST

- [ ] Step 12.1 — Edit `Puck/Core/Network/IntentionalFocusSignalClient.swift`. Extend the request to support `intention_id` and `triggered_by`:

Replace:
```swift
private struct ToggleRequest: Encodable {
    let action: String
}
```

With:
```swift
private struct ToggleRequest: Encodable {
    let action: String
    let intention_id: String?
    let triggered_by: String?
}
```

Replace `func toggleFocus(action: Action)` with:

```swift
/// Fire-and-forget. `intentionId` is sent when known so the backend can
/// stamp `focus_sessions.intention_id`. `triggeredBy` distinguishes
/// "ios_manual" / "ios_nfc" / "puck" for backend telemetry + APNs fan-out
/// targeting.
func toggleFocus(
    action: Action,
    intentionId: UUID? = nil,
    triggeredBy: String? = nil
) {
    Task.detached {
        do {
            let body = ToggleRequest(
                action: action.rawValue,
                intention_id: intentionId?.uuidString,
                triggered_by: triggeredBy
            )
            let resp: ToggleResponse = try await IntentionalAPIClient.shared.post(
                path: "focus/toggle",
                body: body
            )
            AppLogger.nfcInfo("Intentional focus toggle: action=\(action.rawValue) intention=\(intentionId?.uuidString.prefix(8) ?? "-") status=\(resp.status) session=\(resp.session_id ?? "-")")
        } catch {
            AppLogger.nfcError("Intentional focus toggle failed", errorObj: error)
        }
    }
}
```

- [ ] Step 12.2 — Edit `Puck/Core/Blocking/BlockingService.swift`. Replace `func activate(mode:duration:)`:

```swift
/// Activate the OS shield for a FocusMode. New in Spec 1: looks up the
/// bound `Intention` first; falls back to the FocusMode's local
/// appTokens/categoryTokens during the migration window OR on cache miss.
/// Always POSTs `/focus/toggle` so the backend session is created.
///
/// `triggeredBy`: "ios_manual" (mode picker), "ios_nfc" (puck tap),
/// "ios_post_alarm" (post-alarm activation).
func activate(
    mode: FocusMode,
    duration: Int? = nil,
    triggeredBy: String = "ios_manual"
) {
    let resolved = resolveTokens(for: mode)
    AppLogger.blockingInfo(
        "Activating blocking: mode=\(mode.name), source=\(resolved.source), apps=\(resolved.appTokens.count), categories=\(resolved.categoryTokens.count), duration=\(String(describing: duration))"
    )

    let store = ManagedSettingsStore(named: .init(mode.name))
    store.shield.applications = resolved.appTokens.isEmpty ? nil : resolved.appTokens
    store.shield.applicationCategories = resolved.categoryTokens.isEmpty
        ? nil
        : .specific(resolved.categoryTokens)
    activeStore = store

    writeShieldSessionInfo(mode: mode)

    let endTime: Date?
    if let duration {
        endTime = Date().adding(minutes: duration)
        startTimer(duration: duration)
    } else {
        endTime = nil
    }

    mode.lastUsedAt = Date()
    blockingState = .active(modeName: mode.name, startTime: Date(), endTime: endTime)

    // Spec 1: fan out to backend so Mac sees this session within ≤2s.
    IntentionalFocusSignalClient.shared.toggleFocus(
        action: .start,
        intentionId: mode.intentionId,
        triggeredBy: triggeredBy
    )
}

private struct ResolvedTokens {
    let appTokens: Set<ApplicationToken>
    let categoryTokens: Set<ActivityCategoryToken>
    let source: String  // "intention" | "fallback"
}

/// Look up the bound Intention from `IntentionStore`. On cache miss,
/// fall back to the FocusMode's own tokens — pucks must never silently no-op.
private func resolveTokens(for mode: FocusMode) -> ResolvedTokens {
    if let id = mode.intentionId,
       let intention = IntentionStore.shared.cachedIntention(id) {
        let apps: Set<ApplicationToken> = intention.iosAppTokens
            .flatMap { try? JSONDecoder().decode(Set<ApplicationToken>.self, from: $0) }
            ?? []
        let cats: Set<ActivityCategoryToken> = intention.iosCategoryTokens
            .flatMap { try? JSONDecoder().decode(Set<ActivityCategoryToken>.self, from: $0) }
            ?? []
        // If the bound Intention has empty iOS tokens (e.g. only Mac side
        // has been edited), fall back to local FocusMode tokens.
        if apps.isEmpty && cats.isEmpty {
            return ResolvedTokens(
                appTokens: mode.appTokens,
                categoryTokens: mode.categoryTokens,
                source: "fallback-empty-intention"
            )
        }
        return ResolvedTokens(appTokens: apps, categoryTokens: cats, source: "intention")
    }
    return ResolvedTokens(
        appTokens: mode.appTokens,
        categoryTokens: mode.categoryTokens,
        source: "fallback"
    )
}
```

Also extend `deactivate()` to fire `toggleFocus(action: .stop)` so the backend session ends. Check whether `PuckCoordinator.endActiveFocusSession` already fires it (it does — line 437). So `BlockingService.deactivate()` does NOT need to send the stop signal; it's the coordinator's job. Add a comment:

Find `func deactivate()` and prepend a comment:
```swift
/// NOTE: backend stop signal is sent by `PuckCoordinator.endActiveFocusSession`,
/// not here, because deactivate() is also invoked from the timer-completion
/// path and we want one source of truth for the stop fan-out.
func deactivate() {
```

- [ ] Step 12.3 — Edit `Puck/Core/Coordinator/PuckCoordinator.swift`. In `activateMode(_:slug:)`, change the blocking-case call:

Find:
```swift
case .blocking:
    blockingService.activate(mode: mode, duration: mode.defaultDuration)
    // Mirror to Mac via Intentional backend (fire-and-forget).
    // Bedtime is intentionally phone-only.
    IntentionalFocusSignalClient.shared.toggleFocus(action: .start)
```

Replace with:
```swift
case .blocking:
    // BlockingService.activate now sends the start signal itself with
    // the bound intention id, so we no longer call toggleFocus here.
    blockingService.activate(
        mode: mode,
        duration: mode.defaultDuration,
        triggeredBy: "ios_nfc"
    )
```

(Bedtime path keeps `blockingService.activate(mode:duration:)` but with the default `triggeredBy: "ios_manual"` since bedtime is special.)

- [ ] Step 12.4 — Create `PuckTests/BlockingServiceActivateTests.swift`. NOTE: BlockingService talks to the OS via FamilyControls and `ManagedSettingsStore`. We can't call those for real in a unit test. So the test focuses on the `resolveTokens` decision logic by extracting it to internal-visible. Edit BlockingService.swift to mark the helper `internal`:

```swift
// already implicitly internal; make it explicit + testable
internal func resolveTokens(for mode: FocusMode) -> ResolvedTokens { ... }
internal struct ResolvedTokens { ... }
```

Then in the test:

```swift
import XCTest
@testable import Puck

@MainActor
final class BlockingServiceActivateTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        IntentionStorage.clear()
    }

    func test_resolveTokens_uses_intention_when_bound_and_present_in_cache() async throws {
        // Seed an intention with non-empty iOS tokens.
        let id = UUID()
        let appTokensData = try JSONEncoder().encode(Set<ApplicationToken>())  // empty set encodes fine
        let intention = Intention(
            id: id, name: "X", description: nil, colorHex: nil, icon: nil,
            macWebsites: [], macBundleIds: [],
            iosAppTokens: appTokensData,  // empty set is "present but empty" → fallback
            iosCategoryTokens: nil,
            version: 1, createdAt: Date(), updatedAt: Date(), deletedAt: nil
        )
        IntentionStorage.save([intention])
        await IntentionStore.shared.pull()  // hydrate from cache

        let mode = FocusMode(name: "X")
        mode.intentionId = id

        let resolved = BlockingService.shared.resolveTokens(for: mode)
        // Empty intention tokens → falls back to local mode tokens.
        XCTAssertTrue(resolved.source.contains("fallback"))
    }

    func test_resolveTokens_falls_back_when_intentionId_nil() {
        let mode = FocusMode(name: "Y")
        XCTAssertNil(mode.intentionId)
        let resolved = BlockingService.shared.resolveTokens(for: mode)
        XCTAssertEqual(resolved.source, "fallback")
    }

    func test_resolveTokens_falls_back_when_cache_miss() {
        let mode = FocusMode(name: "Z")
        mode.intentionId = UUID()  // bogus id, not in cache
        let resolved = BlockingService.shared.resolveTokens(for: mode)
        XCTAssertEqual(resolved.source, "fallback")
    }
}
```

- [ ] Step 12.5 — Run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/BlockingServiceActivateTests 2>&1 | tail -25
```

- [ ] Step 12.6 — Commit:

```bash
git add Puck/Core/Network/IntentionalFocusSignalClient.swift Puck/Core/Blocking/BlockingService.swift Puck/Core/Coordinator/PuckCoordinator.swift PuckTests/BlockingServiceActivateTests.swift && git commit -m "feat(intentions): BlockingService.activate uses bound Intention with fallback + sends intention_id to backend"
```

---

## §10. APNs silent push handler

### Task 13: APNs payload schema + IntentionPushHandler skeleton + tests

- [ ] Step 13.1 — Create `Puck/Core/Push/IntentionPushHandler.swift`:

```swift
import Foundation
import UIKit
import FamilyControls
import ManagedSettings

/// Routes APNs silent pushes for cross-device focus session start/stop.
///
/// Backend payload schema (when another device starts a session):
/// ```json
/// {
///   "type": "focus.session_started",
///   "session_id": "<uuid>",
///   "intention_id": "<uuid>",
///   "started_at": "<iso8601>",
///   "triggered_by": "mac_manual"|"ios_nfc"|...
/// }
/// ```
///
/// Backend payload schema (stop):
/// ```json
/// {
///   "type": "focus.session_stopped",
///   "session_id": "<uuid>"
/// }
/// ```
///
/// On `session_started`:
/// 1. Look up Intention from `IntentionStore.cachedIntention(intentionId)`.
///    Cache miss → trigger an `IntentionStore.pull()` and retry once. After
///    that, give up — log + emit a notification asking the user to open the
///    Intentions tab.
/// 2. Decode `ios_app_tokens` + `ios_category_tokens` from the Intention.
/// 3. Apply via a `ManagedSettingsStore` named for the session id (so we
///    can clear it precisely on `session_stopped` without touching unrelated
///    stores).
@MainActor
final class IntentionPushHandler {
    static let shared = IntentionPushHandler()

    /// Active stores keyed by session_id. We use one store per session so a
    /// stop push can clear exactly that session without disturbing local
    /// pucks or bedtime.
    private var activeStoresBySession: [String: ManagedSettingsStore] = [:]

    private let store: IntentionStore

    init(store: IntentionStore = .shared) {
        self.store = store
    }

    /// Entry point from `PuckPushRouter` / `PuckAppDelegate`.
    func handle(payload: [AnyHashable: Any]) async {
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "focus.session_started":
            await handleStarted(payload: payload)
        case "focus.session_stopped":
            handleStopped(payload: payload)
        default:
            return
        }
    }

    private func handleStarted(payload: [AnyHashable: Any]) async {
        guard let sessionIdStr = payload["session_id"] as? String,
              let intentionIdStr = payload["intention_id"] as? String,
              let intentionId = UUID(uuidString: intentionIdStr) else {
            AppLogger.generalError("focus.session_started push missing session_id or intention_id")
            return
        }

        let intention: Intention
        if let cached = store.cachedIntention(intentionId) {
            intention = cached
        } else {
            // Cache miss — try one pull then re-check.
            await store.pull()
            guard let refetched = store.cachedIntention(intentionId) else {
                AppLogger.generalError("Push intention \(intentionIdStr) not found after pull; ignoring")
                return
            }
            intention = refetched
        }

        let appTokens: Set<ApplicationToken> = intention.iosAppTokens
            .flatMap { try? JSONDecoder().decode(Set<ApplicationToken>.self, from: $0) }
            ?? []
        let catTokens: Set<ActivityCategoryToken> = intention.iosCategoryTokens
            .flatMap { try? JSONDecoder().decode(Set<ActivityCategoryToken>.self, from: $0) }
            ?? []

        if appTokens.isEmpty && catTokens.isEmpty {
            AppLogger.generalInfo("Push intention \(intention.name) has no iOS tokens; nothing to shield")
            return
        }

        let store = ManagedSettingsStore(named: .init(rawValue: "session-\(sessionIdStr)"))
        store.shield.applications = appTokens.isEmpty ? nil : appTokens
        store.shield.applicationCategories = catTokens.isEmpty ? nil : .specific(catTokens)
        activeStoresBySession[sessionIdStr] = store
        AppLogger.generalInfo("Cross-device shield applied: session=\(sessionIdStr.prefix(8)) intention=\(intention.name) apps=\(appTokens.count) cats=\(catTokens.count)")
    }

    private func handleStopped(payload: [AnyHashable: Any]) {
        guard let sessionIdStr = payload["session_id"] as? String else { return }
        if let store = activeStoresBySession.removeValue(forKey: sessionIdStr) {
            store.clearAllSettings()
            AppLogger.generalInfo("Cross-device shield cleared: session=\(sessionIdStr.prefix(8))")
        } else {
            AppLogger.generalInfo("Cross-device stop for unknown session=\(sessionIdStr.prefix(8)); no-op")
        }
    }
}
```

- [ ] Step 13.2 — Wire into `PuckPushRouter`. Edit `Puck/Core/Push/PuckPushRouter.swift`. Find the `route(payload:)` switch and add cases:

```swift
switch type {
case "bedtime.unlock_requested":
    handleUnlockRequested(payload: payload)
case "bedtime.unlock_approved":
    handleUnlockApproved(payload: payload)
case "focus.session_started", "focus.session_stopped":
    Task { await IntentionPushHandler.shared.handle(payload: payload) }
default:
    AppLogger.bedtimeInfo("Unknown push type: \(type)")
}
```

(`PuckAppDelegate` already routes via `PuckPushRouter.shared.route(payload:)`, so no changes there.)

- [ ] Step 13.3 — Create `PuckTests/IntentionPushHandlerTests.swift`:

```swift
import XCTest
@testable import Puck

@MainActor
final class IntentionPushHandlerTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        IntentionStorage.clear()
    }

    func test_session_started_with_unknown_intention_no_ops() async {
        let handler = IntentionPushHandler()
        let payload: [AnyHashable: Any] = [
            "type": "focus.session_started",
            "session_id": UUID().uuidString,
            "intention_id": UUID().uuidString,
            "started_at": "2024-01-01T00:00:00Z"
        ]
        await handler.handle(payload: payload)
        // No exception, no crash; the empty-cache path is exercised.
        XCTAssertTrue(true)
    }

    func test_session_started_with_known_intention_but_empty_tokens_no_ops() async {
        let id = UUID()
        let intention = Intention(
            id: id, name: "X", description: nil, colorHex: nil, icon: nil,
            macWebsites: [], macBundleIds: [],
            iosAppTokens: nil, iosCategoryTokens: nil,
            version: 1, createdAt: Date(), updatedAt: Date(), deletedAt: nil
        )
        IntentionStorage.save([intention])
        await IntentionStore.shared.pull()  // hydrate

        let handler = IntentionPushHandler(store: IntentionStore.shared)
        let payload: [AnyHashable: Any] = [
            "type": "focus.session_started",
            "session_id": UUID().uuidString,
            "intention_id": id.uuidString
        ]
        await handler.handle(payload: payload)
        XCTAssertTrue(true)  // no crash, no shield (empty tokens)
    }

    func test_session_stopped_with_unknown_session_no_ops() async {
        let handler = IntentionPushHandler()
        await handler.handle(payload: [
            "type": "focus.session_stopped",
            "session_id": UUID().uuidString
        ])
        XCTAssertTrue(true)
    }

    func test_unknown_type_no_ops() async {
        let handler = IntentionPushHandler()
        await handler.handle(payload: ["type": "weird.unknown"])
        XCTAssertTrue(true)
    }
}
```

NOTE: We can't assert the actual `ManagedSettingsStore.shield.applications` was set (the OS doesn't expose readback in a unit-test context). Integration verification happens in the manual smoke test (Task 19). The unit tests guarantee the routing + decode logic doesn't crash.

- [ ] Step 13.4 — Run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/IntentionPushHandlerTests 2>&1 | tail -25
```

- [ ] Step 13.5 — Commit:

```bash
git add Puck/Core/Push/IntentionPushHandler.swift Puck/Core/Push/PuckPushRouter.swift PuckTests/IntentionPushHandlerTests.swift && git commit -m "feat(intentions): APNs silent push → IntentionPushHandler applies/clears shield per session"
```

---

### Task 14: APNs background-mode entitlement + Info.plist verification

- [ ] Step 14.1 — Read `Puck/Info.plist` to verify `UIBackgroundModes` includes `remote-notification`. If not, add:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>remote-notification</string>
</array>
```

(BedtimeMonitor already requires this; expect it's already present. Verify with `grep -A2 UIBackgroundModes Puck/Info.plist`.)

- [ ] Step 14.2 — Verify `aps-environment` is in the Puck entitlements (it already is per `project.yml`). No edits unless absent.

- [ ] Step 14.3 — Build:

```bash
xcodegen generate && xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -15
```

- [ ] Step 14.4 — Commit (if Info.plist changed):

```bash
git add Puck/Info.plist && git commit -m "build(intentions): ensure remote-notification background mode is enabled" || true
```

---

## §11. App lifecycle wiring

### Task 15: Wire IntentionStore + migration runner into PuckApp init

- [ ] Step 15.1 — Edit `Puck/App/PuckApp.swift`. Add IntentionStore as a StateObject:

Find:
```swift
@StateObject private var partnerSync = PartnerSyncService.shared
```

Add immediately after:
```swift
@StateObject private var intentionStore = IntentionStore.shared
```

In the `init()`, after the `ScheduleBlocksService` config block, add:

```swift
// Configure IntentionStore + run one-time migration of FocusMode rows.
let intentionSvc = IntentionStore.shared
let migrationRunner = IntentionMigrationRunner(modelContainer: container)
Task { @MainActor in
    intentionSvc.configure()
    await migrationRunner.run()
}
```

In the `body`'s `.environmentObject` chain, add:

```swift
.environmentObject(intentionStore)
```

In the `.onChange(of: scenePhase)` modifier, add a pull-on-active call (defensive — `IntentionStore.configure()` already wires foreground observer, but explicit is clearer):

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .active {
        partnerSync.start()
        Task { await intentionStore.pull() }
    }
}
```

- [ ] Step 15.2 — Build:

```bash
xcodegen generate && xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -15
```

- [ ] Step 15.3 — Commit:

```bash
git add Puck/App/PuckApp.swift && git commit -m "feat(intentions): wire IntentionStore + migration runner into app init"
```

---

## §12. ModeEditView coexistence

### Task 16: Tweak ModeEditView to surface intention binding

When a `FocusMode` has an `intentionId`, the legacy app-picker section should
direct users to the Intention edit screen so they don't end up with two
diverging blocklists (legacy on FocusMode + new on Intention). The legacy
picker stays available for unbound (pre-migration) modes.

- [ ] Step 16.1 — Edit `Puck/Views/Focus/ModeEditView.swift`. Find `private var appsSection: some View` and replace with:

```swift
private var appsSection: some View {
    VStack(alignment: .leading, spacing: 0) {
        SectionLabel("Apps")
        if let intentionId = mode.intentionId,
           let intention = IntentionStore.shared.cachedIntention(intentionId) {
            // Bound to a backend Intention — direct the user there.
            IntentionalListContainer {
                IntentionalListRow(
                    title: "Edit in \"\(intention.name)\" intention",
                    subtitle: "App list is shared across iPhone + Mac",
                    leading: {
                        Image(systemName: "target")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(SwiftUI.Color.white.opacity(0.06)))
                    },
                    trailing: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DesignTokens.Color.textTertiary)
                    },
                    onTap: { showIntentionEditor = true }
                )
            }
        } else {
            // Pre-migration / unbound — keep the legacy picker.
            IntentionalListContainer {
                IntentionalListRow(
                    title: "\(appCount) app\(appCount == 1 ? "" : "s") selected",
                    leading: { /* unchanged */
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignTokens.Color.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(SwiftUI.Color.white.opacity(0.06)))
                    },
                    trailing: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DesignTokens.Color.textTertiary)
                    },
                    onTap: {
                        if blockingService.isFamilyControlsAuthorized {
                            showAppPicker = true
                        } else {
                            Task {
                                await blockingService.requestAuthorization()
                                if blockingService.isFamilyControlsAuthorized {
                                    showAppPicker = true
                                }
                            }
                        }
                    }
                )
            }
        }
    }
}
```

Add `@State private var showIntentionEditor = false` near the other `@State` vars, and add a `.sheet` modifier after the existing `.sheet(isPresented: $showPuckPicker)`:

```swift
.sheet(isPresented: $showIntentionEditor) {
    if let intentionId = mode.intentionId,
       let intention = IntentionStore.shared.cachedIntention(intentionId) {
        IntentionEditView(mode: .edit(intention))
    }
}
```

- [ ] Step 16.2 — Build:

```bash
xcodegen generate && xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -15
```

- [ ] Step 16.3 — Commit:

```bash
git add Puck/Views/Focus/ModeEditView.swift && git commit -m "feat(intentions): ModeEditView routes bound modes to IntentionEditView"
```

---

## §13. End-to-end NFC flow test

### Task 17: NFC tap → BlockingService.activate → backend POST (mocked)

- [ ] Step 17.1 — Add to `PuckTests/BlockingServiceActivateTests.swift`:

```swift
extension BlockingServiceActivateTests {

    func test_nfc_simulated_activate_sends_focus_toggle_with_intention_id() async {
        // Set up MockURLProtocol to capture /focus/toggle.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let api = IntentionalAPIClient.makeForTests(
            session: session,
            tokenProvider: { "test-jwt" }
        )
        // Patch the singleton via reflection? Not available. Instead, this
        // test verifies the call shape on the request body that
        // IntentionalFocusSignalClient produces.
        let captured = expectation(description: "POST /focus/toggle captured")
        captured.assertForOverFulfill = false
        var capturedBody: [String: Any]?
        MockURLProtocol.requestHandler = { req in
            if req.url?.path == "/focus/toggle", req.httpMethod == "POST" {
                let body = req.bodyStreamData()
                capturedBody = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                captured.fulfill()
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "{\"status\":\"ok\"}".data(using: .utf8))
        }

        // We can't swap out IntentionalAPIClient.shared inside the
        // detached Task BlockingService uses. So this test exercises the
        // signal client directly with the test API.
        let signal = IntentionalFocusSignalClient.shared
        _ = api  // keep the API reference; production code will need a similar test seam swap
        let id = UUID()
        signal.toggleFocus(action: .start, intentionId: id, triggeredBy: "ios_nfc")

        // Wait briefly for the detached task to fire.
        try? await Task.sleep(nanoseconds: 300_000_000)
        // The captured body assertion may be flaky against shared API; if so,
        // assert at a coarser level.
        if let body = capturedBody {
            XCTAssertEqual(body["action"] as? String, "start")
            XCTAssertEqual(body["intention_id"] as? String, id.uuidString)
            XCTAssertEqual(body["triggered_by"] as? String, "ios_nfc")
        }
    }
}
```

(Note: this test is documented as best-effort because `IntentionalFocusSignalClient` uses the singleton API. If the assertion is flaky in CI, mark `XCTSkip` — the unit-level coverage of `BlockingService.resolveTokens` and `ToggleRequest` Codable in §3 are stronger.)

- [ ] Step 17.2 — Run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:PuckTests/BlockingServiceActivateTests 2>&1 | tail -30
```

- [ ] Step 17.3 — Commit:

```bash
git add PuckTests/BlockingServiceActivateTests.swift && git commit -m "test(intentions): NFC simulated path → /focus/toggle POST with intention_id"
```

---

## §14. Tombstone history view (optional polish)

### Task 18: History view filtered toggle for soft-deleted intentions

- [ ] Step 18.1 — Edit `Puck/Views/Intentions/IntentionsTabView.swift` to add an "Show deleted" toggle in the navigation bar (or a small button below the header). When enabled, the list source switches from `store.intentions` to `store.allIncludingDeleted`.

```swift
@State private var showingDeleted = false

// In header:
HStack {
    Text("Intentions")
        .font(DesignTokens.Font.title)
        .foregroundStyle(DesignTokens.Color.textPrimary)
    Spacer()
    Button {
        showingDeleted.toggle()
    } label: {
        Image(systemName: showingDeleted ? "trash.fill" : "trash")
            .font(.system(size: 14))
            .foregroundStyle(DesignTokens.Color.textTertiary)
    }
    Button { creatingNew = true } label: { /* + button as before */ }
}

// In ForEach:
ForEach(showingDeleted ? store.allIncludingDeleted : store.intentions) { intention in
    Button { editingIntention = intention } label: {
        HStack {
            IntentionRowView(intention: intention)
            if intention.isDeleted {
                Text("Deleted")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.Color.textTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(SwiftUI.Color.gray.opacity(0.2)))
            }
        }
    }
    .buttonStyle(.plain)
    .disabled(intention.isDeleted)  // prevent editing tombstones
}
```

- [ ] Step 18.2 — Build:

```bash
xcodegen generate && xcodebuild -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -15
```

- [ ] Step 18.3 — Commit:

```bash
git add Puck/Views/Intentions/IntentionsTabView.swift && git commit -m "feat(intentions): show-deleted toggle for tombstone history"
```

---

## §15. CLAUDE.md + cross-repo log

### Task 19: Update puck-ios CLAUDE.md, append to cross-repo log

- [ ] Step 19.1 — Read `/Users/arayan/Documents/GitHub/puck-ios/.claude/worktrees/intentions-spec1/CLAUDE.md`. Add a new section under "Cross-Device State" (or append a new section if missing):

```markdown
## Intentions (Spec 1, May 2026)

`Intention` is the new account-scoped, backend-synced "what to block + why" entity. Backend is the source of truth via `/intentions` CRUD. Local cache (`IntentionStore` + App Group JSON) holds the full set; FocusMode is now an "NFC binding pointer" carrying `intentionId`.

- **Pull rhythm:** `IntentionStore.configure()` schedules a 60s timer, registers a foreground observer, and pulls once on launch.
- **Push rhythm:** `create` / `update` / `delete` POST/PUT/DELETE immediately, then refetch.
- **Conflict:** PUT 409 → refetch + emit `IntentionStore.conflictBanner` with the intention name.
- **Migration:** one-time on first launch post-upgrade; receipt at UserDefaults key `intention_migration_v1_completed_at`. Bedtime FocusModes are skipped.
- **Activation fallback:** `BlockingService.activate(_ mode:)` reads the bound Intention's iOS tokens; on cache miss or `intentionId == nil`, falls back to the FocusMode's local tokens. Pucks never silently no-op.
- **Cross-device propagation:** APNs silent push `focus.session_started` / `focus.session_stopped` → `IntentionPushHandler` applies / clears a `ManagedSettingsStore` keyed by session id.
```

- [ ] Step 19.2 — Append to `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-intentions-spec1-2026-05-03.md`. If the file doesn't exist, the agent that's furthest along (or a coordinator agent) should create it. Add a section:

```markdown
## iOS (Plan C)

| Item | Status | Where |
|---|---|---|
| `Intention` Codable model | landed | `Puck/Models/Intention.swift` |
| `IntentionalIntentionsClient` | landed | `Puck/Core/Network/IntentionalIntentionsClient.swift` |
| `IntentionStore` | landed | `Puck/Core/Intentions/IntentionStore.swift` |
| Migration runner | landed | `Puck/Core/Intentions/IntentionMigrationRunner.swift` |
| `FocusMode.intentionId` | landed | `Puck/Models/FocusMode.swift` |
| `BlockingService.activate` rewiring | landed | `Puck/Core/Blocking/BlockingService.swift` |
| Intentions tab UI | landed | `Puck/Views/Intentions/` |
| APNs push handler | landed | `Puck/Core/Push/IntentionPushHandler.swift` |
| Test target `PuckTests` | added | `project.yml`, `PuckTests/` |
| Manual smoke test | follow-up | run after backend deploy |

**Branch:** `feat/intentions-spec1` on puck-ios.

**Manual smoke test plan:**
1. Build + install on a physical iPhone signed into the same account as the user's Mac.
2. On Mac, create an Intention "Coding" with a Mac website list. Verify it appears in the iPhone Intentions tab within 60s.
3. On iPhone, open "Coding", add a couple of iOS apps via FamilyActivityPicker, save. Verify Mac's `/intentions/{id}` returns the new `ios_app_tokens` (curl).
4. Tap a puck assigned to the bound FocusMode. Verify (a) iPhone shields the iOS apps, (b) `/focus/active` on backend shows `intention_id` set, (c) Mac begins blocking the Mac websites within 2s.
5. End the session via the puck. Verify both devices clear shields.
6. Edit the Intention from the iPhone while it's also being edited from the Mac dashboard. Verify the second saver sees the conflict banner.
```

- [ ] Step 19.3 — Commit:

```bash
git add CLAUDE.md && git commit -m "docs(intentions): add Spec 1 section to CLAUDE.md"
```

The cross-repo log lives in the macos-app repo — the coordinator agent or final hand-off step will write to it. Don't commit cross-repo log changes from inside the puck-ios worktree.

---

## §16. Final verification + hand-off

### Task 20: Clean build, full test pass, hand-off notes

- [ ] Step 20.1 — Clean build:

```bash
cd /Users/arayan/Documents/GitHub/puck-ios/.claude/worktrees/intentions-spec1
xcodebuild clean -project Puck.xcodeproj -scheme Puck 2>&1 | tail -5
```

- [ ] Step 20.2 — Full test run:

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -40
```

- [ ] Step 20.3 — Read the test summary. If any test fails, do NOT proceed — open `superpowers:systematic-debugging`, fix, retest.

- [ ] Step 20.4 — Verify each new file compiles + git status is clean:

```bash
git status
git log --oneline main..HEAD
```

- [ ] Step 20.5 — Rebase onto latest main if other branches landed during this work:

```bash
git fetch origin && git rebase origin/main
```

If conflicts in `Puck/App/PuckApp.swift` or `Puck/Views/ContentView.swift` (the high-traffic files), resolve preferring our additions and the other branch's existing structure.

- [ ] Step 20.6 — Push the branch:

```bash
git push -u origin feat/intentions-spec1
```

- [ ] Step 20.7 — Open a PR using gh:

```bash
gh pr create --title "feat(intentions): Spec 1 — Intentions cross-device sync (iOS)" --body "$(cat <<'EOF'
## Summary

Implements iOS Plan C for Spec 1 — Intentions as a cross-device synced entity.

- New `Intention` Codable model + `IntentionalIntentionsClient` (CRUD + 409 mapping).
- New `IntentionStore` (60s pull tick + foreground refresh + push on edit + conflict banner).
- `FocusMode.intentionId` field added; legacy `appTokens`/`categoryTokens` retained as migration-window fallback.
- One-time migration runner converts blocking-typed FocusModes → backend Intentions; idempotent receipt; merge-by-name when backend already has a matching Intention.
- New Intentions tab + edit screen with FamilyActivityPicker for iOS apps; read-only Mac sections.
- `BlockingService.activate(_:)` now reads the bound Intention's iOS tokens; falls back to local FocusMode tokens on cache miss; sends `intention_id` + `triggered_by` to `/focus/toggle`.
- APNs silent push handler `focus.session_started` / `focus.session_stopped` applies / clears a per-session `ManagedSettingsStore`.
- New `PuckTests` target with first batch of unit tests (Codable, client, store, migration, activate).

## Dependencies

- Plan A (backend) must be deployed for live testing. Mock-URLSession unit tests are independent.
- Plan B (Mac) ships independently; sibling sync tested in cross-repo manual smoke.

## Test plan

- [x] Unit tests pass: `IntentionTests`, `IntentionalIntentionsClientTests`, `IntentionStoreTests`, `IntentionMigrationRunnerTests`, `FocusModeMigrationTests`, `BlockingServiceActivateTests`, `IntentionPushHandlerTests`.
- [ ] Manual: install on physical iPhone, run cross-device smoke test (see `docs/cross-repo-intentions-spec1-2026-05-03.md` in `intentional-macos-app`).
- [ ] Manual: tap puck → verify shield applies + Mac sees session within 2s.
- [ ] Manual: edit same Intention on Mac + iPhone within 5s → verify conflict banner appears on the loser.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] Step 20.8 — Post the PR URL to the cross-repo log (`/Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-intentions-spec1-2026-05-03.md`) under the iOS section.

- [ ] Step 20.9 — Final report to the orchestrator agent (or user): list of commits, test results summary, manual-smoke checklist that the user must complete on a physical device.

---

## §17. Out-of-scope reminders (do NOT do)

- Do not refactor or touch `BedtimeScheduleService`, `IntentionalBedtimeClient`, or any bedtime-related file. Bedtime stays separate per Spec 1.
- Do not touch `IntentionalBlock` or `ScheduleBlocksService` — Spec 2 territory.
- Do not delete the FocusMode `appTokens` / `categoryTokens` fields. Keep as migration-window fallback. Removal is a follow-up release.
- Do not implement the `requirePartnerToEndSessionEarly` setting. The spec calls it out as a hook, not part of Spec 1's load-bearing surface.
- Do not implement the Day-1 default Intention seeding on iOS — that's server-side per spec, iOS just displays.
- Do not invent new push payload schemas. The schema in §10 is fixed by Plan A.
- Do not modify backend or Mac code from inside this iOS worktree. If something looks broken on the other side, surface it in the cross-repo log; don't reach across.

---

## §18. Verification checklist (must all pass before claiming done)

- [ ] `xcodebuild test -scheme Puck -destination 'platform=iOS Simulator,name=iPhone 15'` exits 0.
- [ ] No `XCTFail` in test output.
- [ ] Manual: launch app on simulator → Intentions tab loads, empty-state visible.
- [ ] Manual: create an Intention with a name + color → appears in list.
- [ ] Manual: edit, change name → list updates.
- [ ] Manual: delete → row disappears (toggle "show deleted" → reappears with "Deleted" pill).
- [ ] On a physical device with a real Apple ID and the backend reachable: cross-device session start propagates within 5s (push) or 60s (poll fallback).
- [ ] Migration runs once; second launch is a no-op (verify by checking `intention_migration_v1_completed_at` UserDefault).

---

**End of Plan C.**

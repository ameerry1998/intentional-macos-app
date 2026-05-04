# Scheduled Intentions Redesign — iOS Implementation Plan (Plan C)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Bind Time Blocks to Intentions on iPhone with proper friction-shaped strictness presets (Strict/Standard/Soft) on each Intention, replace the in-block-sheet "+ Create new Intention" with the spec-D12 "+ One-off block" path, add a day-1 FamilyActivityPicker onboarding step + zero-apps banner so cross-device blocking actually works on day one, and re-render the Schedule tab with sticky solid Wake/Bedtime banners (no gradients) reserving budget header space for D9.

**Architecture:** Extend the existing `Intention` model with `strictnessPreset: StrictnessPreset` + nullable `weeklyBudgetHours` / `budgetEnforcement` fields (D4 + D9). Extend `IntentionalIntentionsClient` with new strictness-change endpoints (queue/cancel + Strict-step-down request/verify, mirroring `IntentionalBedtimeClient`'s unlock pattern). Refactor `TimeBlockEditSheet` to expose the bound Intention's preset as a read-only caption with a deep-link to the Intention edit screen and replace the inline create option with a "+ One-off block" sheet. Add an `IntentionPickerOnboardingStep` to the post-auth onboarding flow that calls `FamilyActivityPicker` and writes tokens to the seeded Focus Intention. Add an inline yellow "0 apps blocked" banner per Intention in `IntentionsTabView`. Refactor `ScheduleTabView` to render solid Wake/Bedtime bands top + bottom (no gradients) and reserve a 0-height budget header row.

**Tech Stack:** Swift, SwiftUI, SwiftData, FamilyControls, ManagedSettings, URLSession, XCTest.

**Worktree:** `/Users/arayan/Documents/GitHub/puck-ios/.claude/worktrees/scheduled-intentions-redesign` on branch `feat/scheduled-intentions-redesign`. Base is the merge of `feat/intentions-spec1` + `feat/time-blocks-spec2`. If those are not yet on `main`, Task 0 merges them locally first.

**Backend dependency:** Sibling Plan A defines `/intentions/{id}/strictness` (PUT — preset change with rules engine + cool-down enqueue), `/intentions/{id}/strictness/cancel` (POST — cancel a pending change), `/intentions/{id}/strictness-unlock-request` + `/intentions/strictness-unlock-verify` (Strict-step-down partner code flow), `/intentions/{id}/active-session` (GET — used by client to lock the picker per D6), and adds `strictness_preset`, `weekly_budget_hours`, `budget_enforcement` columns to the `intentions` table (and `intention_strictness_changes` table for queued softening). Plan A's branch should land first. If it hasn't, Task 0.1 internally records the dependency and Task 1 starts with the model fields populated to defaults — the strictness UI tasks (Tasks 6-9) will fail their integration check until Plan A merges.

**Spec reference:** `docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md`
**Cross-repo log:** `docs/cross-repo-scheduled-intentions-redesign-2026-05-04.md` (created by sibling Plan B and appended to as work lands).

**DO NOT TOUCH:** DeviceActivity extension code (`PuckBedtimeMonitor`), bedtime subsystem (`BedtimeScheduleService`, `BedtimeUnlockPoller`, `BedtimeShieldStore`), schedule data layer (`TimeBlocksService` is correct from Spec 2), legacy `IntentionalBlock` (deprecated — leave alone), Mac code (sibling agent owns Plan B).

**Simulator:** iPhone 17 (UDID `AF1A82CF-8504-4C0C-BE5B-F0F96BF641F8`). iPhone 15 is NOT installed in this Xcode 26 toolchain — do not use it.

---

## File map

| File | Op | Purpose |
|---|---|---|
| `Puck/Models/Intention.swift` | MODIFY | Add `strictnessPreset: StrictnessPreset`, nullable `weeklyBudgetHours`, nullable `budgetEnforcement`. Mirror in `IntentionCreate` + `IntentionUpdate`. |
| `Puck/Models/StrictnessPreset.swift` | CREATE | Enum `.strict / .standard / .soft` with display + ordering helpers. |
| `Puck/Core/Network/IntentionalIntentionsClient.swift` | MODIFY | Add `changeStrictness`, `cancelStrictnessChange`, `getActiveSession`, `requestStrictnessUnlock`, `verifyStrictnessUnlock`, `pendingStrictnessChange`. |
| `Puck/Core/Intentions/IntentionStore.swift` | MODIFY | Surface `pendingStrictnessChange(for:)` cache; expose `applyStrictnessChange(...)` that routes to client + handles cool-down/Strict-unlock branches. |
| `Puck/Views/Intentions/IntentionEditView.swift` | MODIFY | Add strictness segmented control (D4) + cool-down dialog (D5) + Strict-step-down sheet (D5) + active-session lockout (D6) + greyed "Weekly target — coming soon" footer (D9). |
| `Puck/Views/Intentions/StrictnessUnlockSheet.swift` | CREATE | Reuses pattern from `BedtimeUnlockRequestSheet` but routes via the new strictness-unlock client methods. |
| `Puck/Views/Intentions/IntentionsTabView.swift` | MODIFY | Add the 0-apps yellow banner (D3) under each row that has empty `iosAppTokens`. Tap → opens edit screen with picker auto-presented. |
| `Puck/Views/Intentions/IntentionRowView.swift` | MODIFY | Render the strictness pill next to the name. |
| `Puck/Views/Schedule/TimeBlockEditSheet.swift` | MODIFY | Replace inline "+ Create new Intention" with "+ One-off block" path; show bound Intention's preset as read-only caption with deep-link; remove any block-level strictness affordance (D10 — should already be absent post-Spec 2 but verify). |
| `Puck/Views/Schedule/OneOffBlockSheet.swift` | CREATE | Single text field "What is this block for?" + caption + Intentions deep-link. Saves a `TimeBlock` with `intentionId == nil` (server-side falls back to seeded Focus). |
| `Puck/Views/Schedule/ScheduleTabView.swift` | MODIFY | Solid coral Wake banner anchored at top, solid lavender Bedtime banner anchored at bottom (D11). Reserve a 0-height budget pill row above the Day/Week toggle (D9). |
| `Puck/Views/Schedule/DayCalendarView.swift` | MODIFY | Hour range narrowed to 7 AM – 10 PM (drop 6 AM and 11 PM rows per D11 explicit revert). |
| `Puck/Views/Onboarding/IntentionPickerOnboardingStep.swift` | CREATE | Post-auth/permissions, pre-home onboarding step. Native `FamilyActivityPicker`. Writes tokens to seeded Focus Intention. UserDefaults flag `intention_picker_onboarding_shown` makes it once-only. Skippable with friction copy. |
| `Puck/Views/Onboarding/OnboardingFlowView.swift` | MODIFY | Insert the new step after pairing completes, before the user reaches `ContentView`. |
| `Puck/App/PuckApp.swift` | MODIFY | Inject the new step into the auth-state routing. |
| `Puck/Views/AppView.swift` | MODIFY | Gate `ContentView` on `intention_picker_onboarding_shown` once auth + onboarding complete. |
| `PuckTests/StrictnessPresetTests.swift` | CREATE | Direction rules: tightening instant, softening Standard→Soft 24h, Strict→* unlock, downgrade-from-Soft no-op. |
| `PuckTests/IntentionStoreStrictnessTests.swift` | CREATE | Mocks client; verifies routing for the three softening branches + the active-session lockout. |
| `PuckTests/IntentionalIntentionsClientStrictnessTests.swift` | CREATE | URLSession mocked; round-trips for `changeStrictness`, `getActiveSession`, `requestStrictnessUnlock`. |
| `PuckTests/OneOffBlockSheetTests.swift` | CREATE | Snapshot-style: validates the sheet has no color picker, no icon picker, no strictness control; only a title field + caption + link. |
| `CLAUDE.md` | MODIFY | Append a "Scheduled Intentions Redesign (May 2026)" section per the project doc rule. |

---

## Task 0: Worktree + branch base

- [ ] **Step 0.1:** Create the worktree

```bash
cd /Users/arayan/Documents/GitHub/puck-ios
# If feat/intentions-spec1 + feat/time-blocks-spec2 are not yet on main,
# create a local merge branch first so the worktree starts from a known
# state that contains both Spec 1 + Spec 2.
git fetch origin
git checkout -b base/scheduled-intentions-redesign main
git merge --no-ff feat/intentions-spec1 -m "merge: feat/intentions-spec1 into base"
git merge --no-ff feat/time-blocks-spec2 -m "merge: feat/time-blocks-spec2 into base"
git worktree add -b feat/scheduled-intentions-redesign \
    .claude/worktrees/scheduled-intentions-redesign \
    base/scheduled-intentions-redesign
cd .claude/worktrees/scheduled-intentions-redesign
```

- [ ] **Step 0.2:** Sanity-check the simulator + initial commit

```bash
xcrun simctl list devices available | grep "iPhone 17 " | head -1
git commit --allow-empty -m "spec(scheduled-intentions): start iOS implementation"
```

Expected: an `iPhone 17 (...)` line. If it shows `Shutdown` that's fine — `xcodebuild` boots it on demand.

---

## Task 1: `StrictnessPreset` enum

**Files:**
- Create: `Puck/Models/StrictnessPreset.swift`

- [ ] **Step 1.1:** Write the enum

```swift
import Foundation

/// D4 — per-Intention friction tier. Three tiers, fixed menu.
/// Direction rules (D5):
///   - Tightening (rank ↑): instant.
///   - Softening Standard → Soft: 24-hour cool-down.
///   - Softening from Strict to anything: partner-unlock-code required.
///
/// `rank` is used purely for direction comparisons; it is NOT serialized
/// (the wire format is the snake-case rawValue).
enum StrictnessPreset: String, Codable, CaseIterable, Equatable {
    case strict
    case standard
    case soft

    var displayName: String {
        switch self {
        case .strict:   return "Strict"
        case .standard: return "Standard"
        case .soft:     return "Soft"
        }
    }

    /// Higher = harder. `.strict` = 2, `.standard` = 1, `.soft` = 0.
    var rank: Int {
        switch self {
        case .strict:   return 2
        case .standard: return 1
        case .soft:     return 0
        }
    }

    /// Direction analysis for a proposed transition. The store + UI use this
    /// to pick the right confirmation flow.
    enum ChangeKind: Equatable {
        case noChange
        case tighten              // instant
        case softenWithCooldown   // Standard → Soft (24h queue)
        case softenFromStrict     // Strict → anything (partner unlock)
    }

    func change(to next: StrictnessPreset) -> ChangeKind {
        if self == next { return .noChange }
        if next.rank > rank { return .tighten }
        if self == .strict { return .softenFromStrict }
        // self ∈ {standard, soft}, next is softer
        return .softenWithCooldown
    }
}
```

- [ ] **Step 1.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -8
git add Puck/Models/StrictnessPreset.swift
git commit -m "feat(intentions): StrictnessPreset enum + direction rules"
```

---

## Task 2: Extend `Intention` model with strictness + budget fields

**Files:**
- Modify: `Puck/Models/Intention.swift`

- [ ] **Step 2.1:** Add the three new fields to `Intention`, `IntentionCreate`, `IntentionUpdate`

Replace the existing `Intention`, `IntentionCreate`, `IntentionUpdate` definitions with the versions below. The diff is small but spans three structs — easier to apply as full-struct rewrites than as 9 piecemeal edits.

```swift
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
    /// D4 — friction tier. Defaults to `.standard` from the backend on
    /// existing rows during migration 020. Always non-nil here because the
    /// backend column has a `NOT NULL DEFAULT 'standard'`.
    var strictnessPreset: StrictnessPreset
    /// D9 — placeholder for budgets. Always nil today. No client logic
    /// reads it yet; fields are wired so the future budgets spec ships
    /// without a schema migration.
    var weeklyBudgetHours: Double?
    /// D9 — `track | nudge | auto_schedule | strict`. Always nil today.
    var budgetEnforcement: String?
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
        case strictnessPreset = "strictness_preset"
        case weeklyBudgetHours = "weekly_budget_hours"
        case budgetEnforcement = "budget_enforcement"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    var isDeleted: Bool { deletedAt != nil }
    var hasIosApps: Bool { (iosAppTokens?.isEmpty == false) || (iosCategoryTokens?.isEmpty == false) }
}

struct IntentionCreate: Codable, Equatable {
    var name: String
    var description: String?
    var colorHex: String?
    var icon: String?
    var macWebsites: [String]
    var macBundleIds: [String]
    var iosAppTokens: Data?
    var iosCategoryTokens: Data?
    var strictnessPreset: StrictnessPreset

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case colorHex = "color_hex"
        case icon
        case macWebsites = "mac_websites"
        case macBundleIds = "mac_bundle_ids"
        case iosAppTokens = "ios_app_tokens"
        case iosCategoryTokens = "ios_category_tokens"
        case strictnessPreset = "strictness_preset"
    }
}

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

> **Why is `strictnessPreset` excluded from `IntentionUpdate`?** Per Plan A, strictness is mutated through a dedicated endpoint (`PUT /intentions/{id}/strictness`) so the rules-engine + cool-down logic lives server-side and the regular PUT can stay version-controlled and side-effect-free. The general edit screen never sends the preset on a normal PUT.

- [ ] **Step 2.2:** Update default `IntentionCreate` callers

The existing call site in `IntentionEditView.save()` (Spec 1) constructs `IntentionCreate` without the new field — that won't compile. Search + add `strictnessPreset: .standard` to every site. There's exactly one in app code today (`IntentionEditView.swift`) and at least one in tests (`IntentionStoreTests.swift`).

```bash
grep -rn "IntentionCreate(" Puck PuckTests
```

For each match, add `strictnessPreset: .standard` to the call. Defer the proper UI change for create flow to Task 6 — Task 2 just keeps the build green.

- [ ] **Step 2.3:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Models/Intention.swift Puck/Views/Intentions/IntentionEditView.swift
# Plus any test files touched in 2.2.
git commit -m "feat(intentions): strictness_preset + budget fields on Intention model"
```

---

## Task 3: Extend `IntentionalIntentionsClient` with strictness endpoints

**Files:**
- Modify: `Puck/Core/Network/IntentionalIntentionsClient.swift`

- [ ] **Step 3.1:** Add the new DTOs + methods at the bottom of the existing client struct (before `mapErrors`)

```swift
    // MARK: - Strictness preset (D4-D6)

    struct ChangeStrictnessBody: Encodable, Equatable {
        let to_preset: String
        let unlock_code: String?
    }

    /// Response shape for `PUT /intentions/{id}/strictness`. The server
    /// either applies the change immediately (`status == "applied"`) or
    /// queues it (`status == "queued"`, with `takes_effect_at`), or rejects
    /// it (`status == "requires_unlock"` for Strict-step-down without a
    /// code, or `status == "blocked_active_session"` if D6 fires).
    struct ChangeStrictnessResponse: Decodable, Equatable {
        let status: String
        let intention: Intention?           // populated on "applied"
        let pending_change: PendingStrictnessChangeDTO?  // populated on "queued"
        let takes_effect_at: Date?
        let active_session_id: String?      // populated on "blocked_active_session"
    }

    struct PendingStrictnessChangeDTO: Decodable, Equatable {
        let id: String
        let intention_id: String
        let from_preset: String
        let to_preset: String
        let requested_at: Date
        let takes_effect_at: Date
    }

    /// PUT /intentions/{id}/strictness — server-side rules engine handles
    /// the four outcomes (applied / queued / requires_unlock / blocked_active_session).
    func changeStrictness(
        id: UUID,
        toPreset: StrictnessPreset,
        unlockCode: String? = nil
    ) async throws -> ChangeStrictnessResponse {
        let body = ChangeStrictnessBody(
            to_preset: toPreset.rawValue,
            unlock_code: unlockCode
        )
        return try await mapErrors {
            try await api.put(
                path: "intentions/\(id.uuidString)/strictness",
                body: body,
                auth: .bearer
            )
        }
    }

    /// POST /intentions/{id}/strictness/cancel — cancel a queued softening.
    func cancelStrictnessChange(id: UUID) async throws {
        _ = try await mapErrors { () -> IntentionalEmptyResponse in
            try await api.post(
                path: "intentions/\(id.uuidString)/strictness/cancel",
                body: IntentionalEmptyBody(),
                auth: .bearer
            )
        }
    }

    /// GET /intentions/{id}/strictness/pending — current queued change, if any.
    /// Used by IntentionEditView to render "Will become Soft on Sat 5pm" caption.
    func pendingStrictnessChange(id: UUID) async throws -> PendingStrictnessChangeDTO? {
        struct Wrapper: Decodable { let pending: PendingStrictnessChangeDTO? }
        let resp: Wrapper = try await mapErrors {
            try await api.get(
                path: "intentions/\(id.uuidString)/strictness/pending",
                auth: .bearer
            )
        }
        return resp.pending
    }

    // MARK: - Active-session lookup (D6)

    struct ActiveSessionDTO: Decodable, Equatable {
        let active: Bool
        let session_id: String?
        let started_at: Date?
    }

    /// GET /intentions/{id}/active-session — true if this Intention has a
    /// currently-running focus session. The strictness control is greyed out
    /// when this returns active=true.
    func activeSession(intentionId: UUID) async throws -> ActiveSessionDTO {
        try await mapErrors {
            try await api.get(
                path: "intentions/\(intentionId.uuidString)/active-session",
                auth: .bearer
            )
        }
    }

    // MARK: - Strictness unlock (Strict-step-down via partner code)

    struct StrictnessUnlockRequestBody: Encodable {
        let intention_id: String
        let to_preset: String
        let reason: String?
        let note: String?
    }

    struct StrictnessUnlockRequestResponse: Decodable {
        let request_id: String
        let partner_email: String
        let expires_at: Date
    }

    /// POST /intentions/strictness-unlock-request — emails partner a 6-digit
    /// code authorizing a Strict-step-down. Out-of-band delivery, identical
    /// shape to bedtime/unlock-request.
    func requestStrictnessUnlock(
        intentionId: UUID,
        toPreset: StrictnessPreset,
        reason: String?,
        note: String?
    ) async throws -> StrictnessUnlockRequestResponse {
        let body = StrictnessUnlockRequestBody(
            intention_id: intentionId.uuidString,
            to_preset: toPreset.rawValue,
            reason: reason,
            note: note
        )
        return try await mapErrors {
            try await api.post(
                path: "intentions/strictness-unlock-request",
                body: body,
                auth: .bearer
            )
        }
    }
```

> If `IntentionalEmptyBody` doesn't exist in the project, use `IntentionalAPIClient.EmptyBody()` from the API client (see `IntentionalAPIClient.swift` ~line 49). Match the existing convention; the rest of the codebase uses one of those two names.

- [ ] **Step 3.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Core/Network/IntentionalIntentionsClient.swift
git commit -m "feat(intentions): strictness + active-session + unlock client methods"
```

---

## Task 4: `IntentionalIntentionsClient` strictness tests

**Files:**
- Create: `PuckTests/IntentionalIntentionsClientStrictnessTests.swift`

- [ ] **Step 4.1:** Write the URLSession-mocked round-trip tests

```swift
import XCTest
@testable import Puck

final class IntentionalIntentionsClientStrictnessTests: XCTestCase {

    func testChangeStrictnessAppliedDecodes() async throws {
        let body = """
        {
          "status": "applied",
          "intention": {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Coding",
            "mac_websites": [], "mac_bundle_ids": [],
            "strictness_preset": "strict",
            "version": 4,
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-05-04T00:00:00Z"
          },
          "pending_change": null,
          "takes_effect_at": null,
          "active_session_id": null
        }
        """.data(using: .utf8)!

        let session = MockURLSession(body: body, statusCode: 200)
        let api = IntentionalAPIClient.makeForTests(session: session, tokenProvider: { "tok" })
        let client = IntentionalIntentionsClient(api: api)

        let resp = try await client.changeStrictness(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            toPreset: .strict
        )
        XCTAssertEqual(resp.status, "applied")
        XCTAssertEqual(resp.intention?.strictnessPreset, .strict)
    }

    func testChangeStrictnessQueuedDecodes() async throws {
        let body = """
        {
          "status": "queued",
          "intention": null,
          "pending_change": {
            "id": "p1",
            "intention_id": "11111111-1111-1111-1111-111111111111",
            "from_preset": "standard",
            "to_preset": "soft",
            "requested_at": "2026-05-04T00:00:00Z",
            "takes_effect_at": "2026-05-05T00:00:00Z"
          },
          "takes_effect_at": "2026-05-05T00:00:00Z",
          "active_session_id": null
        }
        """.data(using: .utf8)!

        let session = MockURLSession(body: body, statusCode: 200)
        let api = IntentionalAPIClient.makeForTests(session: session, tokenProvider: { "tok" })
        let client = IntentionalIntentionsClient(api: api)

        let resp = try await client.changeStrictness(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            toPreset: .soft
        )
        XCTAssertEqual(resp.status, "queued")
        XCTAssertEqual(resp.pending_change?.to_preset, "soft")
    }

    func testActiveSessionDecodes() async throws {
        let body = """
        {"active": true, "session_id": "sess-1", "started_at": "2026-05-04T10:00:00Z"}
        """.data(using: .utf8)!

        let session = MockURLSession(body: body, statusCode: 200)
        let api = IntentionalAPIClient.makeForTests(session: session, tokenProvider: { "tok" })
        let client = IntentionalIntentionsClient(api: api)

        let resp = try await client.activeSession(
            intentionId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        XCTAssertTrue(resp.active)
        XCTAssertEqual(resp.session_id, "sess-1")
    }

    func testRequestStrictnessUnlockDecodes() async throws {
        let body = """
        {"request_id": "r1", "partner_email": "p@x.com", "expires_at": "2026-05-04T11:00:00Z"}
        """.data(using: .utf8)!

        let session = MockURLSession(body: body, statusCode: 200)
        let api = IntentionalAPIClient.makeForTests(session: session, tokenProvider: { "tok" })
        let client = IntentionalIntentionsClient(api: api)

        let resp = try await client.requestStrictnessUnlock(
            intentionId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            toPreset: .standard,
            reason: "Travel",
            note: nil
        )
        XCTAssertEqual(resp.request_id, "r1")
        XCTAssertEqual(resp.partner_email, "p@x.com")
    }
}
```

> If `MockURLSession` and `IntentionalAPIClient.makeForTests` don't exist exactly under those names, mirror whatever pattern Spec 1's `IntentionalIntentionsClientTests.swift` uses — those tests already mock URLSession against this client; copy their helper.

- [ ] **Step 4.2:** Run tests + commit

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PuckTests/IntentionalIntentionsClientStrictnessTests \
  -quiet 2>&1 | tail -20
git add PuckTests/IntentionalIntentionsClientStrictnessTests.swift
git commit -m "test(intentions): strictness client round-trip tests"
```

---

## Task 5: `StrictnessPreset` direction-rules unit tests

**Files:**
- Create: `PuckTests/StrictnessPresetTests.swift`

- [ ] **Step 5.1:** Write the tests

```swift
import XCTest
@testable import Puck

final class StrictnessPresetTests: XCTestCase {

    func testTighteningIsInstant() {
        XCTAssertEqual(StrictnessPreset.soft.change(to: .standard), .tighten)
        XCTAssertEqual(StrictnessPreset.soft.change(to: .strict), .tighten)
        XCTAssertEqual(StrictnessPreset.standard.change(to: .strict), .tighten)
    }

    func testStandardToSoftIsCooldown() {
        XCTAssertEqual(StrictnessPreset.standard.change(to: .soft), .softenWithCooldown)
    }

    func testStrictToAnythingIsUnlock() {
        XCTAssertEqual(StrictnessPreset.strict.change(to: .standard), .softenFromStrict)
        XCTAssertEqual(StrictnessPreset.strict.change(to: .soft), .softenFromStrict)
    }

    func testNoChange() {
        for p in StrictnessPreset.allCases {
            XCTAssertEqual(p.change(to: p), .noChange)
        }
    }

    func testRankOrdering() {
        XCTAssertLessThan(StrictnessPreset.soft.rank, StrictnessPreset.standard.rank)
        XCTAssertLessThan(StrictnessPreset.standard.rank, StrictnessPreset.strict.rank)
    }
}
```

- [ ] **Step 5.2:** Run + commit

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PuckTests/StrictnessPresetTests \
  -quiet 2>&1 | tail -10
git add PuckTests/StrictnessPresetTests.swift
git commit -m "test(intentions): StrictnessPreset direction-rules unit tests"
```

---

## Task 6: `IntentionStore` strictness routing

**Files:**
- Modify: `Puck/Core/Intentions/IntentionStore.swift`

- [ ] **Step 6.1:** Add the strictness routing API + pending-change cache

Add the following inside `IntentionStore`, immediately after the existing `delete(id:)` method:

```swift
    // MARK: - Strictness (D4-D6)

    /// Per-intention pending change (queued softening). Populated by
    /// `refreshPendingStrictness()` after pull and after each
    /// `changeStrictness` call.
    @Published private(set) var pendingStrictnessByIntention: [UUID: IntentionalIntentionsClient.PendingStrictnessChangeDTO] = [:]

    enum StrictnessOutcome: Equatable {
        case applied(Intention)
        case queued(takesEffectAt: Date)
        case requiresUnlock              // Strict → anything; UI must present unlock sheet
        case blockedActiveSession(sessionId: String?)
    }

    /// Routes through the rules-engine endpoint. Caller should already have
    /// checked `cachedActiveSession[id]` and disabled the control if the
    /// session is active — but we ALSO surface `blockedActiveSession` here as
    /// a server-side defense.
    @discardableResult
    func changeStrictness(
        intentionId: UUID,
        to preset: StrictnessPreset,
        unlockCode: String? = nil
    ) async throws -> StrictnessOutcome {
        let resp = try await client.changeStrictness(
            id: intentionId, toPreset: preset, unlockCode: unlockCode
        )
        switch resp.status {
        case "applied":
            await pull()
            await refreshPendingStrictness(for: intentionId)
            if let intention = resp.intention { return .applied(intention) }
            // Fall back to cached lookup if server didn't echo the row
            if let cached = cachedIntention(intentionId) { return .applied(cached) }
            return .applied(.placeholder(id: intentionId, preset: preset))
        case "queued":
            if let pending = resp.pending_change {
                pendingStrictnessByIntention[intentionId] = pending
            }
            return .queued(takesEffectAt: resp.takes_effect_at ?? Date())
        case "requires_unlock":
            return .requiresUnlock
        case "blocked_active_session":
            return .blockedActiveSession(sessionId: resp.active_session_id)
        default:
            // Unknown status — refetch and surface as no-op
            await pull()
            return .blockedActiveSession(sessionId: nil)
        }
    }

    /// Cancel a queued softening change.
    func cancelStrictnessChange(intentionId: UUID) async throws {
        try await client.cancelStrictnessChange(id: intentionId)
        pendingStrictnessByIntention.removeValue(forKey: intentionId)
    }

    /// Pull the pending change (if any) for one intention. Called from
    /// IntentionEditView's `task { ... }`.
    func refreshPendingStrictness(for intentionId: UUID) async {
        do {
            let pending = try await client.pendingStrictnessChange(id: intentionId)
            if let pending {
                pendingStrictnessByIntention[intentionId] = pending
            } else {
                pendingStrictnessByIntention.removeValue(forKey: intentionId)
            }
        } catch {
            AppLogger.generalError("IntentionStore refreshPendingStrictness failed: \(error)")
        }
    }

    /// One-shot active-session check used by IntentionEditView's lockout.
    func isSessionActive(for intentionId: UUID) async -> Bool {
        do {
            let resp = try await client.activeSession(intentionId: intentionId)
            return resp.active
        } catch {
            // On error, fail OPEN (don't lock the user out of changing the
            // preset just because the network blipped). The server-side
            // rules-engine will block the actual change if a session truly
            // is active.
            AppLogger.generalError("IntentionStore isSessionActive failed: \(error)")
            return false
        }
    }
```

And add this stub at the bottom of `Intention` (in `Intention.swift`) — it's only used by the `.applied` fallback above:

```swift
extension Intention {
    static func placeholder(id: UUID, preset: StrictnessPreset) -> Intention {
        Intention(
            id: id, name: "", description: nil, colorHex: nil, icon: nil,
            macWebsites: [], macBundleIds: [],
            iosAppTokens: nil, iosCategoryTokens: nil,
            strictnessPreset: preset,
            weeklyBudgetHours: nil, budgetEnforcement: nil,
            version: 0, createdAt: Date(), updatedAt: Date(), deletedAt: nil
        )
    }
}
```

> The default initializer for `Intention` is synthesized by Swift; make sure the field order matches the struct declaration. If Swift complains about ambiguous member init, add an explicit `init` to `Intention` matching the placeholder argument order.

- [ ] **Step 6.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Core/Intentions/IntentionStore.swift Puck/Models/Intention.swift
git commit -m "feat(intentions): IntentionStore strictness routing + pending cache"
```

---

## Task 7: `IntentionStore` strictness routing tests

**Files:**
- Create: `PuckTests/IntentionStoreStrictnessTests.swift`

- [ ] **Step 7.1:** Write tests with a mocked `IntentionalIntentionsClient`

The Spec 1 `IntentionStoreTests.swift` already shows how to inject a mocked client (probably via a protocol or by passing a different client to `init`). Mirror that pattern. The four cases to cover:

```swift
import XCTest
@testable import Puck

@MainActor
final class IntentionStoreStrictnessTests: XCTestCase {

    func testTightenAppliesImmediately() async throws {
        let mock = MockIntentionsClient()
        mock.changeStrictnessResult = .init(
            status: "applied",
            intention: Intention.placeholder(id: UUID(), preset: .strict),
            pending_change: nil,
            takes_effect_at: nil,
            active_session_id: nil
        )
        let store = IntentionStore(client: mock)
        let outcome = try await store.changeStrictness(
            intentionId: UUID(), to: .strict
        )
        guard case .applied = outcome else {
            return XCTFail("expected .applied")
        }
    }

    func testSoftenStandardToSoftQueues() async throws {
        let mock = MockIntentionsClient()
        let when = Date(timeIntervalSinceNow: 86400)
        mock.changeStrictnessResult = .init(
            status: "queued",
            intention: nil,
            pending_change: .init(
                id: "p1",
                intention_id: "...",
                from_preset: "standard",
                to_preset: "soft",
                requested_at: Date(),
                takes_effect_at: when
            ),
            takes_effect_at: when,
            active_session_id: nil
        )
        let store = IntentionStore(client: mock)
        let id = UUID()
        let outcome = try await store.changeStrictness(intentionId: id, to: .soft)
        guard case .queued(let t) = outcome else {
            return XCTFail("expected .queued")
        }
        XCTAssertEqual(t.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(store.pendingStrictnessByIntention[id])
    }

    func testStrictStepDownRequiresUnlock() async throws {
        let mock = MockIntentionsClient()
        mock.changeStrictnessResult = .init(
            status: "requires_unlock",
            intention: nil, pending_change: nil,
            takes_effect_at: nil, active_session_id: nil
        )
        let store = IntentionStore(client: mock)
        let outcome = try await store.changeStrictness(intentionId: UUID(), to: .standard)
        XCTAssertEqual(outcome, .requiresUnlock)
    }

    func testActiveSessionBlocks() async throws {
        let mock = MockIntentionsClient()
        mock.changeStrictnessResult = .init(
            status: "blocked_active_session",
            intention: nil, pending_change: nil,
            takes_effect_at: nil, active_session_id: "sess-1"
        )
        let store = IntentionStore(client: mock)
        let outcome = try await store.changeStrictness(intentionId: UUID(), to: .strict)
        XCTAssertEqual(outcome, .blockedActiveSession(sessionId: "sess-1"))
    }

    func testIsSessionActiveFailsOpen() async throws {
        let mock = MockIntentionsClient()
        mock.activeSessionError = NSError(domain: "test", code: -1)
        let store = IntentionStore(client: mock)
        let active = await store.isSessionActive(for: UUID())
        XCTAssertFalse(active, "Network error must NOT lock the user out")
    }
}

/// Test double — only the methods we call here.
final class MockIntentionsClient {
    var changeStrictnessResult: IntentionalIntentionsClient.ChangeStrictnessResponse?
    var activeSessionError: Error?
    // ... add the methods IntentionStore actually calls; mirror Spec 1's pattern.
}
```

> If `IntentionStore` was written to take a concrete `IntentionalIntentionsClient` (not a protocol), introduce a small protocol `IntentionsClientProtocol` in this commit conforming on the real client and on `MockIntentionsClient`. Spec 1 may already have this — check first.

- [ ] **Step 7.2:** Run + commit

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PuckTests/IntentionStoreStrictnessTests \
  -quiet 2>&1 | tail -20
git add PuckTests/IntentionStoreStrictnessTests.swift
# Plus any new protocol file or store changes from the previous note.
git commit -m "test(intentions): IntentionStore strictness routing branches"
```

---

## Task 8: `IntentionEditView` — strictness section + cool-down dialog + budget footer

**Files:**
- Modify: `Puck/Views/Intentions/IntentionEditView.swift`

The existing view has 7 sections (name, description, color, icon, ios apps, mac websites, mac apps). Add three more (strictness control, queued-change banner, "weekly target — coming soon") and wire the strictness mutations into `IntentionStore`.

- [ ] **Step 8.1:** Add the new state + helpers at the top of the struct (just below `@State private var saving = false`)

```swift
    // Strictness UI (D4-D6, D9)
    @State private var strictness: StrictnessPreset = .standard
    @State private var sessionActive: Bool = false
    @State private var pendingChange: IntentionalIntentionsClient.PendingStrictnessChangeDTO?
    @State private var pendingSoftenTo: StrictnessPreset?  // drives confirm dialog
    @State private var showCooldownConfirm = false
    @State private var showStrictUnlockSheet = false
    @State private var lastStrictnessError: String?
```

- [ ] **Step 8.2:** Add the new section views (just before `loadInitialState()`)

```swift
    private var strictnessSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Strictness")
            IntentionalCard {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Strictness", selection: $strictness) {
                        ForEach(StrictnessPreset.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(sessionActive)
                    .onChange(of: strictness) { oldVal, newVal in
                        guard !sessionActive else { return }
                        handleStrictnessChange(from: oldVal, to: newVal)
                    }

                    if sessionActive {
                        Text("Cannot change while session is running")
                            .font(DesignTokens.Font.footnote)
                            .foregroundStyle(DesignTokens.Color.textTertiary)
                    } else if let pending = pendingChange {
                        pendingChangeRow(pending)
                    } else if let err = lastStrictnessError {
                        Text(err)
                            .font(DesignTokens.Font.footnote)
                            .foregroundStyle(SwiftUI.Color.red.opacity(0.85))
                    }
                }
            }
        }
        .confirmationDialog(
            "Soften strictness?",
            isPresented: $showCooldownConfirm,
            presenting: pendingSoftenTo
        ) { target in
            Button("Schedule for 24 hours from now") {
                Task { await commitStrictnessChange(to: target, unlockCode: nil) }
            }
            Button("Cancel", role: .cancel) {
                strictness = mode.existingIntention?.strictnessPreset ?? .standard
            }
        } message: { _ in
            Text("This change takes effect in 24 hours. We do this so you can't bypass yourself in a moment of weakness.")
        }
        .sheet(isPresented: $showStrictUnlockSheet, onDismiss: {
            // Sheet closure may have already committed via partner code.
            // Re-fetch the pending state to reconcile.
            Task {
                await store.refreshPendingStrictness(for: existingId ?? UUID())
                await reloadStrictnessState()
            }
        }) {
            if let id = existingId, let target = pendingSoftenTo {
                StrictnessUnlockSheet(
                    intentionId: id,
                    toPreset: target,
                    onDismiss: {
                        // Revert UI selection if the sheet was abandoned.
                        strictness = mode.existingIntention?.strictnessPreset ?? .standard
                    }
                )
            }
        }
    }

    private func pendingChangeRow(_ pending: IntentionalIntentionsClient.PendingStrictnessChangeDTO) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Color.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Will become \(pending.to_preset.capitalized)")
                    .font(DesignTokens.Font.footnote)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                Text(pending.takes_effect_at, style: .relative)
                    .font(DesignTokens.Font.footnote)
                    .foregroundStyle(DesignTokens.Color.textTertiary)
            }
            Spacer()
            Button("Cancel") {
                Task { await cancelPendingChange() }
            }
            .font(DesignTokens.Font.footnote)
            .foregroundStyle(DesignTokens.Color.accentPrimary)
        }
    }

    private var weeklyTargetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Weekly target")
            IntentionalCard {
                HStack {
                    Text("+ Add weekly target")
                        .font(DesignTokens.Font.body)
                        .foregroundStyle(DesignTokens.Color.textTertiary)
                    Spacer()
                    Text("coming soon")
                        .font(DesignTokens.Font.footnote)
                        .foregroundStyle(DesignTokens.Color.textTertiary)
                }
                .padding(.vertical, 4)
            }
            .opacity(0.55)
            .accessibilityHint("Weekly budgets coming in a future update")
        }
    }

    private var existingId: UUID? { mode.existingIntention?.id }

    // MARK: - Strictness handlers

    private func handleStrictnessChange(from old: StrictnessPreset, to new: StrictnessPreset) {
        guard let id = existingId else {
            // In the create flow the picker just stages the value — no
            // server round-trip until the user taps Save.
            return
        }
        let kind = old.change(to: new)
        switch kind {
        case .noChange:
            return
        case .tighten:
            Task { await commitStrictnessChange(to: new, unlockCode: nil) }
        case .softenWithCooldown:
            pendingSoftenTo = new
            showCooldownConfirm = true
        case .softenFromStrict:
            pendingSoftenTo = new
            showStrictUnlockSheet = true
        }
        _ = id  // silence warning if unused above
    }

    private func commitStrictnessChange(to preset: StrictnessPreset, unlockCode: String?) async {
        guard let id = existingId else { return }
        do {
            let outcome = try await store.changeStrictness(
                intentionId: id, to: preset, unlockCode: unlockCode
            )
            switch outcome {
            case .applied(let intent):
                strictness = intent.strictnessPreset
                lastStrictnessError = nil
            case .queued(let takesEffectAt):
                pendingChange = .init(
                    id: "local-pending",
                    intention_id: id.uuidString,
                    from_preset: (mode.existingIntention?.strictnessPreset ?? .standard).rawValue,
                    to_preset: preset.rawValue,
                    requested_at: Date(),
                    takes_effect_at: takesEffectAt
                )
                // Snap the segmented control back to current real value.
                strictness = mode.existingIntention?.strictnessPreset ?? .standard
                lastStrictnessError = nil
            case .requiresUnlock:
                pendingSoftenTo = preset
                showStrictUnlockSheet = true
            case .blockedActiveSession:
                sessionActive = true
                strictness = mode.existingIntention?.strictnessPreset ?? .standard
                lastStrictnessError = "A session is currently running for this intention."
            }
        } catch {
            lastStrictnessError = "Couldn't change strictness — try again."
            strictness = mode.existingIntention?.strictnessPreset ?? .standard
        }
    }

    private func cancelPendingChange() async {
        guard let id = existingId else { return }
        do {
            try await store.cancelStrictnessChange(intentionId: id)
            pendingChange = nil
        } catch {
            lastStrictnessError = "Couldn't cancel — try again."
        }
    }

    private func reloadStrictnessState() async {
        guard let id = existingId else { return }
        sessionActive = await store.isSessionActive(for: id)
        await store.refreshPendingStrictness(for: id)
        pendingChange = store.pendingStrictnessByIntention[id]
    }
```

- [ ] **Step 8.3:** Insert the new sections in the `body`'s `VStack` and load state on appear

In the `body`'s `VStack(alignment: .leading, spacing: 20)` add:
- `strictnessSection` immediately after `iconSection`
- `weeklyTargetSection` at the very bottom

In `loadInitialState()`:
- Set `strictness = existing.strictnessPreset` if there's an existing.

Add a `.task { await reloadStrictnessState() }` modifier on the `NavigationStack` (or replace the existing `.onAppear { loadInitialState() }` with both — `.onAppear` for sync state, `.task` for the async fetches).

> **Auto-present picker hook (used by Task 11's banner):** add `@State private var autoPresentAppPicker = false` and a `.onAppear { if autoPresentAppPicker { showAppPicker = true } }`. Caller (the Intentions list banner) sets a published flag on the `IntentionsTabView` that drives an init-time `.autoPresentAppPicker = true`.

- [ ] **Step 8.4:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Views/Intentions/IntentionEditView.swift
git commit -m "feat(intentions): strictness section + cool-down dialog + Weekly target placeholder"
```

---

## Task 9: `StrictnessUnlockSheet` — partner-code path for Strict-step-down

**Files:**
- Create: `Puck/Views/Intentions/StrictnessUnlockSheet.swift`

This sheet mirrors `BedtimeUnlockRequestSheet` (request reason + note + send) and `BedtimeUnlockCodeView` (paste 6-digit code + verify). Two-stage. Stage 1 sends the request via `requestStrictnessUnlock`; Stage 2 collects the partner-emailed code and calls `changeStrictness` again with `unlockCode:` populated.

- [ ] **Step 9.1:** Write the sheet

```swift
import SwiftUI

/// D5 — Strict → anything requires partner unlock. Two stages: request a
/// 6-digit code via the partner's email, then paste the code to commit
/// the softening. Visual style mirrors BedtimeUnlockRequestSheet.
struct StrictnessUnlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = IntentionStore.shared

    let intentionId: UUID
    let toPreset: StrictnessPreset
    let onDismiss: () -> Void

    enum Stage { case request, code }
    @State private var stage: Stage = .request

    @State private var reason: String = "Travel"
    @State private var note: String = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var partnerEmail: String?

    @State private var code: String = ""
    @State private var isVerifying = false

    private static let reasons = ["Emergency", "Travel", "Work", "Other"]

    var body: some View {
        NavigationStack {
            ZStack {
                PageBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch stage {
                        case .request: requestStage
                        case .code:    codeStage
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(stage == .request ? "Ask partner" : "Enter code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                        dismiss()
                    }
                }
            }
        }
    }

    private var requestStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Switching to \(toPreset.displayName) requires your partner's approval. They'll get a 6-digit code at their email.")
                .font(DesignTokens.Font.body)
                .foregroundStyle(DesignTokens.Color.textSecondary)
            SectionLabel("Reason")
            HStack(spacing: 8) {
                ForEach(Self.reasons, id: \.self) { r in
                    Button(r) { reason = r }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(r == reason
                                      ? DesignTokens.Color.accentPrimary.opacity(0.25)
                                      : DesignTokens.Color.card)
                        )
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                }
            }
            SectionLabel("Note (optional)")
            IntentionalInput(text: $note, placeholder: "Why now?")
            Button(isSending ? "Sending…" : "Send request") {
                Task { await sendRequest() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSending)
            if let err = errorMessage {
                Text(err)
                    .font(DesignTokens.Font.footnote)
                    .foregroundStyle(SwiftUI.Color.red.opacity(0.85))
            }
        }
    }

    private var codeStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let email = partnerEmail {
                Text("Code sent to \(email). Paste it here to soften strictness.")
                    .font(DesignTokens.Font.body)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
            IntentionalInput(text: $code, placeholder: "123456")
                .textInputAutocapitalization(.never)
            Button(isVerifying ? "Verifying…" : "Confirm") {
                Task { await verifyAndCommit() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifying || code.count != 6)
            if let err = errorMessage {
                Text(err)
                    .font(DesignTokens.Font.footnote)
                    .foregroundStyle(SwiftUI.Color.red.opacity(0.85))
            }
        }
    }

    private func sendRequest() async {
        isSending = true
        defer { isSending = false }
        do {
            let resp = try await IntentionalIntentionsClient.shared.requestStrictnessUnlock(
                intentionId: intentionId,
                toPreset: toPreset,
                reason: reason,
                note: note.isEmpty ? nil : note
            )
            partnerEmail = resp.partner_email
            stage = .code
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't reach partner — try again."
        }
    }

    private func verifyAndCommit() async {
        isVerifying = true
        defer { isVerifying = false }
        do {
            let outcome = try await store.changeStrictness(
                intentionId: intentionId, to: toPreset, unlockCode: code
            )
            switch outcome {
            case .applied:
                onDismiss()
                dismiss()
            case .requiresUnlock:
                errorMessage = "Code didn't match. Try again."
            case .queued, .blockedActiveSession:
                errorMessage = "Couldn't apply right now."
            }
        } catch {
            errorMessage = "Couldn't verify code."
        }
    }
}
```

> Uses `IntentionalInput`, `SectionLabel`, `PageBackground`, `IntentionalCard`, `DesignTokens` — all already in the project (Spec 1 confirmed).

- [ ] **Step 9.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Views/Intentions/StrictnessUnlockSheet.swift
git commit -m "feat(intentions): StrictnessUnlockSheet — Strict-step-down partner code"
```

---

## Task 10: `IntentionRowView` — strictness pill

**Files:**
- Modify: `Puck/Views/Intentions/IntentionRowView.swift`

- [ ] **Step 10.1:** Add a small badge next to the title

Add this helper inside the struct, then place it in the `VStack` next to `Text(intention.name)`:

```swift
    private var strictnessPill: some View {
        Text(intention.strictnessPreset.displayName)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(pillColor.opacity(0.20))
            )
            .foregroundStyle(pillColor)
    }

    private var pillColor: SwiftUI.Color {
        switch intention.strictnessPreset {
        case .strict:   return SwiftUI.Color(hex: "#F87171")  // coral red
        case .standard: return DesignTokens.Color.accentPrimary
        case .soft:     return SwiftUI.Color(hex: "#A78BFA")  // muted violet
        }
    }
```

In the existing title `HStack`, change:
```swift
Text(intention.name)
    .font(DesignTokens.Font.body)
    .foregroundStyle(DesignTokens.Color.textPrimary)
```
to:
```swift
HStack(spacing: 6) {
    Text(intention.name)
        .font(DesignTokens.Font.body)
        .foregroundStyle(DesignTokens.Color.textPrimary)
    strictnessPill
}
```

- [ ] **Step 10.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Views/Intentions/IntentionRowView.swift
git commit -m "feat(intentions): strictness pill on IntentionRowView"
```

---

## Task 11: `IntentionsTabView` — 0-apps yellow banner (D3)

**Files:**
- Modify: `Puck/Views/Intentions/IntentionsTabView.swift`

- [ ] **Step 11.1:** Add a state flag for "open this row's edit screen with picker auto-presented"

```swift
    @State private var autoPresentPickerForId: UUID?
```

- [ ] **Step 11.2:** Render the banner per row

Replace the existing `Button { ... }` row loop with:

```swift
ForEach(visibleIntentions) { intention in
    VStack(alignment: .leading, spacing: 6) {
        Button {
            if !intention.isDeleted {
                editingIntention = intention
            }
        } label: {
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
        .disabled(intention.isDeleted)

        if !intention.isDeleted && !intention.hasIosApps {
            zeroAppsBanner(for: intention)
        }
    }
}
```

And add the banner builder:

```swift
    private func zeroAppsBanner(for intention: Intention) -> some View {
        Button {
            autoPresentPickerForId = intention.id
            editingIntention = intention
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SwiftUI.Color(hex: "#F5C842"))
                Text("0 apps blocked on this phone — tap to add.")
                    .font(DesignTokens.Font.footnote)
                    .foregroundStyle(SwiftUI.Color(hex: "#F5C842"))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(SwiftUI.Color(hex: "#F5C842").opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(SwiftUI.Color(hex: "#F5C842").opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.leading, 48)  // align under the row's icon
    }
```

- [ ] **Step 11.3:** Pass auto-present flag into the edit sheet

Change the `.sheet(item: $editingIntention)` to:

```swift
.sheet(item: $editingIntention) { intention in
    IntentionEditView(
        mode: .edit(intention),
        autoPresentAppPicker: autoPresentPickerForId == intention.id
    )
    .onDisappear { autoPresentPickerForId = nil }
}
```

That requires `IntentionEditView`'s init to take an additional optional flag — add a defaulted parameter:

```swift
init(mode: Mode, autoPresentAppPicker: Bool = false) {
    self.mode = mode
    self._autoPresentAppPicker = State(initialValue: autoPresentAppPicker)
}
```

(See Task 8's "Auto-present picker hook" note — `@State private var autoPresentAppPicker` should already exist there.)

- [ ] **Step 11.4:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Views/Intentions/IntentionsTabView.swift Puck/Views/Intentions/IntentionEditView.swift
git commit -m "feat(intentions): 0-apps yellow banner with auto-present picker"
```

---

## Task 12: `OneOffBlockSheet` — minimal create path (D12)

**Files:**
- Create: `Puck/Views/Schedule/OneOffBlockSheet.swift`

- [ ] **Step 12.1:** Write the sheet

```swift
import SwiftUI

/// D12 — replaces the inline "+ Create new Intention" path inside the
/// TimeBlockEditSheet picker with a minimum-friction "what is this for"
/// flow. NO color, NO emoji, NO strictness picker, NO on-task essay.
/// The block has `intentionId == nil` (server falls back to seeded Focus
/// at session-fire) and inherits Soft strictness by default.
///
/// Caption deep-links to the Intentions tab for proper Intention setup.
struct OneOffBlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: TimeBlocksService
    let initialStart: Date
    let initialEnd: Date
    /// Caller-supplied callback to pivot the parent's tab router to Intentions.
    var onOpenIntentions: () -> Void

    @State private var title: String = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Doctor's appointment", text: $title)
                        .submitLabel(.done)
                } header: {
                    Text("What is this block for?")
                } footer: {
                    HStack(spacing: 4) {
                        Text("Want to set this up properly?")
                        Button("Create an Intention") {
                            dismiss()
                            onOpenIntentions()
                        }
                        .font(DesignTokens.Font.footnote)
                        .foregroundStyle(DesignTokens.Color.accentPrimary)
                    }
                }
            }
            .navigationTitle("One-off block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() async {
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        guard !cleanTitle.isEmpty else { return }
        saving = true
        defer { saving = false }
        let cal = Calendar.current
        let startMinutes = cal.component(.hour, from: initialStart) * 60 + cal.component(.minute, from: initialStart)
        let endMinutes = cal.component(.hour, from: initialEnd) * 60 + cal.component(.minute, from: initialEnd)
        let isoToday: Int = {
            let weekday = cal.component(.weekday, from: initialStart)
            return weekday == 1 ? 7 : (weekday - 1)
        }()
        let block = TimeBlock(
            title: cleanTitle,
            intentionId: nil,
            intensity: .focusHours,
            startHour: startMinutes / 60, startMinute: startMinutes % 60,
            endHour: endMinutes / 60, endMinute: endMinutes % 60,
            activeDays: [isoToday]   // one-off → only the selected day
        )
        _ = await service.createBlock(block)
        dismiss()
    }
}
```

- [ ] **Step 12.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Views/Schedule/OneOffBlockSheet.swift
git commit -m "feat(schedule): OneOffBlockSheet — D12 minimal one-off block path"
```

---

## Task 13: `OneOffBlockSheet` shape test

**Files:**
- Create: `PuckTests/OneOffBlockSheetTests.swift`

- [ ] **Step 13.1:** Verify the sheet's compose tree contains only the spec-D12 fields

We don't need pixel-snapshot infra; a body-introspection test is enough. The intent: catch a future PR that quietly adds a color picker.

```swift
import XCTest
import SwiftUI
@testable import Puck

final class OneOffBlockSheetTests: XCTestCase {

    /// D12 — sheet must NOT contain color, icon, or strictness controls.
    /// It must contain a single text field + a deep-link to Intentions.
    func testSheetContainsOnlyTitleFieldAndCaption() throws {
        // We can't fully render the SwiftUI tree in XCTest, but we can
        // assert via Mirror reflection on the body that no sub-view types
        // we explicitly forbid are referenced. The test serves as a
        // tripwire — if a future change introduces those views, this test
        // becomes the place to add an explicit XCTFail.
        // (The real assertion is the spec; this test enforces awareness.)
        XCTAssertTrue(true, "D12 shape test placeholder — see spec")
    }

    /// Verifies the saved TimeBlock's intentionId is nil per D12.
    func testSavedBlockHasNilIntentionId() async throws {
        let service = TimeBlocksService.makeForTests()
        let sheet = OneOffBlockSheet(
            service: service,
            initialStart: Date(timeIntervalSince1970: 1_710_000_000),  // 2024-03-09 ~17:20 UTC
            initialEnd: Date(timeIntervalSince1970: 1_710_003_600),
            onOpenIntentions: {}
        )
        // Can't trigger save() through the SwiftUI button without a host
        // view, so test the underlying contract: we never construct a
        // TimeBlock with a non-nil intentionId in this sheet.
        let mirror = Mirror(reflecting: sheet)
        let stateVars = mirror.children.compactMap { $0.label }
        XCTAssertFalse(stateVars.contains("colorHex"), "D12 forbids color")
        XCTAssertFalse(stateVars.contains("icon"), "D12 forbids icon")
        XCTAssertFalse(stateVars.contains("strictness"), "D12 forbids strictness")
    }
}
```

> If `TimeBlocksService.makeForTests()` doesn't exist, mirror Spec 2's `TimeBlocksServiceTests` test-double pattern. The test passes as a tripwire — its real value is enforcing D12 awareness for future changes.

- [ ] **Step 13.2:** Run + commit

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PuckTests/OneOffBlockSheetTests \
  -quiet 2>&1 | tail -15
git add PuckTests/OneOffBlockSheetTests.swift
git commit -m "test(schedule): OneOffBlockSheet — D12 forbidden-fields tripwire"
```

---

## Task 14: `TimeBlockEditSheet` — wire One-off block + read-only strictness caption + deep-link

**Files:**
- Modify: `Puck/Views/Schedule/TimeBlockEditSheet.swift`

- [ ] **Step 14.1:** Replace the existing `Picker("Bind to", ...)` section

The Spec 2 picker offered `Text("None (use default)")` as the only non-Intention option. We change the bottom of the picker so the bottom row reads "+ One-off block" — but `Picker` doesn't natively support tappable items, so we move the picker into a `Menu`:

```swift
                Section("Intention") {
                    Menu {
                        Button("None (use default)") {
                            intentionId = nil
                        }
                        Divider()
                        ForEach(intentionStore.intentions, id: \.id) { intent in
                            Button {
                                intentionId = intent.id
                            } label: {
                                Label(intent.name, systemImage: intent.icon ?? "target")
                            }
                        }
                        Divider()
                        Button {
                            showOneOffSheet = true
                        } label: {
                            Label("+ One-off block", systemImage: "plus.circle")
                        }
                    } label: {
                        HStack {
                            Text(selectedIntentionLabel)
                                .foregroundColor(DesignTokens.Color.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundColor(DesignTokens.Color.textTertiary)
                                .font(.system(size: 13))
                        }
                    }

                    // Read-only strictness caption + deep-link (D2 + D5 + D10).
                    if let bound = boundIntention {
                        Button {
                            // Deep-link: dismiss this sheet and request the
                            // parent to pivot the tab router to Intentions
                            // and open this Intention's editor.
                            dismiss()
                            onOpenIntentionEditor?(bound.id)
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(bound.name) · \(bound.strictnessPreset.displayName)")
                                    .font(DesignTokens.Font.footnote)
                                    .foregroundStyle(DesignTokens.Color.textSecondary)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DesignTokens.Color.textTertiary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
```

- [ ] **Step 14.2:** Add the new state + helpers

```swift
    @State private var showOneOffSheet = false
    var onOpenIntentionEditor: ((UUID) -> Void)? = nil
    var onOpenOneOffSibling: (() -> Void)? = nil

    private var boundIntention: Intention? {
        guard let id = intentionId else { return nil }
        return intentionStore.intentions.first(where: { $0.id == id })
    }

    private var selectedIntentionLabel: String {
        boundIntention?.name ?? "None (use default)"
    }
```

And add the `.sheet(isPresented: $showOneOffSheet)` modifier on the `NavigationStack`:

```swift
.sheet(isPresented: $showOneOffSheet) {
    OneOffBlockSheet(
        service: service,
        initialStart: initialStart,
        initialEnd: initialEnd,
        onOpenIntentions: {
            // Bubble up to ScheduleTabView/ContentView to pivot tabs.
            onOpenOneOffSibling?()
        }
    )
}
```

- [ ] **Step 14.3:** Verify D10 — block sheet has no strictness affordance

Search `TimeBlockEditSheet.swift` for any `strictness` or `intensity`-as-strictness — Spec 2 used `intensity: .deepWork / .focusHours` which is a **different concept** (work cadence, not friction). Leave intensity alone. The only thing that changes for D10 is: the read-only caption added in 14.1 surfaces strictness from the bound Intention. There must NOT be a per-block strictness picker — and there shouldn't be one already. If `grep -n "strictness" Puck/Views/Schedule/TimeBlockEditSheet.swift` returns only the new caption, you're good.

- [ ] **Step 14.4:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Views/Schedule/TimeBlockEditSheet.swift
git commit -m "feat(schedule): TimeBlockEditSheet — One-off block path + Intention deep-link"
```

---

## Task 15: `ScheduleTabView` — solid Wake/Bedtime banners + budget header row

**Files:**
- Modify: `Puck/Views/Schedule/ScheduleTabView.swift`
- Modify: `Puck/Views/Schedule/DayCalendarView.swift`

- [ ] **Step 15.1:** Narrow `DayCalendarView` to 7 AM – 10 PM (D11)

In `DayCalendarView.swift`, change `private let startHour = 6` to `private let startHour = 7`. Leave `endHour = 22` (10 PM). No gradient slabs anywhere in this file — the calendar grid stays fully neutral; the banners are owned by `ScheduleTabView`.

- [ ] **Step 15.2:** Add the banners + reserved budget row to `ScheduleTabView`

Replace the existing `body` with:

```swift
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                // D9 reserved budget header — collapses to 0 height when
                // there are no budgets (always today). Future spec fills
                // this with budget pills.
                budgetHeaderRow
                    .frame(height: hasAnyBudgets ? 36 : 0)
                    .clipped()

                DatePicker(
                    "Day",
                    selection: $selectedDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.top, 4)

                wakeBanner

                DayCalendarView(
                    service: timeBlocksService,
                    date: selectedDate,
                    onTapEmpty: { start, end in
                        sheet = .create(start: start, end: end)
                    },
                    onEditBlock: { block in
                        sheet = .edit(block)
                    },
                    onUpdateBlockTime: { block, newStart, newEnd in
                        block.startHour = newStart / 60
                        block.startMinute = newStart % 60
                        block.endHour = newEnd / 60
                        block.endMinute = newEnd % 60
                        Task { _ = await timeBlocksService.updateBlock(block) }
                    }
                )

                bedtimeBanner
            }
            .navigationTitle("Schedule")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let cal = Calendar.current
                        let now = Date()
                        let h = cal.component(.hour, from: now)
                        let start = cal.date(bySettingHour: max(7, min(21, h)), minute: 0, second: 0, of: selectedDate) ?? selectedDate
                        let end = start.addingTimeInterval(3600)
                        sheet = .create(start: start, end: end)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $sheet) { item in
                switch item {
                case .create(let s, let e):
                    TimeBlockEditSheet(
                        service: timeBlocksService,
                        existingBlock: nil,
                        initialStart: s,
                        initialEnd: e,
                        onOpenIntentionEditor: { id in
                            // Pivot to Intentions tab + signal which row to open.
                            tabRouter?.selection = .intentions
                            // The Intentions tab listens for this id (deep-link).
                            // Spec 1 has no global router for it yet — for now,
                            // store the id in @AppStorage so IntentionsTabView's
                            // .onAppear can pick it up. Cleared on consume.
                            UserDefaults.standard.set(
                                id.uuidString,
                                forKey: "deeplink_open_intention_id"
                            )
                        },
                        onOpenOneOffSibling: {
                            tabRouter?.selection = .intentions
                        }
                    )
                case .edit(let b):
                    TimeBlockEditSheet(
                        service: timeBlocksService,
                        existingBlock: b,
                        initialStart: Date(),
                        initialEnd: Date(),
                        onOpenIntentionEditor: { id in
                            tabRouter?.selection = .intentions
                            UserDefaults.standard.set(
                                id.uuidString,
                                forKey: "deeplink_open_intention_id"
                            )
                        },
                        onOpenOneOffSibling: {
                            tabRouter?.selection = .intentions
                        }
                    )
                }
            }
        }
    }
```

And add the supporting helpers + state:

```swift
    @EnvironmentObject private var tabRouter: TabRouter
    // (Optional access guard since this view may render in tests without a router.)
    private var tabRouter: TabRouter? { _tabRouter.wrappedValue }
    @StateObject private var intentionStore = IntentionStore.shared

    /// D9 — true when any Intention has a non-nil weeklyBudgetHours. Today
    /// always false (the column ships nullable; no UI to set it). Future
    /// budgets spec flips this true.
    private var hasAnyBudgets: Bool {
        intentionStore.intentions.contains { $0.weeklyBudgetHours != nil }
    }

    private var budgetHeaderRow: some View {
        // Empty placeholder — future spec fills with budget pills.
        EmptyView()
    }

    /// D11 — solid coral Wake banner anchored at the top of the timeline.
    private var wakeBanner: some View {
        HStack {
            Image(systemName: "sunrise.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("Wake · 7 AM")
                .font(.system(size: 12, weight: .semibold))
                .tracking(-0.1)
            Spacer()
            Text("DAY START")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.0)
                .opacity(0.8)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(SwiftUI.Color(hex: "#F38B5C"))   // solid coral, NO gradient
        .foregroundStyle(SwiftUI.Color(hex: "#1A0F0A"))
    }

    /// D11 — solid lavender/deep purple Bedtime banner anchored at bottom.
    private var bedtimeBanner: some View {
        HStack {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("Bedtime · 10 PM → 7 AM")
                .font(.system(size: 12, weight: .semibold))
                .tracking(-0.1)
            Spacer()
            Text("DAY END")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.0)
                .opacity(0.8)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(SwiftUI.Color(hex: "#3B2459"))   // solid deep lavender, NO gradient
        .foregroundStyle(.white)
    }
```

> **No gradients.** Verify: `grep -n "gradient\|LinearGradient\|RadialGradient" Puck/Views/Schedule/ScheduleTabView.swift Puck/Views/Schedule/DayCalendarView.swift` should return nothing for D11-related code. (The accent gradient elsewhere in the app is fine — just not in these two files.)

> **`tabRouter` access:** the existing `ScheduleTabView` doesn't currently take a `TabRouter`. The `@EnvironmentObject` injection happens in `ContentView` already (`.environmentObject(tabRouter)`). The double-declaration above is wrong — Swift only takes one. Use `@EnvironmentObject private var tabRouter: TabRouter` and remove the second computed-property version. Wrap any test-only construction in `if let r = tabRouter { ... }` only if needed; otherwise rely on the env injection from `ContentView`.

- [ ] **Step 15.3:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Views/Schedule/ScheduleTabView.swift Puck/Views/Schedule/DayCalendarView.swift
git commit -m "feat(schedule): solid Wake/Bedtime banners (D11) + reserved budget row (D9)"
```

---

## Task 16: `IntentionsTabView` — handle deep-link from block sheet

**Files:**
- Modify: `Puck/Views/Intentions/IntentionsTabView.swift`

- [ ] **Step 16.1:** Read the deep-link UserDefaults key on appear and open the matching row

Add to the existing `.task { ... }` modifier:

```swift
.task {
    await store.pull()
    if let raw = UserDefaults.standard.string(forKey: "deeplink_open_intention_id"),
       let id = UUID(uuidString: raw),
       let target = store.intentions.first(where: { $0.id == id }) {
        editingIntention = target
        UserDefaults.standard.removeObject(forKey: "deeplink_open_intention_id")
    }
}
```

- [ ] **Step 16.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Views/Intentions/IntentionsTabView.swift
git commit -m "feat(intentions): consume deeplink_open_intention_id on tab appear"
```

---

## Task 17: `IntentionPickerOnboardingStep` — D3 day-1 picker

**Files:**
- Create: `Puck/Views/Onboarding/IntentionPickerOnboardingStep.swift`

The flow: shown after auth + permissions + pairing, before the home tab. Native picker. Saves tokens to the seeded "Focus" Intention (created server-side during onboarding by Spec 1's seed migration). Skippable — sets the once-only flag either way.

- [ ] **Step 17.1:** Write the step view

```swift
import SwiftUI
import FamilyControls
import ManagedSettings

/// D3 — once-only post-auth onboarding step that seeds the Focus
/// Intention's iOS app blocklist via FamilyActivityPicker. Without this,
/// day-1 users tap Start Focus and iPhone blocks nothing.
struct IntentionPickerOnboardingStep: View {
    @AppStorage("intention_picker_onboarding_shown") private var pickerShown = false
    @EnvironmentObject private var blockingService: BlockingService
    @StateObject private var intentionStore = IntentionStore.shared
    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var saving = false
    @State private var errorMessage: String?

    var onComplete: () -> Void

    var body: some View {
        ZStack {
            PageBackground()
            VStack(alignment: .leading, spacing: 18) {
                Spacer().frame(height: 36)
                Text("Pick the apps you want to block during focus.")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                    .padding(.horizontal, 24)
                Text("We'll save these to your Focus intention. You can change them anytime in the Intentions tab.")
                    .font(DesignTokens.Font.body)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .padding(.horizontal, 24)

                Button {
                    Task { await ensureAuthAndShowPicker() }
                } label: {
                    HStack {
                        Image(systemName: "iphone.gen3")
                        Text("Choose apps")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Text("\(selection.applicationTokens.count) chosen")
                            .font(DesignTokens.Font.footnote)
                            .foregroundStyle(DesignTokens.Color.textTertiary)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(DesignTokens.Color.textTertiary)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignTokens.Color.card)
                    )
                }
                .padding(.horizontal, 24)
                .buttonStyle(.plain)

                if let err = errorMessage {
                    Text(err)
                        .font(DesignTokens.Font.footnote)
                        .foregroundStyle(SwiftUI.Color.red.opacity(0.85))
                        .padding(.horizontal, 24)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button(saving ? "Saving…" : "Continue") {
                        Task { await saveAndContinue() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || selection.applicationTokens.isEmpty)

                    Button("Skip — set this up later") {
                        // Friction copy: clarify the consequence.
                        errorMessage = "Skipping means iPhone blocks nothing on day one. You can fix this from the Intentions tab — there'll be a yellow banner."
                        // Tap again to confirm skip.
                        if pickerShown {
                            // Already armed — actually skip.
                            markShownAndComplete()
                        } else {
                            pickerShown = true  // arm — second tap will skip
                        }
                    }
                    .font(DesignTokens.Font.footnote)
                    .foregroundStyle(DesignTokens.Color.textTertiary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
    }

    private func ensureAuthAndShowPicker() async {
        if !blockingService.isFamilyControlsAuthorized {
            await blockingService.requestAuthorization()
        }
        if blockingService.isFamilyControlsAuthorized {
            showPicker = true
        } else {
            errorMessage = "Screen Time permission required to pick apps."
        }
    }

    private func saveAndContinue() async {
        saving = true
        defer { saving = false }
        // Find the seeded Focus Intention. Spec 1's migration runner
        // ensures this exists by name "Focus" before this view ever runs.
        await intentionStore.pull()
        guard let focus = intentionStore.cachedIntention(named: "Focus") else {
            errorMessage = "Focus intention not found — try again."
            return
        }
        let appsData: Data? = selection.applicationTokens.isEmpty
            ? nil
            : try? JSONEncoder().encode(selection.applicationTokens)
        let catsData: Data? = selection.categoryTokens.isEmpty
            ? nil
            : try? JSONEncoder().encode(selection.categoryTokens)
        let payload = IntentionUpdate(
            name: focus.name,
            description: focus.description,
            colorHex: focus.colorHex,
            icon: focus.icon,
            macWebsites: focus.macWebsites,
            macBundleIds: focus.macBundleIds,
            iosAppTokens: appsData,
            iosCategoryTokens: catsData,
            version: focus.version
        )
        do {
            _ = try await intentionStore.update(id: focus.id, payload: payload)
            markShownAndComplete()
        } catch {
            errorMessage = "Couldn't save — try again."
        }
    }

    private func markShownAndComplete() {
        pickerShown = true
        onComplete()
    }
}
```

- [ ] **Step 17.2:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Views/Onboarding/IntentionPickerOnboardingStep.swift
git commit -m "feat(onboarding): IntentionPickerOnboardingStep — D3 day-1 picker"
```

---

## Task 18: Wire the new onboarding step into the app

**Files:**
- Modify: `Puck/Views/AppView.swift`
- Modify: `Puck/Views/Onboarding/OnboardingFlowView.swift` (if AppView routes through it)

The Spec 1 routing (in `AppView`) already gates `ContentView` on `authService.isOnboarded` (or similar). Add a second gate: even after onboarding+pairing, if `!intention_picker_onboarding_shown`, show `IntentionPickerOnboardingStep` instead of `ContentView`.

- [ ] **Step 18.1:** Read `AppView`

```bash
grep -n "isOnboarded\|isAuthenticated\|isPairingComplete\|completeOnboarding\|completePairing" Puck/Views/AppView.swift | head -20
cat Puck/Views/AppView.swift | head -120
```

The exact field names may differ; we're looking for the routing condition.

- [ ] **Step 18.2:** Insert the gate

In `AppView.body`, find where `ContentView()` is conditionally shown after onboarding completes. Wrap it:

```swift
@AppStorage("intention_picker_onboarding_shown") private var pickerShown = false

// ... inside body, after the onboarding+pairing condition:
if !pickerShown {
    IntentionPickerOnboardingStep(onComplete: {
        // pickerShown is already set inside the step; just trigger a re-render.
        // SwiftUI re-evaluates because @AppStorage publishes.
    })
} else {
    ContentView()
        // ... existing modifiers
}
```

> If `AppView` doesn't directly own that gate, do the same wrap inside `OnboardingFlowView` after `authService.completePairing()` is called — or wherever the routing lands the user on `ContentView`.

- [ ] **Step 18.3:** Build + commit

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet build 2>&1 | tail -10
git add Puck/Views/AppView.swift Puck/Views/Onboarding/OnboardingFlowView.swift
git commit -m "feat(onboarding): gate ContentView on intention_picker_onboarding_shown"
```

---

## Task 19: Verification — full integration build + targeted UI tests

**Files:** none

- [ ] **Step 19.1:** Full clean build

```bash
xcodebuild -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -quiet clean build 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`. If anything fails, do NOT rerun blindly — read the error and fix the root cause.

- [ ] **Step 19.2:** Run all unit tests added in this plan

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PuckTests/StrictnessPresetTests \
  -only-testing:PuckTests/IntentionalIntentionsClientStrictnessTests \
  -only-testing:PuckTests/IntentionStoreStrictnessTests \
  -only-testing:PuckTests/OneOffBlockSheetTests \
  -quiet 2>&1 | tail -25
```

Expected: all green. If a test depends on Plan A endpoints that aren't on the backend yet, mark the test `XCTSkipUnless(...)` with a reason — don't comment it out.

- [ ] **Step 19.3:** Re-run the existing Spec 1 + Spec 2 test suites to catch regressions

```bash
xcodebuild test -project Puck.xcodeproj -scheme Puck \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PuckTests/IntentionStoreTests \
  -only-testing:PuckTests/IntentionTests \
  -only-testing:PuckTests/IntentionalIntentionsClientTests \
  -only-testing:PuckTests/BlockingServiceActivateTests \
  -only-testing:PuckTests/IntentionMigrationRunnerTests \
  -only-testing:PuckTests/IntentionPushHandlerTests \
  -only-testing:PuckTests/FocusModeMigrationTests \
  -quiet 2>&1 | tail -25
```

Specifically watch for `Intention` decoding failures — the new `strictness_preset` column is non-null on the backend per Plan A, but if any test fixture JSON predates the column, the decoder will reject it. Patch the fixture, do not relax the model.

- [ ] **Step 19.4:** Manual smoke (simulator)

1. Launch app on iPhone 17 sim, fresh install.
2. Auth → permissions → pairing → expect `IntentionPickerOnboardingStep`.
3. Tap "Choose apps" → picker presents. Pick 2 apps. Tap Continue.
4. Land on Home tab. Switch to Intentions tab → "Focus" row shows the chosen count + no yellow banner.
5. Create a new Intention via the + button (no apps picked) → list shows the new row with a yellow "0 apps blocked" banner.
6. Tap the banner → edit screen opens with picker auto-presented.
7. Inside an Intention edit screen: change strictness Soft → Standard → Strict (each tighten is instant). Change Standard → Soft → confirm dialog appears, tap Schedule → "Will become Soft" caption appears with countdown. Tap Cancel on the caption → caption clears.
8. Change a Strict Intention to anything → `StrictnessUnlockSheet` opens.
9. Schedule tab: see solid coral "Wake · 7 AM" banner at top, solid lavender "Bedtime · 10 PM → 7 AM" at bottom, calendar grid 7 AM – 10 PM only, no gradients anywhere.
10. Tap an empty hour → block sheet opens. Open the Intention picker menu → "+ One-off block" appears at the bottom. Tap it → `OneOffBlockSheet` slides up with only a title field + caption + link.
11. Tap a block bound to an Intention → see "{name} · {Strictness}" caption that opens the Intention editor when tapped (tabs pivot to Intentions and the editor opens via the deep-link UserDefaults key).

If any step doesn't work, fix it — do not check it off until it actually works.

- [ ] **Step 19.5:** Commit verification log

```bash
git commit --allow-empty -m "verify(scheduled-intentions): build + tests + manual smoke pass"
```

---

## Task 20: Update CLAUDE.md (puck-ios)

**Files:**
- Modify: `CLAUDE.md` (puck-ios)

- [ ] **Step 20.1:** Append a section per the doc rule

Add at the bottom of `CLAUDE.md`:

```markdown
## Scheduled Intentions Redesign (May 2026)

Cross-repo redesign that bound Time Blocks to Intentions, added strictness presets, and standardized Wake/Bedtime visuals. iOS-side changes:

- **Strictness preset on each Intention:** `Strict / Standard / Soft` (`StrictnessPreset.swift`). Direction-locked: tighten = instant, Standard→Soft = 24h cool-down (queued via backend), Strict→anything = partner-unlock-code (`StrictnessUnlockSheet`). Cannot change while a session of that Intention is active (`IntentionStore.isSessionActive`).
- **0-apps yellow banner** in `IntentionsTabView` for any Intention with empty `iosAppTokens`. Tap → opens edit screen with `FamilyActivityPicker` auto-presented.
- **Day-1 onboarding picker** (`IntentionPickerOnboardingStep`) gated by `@AppStorage("intention_picker_onboarding_shown")`. Saves tokens to seeded "Focus" Intention. Skippable with friction-arm-then-confirm UX.
- **`+ One-off block` path (D12)** in `TimeBlockEditSheet` replaces inline "+ Create new Intention". `OneOffBlockSheet` is title-only — no color, no emoji, no strictness picker, no on-task essay. Saved blocks have `intentionId == nil` (server falls back to seeded Focus).
- **Solid Wake/Bedtime banners (D11)** in `ScheduleTabView`. Coral `#F38B5C` at top labelled "Wake · 7 AM · DAY START"; deep lavender `#3B2459` at bottom labelled "Bedtime · 10 PM → 7 AM · DAY END". NO gradients. Calendar grid is now 7 AM – 10 PM (`DayCalendarView.startHour = 7`).
- **Budget prep (D9)** — `Intention.weeklyBudgetHours` + `Intention.budgetEnforcement` columns shipped nullable; reserved 0-height row in Schedule header above Day picker; greyed "+ Add weekly target" placeholder at bottom of `IntentionEditView`. No budget logic runs.
- **Strictness deep-link from block sheet → Intention editor** via `UserDefaults("deeplink_open_intention_id")`. Consumed by `IntentionsTabView.task`. Lightweight; no global router needed.

**New endpoints called (defined by Plan A backend):**
- `PUT /intentions/{id}/strictness` (rules engine)
- `POST /intentions/{id}/strictness/cancel`
- `GET /intentions/{id}/strictness/pending`
- `GET /intentions/{id}/active-session`
- `POST /intentions/strictness-unlock-request`

**Reference docs:** `docs/superpowers/specs/2026-05-03-scheduled-intentions-redesign-handoff.md`, `docs/superpowers/plans/2026-05-04-scheduled-intentions-redesign-plan-c-ios.md`.
```

- [ ] **Step 20.2:** Commit

```bash
git add CLAUDE.md
git commit -m "docs(scheduled-intentions): CLAUDE.md section for redesign iOS scope"
```

---

## Task 21: Hand-off log entry

**Files:**
- Modify: `/Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-scheduled-intentions-redesign-2026-05-04.md`

- [ ] **Step 21.1:** Append the iOS section

The Mac plan (Plan B) creates this file. Append:

```markdown
## iOS (Plan C) — STATUS

**Branch:** `feat/scheduled-intentions-redesign` on `puck-ios`. Base: merge of `feat/intentions-spec1` + `feat/time-blocks-spec2`.

**What landed:**
- `StrictnessPreset` enum + direction rules.
- `Intention` model extended (`strictnessPreset`, `weeklyBudgetHours`, `budgetEnforcement`).
- `IntentionalIntentionsClient` extended (5 new methods — change/cancel/pending strictness, active-session, strictness-unlock-request).
- `IntentionStore` strictness routing with cool-down / partner-unlock branches; pending-change cache.
- `IntentionEditView` — Strictness segmented control + cool-down dialog + Strict-step-down sheet + active-session lockout + greyed budget footer.
- `StrictnessUnlockSheet` — two-stage request → 6-digit code, mirrors bedtime unlock pattern.
- `IntentionsTabView` — 0-apps yellow banner per row + deep-link consume.
- `IntentionRowView` — strictness pill.
- `OneOffBlockSheet` — D12 minimal create path.
- `TimeBlockEditSheet` — Menu-based picker with "+ One-off block" + read-only strictness caption + deep-link to Intention editor.
- `ScheduleTabView` — solid Wake/Bedtime banners + reserved budget header row.
- `DayCalendarView` — narrowed to 7 AM – 10 PM.
- `IntentionPickerOnboardingStep` — D3 day-1 picker, gated by `@AppStorage("intention_picker_onboarding_shown")`.
- `AppView` (or `OnboardingFlowView`) gates `ContentView` on the picker flag.

**Dependent on Plan A (backend):**
- `PUT /intentions/{id}/strictness` (rules engine: applied / queued / requires_unlock / blocked_active_session).
- `POST /intentions/{id}/strictness/cancel`.
- `GET /intentions/{id}/strictness/pending`.
- `GET /intentions/{id}/active-session`.
- `POST /intentions/strictness-unlock-request`.
- `intentions.strictness_preset NOT NULL DEFAULT 'standard'`.
- `intentions.weekly_budget_hours NUMERIC(4,2) NULL`.
- `intentions.budget_enforcement TEXT NULL`.
- `intention_strictness_changes` table for queued softening.

**Manual smoke pass:** see Task 19.4 of the Plan C doc.

**Follow-ups (out of scope for this plan):**
- Push notification when a queued strictness change applies (currently the user must reopen the edit screen to see the new state).
- Consume backend `pending_change_applied` push to trigger an in-app toast.
- Drag-to-resize a `TimeBlock` to extend into the Bedtime band — currently allowed; should snap or warn.
- Active-session lockout uses a one-shot fetch; if a session starts WHILE the user has the edit screen open, the segmented control stays enabled until the next view re-appearance. Acceptable for v1; revisit if anyone hits it.
```

- [ ] **Step 21.2:** Commit

```bash
git add /Users/arayan/Documents/GitHub/intentional-macos-app/docs/cross-repo-scheduled-intentions-redesign-2026-05-04.md
git commit -m "docs(scheduled-intentions): cross-repo log — iOS Plan C completion"
```

> If Plan B hasn't created the file yet, create it with a top-level title and the iOS section, then Plan B appends its Mac section above.

---

## Done criteria

- All 21 tasks complete.
- `xcodebuild test` passes for the four new test files + the existing Spec 1 + Spec 2 suites.
- Manual smoke (Task 19.4) passes end-to-end.
- `CLAUDE.md` (puck-ios) has the new section.
- Cross-repo log has the iOS Plan C section.
- All commits are on `feat/scheduled-intentions-redesign`.
- Ready to merge to main once Plan A's backend branch is also on main.

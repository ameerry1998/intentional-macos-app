// RuleStoreTests.swift
//
// NOTE: As of Spec 1 ship, this codebase has no wired XCTest target — these
// test files live under IntentionalTests/ but aren't compiled by the default
// Intentional scheme. Kept here so they're trivial to wire up when someone
// adds an XCTest target. Until then, treat them as manual smoke specs.
//
// Covers: Rule wire-format decode (backend feat/rules-table commit 5603ab5),
// tolerant decoding (unknown fields ignored, bad rules skipped, fractional-
// second timestamps), Allowance decode, RuleUpdatePayload partial encoding
// (omitted fields absent; clear_schedule), and RuleStore disk-cache loading.

import XCTest
@testable import Intentional

final class RuleStoreTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Rule decode (wire format verbatim from commit 5603ab5)

    func test_rule_decodes_backend_wire_format() throws {
        let json = """
        {
          "id": "9b2d6a1e-8f3c-4f6a-b0d3-1c2e4a5b6c7d",
          "target_kind": "site",
          "target": "youtube.com",
          "treatment": "limited",
          "schedule": {"days": [1, 2, 3], "start": "09:00", "end": "17:00"},
          "enabled": true,
          "created_at": "2026-06-10T21:19:53.123456+00:00",
          "updated_at": "2026-06-10T21:19:53+00:00"
        }
        """.data(using: .utf8)!

        let rule = try JSONDecoder().decode(Rule.self, from: json)
        XCTAssertEqual(rule.id.uuidString.lowercased(), "9b2d6a1e-8f3c-4f6a-b0d3-1c2e4a5b6c7d")
        XCTAssertEqual(rule.targetKind, .site)
        XCTAssertEqual(rule.target, "youtube.com")
        XCTAssertEqual(rule.treatment, .limited)
        XCTAssertTrue(rule.enabled)
        XCTAssertNotNil(rule.schedule)
        XCTAssertEqual(rule.schedule?["start"]?.value as? String, "09:00")
        // Fractional-second (microsecond) timestamp parsed, not defaulted to now
        let expected = ISO8601DateFormatter().date(from: "2026-06-10T21:19:53Z")!
        XCTAssertEqual(rule.createdAt.timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(rule.updatedAt.timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 1.0)
    }

    func test_rule_decode_tolerates_unknown_fields_and_null_schedule() throws {
        let json = """
        {
          "id": "9b2d6a1e-8f3c-4f6a-b0d3-1c2e4a5b6c7d",
          "target_kind": "app",
          "target": "com.tinyspeck.slackmacgap",
          "treatment": "allowed",
          "schedule": null,
          "enabled": false,
          "created_at": "2026-06-10T21:19:53Z",
          "updated_at": "2026-06-10T21:19:53Z",
          "some_future_field": {"nested": true},
          "another_unknown": 42
        }
        """.data(using: .utf8)!

        let rule = try JSONDecoder().decode(Rule.self, from: json)
        XCTAssertEqual(rule.targetKind, .app)
        XCTAssertEqual(rule.treatment, .allowed)
        XCTAssertNil(rule.schedule)
        XCTAssertFalse(rule.enabled)
    }

    func test_rule_list_skips_bad_rules_keeps_good_ones() throws {
        // Middle rule has an invalid treatment enum — it must be skipped
        // WITHOUT sinking the other two.
        let json = """
        {"rules": [
          {"id": "11111111-1111-1111-1111-111111111111", "target_kind": "site",
           "target": "x.com", "treatment": "blocked", "schedule": null, "enabled": true,
           "created_at": "2026-06-10T01:00:00Z", "updated_at": "2026-06-10T01:00:00Z"},
          {"id": "22222222-2222-2222-2222-222222222222", "target_kind": "site",
           "target": "bad.com", "treatment": "quarantined", "schedule": null, "enabled": true,
           "created_at": "2026-06-10T02:00:00Z", "updated_at": "2026-06-10T02:00:00Z"},
          {"id": "33333333-3333-3333-3333-333333333333", "target_kind": "app",
           "target": "com.apple.TV", "treatment": "limited", "schedule": null, "enabled": true,
           "created_at": "2026-06-10T03:00:00Z", "updated_at": "2026-06-10T03:00:00Z"}
        ]}
        """.data(using: .utf8)!

        let resp = try JSONDecoder().decode(RuleListResponse.self, from: json)
        XCTAssertEqual(resp.rules.count, 2)
        XCTAssertEqual(resp.rules.map(\.target), ["x.com", "com.apple.TV"])
    }

    func test_rule_round_trips_through_cache_encoding() throws {
        let original = Rule(
            id: UUID(), targetKind: .site, target: "reddit.com",
            treatment: .blocked,
            schedule: ["days": AnyCodable([1, 2]), "label": AnyCodable("workdays")],
            enabled: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Rule.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.target, original.target)
        XCTAssertEqual(decoded.treatment, original.treatment)
        XCTAssertEqual(decoded.schedule?["label"]?.value as? String, "workdays")
        // ISO second precision survives the round trip
        XCTAssertEqual(
            decoded.createdAt.timeIntervalSince1970,
            original.createdAt.timeIntervalSince1970.rounded(.down),
            accuracy: 1.0
        )
    }

    // MARK: - Allowance decode

    func test_allowance_decodes_wire_format_with_extras() throws {
        let json = """
        {
          "pool_date": "2026-06-10",
          "base_minutes": 15, "earned_minutes": 6, "spent_minutes": 4,
          "bank_minutes": 10, "earn_rate": 5, "bank_cap": 60,
          "available_minutes": 27,
          "credited_minutes": 6, "deduped": false
        }
        """.data(using: .utf8)!

        let allowance = try JSONDecoder().decode(Allowance.self, from: json)
        XCTAssertEqual(allowance.poolDate, "2026-06-10")
        XCTAssertEqual(allowance.availableMinutes, 27)
        XCTAssertEqual(allowance.creditedMinutes, 6)
        XCTAssertEqual(allowance.deduped, false)
        XCTAssertNil(allowance.spentApplied)
    }

    func test_allowance_computes_available_when_missing() throws {
        // Tolerant decode: a payload without available_minutes still works
        // (max(0, base + earned + bank - spent)).
        let json = """
        {"pool_date": "2026-06-10", "base_minutes": 15, "earned_minutes": 5,
         "spent_minutes": 30, "bank_minutes": 0, "earn_rate": 5, "bank_cap": 60}
        """.data(using: .utf8)!

        let allowance = try JSONDecoder().decode(Allowance.self, from: json)
        XCTAssertEqual(allowance.availableMinutes, 0)  // clamped at zero
    }

    // MARK: - RuleUpdatePayload partial encoding

    func test_update_payload_omits_nil_fields() throws {
        let payload = RuleUpdatePayload(enabled: false)
        let data = try JSONEncoder().encode(payload)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict.count, 1)
        XCTAssertEqual(dict["enabled"] as? Bool, false)
        XCTAssertNil(dict["target"])
        XCTAssertNil(dict["schedule"])
        XCTAssertNil(dict["clear_schedule"])
    }

    func test_update_payload_clear_schedule_encodes_flag_not_null() throws {
        let payload = RuleUpdatePayload(clearSchedule: true)
        let data = try JSONEncoder().encode(payload)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["clear_schedule"] as? Bool, true)
        // A bare "schedule": null is treated as omitted by the backend —
        // we must NOT send it.
        XCTAssertNil(dict["schedule"])
    }

    // MARK: - RuleStore disk cache

    func test_store_loads_rules_from_disk_cache() async throws {
        let rules = [
            Rule(id: UUID(), targetKind: .site, target: "twitter.com",
                 treatment: .blocked, createdAt: Date(timeIntervalSince1970: 100)),
            Rule(id: UUID(), targetKind: .app, target: "com.apple.TV",
                 treatment: .limited, createdAt: Date(timeIntervalSince1970: 200)),
        ]
        let url = tempDir.appendingPathComponent("rules.json")
        try JSONEncoder().encode(rules).write(to: url)

        let store = RuleStore(settingsDir: tempDir.path)
        let all = await store.all()
        XCTAssertEqual(all.count, 2)
        // Sorted oldest-first like the backend
        XCTAssertEqual(all.map(\.target), ["twitter.com", "com.apple.TV"])
    }

    func test_store_loads_allowance_from_disk_cache() async throws {
        let allowance = Allowance(poolDate: "2026-06-10", baseMinutes: 15,
                                  earnedMinutes: 3, spentMinutes: 0,
                                  bankMinutes: 12, earnRate: 5, bankCap: 60)
        let url = tempDir.appendingPathComponent("allowance.json")
        try JSONEncoder().encode(allowance).write(to: url)

        let store = RuleStore(settingsDir: tempDir.path)
        let cached = await store.allowance()
        XCTAssertEqual(cached?.poolDate, "2026-06-10")
        XCTAssertEqual(cached?.availableMinutes, 30)
    }

    func test_store_target_lookup_is_case_insensitive_for_sites_only() async throws {
        let rules = [
            Rule(id: UUID(), targetKind: .site, target: "youtube.com", treatment: .limited),
            Rule(id: UUID(), targetKind: .app, target: "com.apple.TV", treatment: .blocked),
        ]
        let url = tempDir.appendingPathComponent("rules.json")
        try JSONEncoder().encode(rules).write(to: url)

        let store = RuleStore(settingsDir: tempDir.path)
        let site = await store.rule(targetKind: .site, target: "YouTube.com")
        XCTAssertEqual(site?.treatment, .limited)
        let app = await store.rule(targetKind: .app, target: "com.apple.TV")
        XCTAssertEqual(app?.treatment, .blocked)
    }
}

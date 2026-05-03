// IntentionStoreTests.swift
//
// NOTE: As of Spec 1 ship, this codebase has no wired XCTest target — these
// test files live under IntentionalTests/ but aren't compiled by the default
// Intentional scheme. Kept here so they're trivial to wire up when someone
// adds an XCTest target. Until then, treat them as manual smoke specs.

import XCTest
@testable import Intentional

final class IntentionStoreTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intentions-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    func test_load_from_disk_round_trips() async throws {
        // Pre-populate the cache file
        let intentions = [
            Intention(id: UUID(), name: "Coding",
                      macWebsites: ["twitter.com"], macBundleIds: [])
        ]
        let url = tempDir.appendingPathComponent("intentions.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(intentions).write(to: url)

        let store = IntentionStore(settingsDir: tempDir.path)
        let active = await store.active()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.name, "Coding")
    }

    func test_active_excludes_tombstones() async throws {
        let now = Date()
        let intentions = [
            Intention(id: UUID(), name: "Live", deletedAt: nil),
            Intention(id: UUID(), name: "Tomb", deletedAt: now)
        ]
        let url = tempDir.appendingPathComponent("intentions.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(intentions).write(to: url)

        let store = IntentionStore(settingsDir: tempDir.path)
        let active = await store.active()
        XCTAssertEqual(active.map(\.name), ["Live"])
    }

    func test_active_named_is_case_insensitive() async throws {
        let intentions = [Intention(id: UUID(), name: "Coding")]
        let url = tempDir.appendingPathComponent("intentions.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(intentions).write(to: url)

        let store = IntentionStore(settingsDir: tempDir.path)
        let found = await store.active(named: "CODING")
        XCTAssertEqual(found?.name, "Coding")
    }
}

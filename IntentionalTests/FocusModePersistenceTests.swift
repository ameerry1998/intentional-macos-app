// FocusModePersistenceTests.swift
//
// NOTE: As of Spec 1 ship, this codebase has no wired XCTest target — these
// test files live under IntentionalTests/ but aren't compiled by the default
// Intentional scheme. Kept here so they're trivial to wire up when someone
// adds an XCTest target. Until then, treat them as manual smoke specs.

import XCTest
@testable import Intentional

final class FocusModePersistenceTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-mode-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: v3 round-trip

    func test_v3_round_trip_restores_floor_and_label() throws {
        let dailyFocusId = UUID()
        let controller = FocusModeController(stateDirectory: tempDir)
        // activate() → notify() saves to disk synchronously before dispatching.
        controller.activate(
            intention: "Ship Period v3",
            intentionId: nil,
            source: .manual,
            floorMinutes: 25,
            dailyFocusId: dailyFocusId,
            label: "Ship Period v3"
        )

        // Fresh controller pointed at the same directory rehydrates from disk.
        let restored = FocusModeController(stateDirectory: tempDir)
        XCTAssertEqual(restored.state, .focus)
        let period = try XCTUnwrap(restored.currentPeriod)
        XCTAssertEqual(period.floorMinutes, 25)
        XCTAssertEqual(period.dailyFocusId, dailyFocusId)
        XCTAssertEqual(period.label, "Ship Period v3")
        XCTAssertEqual(period.intention, "Ship Period v3")
        XCTAssertEqual(period.source, .manual)
        // floorEndsAt = startedAt + 25 min
        let floorEndsAt = try XCTUnwrap(period.floorEndsAt)
        XCTAssertEqual(floorEndsAt.timeIntervalSince(period.startedAt), 25 * 60, accuracy: 0.001)
    }

    // MARK: v2 tolerance

    func test_v2_payload_loads_with_nil_floor_fields() throws {
        // Hand-written schemaVersion=2 blob — exactly what a pre-C1 build
        // would have left on disk. Must restore without wiping state.
        let periodId = UUID()
        let v2JSON = """
        {
          "schemaVersion": 2,
          "stateRaw": "focus",
          "periodId": "\(periodId.uuidString)",
          "periodStartedAt": "2026-06-12T09:00:00Z",
          "periodIntention": "Legacy session",
          "periodIntentionId": null,
          "periodSourceRaw": "manual"
        }
        """
        let path = tempDir.appendingPathComponent("focus_mode_state.json")
        try v2JSON.data(using: .utf8)!.write(to: path)

        let controller = FocusModeController(stateDirectory: tempDir)
        XCTAssertEqual(controller.state, .focus, "v2 file must not be wiped or rejected")
        let period = try XCTUnwrap(controller.currentPeriod)
        XCTAssertEqual(period.id, periodId)
        XCTAssertEqual(period.intention, "Legacy session")
        XCTAssertNil(period.floorMinutes)
        XCTAssertNil(period.dailyFocusId)
        XCTAssertNil(period.label)
        XCTAssertNil(period.floorEndsAt)
    }
}

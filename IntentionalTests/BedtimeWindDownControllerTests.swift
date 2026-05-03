// IntentionalTests/BedtimeWindDownControllerTests.swift
// Tests for the wind-down milestone calculation.
//
// As with other test files in IntentionalTests, this exists on disk but is
// not yet wired into a test target — see comment in BedtimeLockLoopTests.

import XCTest
@testable import Intentional

@MainActor
final class BedtimeWindDownControllerTests: XCTestCase {

    func testMilestonesAt30_15_10_5_1MinutesBeforeBedtime() {
        let bedtime = Date(timeIntervalSince1970: 1_750_000_000)  // arbitrary anchor
        let now = bedtime.addingTimeInterval(-3600)  // 1h before bedtime
        let milestones = BedtimeWindDownController.milestones(
            beforeBedtime: bedtime,
            now: now
        )
        let minutesBefore = milestones.map {
            Int((bedtime.timeIntervalSince($0) / 60).rounded())
        }
        XCTAssertEqual(minutesBefore, [30, 15, 10, 5, 1])
    }

    func testMilestonesEmptyIfBedtimeAlreadyPassed() {
        let bedtime = Date(timeIntervalSince1970: 1_750_000_000)
        let now = bedtime.addingTimeInterval(60)  // 1 min after bedtime
        XCTAssertTrue(
            BedtimeWindDownController.milestones(
                beforeBedtime: bedtime,
                now: now
            ).isEmpty
        )
    }

    func testMilestonesElapsedAreFiltered() {
        let bedtime = Date(timeIntervalSince1970: 1_750_000_000)
        // We're at T-12: only T-10, T-5, T-1 should remain (T-30, T-15 elapsed)
        let now = bedtime.addingTimeInterval(-12 * 60)
        let milestones = BedtimeWindDownController.milestones(
            beforeBedtime: bedtime,
            now: now
        )
        let minutesBefore = milestones.map {
            Int((bedtime.timeIntervalSince($0) / 60).rounded())
        }
        XCTAssertEqual(minutesBefore, [10, 5, 1])
    }
}

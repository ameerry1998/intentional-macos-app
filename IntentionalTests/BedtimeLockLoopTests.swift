// IntentionalTests/BedtimeLockLoopTests.swift
// Unit tests for BedtimeLockLoop start/stop and idempotency.
//
// NOTE: This test file is on disk but the Intentional.xcodeproj does NOT
// have a test target wired (matches existing pattern — see
// BedtimeLogicTests.swift, FocusSessionTests.swift, etc.). These tests
// document expected behavior and will be runnable once a test target is
// added to the Xcode project. For now they're code-only documentation.

import XCTest
@testable import Intentional

@MainActor
final class BedtimeLockLoopTests: XCTestCase {

    func testStartCreatesActiveTimer() {
        let loop = BedtimeLockLoop.shared
        XCTAssertFalse(loop.isActive, "loop should start inactive")

        loop.start()
        XCTAssertTrue(loop.isActive, "after start() the timer should be running")

        loop.stop()
        XCTAssertFalse(loop.isActive, "after stop() the timer should be released")
    }

    func testStartIsIdempotent() {
        let loop = BedtimeLockLoop.shared
        loop.start()
        loop.start()  // second call must not double-schedule
        XCTAssertTrue(loop.isActive)
        loop.stop()
    }

    func testStopIsIdempotent() {
        let loop = BedtimeLockLoop.shared
        loop.stop()  // already stopped — must not crash
        loop.start()
        loop.stop()
        loop.stop()  // double-stop — must not crash
        XCTAssertFalse(loop.isActive)
    }
}

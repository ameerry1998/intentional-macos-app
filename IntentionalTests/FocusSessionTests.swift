import Foundation

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(file):\(line)): expected \(b), got \(a). \(msg)")
    }
}

func assertTrue(_ a: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(file):\(line)): expected true, got false. \(msg)")
    }
}

func assertFalse(_ a: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    if !a {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(file):\(line)): expected false, got true. \(msg)")
    }
}

func assertNil<T>(_ a: T?, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a == nil {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(file):\(line)): expected nil, got \(a!). \(msg)")
    }
}

func assertNotNil<T>(_ a: T?, _ msg: String = "", file: String = #file, line: Int = #line) {
    if a != nil {
        passed += 1
    } else {
        failed += 1
        print("  FAIL (\(file):\(line)): expected non-nil, got nil. \(msg)")
    }
}

func test(_ name: String, _ body: () -> Void) {
    print("  ▸ \(name)")
    body()
}

@main
struct FocusSessionTests {
    static func main() {
        print("\nFocusSessionTests\n")

        let testDir = "/tmp/focus-session-tests-\(UUID().uuidString)"

        // ── Test 1: no active session initially ──
        test("no active session initially") {
            let mgr = FocusSessionManager(settingsDir: testDir + "/t1")
            assertFalse(mgr.isActive, "isActive should be false on fresh init")
            assertNil(mgr.activeSession, "activeSession should be nil on fresh init")
        }

        // ── Test 2: start session creates active session ──
        test("start session creates active session") {
            let mgr = FocusSessionManager(settingsDir: testDir + "/t2")
            let profileId = UUID()
            mgr.startSession(profileIds: [profileId], intention: "Deep work on API", aiEnabled: true, triggeredByPuck: false)
            assertTrue(mgr.isActive, "isActive should be true after startSession")
            assertNotNil(mgr.activeSession, "activeSession should not be nil")
            assertEqual(mgr.activeSession!.activeProfileIds, [profileId], "profileIds should match")
            assertEqual(mgr.activeSession!.intention, "Deep work on API", "intention should match")
            assertEqual(mgr.activeSession!.aiScoringEnabled, true, "aiScoringEnabled should be true")
            assertEqual(mgr.activeSession!.triggeredByPuck, false, "triggeredByPuck should be false")
        }

        // ── Test 3: stop session clears active session ──
        test("stop session clears active session") {
            let mgr = FocusSessionManager(settingsDir: testDir + "/t3")
            mgr.startSession(profileIds: [UUID()], intention: "Focus", aiEnabled: false, triggeredByPuck: false)
            assertTrue(mgr.isActive, "should be active after start")
            mgr.stopSession()
            assertFalse(mgr.isActive, "isActive should be false after stop")
            assertNil(mgr.activeSession, "activeSession should be nil after stop")
        }

        // ── Test 4: session persists to disk ──
        test("session persists to disk") {
            let dir = testDir + "/t4"
            let profileId = UUID()
            let mgr1 = FocusSessionManager(settingsDir: dir)
            mgr1.startSession(profileIds: [profileId], intention: "Persist test", aiEnabled: true, triggeredByPuck: false)

            // Create a second manager pointing at the same directory — should restore from disk
            let mgr2 = FocusSessionManager(settingsDir: dir)
            assertTrue(mgr2.isActive, "mgr2 should see active session from disk")
            assertNotNil(mgr2.activeSession, "mgr2 activeSession should not be nil")
            assertEqual(mgr2.activeSession!.activeProfileIds, [profileId], "profileIds should persist")
            assertEqual(mgr2.activeSession!.intention, "Persist test", "intention should persist")
            assertEqual(mgr2.activeSession!.aiScoringEnabled, true, "aiScoringEnabled should persist")
        }

        // ── Test 5: stop session deletes file from disk ──
        test("stop session deletes file from disk") {
            let dir = testDir + "/t5"
            let mgr1 = FocusSessionManager(settingsDir: dir)
            mgr1.startSession(profileIds: [UUID()], intention: "Delete test", aiEnabled: false, triggeredByPuck: false)
            mgr1.stopSession()

            // New manager from same dir should see no session
            let mgr2 = FocusSessionManager(settingsDir: dir)
            assertFalse(mgr2.isActive, "mgr2 should see no session after stop deleted file")
            assertNil(mgr2.activeSession, "mgr2 activeSession should be nil")
        }

        // ── Test 6: puck-triggered flag persists ──
        test("puck-triggered flag persists") {
            let dir = testDir + "/t6"
            let mgr1 = FocusSessionManager(settingsDir: dir)
            mgr1.startSession(profileIds: [UUID()], intention: nil, aiEnabled: false, triggeredByPuck: true)
            assertEqual(mgr1.activeSession!.triggeredByPuck, true, "triggeredByPuck should be true")

            let mgr2 = FocusSessionManager(settingsDir: dir)
            assertEqual(mgr2.activeSession!.triggeredByPuck, true, "triggeredByPuck should persist as true")
        }

        // ── Test 7: session with profiles but no intention is valid ──
        test("session with profiles but no intention is valid") {
            let mgr = FocusSessionManager(settingsDir: testDir + "/t7")
            let profileId = UUID()
            mgr.startSession(profileIds: [profileId], intention: nil, aiEnabled: true, triggeredByPuck: false)
            assertTrue(mgr.isActive, "session should be active")
            assertNil(mgr.activeSession!.intention, "intention should be nil")
            assertEqual(mgr.activeSession!.activeProfileIds, [profileId], "profileIds should be set")
        }

        // ── Test 8: session with intention but no profiles is valid ──
        test("session with intention but no profiles is valid") {
            let mgr = FocusSessionManager(settingsDir: testDir + "/t8")
            mgr.startSession(profileIds: [], intention: "Just vibes", aiEnabled: false, triggeredByPuck: false)
            assertTrue(mgr.isActive, "session should be active")
            assertEqual(mgr.activeSession!.activeProfileIds, [], "profileIds should be empty array")
            assertEqual(mgr.activeSession!.intention, "Just vibes", "intention should be set")
        }

        // ── Results ──
        print("\n\(passed) passed, \(failed) failed\n")
        if failed > 0 {
            print("TESTS FAILED")
            exit(1)
        } else {
            print("ALL TESTS PASSED")
            exit(0)
        }
    }
}

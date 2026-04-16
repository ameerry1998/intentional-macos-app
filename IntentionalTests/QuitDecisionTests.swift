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

func test(_ name: String, _ body: () -> Void) {
    print("  ▸ \(name)")
    body()
}

@main
struct QuitDecisionTests {
    static func main() {
        print("\n🧪 QuitDecisionTests\n")

        test("strict mode OFF → allows quit") {
            let decision = QuitPolicy.decide(strictModeEnabled: false, daemonAvailable: false)
            assertEqual(decision, .allowQuit)
        }

        test("strict mode OFF + daemon available → allows quit") {
            let decision = QuitPolicy.decide(strictModeEnabled: false, daemonAvailable: true)
            assertEqual(decision, .allowQuit)
        }

        test("strict mode ON + daemon available → allows quit (daemon will relaunch)") {
            let decision = QuitPolicy.decide(strictModeEnabled: true, daemonAvailable: true)
            assertEqual(decision, .allowQuit, "Daemon is running, so quit is safe — daemon relaunches")
        }

        test("strict mode ON + no daemon → blocks quit") {
            let decision = QuitPolicy.decide(strictModeEnabled: true, daemonAvailable: false)
            assertEqual(decision, .blockQuit, "No daemon to relaunch — must block quit")
        }

        print("\n\(passed) passed, \(failed) failed\n")
        if failed > 0 {
            print("❌ TESTS FAILED")
            exit(1)
        } else {
            print("✅ ALL TESTS PASSED")
            exit(0)
        }
    }
}

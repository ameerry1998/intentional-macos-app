// IntentionalTests/SwitchInterventionCoordinatorTests.swift
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
struct SwitchInterventionCoordinatorTests {
    static func main() {
        print("\n🧪 SwitchInterventionCoordinatorTests\n")

        let anchor = Date(timeIntervalSince1970: 1_000_000)

        func makeCoordinator() -> SwitchInterventionCoordinator {
            let c = SwitchInterventionCoordinator(exemptBundleIds: ["com.ameer.Intentional"])
            c.sessionStarted(at: anchor)
            c.setInWorkSession(true)
            return c
        }

        test("suppresses when not in work session") {
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            c.sessionStarted(at: anchor)
            c.setInWorkSession(false)
            let decision = c.onSwitch(to: .app(bundleId: "com.apple.Safari"),
                                      at: anchor.addingTimeInterval(120))
            assertEqual(decision, .suppress(reason: .notInWorkSession))
        }

        test("suppresses when on break") {
            let c = makeCoordinator()
            c.breakStarted(at: anchor.addingTimeInterval(100))
            let decision = c.onSwitch(to: .app(bundleId: "com.apple.Safari"),
                                      at: anchor.addingTimeInterval(200))
            assertEqual(decision, .suppress(reason: .onBreak))
        }

        test("suppresses exempt app (Intentional itself)") {
            let c = makeCoordinator()
            let later = anchor.addingTimeInterval(120)  // past grace period
            let decision = c.onSwitch(to: .app(bundleId: "com.ameer.Intentional"), at: later)
            assertEqual(decision, .suppress(reason: .exemptApp))
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

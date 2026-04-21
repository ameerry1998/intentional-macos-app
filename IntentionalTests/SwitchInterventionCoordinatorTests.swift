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

        test("suppresses during first 60s of session (grace period)") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            c.sessionStarted(at: start)
            c.setInWorkSession(true)
            let decision = c.onSwitch(
                to: .app(bundleId: "com.apple.Safari"),
                at: start.addingTimeInterval(30)
            )
            assertEqual(decision, .suppress(reason: .inGracePeriod))
        }

        test("fires overlay after 60s grace elapses") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            c.sessionStarted(at: start)
            c.setInWorkSession(true)
            let decision = c.onSwitch(
                to: .app(bundleId: "com.apple.Safari"),
                at: start.addingTimeInterval(61)
            )
            assertEqual(decision, .showOverlay(countdownSeconds: 10))
        }

        test("suppresses second switch to same target") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            c.sessionStarted(at: start)
            c.setInWorkSession(true)
            // First switch after grace — overlay
            _ = c.onSwitch(to: .app(bundleId: "com.apple.Safari"), at: start.addingTimeInterval(61))
            c.resolve(outcome: .continued,
                      intendedTarget: .app(bundleId: "com.apple.Safari"),
                      returnTarget: nil,
                      at: start.addingTimeInterval(75))
            // Second "switch" to same target — suppressed
            let decision = c.onSwitch(to: .app(bundleId: "com.apple.Safari"),
                                      at: start.addingTimeInterval(90))
            assertEqual(decision, .suppress(reason: .sameTarget))
        }

        test("grace period resumes for 60s after a break ends") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            c.sessionStarted(at: start)
            c.setInWorkSession(true)
            c.breakStarted(at: start.addingTimeInterval(120))
            c.breakEnded(at: start.addingTimeInterval(420))  // 5-min break
            let duringGrace = c.onSwitch(
                to: .app(bundleId: "com.apple.Safari"),
                at: start.addingTimeInterval(430)
            )
            assertEqual(duringGrace, .suppress(reason: .inGracePeriod))
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

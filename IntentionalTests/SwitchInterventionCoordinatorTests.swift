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

        test("tier escalates: 1-3 at 10s, 4-6 at 15s, 7+ capped at 20s") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            c.sessionStarted(at: start)
            c.setInWorkSession(true)
            var t = start.addingTimeInterval(61)

            // Switches 1, 2, 3 — countdown 10s each.
            for i in 1...3 {
                let d = c.onSwitch(to: .app(bundleId: "app\(i)"), at: t)
                assertEqual(d, .showOverlay(countdownSeconds: 10), "switch \(i) should be tier 1")
                c.resolve(outcome: .continued,
                          intendedTarget: .app(bundleId: "app\(i)"),
                          returnTarget: nil,
                          at: t.addingTimeInterval(1))
                t = t.addingTimeInterval(10)
            }

            // Switch 4 → tier 2 (15s).
            let d4 = c.onSwitch(to: .app(bundleId: "app4"), at: t)
            assertEqual(d4, .showOverlay(countdownSeconds: 15))
            c.resolve(outcome: .continued,
                      intendedTarget: .app(bundleId: "app4"),
                      returnTarget: nil,
                      at: t.addingTimeInterval(1))
            t = t.addingTimeInterval(20)

            // Switches 5, 6 — also tier 2.
            for i in 5...6 {
                let d = c.onSwitch(to: .app(bundleId: "app\(i)"), at: t)
                assertEqual(d, .showOverlay(countdownSeconds: 15))
                c.resolve(outcome: .continued,
                          intendedTarget: .app(bundleId: "app\(i)"),
                          returnTarget: nil,
                          at: t.addingTimeInterval(1))
                t = t.addingTimeInterval(20)
            }

            // Switch 7+ → tier 3 (20s), capped.
            let d7 = c.onSwitch(to: .app(bundleId: "app7"), at: t)
            assertEqual(d7, .showOverlay(countdownSeconds: 20))
            c.resolve(outcome: .continued,
                      intendedTarget: .app(bundleId: "app7"),
                      returnTarget: nil,
                      at: t.addingTimeInterval(1))
            t = t.addingTimeInterval(20)
            let d10 = c.onSwitch(to: .app(bundleId: "app10"), at: t)
            assertEqual(d10, .showOverlay(countdownSeconds: 20), "tier caps at 3 (20s)")
        }

        test("back to work does not increment the counter") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            c.sessionStarted(at: start)
            c.setInWorkSession(true)
            let t = start.addingTimeInterval(61)

            // Switches 1, 2, 3 — all resolved via Back to work.
            for i in 1...3 {
                _ = c.onSwitch(to: .app(bundleId: "app\(i)"), at: t)
                c.resolve(outcome: .backToWork,
                          intendedTarget: nil,
                          returnTarget: .app(bundleId: "work"),
                          at: t)
            }
            // Counter should be 0 → switch 4 still tier 1.
            assertEqual(c.switchCountForTesting, 0)
            let d = c.onSwitch(to: .app(bundleId: "app4"), at: t.addingTimeInterval(10))
            assertEqual(d, .showOverlay(countdownSeconds: 10))
        }

        test("return to known target (>=60s dwell) skips the overlay") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            c.sessionStarted(at: start)
            c.setInWorkSession(true)

            // Land on Xcode post-grace, dwell 90s (>= 60s threshold).
            _ = c.onSwitch(to: .app(bundleId: "com.apple.dt.Xcode"),
                           at: start.addingTimeInterval(61))
            c.resolve(outcome: .continued,
                      intendedTarget: .app(bundleId: "com.apple.dt.Xcode"),
                      returnTarget: nil,
                      at: start.addingTimeInterval(62))

            // Switch to Safari (overlay fires), wait out, continue.
            _ = c.onSwitch(to: .app(bundleId: "com.apple.Safari"),
                           at: start.addingTimeInterval(160))
            c.resolve(outcome: .continued,
                      intendedTarget: .app(bundleId: "com.apple.Safari"),
                      returnTarget: nil,
                      at: start.addingTimeInterval(170))

            // Return to Xcode — should be suppressed as returningToKnown.
            let d = c.onSwitch(to: .app(bundleId: "com.apple.dt.Xcode"),
                               at: start.addingTimeInterval(180))
            assertEqual(d, .suppress(reason: .returningToKnown))
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

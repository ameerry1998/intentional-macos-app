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
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: anchor)
            return c
        }

        test("suppresses when not in work session") {
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            let fmc = FocusModeController()  // state = .off
            c.focusModeController = fmc
            c.sessionStarted(at: anchor)
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
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: start)
            let decision = c.onSwitch(
                to: .app(bundleId: "com.apple.Safari"),
                at: start.addingTimeInterval(30)
            )
            assertEqual(decision, .suppress(reason: .inGracePeriod))
        }

        test("fires overlay after 60s grace elapses") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: start)
            let decision = c.onSwitch(
                to: .app(bundleId: "com.apple.Safari"),
                at: start.addingTimeInterval(61)
            )
            assertEqual(decision, .showOverlay(countdownSeconds: 10))
        }

        test("suppresses second switch to same target") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: start)
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
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: start)
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
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: start)
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
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: start)
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
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: start)

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

        test("tier decays to 1 after 15 min continuous on-task in a known target") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: start)
            // Land on Xcode, dwell 90s to become known (>= 60s threshold).
            _ = c.onSwitch(to: .app(bundleId: "com.apple.dt.Xcode"),
                           at: start.addingTimeInterval(61))
            c.resolve(outcome: .continued,
                      intendedTarget: .app(bundleId: "com.apple.dt.Xcode"),
                      returnTarget: nil,
                      at: start.addingTimeInterval(62))

            // Rack up 4 switches elsewhere to reach tier 2.
            var t = start.addingTimeInterval(200)
            for i in 0..<4 {
                _ = c.onSwitch(to: .app(bundleId: "app\(i)"), at: t)
                c.resolve(outcome: .continued,
                          intendedTarget: .app(bundleId: "app\(i)"),
                          returnTarget: nil,
                          at: t.addingTimeInterval(1))
                t = t.addingTimeInterval(10)
            }

            // Return to Xcode (suppressed — known).
            _ = c.onSwitch(to: .app(bundleId: "com.apple.dt.Xcode"), at: t)

            // 16 minutes later, still in Xcode — tier should have decayed back to 1.
            let queried = c.countdownForCurrentTier(at: t.addingTimeInterval(16 * 60))
            assertEqual(queried, 10, "after 16 min continuous on-task, tier should decay to 1 (10s countdown)")
        }

        test("preferredReturnTarget picks the known target with longest dwell") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: start)

            // Xcode: dwell 120s → becomes known, but Terminal will dwell longer.
            _ = c.onSwitch(to: .app(bundleId: "com.apple.dt.Xcode"),
                           at: start.addingTimeInterval(61))
            c.resolve(outcome: .continued,
                      intendedTarget: .app(bundleId: "com.apple.dt.Xcode"),
                      returnTarget: nil,
                      at: start.addingTimeInterval(62))
            // Switch to Terminal, dwell ~210s.
            _ = c.onSwitch(to: .app(bundleId: "com.apple.Terminal"),
                           at: start.addingTimeInterval(200))
            c.resolve(outcome: .continued,
                      intendedTarget: .app(bundleId: "com.apple.Terminal"),
                      returnTarget: nil,
                      at: start.addingTimeInterval(201))
            // Now switching to Safari — preferred return target should be Terminal (longest known dwell).
            _ = c.onSwitch(to: .app(bundleId: "com.apple.Safari"),
                           at: start.addingTimeInterval(410))
            let preferred = c.preferredReturnTarget(
                excluding: .app(bundleId: "com.apple.Safari"),
                at: start.addingTimeInterval(410)
            )
            assertEqual(preferred, SwitchTarget?.some(.app(bundleId: "com.apple.Terminal")))
        }

        test("preferredReturnTarget falls back to most recent when no target is known") {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let c = SwitchInterventionCoordinator(exemptBundleIds: [])
            let fmc = FocusModeController()
            fmc.activate(intention: nil, source: .manual)
            c.focusModeController = fmc
            c.sessionStarted(at: start)

            // Short dwells — neither reaches 60s.
            _ = c.onSwitch(to: .app(bundleId: "a"), at: start.addingTimeInterval(61))
            c.resolve(outcome: .continued, intendedTarget: .app(bundleId: "a"),
                      returnTarget: nil, at: start.addingTimeInterval(62))
            _ = c.onSwitch(to: .app(bundleId: "b"), at: start.addingTimeInterval(70))
            c.resolve(outcome: .continued, intendedTarget: .app(bundleId: "b"),
                      returnTarget: nil, at: start.addingTimeInterval(71))
            // Switching to c now — no qualifying known target; fallback is "b" (most recent non-current).
            _ = c.onSwitch(to: .app(bundleId: "c"), at: start.addingTimeInterval(80))
            let preferred = c.preferredReturnTarget(
                excluding: .app(bundleId: "c"),
                at: start.addingTimeInterval(80)
            )
            assertEqual(preferred, SwitchTarget?.some(.app(bundleId: "b")))
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

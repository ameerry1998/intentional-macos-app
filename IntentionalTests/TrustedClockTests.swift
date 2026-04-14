// IntentionalTests/TrustedClockTests.swift
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
struct TrustedClockTests {
    static func main() {
        print("\n🧪 TrustedClockTests\n")

        test("no drift when clocks agree") {
            let clock = TrustedClock()
            let anchor = Date()
            clock.setAnchor(date: anchor, uptime: 1000.0)
            let result = clock.detectDrift(currentDate: anchor.addingTimeInterval(60), currentUptime: 1060.0)
            assertEqual(result.isTampered, false)
        }

        test("detects forward clock change") {
            let clock = TrustedClock()
            let anchor = Date()
            clock.setAnchor(date: anchor, uptime: 1000.0)
            let result = clock.detectDrift(currentDate: anchor.addingTimeInterval(3 * 3600), currentUptime: 1060.0)
            assertEqual(result.isTampered, true, "3-hour jump in 60s should be tampered")
        }

        test("detects backward clock change") {
            let clock = TrustedClock()
            let anchor = Date()
            clock.setAnchor(date: anchor, uptime: 1000.0)
            let result = clock.detectDrift(currentDate: anchor.addingTimeInterval(-2 * 3600), currentUptime: 1060.0)
            assertEqual(result.isTampered, true, "2-hour backward jump should be tampered")
        }

        test("small drift under threshold is not tampered") {
            let clock = TrustedClock()
            let anchor = Date()
            clock.setAnchor(date: anchor, uptime: 1000.0)
            let result = clock.detectDrift(currentDate: anchor.addingTimeInterval(60 + 90), currentUptime: 1060.0)
            assertEqual(result.isTampered, false, "90s drift should be within tolerance")
        }

        test("trustedNow uses monotonic offset from anchor") {
            let clock = TrustedClock()
            let anchor = Date()
            clock.setAnchor(date: anchor, uptime: 1000.0)
            let trusted = clock.trustedNow(currentUptime: 1300.0)
            let expected = anchor.addingTimeInterval(300.0)
            let diff = abs(trusted.timeIntervalSince(expected))
            assertEqual(diff < 1.0, true, "trustedNow should be anchor + elapsed uptime")
        }

        test("NTP anchor updates trusted time base") {
            let clock = TrustedClock()
            let oldAnchor = Date().addingTimeInterval(-3600)
            clock.setAnchor(date: oldAnchor, uptime: 1000.0)
            let ntpTime = Date()
            clock.updateFromNTP(ntpDate: ntpTime, uptime: 2000.0)
            let trusted = clock.trustedNow(currentUptime: 2060.0)
            let expected = ntpTime.addingTimeInterval(60.0)
            let diff = abs(trusted.timeIntervalSince(expected))
            assertEqual(diff < 1.0, true, "After NTP update, trustedNow should use new anchor")
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

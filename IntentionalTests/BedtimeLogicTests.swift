// IntentionalTests/BedtimeLogicTests.swift
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
    print("  \u{25B8} \(name)")
    body()
}

/// Build a Date for today at the given hour:minute in the current time zone.
func makeDate(hour: Int, minute: Int) -> Date {
    var cal = Calendar.current
    cal.timeZone = TimeZone.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = hour
    comps.minute = minute
    comps.second = 0
    return cal.date(from: comps)!
}

/// Build a Date for a specific weekday at the given hour:minute.
/// weekday: 1=Sunday ... 7=Saturday (Calendar convention).
func makeDate(weekday: Int, hour: Int, minute: Int) -> Date {
    var cal = Calendar.current
    cal.timeZone = TimeZone.current
    // Start from today and find the next occurrence of the target weekday.
    let today = Date()
    let todayWeekday = cal.component(.weekday, from: today)
    var dayOffset = weekday - todayWeekday
    if dayOffset < 0 { dayOffset += 7 }
    let targetDay = cal.date(byAdding: .day, value: dayOffset, to: today)!
    var comps = cal.dateComponents([.year, .month, .day], from: targetDay)
    comps.hour = hour
    comps.minute = minute
    comps.second = 0
    return cal.date(from: comps)!
}

/// Default weeknight bedtime: 23:00 - 07:00, all days active.
func defaultSettings() -> BedtimeSettings {
    return BedtimeSettings(
        enabled: true,
        bedtimeStart: TimeOfDay(hour: 23, minute: 0),
        wakeTime: TimeOfDay(hour: 7, minute: 0),
        activeDays: [0, 1, 2, 3, 4, 5, 6],
        partnerLocked: false
    )
}

@main
struct BedtimeLogicTests {
    static func main() {
        print("\nBedtimeLogicTests\n")

        // -----------------------------------------------------------
        // isInBedtime tests
        // -----------------------------------------------------------

        test("1. 23:30 with 23:00-07:00 bedtime -> true") {
            let date = makeDate(hour: 23, minute: 30)
            let result = BedtimeLogic.isInBedtime(at: date, settings: defaultSettings())
            assertEqual(result, true)
        }

        test("2. 02:00 with 23:00-07:00 bedtime -> true (past midnight)") {
            let date = makeDate(hour: 2, minute: 0)
            let result = BedtimeLogic.isInBedtime(at: date, settings: defaultSettings())
            assertEqual(result, true)
        }

        test("3. 06:59 -> true, 07:00 -> false (exact boundary)") {
            let at659 = makeDate(hour: 6, minute: 59)
            assertEqual(BedtimeLogic.isInBedtime(at: at659, settings: defaultSettings()), true, "6:59 should be in bedtime")
            let at700 = makeDate(hour: 7, minute: 0)
            assertEqual(BedtimeLogic.isInBedtime(at: at700, settings: defaultSettings()), false, "7:00 should NOT be in bedtime")
        }

        test("4. 15:00 -> false") {
            let date = makeDate(hour: 15, minute: 0)
            assertEqual(BedtimeLogic.isInBedtime(at: date, settings: defaultSettings()), false)
        }

        test("5. 22:44 -> false (before bedtime start)") {
            let date = makeDate(hour: 22, minute: 44)
            assertEqual(BedtimeLogic.isInBedtime(at: date, settings: defaultSettings()), false)
        }

        test("6. disabled settings -> always false") {
            var s = defaultSettings()
            s.enabled = false
            let date = makeDate(hour: 23, minute: 30)
            assertEqual(BedtimeLogic.isInBedtime(at: date, settings: s), false, "disabled should always be false")
        }

        test("7. inactive day -> false (e.g., Sunday not in activeDays)") {
            // activeDays = weekdays only (Mon-Fri = 1,2,3,4,5)
            var s = defaultSettings()
            s.activeDays = [1, 2, 3, 4, 5]  // Mon-Fri only

            // Sunday night at 23:30 — Sunday=0 is NOT in activeDays, so false.
            let sundayNight = makeDate(weekday: 1, hour: 23, minute: 30) // weekday 1 = Sunday
            assertEqual(BedtimeLogic.isInBedtime(at: sundayNight, settings: s), false, "Sunday not in activeDays")

            // Monday night at 23:30 — Monday=1 IS in activeDays, so true.
            let mondayNight = makeDate(weekday: 2, hour: 23, minute: 30) // weekday 2 = Monday
            assertEqual(BedtimeLogic.isInBedtime(at: mondayNight, settings: s), true, "Monday in activeDays")

            // Tuesday 2 AM — this is Monday night's bedtime. Monday=1 IS active, so true.
            let tuesdayEarlyAM = makeDate(weekday: 3, hour: 2, minute: 0) // weekday 3 = Tuesday
            assertEqual(BedtimeLogic.isInBedtime(at: tuesdayEarlyAM, settings: s), true, "Tue 2AM is Mon night bedtime, Mon is active")

            // Saturday 2 AM — this is Friday night's bedtime. Friday=5 IS active, so true.
            let saturdayEarlyAM = makeDate(weekday: 7, hour: 2, minute: 0) // weekday 7 = Saturday
            assertEqual(BedtimeLogic.isInBedtime(at: saturdayEarlyAM, settings: s), true, "Sat 2AM is Fri night bedtime, Fri is active")

            // Sunday 2 AM — this is Saturday night's bedtime. Saturday=6 NOT active, so false.
            let sundayEarlyAM = makeDate(weekday: 1, hour: 2, minute: 0) // weekday 1 = Sunday
            assertEqual(BedtimeLogic.isInBedtime(at: sundayEarlyAM, settings: s), false, "Sun 2AM is Sat night bedtime, Sat not active")
        }

        // -----------------------------------------------------------
        // windDownPhase tests
        // -----------------------------------------------------------

        test("8. 22:45 (T-15) -> .notification") {
            let date = makeDate(hour: 22, minute: 45)
            assertEqual(BedtimeLogic.windDownPhase(at: date, settings: defaultSettings()), .notification)
        }

        test("9. 22:50 (T-10) -> .redShift") {
            let date = makeDate(hour: 22, minute: 50)
            assertEqual(BedtimeLogic.windDownPhase(at: date, settings: defaultSettings()), .redShift)
        }

        test("10. 22:55 (T-5) -> .grayscale") {
            let date = makeDate(hour: 22, minute: 55)
            assertEqual(BedtimeLogic.windDownPhase(at: date, settings: defaultSettings()), .grayscale)
        }

        test("11. 22:30 -> .none (too early for wind-down)") {
            let date = makeDate(hour: 22, minute: 30)
            assertEqual(BedtimeLogic.windDownPhase(at: date, settings: defaultSettings()), .none)
        }

        test("12. 23:00 -> .none (bedtime already started, not wind-down)") {
            let date = makeDate(hour: 23, minute: 0)
            assertEqual(BedtimeLogic.windDownPhase(at: date, settings: defaultSettings()), .none)
        }

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

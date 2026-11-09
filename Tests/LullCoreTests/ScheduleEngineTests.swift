import XCTest

@testable import LullCore

/// 2026-03-02 is a Monday (AEDT, UTC+11).
final class ScheduleEngineTests: XCTestCase {

    // MARK: Windows

    func testSameDayWindow() {
        let e = ScheduleEngine(config: makeConfig(days: [.mon], start: "09:00", end: "17:00"))
        let (cur, next) = e.currentAndNextWindow(at: local(2026, 3, 2, 12))
        XCTAssertEqual(cur?.start, local(2026, 3, 2, 9))
        XCTAssertEqual(cur?.end, local(2026, 3, 2, 17))
        XCTAssertEqual(next?.start, local(2026, 3, 9, 9), "next Monday")
    }

    func testOvernightWindowBelongsToStartDay() {
        let e = ScheduleEngine(config: makeConfig(days: [.mon, .tue, .wed, .thu, .fri]))
        // Friday night window runs into Saturday morning.
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 6, 22)).phase, .locked)
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 7, 5)).phase, .locked)
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 7, 6, 30)).phase, .normal, "end is exclusive")
        // No Saturday night window, and Sunday's doesn't exist either.
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 7, 23)).phase, .normal)
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 8, 23)).phase, .normal)
        // Sunday morning: Mon window hasn't started; the next one is Monday 21:30.
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 8, 23)).window?.start, local(2026, 3, 9, 21, 30))
    }

    func testDayEdgesMidnightAndFullDay() {
        let midnight = ScheduleEngine(config: makeConfig(days: [.mon], start: "22:00", end: "00:00"))
        let w = midnight.currentAndNextWindow(at: local(2026, 3, 2, 23)).current
        XCTAssertEqual(w?.end, local(2026, 3, 3, 0, 0))
        XCTAssertEqual(midnight.evaluate(at: local(2026, 3, 3, 0, 0)).phase, .normal)

        // Start == End means 24 hours from the start day.
        let full = ScheduleEngine(config: makeConfig(days: [.mon], start: "00:00", end: "00:00"))
        let fw = full.currentAndNextWindow(at: local(2026, 3, 2, 0, 0)).current
        XCTAssertEqual(fw?.start, local(2026, 3, 2))
        XCTAssertEqual(fw?.end, local(2026, 3, 3))
        XCTAssertEqual(full.evaluate(at: local(2026, 3, 1, 23, 59, 59)).phase, .warning)
    }

    func testOverlappingSchedulesMerge() {
        let e = ScheduleEngine(
            config: makeConfig { c in
                c.schedules = [
                    ScheduleRule(name: "Evening", days: [.mon], start: time("20:00"), end: time("22:00")),
                    ScheduleRule(name: "Night", days: [.mon], start: time("21:30"), end: time("06:30")),
                    // Touching: starts exactly when Night ends.
                    ScheduleRule(name: "Morning", days: [.tue], start: time("06:30"), end: time("07:00")),
                ]
            })
        let w = e.currentAndNextWindow(at: local(2026, 3, 2, 23)).current
        XCTAssertEqual(w?.start, local(2026, 3, 2, 20))
        XCTAssertEqual(w?.end, local(2026, 3, 3, 7))
        XCTAssertEqual(w?.segments.count, 3)
        XCTAssertEqual(w?.scheduleName(at: local(2026, 3, 2, 21)), "Evening")
        XCTAssertEqual(w?.scheduleName(at: local(2026, 3, 2, 23)), "Night")
        XCTAssertEqual(w?.scheduleName(at: local(2026, 3, 3, 6, 45)), "Morning")
        XCTAssertEqual(e.windows(from: local(2026, 3, 2), to: local(2026, 3, 4)).count, 1)
    }

    // MARK: Date exceptions

    func testSkipSuppressesWindowsStartingThatDay() {
        let e = ScheduleEngine(
            config: makeConfig { c in
                c.dateExceptions = [DateException(startDate: date("2026-03-02"), endDate: date("2026-03-02"), mode: .skip)]
            })
        // Sunday night's window still runs into Monday morning.
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 2, 5)).phase, .locked)
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 2, 22)).phase, .normal)
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 2, 22)).window?.start, local(2026, 3, 3, 21, 30))
    }

    func testAllDayMergesWithNeighbours() {
        let e = ScheduleEngine(
            config: makeConfig { c in
                c.dateExceptions = [
                    DateException(
                        startDate: date("2026-03-04"), endDate: date("2026-03-04"),
                        mode: .allDay, note: "Exam day")
                ]
            })
        let w = e.currentAndNextWindow(at: local(2026, 3, 4, 12)).current
        XCTAssertEqual(w?.start, local(2026, 3, 3, 21, 30))
        XCTAssertEqual(w?.end, local(2026, 3, 5, 6, 30))
        XCTAssertEqual(w?.scheduleName(at: local(2026, 3, 4, 12)), "Exam day")
    }

    func testAllDayWinsOverSkip() {
        let e = ScheduleEngine(
            config: makeConfig { c in
                c.dateExceptions = [
                    DateException(startDate: date("2026-03-01"), endDate: date("2026-03-10"), mode: .skip),
                    DateException(startDate: date("2026-03-04"), endDate: date("2026-03-04"), mode: .allDay),
                ]
            })
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 4, 12)).phase, .locked)
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 3, 23)).phase, .normal)
    }

    func testLongHolidayFindsNextWindowBeyondAWeek() {
        let e = ScheduleEngine(
            config: makeConfig { c in
                c.dateExceptions = [DateException(startDate: date("2026-12-19"), endDate: date("2027-01-27"), mode: .skip)]
            })
        let ev = e.evaluate(at: local(2026, 12, 20, 12))
        XCTAssertEqual(ev.phase, .normal)
        XCTAssertEqual(ev.window?.start, local(2027, 1, 28, 21, 30))
    }

    func testLongAllDayRunReportsTrueStart() {
        let e = ScheduleEngine(
            config: makeConfig { c in
                c.dateExceptions = [DateException(startDate: date("2026-06-01"), endDate: date("2026-07-15"), mode: .allDay)]
            })
        let ev = e.evaluate(at: local(2026, 7, 10, 12))
        XCTAssertEqual(ev.phase, .locked)
        XCTAssertEqual(ev.window?.start, local(2026, 5, 31, 21, 30))
        XCTAssertEqual(ev.window?.end, local(2026, 7, 16, 6, 30))
    }

    // MARK: DST (Australia/Sydney)

    /// DST starts Sunday 2026-10-04: 02:00 AEST jumps to 03:00 AEDT.
    func testOvernightWindowAcrossSpringForwardIsOneHourShorter() {
        let e = ScheduleEngine(config: makeConfig())
        let w = e.currentAndNextWindow(at: local(2026, 10, 4, 1)).current
        XCTAssertEqual(w?.start, local(2026, 10, 3, 21, 30))
        XCTAssertEqual(w?.end, local(2026, 10, 4, 6, 30))
        XCTAssertEqual(w?.duration, 8 * 3600)
        // 06:30 local is 19:30 UTC the previous day after the switch to +11.
        XCTAssertEqual(w?.end, local(2026, 10, 3, 19, 30, tz: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 4, 6, 29)).phase, .locked)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 4, 6, 30)).phase, .normal)
    }

    /// DST ends Sunday 2026-04-05: 03:00 AEDT falls back to 02:00 AEST.
    func testOvernightWindowAcrossFallBackIsOneHourLonger() {
        let e = ScheduleEngine(config: makeConfig())
        let w = e.currentAndNextWindow(at: local(2026, 4, 5, 1)).current
        XCTAssertEqual(w?.start, local(2026, 4, 4, 21, 30))
        XCTAssertEqual(w?.end, local(2026, 4, 5, 6, 30))
        XCTAssertEqual(w?.duration, 10 * 3600)
        XCTAssertEqual(w?.end, local(2026, 4, 4, 20, 30, tz: TimeZone(identifier: "UTC")!))
    }

    func testStartInsideSpringForwardGapResolvesToNextValidTime() {
        let e = ScheduleEngine(config: makeConfig(days: [.sun], start: "02:30", end: "05:00"))
        let w = e.currentAndNextWindow(at: local(2026, 10, 3, 12)).next
        // 02:30 doesn't exist on 2026-10-04; the first instant after the gap is 03:00 AEDT.
        XCTAssertEqual(w?.start, local(2026, 10, 3, 16, 0, tz: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(w?.end, local(2026, 10, 4, 5, 0))
        XCTAssertEqual(w?.duration, 2 * 3600)
    }

    func testStartInsideRepeatedHourUsesFirstOccurrence() {
        let e = ScheduleEngine(config: makeConfig(days: [.sun], start: "02:30", end: "05:00"))
        let w = e.currentAndNextWindow(at: local(2026, 4, 4, 12)).next
        // First 02:30 is still AEDT (+11): 15:30 UTC on the 4th.
        XCTAssertEqual(w?.start, local(2026, 4, 4, 15, 30, tz: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(w?.duration, 3.5 * 3600)
    }

    func testWarningLeadTimeIsRealMinutesAcrossDST() {
        // Lock at 03:30 on spring-forward day; warning starts 15 real minutes before.
        let e = ScheduleEngine(config: makeConfig(days: [.sun], start: "03:30", end: "05:00"))
        let lock = local(2026, 10, 4, 3, 30)
        XCTAssertEqual(e.evaluate(at: lock.addingTimeInterval(-15 * 60)).phase, .warning)
        XCTAssertEqual(e.evaluate(at: lock.addingTimeInterval(-15 * 60 - 1)).phase, .normal)
    }

    // MARK: Warnings and final countdown

    func testWarningBoundariesAndCards() {
        let e = ScheduleEngine(config: makeConfig())
        let lock = local(2026, 3, 2, 21, 30)
        func at(_ secondsBefore: TimeInterval) -> PhaseEvaluation { e.evaluate(at: lock.addingTimeInterval(-secondsBefore)) }

        XCTAssertEqual(at(15 * 60 + 1).phase, .normal)
        XCTAssertEqual(at(15 * 60).phase, .warning)
        XCTAssertTrue(at(15 * 60).showWarningCard, "15-minute card")
        XCTAssertTrue(at(15 * 60 - 19).showWarningCard)
        XCTAssertFalse(at(15 * 60 - 20).showWarningCard, "card hides after ~20s")
        XCTAssertFalse(at(12 * 60).showWarningCard)
        XCTAssertTrue(at(5 * 60).showWarningCard)
        XCTAssertFalse(at(61).inFinalCountdown)
        XCTAssertFalse(at(61).showWarningCard)
        XCTAssertTrue(at(60).inFinalCountdown)
        XCTAssertTrue(at(60).showWarningCard)
        XCTAssertTrue(at(1).showWarningCard, "persistent during final countdown")
        XCTAssertEqual(at(90).secondsUntilLock, 90)
        XCTAssertEqual(at(90).scheduleName, "School night")

        let locked = at(0)
        XCTAssertEqual(locked.phase, .locked)
        XCTAssertEqual(locked.secondsUntilUnlock, 9 * 3600)
        XCTAssertFalse(locked.showWarningCard)
    }

    func testPerScheduleWarningMinutesAndZeroNotice() {
        let e = ScheduleEngine(
            config: makeConfig { c in
                c.schedules[0].warningMinutes = 5
            })
        let lock = local(2026, 3, 2, 21, 30)
        XCTAssertEqual(e.evaluate(at: lock.addingTimeInterval(-6 * 60)).phase, .normal)
        XCTAssertEqual(e.evaluate(at: lock.addingTimeInterval(-5 * 60)).phase, .warning)
        XCTAssertFalse(e.evaluate(at: lock.addingTimeInterval(-10 * 60)).showWarningCard)

        let none = ScheduleEngine(config: makeConfig { c in c.warningMinutes = 0 })
        XCTAssertEqual(none.evaluate(at: lock.addingTimeInterval(-30)).phase, .normal)
        XCTAssertEqual(none.evaluate(at: lock).phase, .locked)
    }

    func testDisabled() {
        let e = ScheduleEngine(config: makeConfig { c in c.enabled = false })
        XCTAssertEqual(e.evaluate(at: local(2026, 3, 2, 23)).phase, .disabled)
        XCTAssertTrue(e.windows(from: local(2026, 3, 1), to: local(2026, 3, 9)).isEmpty)
    }

    // MARK: Snooze

    func testSnoozeDelaysLockAndRespectsLimit() throws {
        let e = ScheduleEngine(
            config: makeConfig { c in
                c.snoozeEnabled = true
                c.snoozeMinutes = 10
                c.maxSnoozesPerWindow = 1
            })
        let lock = local(2026, 3, 2, 21, 30)
        XCTAssertNil(e.snooze(at: lock.addingTimeInterval(-20 * 60), ledger: nil), "not during normal phase")

        let before = e.evaluate(at: lock.addingTimeInterval(-5 * 60))
        XCTAssertTrue(before.snoozeAvailable)
        let ledger = try XCTUnwrap(e.snooze(at: lock.addingTimeInterval(-5 * 60), ledger: nil))
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.delaySeconds, 600)

        let during = e.evaluate(at: lock.addingTimeInterval(60), snooze: ledger)
        XCTAssertEqual(during.phase, .warning)
        XCTAssertEqual(during.lockStart, lock.addingTimeInterval(600))
        XCTAssertFalse(during.snoozeAvailable, "max one snooze")
        XCTAssertNil(e.snooze(at: lock.addingTimeInterval(60), ledger: ledger))
        XCTAssertEqual(e.evaluate(at: lock.addingTimeInterval(600), snooze: ledger).phase, .locked)

        // The ledger only applies to its own window.
        let tomorrow = lock.addingTimeInterval(24 * 3600)
        XCTAssertEqual(e.evaluate(at: tomorrow, snooze: ledger).phase, .locked)
        XCTAssertTrue(e.evaluate(at: tomorrow.addingTimeInterval(-60), snooze: ledger).snoozeAvailable)
    }

    func testSnoozeNeverPastWindowEnd() throws {
        let e = ScheduleEngine(
            config: makeConfig(days: [.mon], start: "21:30", end: "21:40") { c in
                c.snoozeEnabled = true
                c.snoozeMinutes = 30
            })
        let lock = local(2026, 3, 2, 21, 30)
        let ledger = try XCTUnwrap(e.snooze(at: lock.addingTimeInterval(-60), ledger: nil))
        XCTAssertEqual(ledger.delaySeconds, 600, "clamped to window length")
        let ev = e.evaluate(at: lock.addingTimeInterval(5 * 60), snooze: ledger)
        XCTAssertEqual(ev.phase, .normal)
        XCTAssertEqual(ev.window?.start, local(2026, 3, 9, 21, 30))
    }

    func testSnoozeUnavailableWhenDisabled() {
        let e = ScheduleEngine(config: makeConfig())
        let lock = local(2026, 3, 2, 21, 30)
        XCTAssertFalse(e.evaluate(at: lock.addingTimeInterval(-60)).snoozeAvailable)
        XCTAssertNil(e.snooze(at: lock.addingTimeInterval(-60), ledger: nil))
    }

    func testProgress() {
        let w = DowntimeWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100), name: "x")
        XCTAssertEqual(w.progress(at: Date(timeIntervalSince1970: 25)), 0.25)
        XCTAssertEqual(w.progress(at: Date(timeIntervalSince1970: -5)), 0)
        XCTAssertEqual(w.progress(at: Date(timeIntervalSince1970: 500)), 1)
    }
}

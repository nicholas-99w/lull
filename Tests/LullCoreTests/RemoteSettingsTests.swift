import XCTest

@testable import LullCore

/// Portal settings (lull-portal contract/PORTAL_API.md): validation, rollback protection, precedence over
/// the profile, and the wire contract shared with the portal's tests.
/// 2026-10-15 is a Thursday (AEDT, UTC+11).
final class RemoteSettingsTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/portal")

    func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        return try PortalAPI.decoder().decode(T.self, from: data)
    }

    func settings(
        revision: Int64 = 10, enabled: Bool = true, school: (String, String) = ("21:30", "06:30"),
        weekend: (String, String) = ("23:00", "08:00")
    ) -> RemoteSettings {
        RemoteSettings(
            revision: revision, enabled: enabled,
            schoolNights: .init(start: time(school.0), end: time(school.1)),
            weekend: .init(start: time(weekend.0), end: time(weekend.1)))
    }

    /// Profile with portal management on and its own (different) school default.
    func profile(_ tweak: (inout LullConfig) -> Void = { _ in }) -> LullConfig {
        makeConfig(days: [.mon, .tue, .wed, .thu, .fri], start: "20:00", end: "07:00", name: "Profile") {
            $0.portal = PortalConfig(url: URL(string: "https://lull.example.edu.au")!)
            tweak(&$0)
        }
    }

    // MARK: Validation

    func testValidFixture() throws {
        let r = try RemoteSettings.validate(fixture("settings.json", as: PortalAPI.SettingsPayload.self)).get()
        XCTAssertEqual(r, settings(revision: 1_760_000_000_000))
    }

    func testUnknownFieldsAreIgnored() throws {
        let r = try RemoteSettings.validate(fixture("settings-opted-out.json", as: PortalAPI.SettingsPayload.self)).get()
        XCTAssertFalse(r.enabled)
    }

    func testInvalidTimeIsRejected() throws {
        let r = RemoteSettings.validate(try fixture("settings-invalid.json", as: PortalAPI.SettingsPayload.self))
        XCTAssertEqual(r, .failure(.invalidTime(field: "schoolNights.start", value: "9:30pm")))
    }

    func testBadRevisionAndEmptyWindowAreRejected() {
        let w = PortalAPI.WindowPayload(start: "21:30", end: "06:30")
        XCTAssertEqual(
            RemoteSettings.validate(.init(revision: 0, enabled: true, schoolNights: w, weekend: w)),
            .failure(.invalidRevision(0)))
        XCTAssertEqual(
            RemoteSettings.validate(
                .init(revision: 1, enabled: true, schoolNights: w, weekend: .init(start: "22:00", end: "22:00"))),
            .failure(.emptyWindow(field: "weekend")))
    }

    // MARK: Rollback protection

    func testUpdateRules() {
        XCTAssertEqual(RemoteSettings.update(from: nil, to: settings(revision: 5)), .apply)
        XCTAssertEqual(RemoteSettings.update(from: settings(revision: 5), to: settings(revision: 6, enabled: false)), .apply)
        XCTAssertEqual(RemoteSettings.update(from: settings(revision: 5), to: settings(revision: 5)), .unchanged)
        XCTAssertEqual(
            RemoteSettings.update(from: settings(revision: 6), to: settings(revision: 5, enabled: false)),
            .rollback(cached: 6, offered: 5))
        XCTAssertEqual(
            RemoteSettings.update(from: settings(revision: 5), to: settings(revision: 5, enabled: false)), .revisionReused(5))
    }

    // MARK: Precedence

    func testWithoutPortalOrSettingsTheProfileDecides() {
        var noPortal = profile()
        noPortal.portal = nil
        XCTAssertEqual(noPortal.applying(settings(enabled: false)), noPortal, "portal off: cached settings ignored")
        XCTAssertEqual(profile().applying(nil), profile(), "never reached the portal: school default applies")
    }

    func testPortalWindowsReplaceProfileSchedules() {
        let c = profile().applying(settings())
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.schedules.map(\.name), ["School nights", "Weekend"])
        XCTAssertEqual(c.schedules[0].days, [.sun, .mon, .tue, .wed, .thu])
        XCTAssertEqual(c.schedules[1].days, [.fri, .sat])
        XCTAssertEqual(c.schedules[1].start, time("23:00"))
        XCTAssertNil(c.schedules[0].warningMinutes)
    }

    func testOptOutDisablesAndProfileEnabledFalseWins() {
        XCTAssertFalse(profile().applying(settings(enabled: false)).enabled, "parent opt-out")
        XCTAssertFalse(profile { $0.enabled = false }.applying(settings(enabled: true)).enabled, "IT's master switch wins")
    }

    func testEverythingElseComesFromTheProfile() {
        let base = profile {
            $0.dateExceptions = [DateException(startDate: date("2026-12-19"), endDate: date("2027-01-27"), mode: .skip)]
            $0.warningMinutes = 10
            $0.texts.organizationName = "Example College"
        }
        let c = base.applying(settings())
        XCTAssertEqual(c.dateExceptions, base.dateExceptions)
        XCTAssertEqual(c.warningMinutes, 10)
        XCTAssertEqual(c.texts, base.texts)
        XCTAssertEqual(c.portal, base.portal)
    }

    func testEffectiveScheduleAcrossTheWeek() {
        let e = ScheduleEngine(config: profile().applying(settings()))
        // Thursday is a school night.
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 22)).phase, .locked)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 22)).scheduleName, "School nights")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 16, 6, 30)).phase, .normal, "school-night window ends 06:30 Friday")
        // Friday is the weekend: 23:00 to 08:00.
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 16, 22)).phase, .normal, "before the 15-minute notice for 23:00")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 16, 22, 50)).phase, .warning)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 16, 23, 30)).scheduleName, "Weekend")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 17, 7, 30)).phase, .locked, "Friday night runs to 08:00 Saturday")
        // Sunday night is a school night again.
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 18, 7, 30)).phase, .locked, "Saturday night runs to 08:00 Sunday")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 18, 21, 45)).scheduleName, "School nights")
    }

    func testWeekendWindowAcrossDSTStart() {
        // Sydney springs forward 02:00 -> 03:00 on Sunday 2026-10-04.
        let e = ScheduleEngine(config: profile().applying(settings()))
        let ev = e.evaluate(at: local(2026, 10, 4, 1, 30))
        XCTAssertEqual(ev.phase, .locked)
        XCTAssertEqual(ev.window?.start, local(2026, 10, 3, 23))
        XCTAssertEqual(ev.window?.end, local(2026, 10, 4, 8))
        XCTAssertEqual(ev.window.map { $0.end.timeIntervalSince($0.start) }, 8 * 3600, "nine wall-clock hours, eight real")
    }

    // MARK: Follow the school, or customise

    func testFollowingTheSchoolKeepsTheProfileSchedules() throws {
        let r = try RemoteSettings.validate(fixture("settings-follow.json", as: PortalAPI.SettingsPayload.self)).get()
        XCTAssertNil(r.schoolNights)
        XCTAssertNil(r.weekend)
        let c = profile().applying(r)
        XCTAssertEqual(c.schedules, profile().schedules, "IT's schedule, untouched")
        XCTAssertTrue(c.enabled)
        XCTAssertFalse(profile().applying(RemoteSettings(revision: 2, enabled: false)).enabled, "opting out still works")
    }

    func testCustomSchoolNightsKeepTheSchoolsFridayWindow() {
        // Profile: Mon–Fri 20:00–07:00. Parent customises school nights only.
        let s = RemoteSettings(revision: 3, enabled: true, schoolNights: .init(start: time("21:30"), end: time("06:30")))
        let rules = profile().applying(s).schedules
        XCTAssertEqual(rules.map(\.name), ["Profile", "School nights"])
        XCTAssertEqual(rules[0].days, [.fri], "the profile rule keeps only the day that isn't customised")
        XCTAssertEqual(rules[0].start, time("20:00"))
        XCTAssertEqual(rules[1].days, [.sun, .mon, .tue, .wed, .thu])
        let e = ScheduleEngine(config: profile().applying(s))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 21)).phase, .normal, "Thursday: the parent's 21:30")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 16, 20, 30)).phase, .locked, "Friday: still the school's 20:00")
    }

    func testOptOutPerKind() throws {
        // School nights customised, weekend opted out: the profile's Friday window goes too.
        let r = try RemoteSettings.validate(fixture("settings-optout.json", as: PortalAPI.SettingsPayload.self)).get()
        XCTAssertEqual(r.weekendOff, true)
        XCTAssertNil(r.schoolNightsOff)
        let c = profile().applying(r)
        XCTAssertEqual(c.schedules.map(\.name), ["School nights"])
        XCTAssertTrue(c.enabled)
        let e = ScheduleEngine(config: c)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 23)).phase, .locked, "Thursday: the parent's school night")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 16, 21)).phase, .normal, "Friday: opted out")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 17, 23)).phase, .normal, "Saturday: opted out")
    }

    func testOptOutOfSchoolNightsKeepsTheSchoolsWeekend() {
        // Profile Mon–Fri 20:00–07:00; school nights off, weekend follows the school: only Friday is left.
        let s = RemoteSettings(revision: 4, enabled: true, schoolNightsOff: true)
        let rules = profile().applying(s).schedules
        XCTAssertEqual(rules.map(\.name), ["Profile"])
        XCTAssertEqual(rules[0].days, [.fri])
        // Both off: no schedules at all, but a lock-down still works.
        var both = RemoteSettings(revision: 5, enabled: true, schoolNightsOff: true, weekendOff: true)
        XCTAssertEqual(profile().applying(both).schedules, [])
        both.lockNow = lock(local(2026, 10, 17, 13), hours: 1)
        XCTAssertEqual(ScheduleEngine(config: profile().applying(both)).evaluate(at: local(2026, 10, 17, 13, 30)).phase, .locked)
    }

    func testAnOptedOutKindsWindowIsIgnored() throws {
        let p = PortalAPI.SettingsPayload(
            revision: 6, enabled: true, schoolNights: .init(start: "21:30", end: "06:30"), schoolNightsOff: true)
        let r = try RemoteSettings.validate(p).get()
        XCTAssertNil(r.schoolNights)
        XCTAssertEqual(r.schoolNightsOff, true)
    }

    func testCustomWeekendOnly() {
        let s = RemoteSettings(revision: 3, enabled: true, weekend: .init(start: time("10:00"), end: time("14:00")))
        let rules = profile().applying(s).schedules
        XCTAssertEqual(rules.map(\.name), ["Profile", "Weekend"])
        XCTAssertEqual(rules[0].days, [.mon, .tue, .wed, .thu])
        XCTAssertEqual(rules[1].days, [.fri, .sat])
    }

    func testCustomisingBothReplacesEveryProfileWindowOnThoseDays() {
        // A homework block on school days goes too: the parent owns those days now.
        let base = profile {
            $0.schedules.append(ScheduleRule(name: "Homework", days: [.mon, .tue], start: time("16:00"), end: time("17:00")))
        }
        let rules = base.applying(settings()).schedules
        XCTAssertEqual(rules.map(\.name), ["School nights", "Weekend"])
    }

    // MARK: Lock down now

    func lock(_ from: Date, hours: Double) -> LockNowWindow { LockNowWindow(start: from, end: from.addingTimeInterval(hours * 3600)) }

    func testLockFixtureValidates() throws {
        let r = try RemoteSettings.validate(fixture("settings-lock.json", as: PortalAPI.SettingsPayload.self)).get()
        // 2026-10-17 is a Saturday: 13:00-15:00 in Sydney (AEDT).
        XCTAssertEqual(r.lockNow, LockNowWindow(start: local(2026, 10, 17, 13), end: local(2026, 10, 17, 15)))
        XCTAssertEqual(r.weekend, .init(start: time("10:00"), end: time("14:00")), "daytime windows are fine")
        XCTAssertFalse(r.enabled)
    }

    func testBadLocksAreRejected() {
        let w = PortalAPI.WindowPayload(start: "21:30", end: "06:30")
        let t = local(2026, 10, 17, 13)
        func payload(_ from: Date?, _ until: Date?) -> PortalAPI.SettingsPayload {
            .init(revision: 1, enabled: true, schoolNights: w, weekend: w, lockFrom: from, lockUntil: until)
        }
        XCTAssertEqual(RemoteSettings.validate(payload(t, nil)), .failure(.invalidLockNow("lockFrom and lockUntil must both be set")))
        XCTAssertEqual(RemoteSettings.validate(payload(t, t)), .failure(.invalidLockNow("lockUntil is not after lockFrom")))
        XCTAssertEqual(
            RemoteSettings.validate(payload(t, t.addingTimeInterval(25 * 3600))), .failure(.invalidLockNow("longer than 24 hours")))
        XCTAssertNotNil(try? RemoteSettings.validate(payload(t, t.addingTimeInterval(24 * 3600))).get())
    }

    func testLockNowPrecedence() {
        var s = settings()
        s.lockNow = lock(local(2026, 10, 17, 13), hours: 2)
        XCTAssertEqual(profile().applying(s).lockNow, s.lockNow)
        s.enabled = false
        XCTAssertEqual(profile().applying(s).lockNow, s.lockNow, "applies even when opted out of schedules")
        XCTAssertNil(profile { $0.enabled = false }.applying(s).lockNow, "IT's master switch still wins")
        var noPortal = profile()
        noPortal.portal = nil
        XCTAssertNil(noPortal.applying(s).lockNow)
    }

    func testLockNowLocksAtOnceAndEnds() {
        // Saturday 13:00-15:00, outside both schedule windows.
        var s = settings()
        s.lockNow = lock(local(2026, 10, 17, 13), hours: 2)
        let e = ScheduleEngine(config: profile().applying(s))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 17, 12, 59)).phase, .normal, "no warning period before a lock-down")
        let during = e.evaluate(at: local(2026, 10, 17, 13, 30))
        XCTAssertEqual(during.phase, .locked)
        XCTAssertEqual(during.scheduleName, "Lock down")
        XCTAssertEqual(during.window?.end, local(2026, 10, 17, 15))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 17, 15)).phase, .normal)
    }

    func testLockNowWhileOptedOutThenDisabledAgain() {
        var s = settings(enabled: false)
        s.lockNow = lock(local(2026, 10, 17, 13), hours: 2)
        let e = ScheduleEngine(config: profile().applying(s))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 17, 12)).phase, .disabled)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 17, 14)).phase, .locked)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 17, 15, 1)).phase, .disabled)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 17, 23, 30)).phase, .disabled, "the weekend schedule stays off")
    }

    func testLockNowIgnoresHolidaySkipAndMergesWithSchedules() {
        var s = settings()
        // Friday 21:00 to Saturday 00:00 overlaps the weekend window (23:00-08:00).
        s.lockNow = lock(local(2026, 10, 16, 21), hours: 3)
        let base = profile { $0.dateExceptions = [DateException(startDate: date("2026-10-16"), endDate: date("2026-10-16"), mode: .skip)] }
        let e = ScheduleEngine(config: base.applying(s))
        let ev = e.evaluate(at: local(2026, 10, 16, 22))
        XCTAssertEqual(ev.phase, .locked, "Skip doesn't cancel a parent's lock-down")
        XCTAssertEqual(ev.window?.end, local(2026, 10, 17, 0), "Friday's weekend window was skipped")
        let noSkip = ScheduleEngine(config: profile().applying(s)).evaluate(at: local(2026, 10, 16, 22))
        XCTAssertEqual(noSkip.window?.end, local(2026, 10, 17, 8), "merged with the weekend window")
    }

    // MARK: Release now

    func testReleaseFixtureValidates() throws {
        let r = try RemoteSettings.validate(fixture("settings-release.json", as: PortalAPI.SettingsPayload.self)).get()
        XCTAssertEqual(r.releasedAt, local(2026, 10, 15, 23))  // Thursday 11 pm in Sydney
        XCTAssertEqual(profile().applying(r).releasedAt, r.releasedAt)
    }

    func testReleaseEndsOnlyTheWindowInProgress() {
        var s = settings()
        s.releasedAt = local(2026, 10, 15, 23)  // during Thursday's school-night window (22:30-06:30)
        let e = ScheduleEngine(config: profile().applying(s))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 22, 45)).phase, .locked, "before the release")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 23, 1)).phase, .normal)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 16, 5)).phase, .normal, "the rest of that window is released")
        let next = e.evaluate(at: local(2026, 10, 16, 12))
        XCTAssertEqual(next.window?.start, local(2026, 10, 16, 23), "Friday's weekend window still comes")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 16, 23, 30)).phase, .locked)
    }

    func testReleaseOutsideAWindowDoesNothing() {
        var s = settings()
        s.releasedAt = local(2026, 10, 15, 20)  // before Thursday's window
        let e = ScheduleEngine(config: profile().applying(s))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 23)).phase, .locked)
    }

    func testReleaseEndsALockDownAndAMergedRun() {
        var s = settings()
        // Lock-down Thursday 21:00-23:00 merges with the 22:30 school-night window.
        s.lockNow = lock(local(2026, 10, 15, 21), hours: 2)
        s.releasedAt = local(2026, 10, 15, 21, 30)
        let e = ScheduleEngine(config: profile().applying(s))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 21, 15)).phase, .locked)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 22, 45)).phase, .normal, "the whole merged run was released")
        // A lock-down started after the release is not affected.
        s.lockNow = lock(local(2026, 10, 16, 16), hours: 1)
        XCTAssertEqual(ScheduleEngine(config: profile().applying(s)).evaluate(at: local(2026, 10, 16, 16, 30)).phase, .locked)
    }

    // MARK: School holidays

    /// The Term 3 break in the fixture: from Fri 16 Oct 15:30 (school end on the last school day)
    /// to Sun 25 Oct (the night before school goes back on Mon 26).
    static let term3 = HolidayPeriod(startDay: date("2026-10-16"), startTime: time("15:30"), lastDay: date("2026-10-25"))

    /// School nights customised 21:30–06:30, holiday times 23:00–09:00, over the Term 3 break.
    func holidaySettings(_ tweak: (inout RemoteSettings) -> Void = { _ in }) -> RemoteSettings {
        var s = RemoteSettings(
            revision: 7, enabled: true, schoolNights: .init(start: time("21:30"), end: time("06:30")),
            holiday: .init(start: time("23:00"), end: time("09:00")), holidayPeriods: [Self.term3])
        tweak(&s)
        return s
    }

    func engine(holiday: (String, String)? = ("23:00", "09:00"), _ tweak: (inout RemoteSettings) -> Void = { _ in }) -> ScheduleEngine {
        ScheduleEngine(
            config: profile().applying(
                holidaySettings {
                    $0.holiday = holiday.map { .init(start: time($0.0), end: time($0.1)) }
                    $0.holidayOff = holiday == nil ? true : nil
                    tweak(&$0)
                }))
    }

    func testHolidayFixturesValidate() throws {
        let r = try RemoteSettings.validate(fixture("settings-holiday.json", as: PortalAPI.SettingsPayload.self)).get()
        XCTAssertEqual(r.holiday, .init(start: time("23:00"), end: time("09:00")))
        XCTAssertNil(r.holidayOff)
        XCTAssertEqual(
            r.holidayPeriods,
            [
                Self.term3,
                HolidayPeriod(startDay: date("2026-12-18"), startTime: time("15:30"), lastDay: date("2027-01-31")),
            ])
        let off = try RemoteSettings.validate(fixture("settings-holiday-off.json", as: PortalAPI.SettingsPayload.self)).get()
        XCTAssertEqual(off.holidayOff, true)
        XCTAssertNil(off.holiday)
        XCTAssertEqual(off.holidaySchedule?.rules, [], "opted out: no holiday windows")
    }

    func testBadHolidaySettingsAreRejected() {
        func validate(_ tweak: (inout PortalAPI.SettingsPayload) -> Void) -> Result<RemoteSettings, RemoteSettingsError> {
            var p = PortalAPI.SettingsPayload(
                revision: 1, enabled: true, holiday: .init(start: "23:00", end: "09:00"),
                holidayPeriods: [.init(start: "2026-10-16T15:30", lastDay: "2026-10-25")])
            tweak(&p)
            return RemoteSettings.validate(p)
        }
        XCTAssertNoThrow(try validate { _ in }.get())
        for bad in ["2026-10-32T15:30", "2026-10-16T25:00", "2026-10-16 15:30", "2026-10-16"] {
            XCTAssertEqual(
                validate { $0.holidayPeriods = [.init(start: bad, lastDay: "2026-10-25")] }.failure,
                .invalidDate(field: "holidayPeriods[0].start", value: bad))
        }
        XCTAssertEqual(
            validate { $0.holidayPeriods = [.init(start: "2026-10-16T15:30", lastDay: "25/10/2026")] }.failure,
            .invalidDate(field: "holidayPeriods[0].lastDay", value: "25/10/2026"))
        XCTAssertEqual(
            validate { $0.holidayPeriods = [.init(start: "2026-10-16T15:30", lastDay: "2026-10-16")] }.failure,
            .invalidHolidayPeriod(field: "holidayPeriods[0]"), "the last day must be after the start day")
        XCTAssertEqual(
            validate {
                $0.holidayPeriods = [
                    .init(start: "2026-10-16T15:30", lastDay: "2026-10-25"), .init(start: "2026-10-25T15:30", lastDay: "2026-10-27"),
                ]
            }.failure,
            .invalidHolidayPeriod(field: "holidayPeriods[1]"), "periods must not share a day")
        XCTAssertEqual(validate { $0.holiday = .init(start: "23:00", end: "23:00") }.failure, .emptyWindow(field: "holiday"))
    }

    func testHolidayPeriodsWithoutAChoiceAreDropped() throws {
        // Equality stays meaningful: periods alone, or an opted-out window, change nothing.
        let p = PortalAPI.SettingsPayload(
            revision: 1, enabled: true, holidayPeriods: [.init(start: "2026-10-16T15:30", lastDay: "2026-10-25")])
        XCTAssertNil(try RemoteSettings.validate(p).get().holidayPeriods)
        var off = p
        off.holidayOff = true
        off.holiday = .init(start: "23:00", end: "09:00")
        XCTAssertNil(try RemoteSettings.validate(off).get().holiday)
        var empty = off
        empty.holidayPeriods = []
        XCTAssertNil(try RemoteSettings.validate(empty).get().holidayPeriods)
        XCTAssertNil(profile().applying(try RemoteSettings.validate(empty).get()).holidaySchedule)
    }

    // MARK: Advanced schedules

    func testWeekFixtureValidates() throws {
        let r = try RemoteSettings.validate(fixture("settings-week.json", as: PortalAPI.SettingsPayload.self)).get()
        XCTAssertEqual(r.week?.count, 9)
        XCTAssertEqual(r.week?.first, .init(day: .mon, start: time("15:30"), end: time("17:00")))
        XCTAssertEqual(r.week?[6], .init(day: .sat, start: time("00:00"), end: time("00:00")), "a whole day")
        XCTAssertNil(r.schoolNights, "sent for older lulld builds; means nothing next to week")
        let c = profile().applying(r)
        XCTAssertEqual(c.schedules.count, 9, "the profile's schedules are replaced")
        XCTAssertEqual(Set(c.schedules.map(\.name)), ["Downtime"])
    }

    func testWeekIsEnforcedDayByDay() throws {
        let r = try RemoteSettings.validate(fixture("settings-week.json", as: PortalAPI.SettingsPayload.self)).get()
        let e = ScheduleEngine(config: profile().applying(r))
        // Thursday 15 Oct: 21:00 until Friday 07:00.
        let thursday = e.evaluate(at: local(2026, 10, 15, 22))
        XCTAssertEqual(thursday.phase, .locked)
        XCTAssertEqual(thursday.scheduleName, "Downtime")
        XCTAssertEqual(thursday.window?.end, local(2026, 10, 16, 7))
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 16, 20, 30)).phase, .locked, "the profile's Friday 20:00 is gone")
        // Friday 22:00 to Sunday 08:00, sent as three windows split at midnight: one run.
        let saturday = e.evaluate(at: local(2026, 10, 17, 12))
        XCTAssertEqual(saturday.phase, .locked)
        XCTAssertEqual(saturday.window?.start, local(2026, 10, 16, 22))
        XCTAssertEqual(saturday.window?.end, local(2026, 10, 18, 8))
        // Monday 19 Oct, 15:30–17:00: from when school ends.
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 19, 15, 15)).phase, .locked)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 19, 16)).phase, .locked)
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 19, 18)).phase, .locked)
    }

    func testEmptyWeekIsNoDowntime() {
        let e = ScheduleEngine(config: profile().applying(RemoteSettings(revision: 1, enabled: true, week: [])))
        XCTAssertNil(e.evaluate(at: local(2026, 10, 15, 22)).window)
    }

    func testHolidayWeekReplacesTheUsualWindowsInTheBreak() throws {
        let r = try RemoteSettings.validate(fixture("settings-holiday-week.json", as: PortalAPI.SettingsPayload.self)).get()
        XCTAssertEqual(r.holidaySchedule?.rules.count, 7)
        XCTAssertNil(r.holiday)
        let e = ScheduleEngine(config: profile().applying(r))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 22)).scheduleName, "School nights", "Thursday: still term")
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 20, 21, 45)).phase, .locked, "Tuesday of the break: not 21:30")
        let tuesday = e.evaluate(at: local(2026, 10, 20, 23))
        XCTAssertEqual(tuesday.scheduleName, "School holidays")
        XCTAssertEqual(tuesday.window?.end, local(2026, 10, 21, 8))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 24, 8, 30)).phase, .locked, "Friday and Saturday nights: until 09:00")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 25, 22)).scheduleName, "School nights", "Sunday 25: the night before school")
    }

    func testHolidayWeekWithoutPeriodsMeansNothing() throws {
        var p = try fixture("settings-holiday-week.json", as: PortalAPI.SettingsPayload.self)
        p.holidayPeriods = nil
        let r = try RemoteSettings.validate(p).get()
        XCTAssertNil(r.holidayWeek)
        XCTAssertNil(r.holidaySchedule)
    }

    func testBadWeeksAreRejected() {
        func validate(_ week: [PortalAPI.WeekWindowPayload]) -> Result<RemoteSettings, RemoteSettingsError> {
            RemoteSettings.validate(PortalAPI.SettingsPayload(revision: 1, enabled: true, week: week))
        }
        XCTAssertNoThrow(try validate([.init(day: "Sat", start: "00:00", end: "00:00")]).get(), "a whole day")
        XCTAssertEqual(
            validate([.init(day: "Monday", start: "21:00", end: "07:00")]).failure, .invalidDay(field: "week[0].day", value: "Monday"))
        XCTAssertEqual(
            validate([.init(day: "Mon", start: "21:00", end: "07:00"), .init(day: "Tue", start: "9pm", end: "07:00")]).failure,
            .invalidTime(field: "week[1].start", value: "9pm"))
        XCTAssertEqual(
            validate(Array(repeating: .init(day: "Mon", start: "21:00", end: "22:00"), count: RemoteSettings.maxWeekWindows + 1)).failure,
            .tooManyWindows(field: "week"))
        XCTAssertEqual(
            RemoteSettings.validate(
                PortalAPI.SettingsPayload(revision: 1, enabled: true, holidayWeek: [.init(day: "Sun", start: "24:00", end: "07:00")])
            ).failure,
            .invalidTime(field: "holidayWeek[0].start", value: "24:00"))
    }

    func testSettingsCachedByAnOlderLulldStillDecode() throws {
        let old = try JSONEncoder().encode(settings())
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("holiday"))
        let decoded = try JSONDecoder().decode(RemoteSettings.self, from: old)
        XCTAssertEqual(decoded, settings())
        XCTAssertNil(decoded.holidaySchedule)
    }

    // Four worked holiday examples. Profile: Mon–Fri 20:00–07:00 (so its Friday window
    // is the usual weekend one); school nights customised 21:30–06:30.

    func testLateHolidayWindow() {
        let e = engine()
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 22)).scheduleName, "School nights", "Thursday: still term")
        // Fri 16 from 15:30: the school's Friday 20:00 is replaced by the holiday 23:00.
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 16, 21)).phase, .normal)
        let first = e.evaluate(at: local(2026, 10, 16, 23, 30))
        XCTAssertEqual(first.scheduleName, "School holidays")
        XCTAssertEqual(first.window?.end, local(2026, 10, 17, 9))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 20, 22)).phase, .normal, "Tuesday of the break: not 21:30")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 25, 8, 30)).scheduleName, "School holidays", "Saturday 24's night")
        // Sun 25: the school night starts at 21:30, so the 23:00 holiday window doesn't start.
        let last = e.evaluate(at: local(2026, 10, 25, 23, 30))
        XCTAssertEqual(last.scheduleName, "School nights")
        XCTAssertEqual(last.window?.start, local(2026, 10, 25, 21, 30))
        XCTAssertEqual(last.window?.end, local(2026, 10, 26, 6, 30))
    }

    func testAfternoonHolidayWindowStartsWhenSchoolEnds() {
        let e = engine(holiday: ("14:00", "09:00"))
        let before = e.evaluate(at: local(2026, 10, 16, 14, 30))
        XCTAssertEqual(before.phase, .normal, "Friday 14:30: school is still on")
        XCTAssertEqual(before.window?.start, local(2026, 10, 16, 15, 30), "next: when school ends")
        let first = e.evaluate(at: local(2026, 10, 16, 16))
        XCTAssertEqual(first.window?.start, local(2026, 10, 16, 15, 30))
        XCTAssertEqual(first.window?.end, local(2026, 10, 17, 9))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 20, 14, 30)).phase, .locked, "Tuesday of the break: from 14:00")
        // Sun 25: 14:00 until the school night starts at 21:30, then the school night, as one run.
        let last = e.evaluate(at: local(2026, 10, 25, 15))
        XCTAssertEqual(last.window?.start, local(2026, 10, 25, 14))
        XCTAssertEqual(last.window?.end, local(2026, 10, 26, 6, 30))
        XCTAssertEqual(last.window?.scheduleName(at: local(2026, 10, 25, 22)), "School nights")
    }

    func testDaytimeHolidayWindow() {
        let e = engine(holiday: ("10:00", "14:00"))
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 16, 12)).phase, .locked, "Friday: over before school ends")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 16, 20, 30)).phase, .normal, "and the school's Friday 20:00 is gone")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 19, 12)).phase, .locked, "Monday of the break")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 25, 12)).phase, .locked, "Sunday 25: still a holiday day")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 25, 22)).scheduleName, "School nights", "then the school night")
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 26, 12)).phase, .locked, "Monday back at school")
    }

    func testLastDayEndsAtMidnightWithoutASchoolNight() {
        let e = engine {
            $0.schoolNights = nil
            $0.schoolNightsOff = true
        }
        let last = e.evaluate(at: local(2026, 10, 25, 23, 30))
        XCTAssertEqual(last.scheduleName, "School holidays")
        XCTAssertEqual(last.window?.end, local(2026, 10, 26), "cut at midnight, clear of Monday's school morning")
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 26, 1)).phase, .locked)
    }

    func testHolidayOptOut() {
        let e = engine(holiday: nil)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 15, 22)).phase, .locked, "Thursday: term")
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 16, 21)).phase, .locked, "the school's Friday 20:00 is off")
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 21, 2)).phase, .locked)
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 25, 22)).phase, .locked, "Sunday: the night before school")
    }

    func testPupilFreeWednesday() {
        // Wednesday 21 off: from Tuesday after school to Wednesday night (a school night again).
        let e = engine(holiday: ("10:00", "14:00")) {
            $0.holidayPeriods = [HolidayPeriod(startDay: date("2026-10-20"), startTime: time("15:30"), lastDay: date("2026-10-21"))]
        }
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 20, 22)).phase, .normal, "Tuesday night: no school night")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 21, 12)).phase, .locked, "Wednesday daytime: holiday")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 21, 22)).scheduleName, "School nights")
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 22, 12)).phase, .locked)
    }

    func testDateExceptionsStillApplyInAHolidayPeriod() {
        let base = profile {
            $0.dateExceptions = [
                DateException(startDate: date("2026-10-20"), endDate: date("2026-10-20"), mode: .skip),
                DateException(startDate: date("2026-10-21"), endDate: date("2026-10-21"), mode: .allDay, note: "Device-free day"),
            ]
        }
        let e = ScheduleEngine(config: base.applying(holidaySettings()))
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 20, 23, 30)).phase, .locked, "Skip: no window starts Tuesday")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 21, 12)).phase, .locked, "AllDay Wednesday")
        let night = e.evaluate(at: local(2026, 10, 22, 8))
        XCTAssertEqual(night.phase, .locked)
        XCTAssertEqual(night.window?.end, local(2026, 10, 22, 9), "the AllDay merges with Wednesday's holiday window")
    }

    func testLockDownAndReleaseInAHolidayPeriod() {
        var s = holidaySettings()
        s.lockNow = lock(local(2026, 10, 20, 13), hours: 1)
        s.releasedAt = local(2026, 10, 20, 23, 30)
        let e = ScheduleEngine(config: profile().applying(s))
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 20, 13, 30)).phase, .locked, "lock-down on a holiday afternoon")
        XCTAssertEqual(e.evaluate(at: local(2026, 10, 20, 23, 15)).phase, .locked)
        XCTAssertNotEqual(e.evaluate(at: local(2026, 10, 20, 23, 45)).phase, .locked, "released")
    }

    func testHolidayWindowAcrossDSTStart() {
        // Sydney springs forward 02:00 -> 03:00 on Sunday 2026-10-04.
        let e = engine {
            $0.holidayPeriods = [HolidayPeriod(startDay: date("2026-10-02"), startTime: time("15:30"), lastDay: date("2026-10-04"))]
        }
        let ev = e.evaluate(at: local(2026, 10, 4, 1, 30))
        XCTAssertEqual(ev.window?.start, local(2026, 10, 3, 23))
        XCTAssertEqual(ev.window?.end, local(2026, 10, 4, 9))
        XCTAssertEqual(ev.window.map { $0.end.timeIntervalSince($0.start) }, 9 * 3600, "ten wall-clock hours, nine real")
    }

    // MARK: Wire contract

    func testRegisterFixturesRoundTrip() throws {
        let req: PortalAPI.RegisterRequest = try fixture("register-request.json")
        XCTAssertEqual(req.serialNumber, "C02EXAMPLE01")
        let res: PortalAPI.RegisterResponse = try fixture("register-response.json")
        XCTAssertEqual(res.deviceToken, "example-device-token")
    }

    func testCheckInMatchesFixture() throws {
        // The fixture is a Mac on 0.2.0 (the portal's tests use it as one too old for holidays).
        let status = DaemonStatus(
            version: "0.2.0", debugBuild: false, generatedAt: local(2026, 10, 15, 23), generatedAtContinuous: 5_000,
            bootSessionUUID: "boot-A",
            phase: .locked, scheduleName: "School nights",
            windowStart: local(2026, 10, 15, 21, 30), windowEnd: local(2026, 10, 16, 6, 30),
            lockStart: local(2026, 10, 15, 21, 30), nextTransition: local(2026, 10, 16, 6, 30),
            config: .init(source: "managed", currentValid: true, hasActiveConfig: true, timeZone: "Australia/Sydney"),
            time: .init(status: .synced),
            agents: [.init(uid: 501, username: "jsmith26", fullName: "Jane Smith", connected: true, exempt: false)])
        let checkIn = PortalAPI.CheckIn.make(
            status: status, config: profile().applying(settings(revision: 1_760_000_000_000)), profile: profile(),
            settingsRevision: 1_760_000_000_000, settingsError: nil)
        XCTAssertEqual(checkIn, try fixture("checkin.json"))

        // Same JSON object as the fixture, so the portal's tests see what lulld sends.
        let sent = try JSONSerialization.jsonObject(with: PortalAPI.encoder().encode(checkIn)) as? NSDictionary
        let expected =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: Self.fixtures.appendingPathComponent("checkin.json"))) as? NSDictionary
        XCTAssertEqual(sent, expected)
    }
}

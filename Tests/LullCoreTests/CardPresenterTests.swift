import XCTest

@testable import LullCore

final class CardPresenterTests: XCTestCase {
    let en = Locale(identifier: "en_AU")
    let start = local(2026, 10, 5, 21, 30)
    let end = local(2026, 10, 6, 6, 30)

    func lockedState(_ tweak: (inout DisplayState) -> Void = { _ in }) -> DisplayState {
        var s = DisplayState(
            phase: .locked, trustedNow: start, windowStart: start, windowEnd: end, lockStart: start,
            scheduleName: "School night", overrideAvailable: true, timeZoneIdentifier: "Australia/Sydney")
        tweak(&s)
        return s
    }

    func clean(_ s: String?) -> String? { s?.replacingOccurrences(of: "\u{202F}", with: " ") }

    func testLockContent() {
        let state = lockedState { $0.texts.lockedTitle = "Goodnight, {{firstName}}" }
        let now = local(2026, 10, 5, 22, 58)
        let c = CardPresenter.content(for: state, kind: .lock, now: now, userFullName: "Alex Citizen", locale: en)
        XCTAssertEqual(c.title, "Goodnight, Alex")
        XCTAssertEqual(c.message, "Devices at your school are unavailable during downtime hours.")
        XCTAssertEqual(c.countdown, "Available again in 7h 32m")
        XCTAssertEqual(c.countdownAccessibility, "Available again in 7 hours, 32 minutes")
        XCTAssertEqual(c.progress!, 88.0 / 540, accuracy: 0.0001)
        XCTAssertEqual(clean(c.unlockLabel), "Back online at 6:30 am")
        XCTAssertNil(c.footer, "empty footer is hidden")
        XCTAssertEqual(c.support, "Need help? Contact your IT team.")
        XCTAssertEqual(c.overrideLabel, "Admin override")
        XCTAssertEqual(c.shutdownLabel, "Shut Down")
    }

    func testOrganizationAndSupportContactFlowIntoDefaults() {
        let state = lockedState {
            $0.texts.organizationName = "Example College"
            $0.texts.supportContact = "the IT Service Desk (ext. 1234)"
        }
        let c = CardPresenter.content(for: state, kind: .lock, now: start, userFullName: "", locale: en)
        XCTAssertEqual(c.message, "Devices at Example College are unavailable during downtime hours.")
        XCTAssertEqual(c.support, "Need help? Contact the IT Service Desk (ext. 1234).")
        XCTAssertNil(c.footer, "footer stays empty unless configured")
    }

    func testHiddenCountdownAndProgress() {
        let state = lockedState {
            $0.appearance.showCountdown = false
            $0.appearance.showProgress = false
        }
        let c = CardPresenter.content(for: state, kind: .lock, now: start, userFullName: "", locale: en)
        XCTAssertNil(c.countdown)
        XCTAssertNil(c.progress)
    }

    func testLockedWithoutWindowHasNoTimes() {
        let state = DisplayState(phase: .locked, trustedNow: start)
        let c = CardPresenter.content(for: state, kind: .lock, now: start, userFullName: "", locale: en)
        XCTAssertNil(c.countdown)
        XCTAssertNil(c.progress)
        XCTAssertNil(c.unlockLabel, "no 'Back online at' with an empty time")
    }

    func testWarningContentAndFinalCountdownProgress() {
        var state = lockedState()
        state.phase = .warning
        let early = CardPresenter.content(for: state, kind: .warning, now: start.addingTimeInterval(-300), userFullName: "", locale: en)
        XCTAssertEqual(early.title, Texts().warningTitle)
        XCTAssertEqual(clean(early.message), "This Mac will lock at 9:30 pm. Please save your work.")
        XCTAssertEqual(early.countdown, "Locks in 5m 0s")
        XCTAssertNil(early.progress, "no bar before the final countdown")
        XCTAssertNil(early.unlockLabel)

        state.inFinalCountdown = true
        let late = CardPresenter.content(for: state, kind: .warning, now: start.addingTimeInterval(-15), userFullName: "", locale: en)
        XCTAssertEqual(late.countdown, "Locks in 15s")
        XCTAssertEqual(late.progress!, 0.75, accuracy: 0.0001)
    }

    func testSnoozedLockTimeIsShown() {
        var state = lockedState()
        state.phase = .warning
        state.lockStart = start.addingTimeInterval(600)
        let c = CardPresenter.content(for: state, kind: .warning, now: start, userFullName: "", locale: en)
        XCTAssertEqual(c.countdown, "Locks in 10m")
        XCTAssertEqual(clean(c.message), "This Mac will lock at 9:40 pm. Please save your work.")
    }

    func testDurationFormatting() {
        XCTAssertEqual(CardPresenter.formatDuration(5 * 3600 + 32 * 60 + 59, locale: en), "5h 32m")
        XCTAssertEqual(CardPresenter.formatDuration(3600, locale: en), "1h 0m")
        XCTAssertEqual(CardPresenter.formatDuration(15 * 60 + 30, locale: en), "15m")
        XCTAssertEqual(CardPresenter.formatDuration(4 * 60 + 30, locale: en), "4m 30s")
        XCTAssertEqual(CardPresenter.formatDuration(45, locale: en), "45s")
        XCTAssertEqual(CardPresenter.formatDuration(-3, locale: en), "0s")
    }

    func testDisplayStateMake() {
        var config = makeConfig { $0.snoozeEnabled = true }
        config.showShutdownButton = false
        let engine = ScheduleEngine(config: config)
        let now = local(2026, 3, 2, 21, 29, 30)
        let ev = engine.evaluate(at: now)
        let s = DisplayState.make(phase: ev.phase, evaluation: ev, config: config, now: now, overrideAvailable: true)
        XCTAssertEqual(s.phase, .warning)
        XCTAssertTrue(s.showWarningCard)
        XCTAssertTrue(s.inFinalCountdown)
        XCTAssertTrue(s.snoozeAvailable)
        XCTAssertTrue(s.overrideAvailable)
        XCTAssertFalse(s.shutdownAvailable)
        XCTAssertEqual(s.lockStart, local(2026, 3, 2, 21, 30))
        XCTAssertEqual(s.timeZoneIdentifier, "Australia/Sydney")

        // Locked while awaiting sync: the warning flags must not leak through.
        let locked = DisplayState.make(phase: .locked, evaluation: ev, config: config, now: now, overrideAvailable: false)
        XCTAssertFalse(locked.showWarningCard)
        XCTAssertFalse(locked.snoozeAvailable)
        XCTAssertFalse(locked.overrideAvailable)
    }

    func testDisplayStateRoundTripsThroughJSON() throws {
        let s = lockedState()
        XCTAssertEqual(try JSONDecoder().decode(DisplayState.self, from: JSONEncoder().encode(s)), s)
    }
}

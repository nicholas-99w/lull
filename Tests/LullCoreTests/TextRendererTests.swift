import XCTest

@testable import LullCore

final class TextRendererTests: XCTestCase {
    let renderer = TextRenderer(timeZone: sydney, locale: Locale(identifier: "en_AU"))

    func testTokens() {
        let ctx = TextContext(
            windowStart: local(2026, 3, 2, 21, 30), windowEnd: local(2026, 3, 3, 6, 30),
            secondsRemaining: 61, scheduleName: "School night", userFullName: "Alex Citizen")
        let out = renderer.render(
            "{{firstName}}: {{scheduleName}} {{startTime}}-{{endTime}} in {{minutesRemaining}}m ({{secondsRemaining}}s) {{bogus}}",
            context: ctx)
        XCTAssertEqual(
            out.replacingOccurrences(of: "\u{202F}", with: " "),
            "Alex: School night 9:30 pm-6:30 am in 2m (61s) {{bogus}}")
    }

    func testOrganizationTokens() {
        XCTAssertEqual(
            renderer.render("{{organizationName}} / {{supportContact}}", context: TextContext()), "your school / your IT team")
        XCTAssertEqual(
            renderer.render(
                "{{organizationName}} / {{supportContact}}",
                context: TextContext(organizationName: "Example College", supportContact: "the Service Desk")),
            "Example College / the Service Desk")
    }

    func testTimesUseConfiguredZoneNotSystem() {
        // 10:30 UTC is 21:30 in Sydney (AEDT, +11) on 2026-03-02.
        let utc = TimeZone(identifier: "UTC")!
        let start = local(2026, 3, 2, 10, 30, tz: utc)
        let out = renderer.render("{{startTime}}", context: TextContext(windowStart: start))
        XCTAssertEqual(out.replacingOccurrences(of: "\u{202F}", with: " "), "9:30 pm")
    }

    func testMinutesRoundUpAndNeverNegative() {
        XCTAssertEqual(renderer.render("{{minutesRemaining}}", context: TextContext(secondsRemaining: 1)), "1")
        XCTAssertEqual(renderer.render("{{minutesRemaining}}", context: TextContext(secondsRemaining: 120)), "2")
        XCTAssertEqual(renderer.render("{{minutesRemaining}}", context: TextContext(secondsRemaining: -5)), "0")
    }

    func testFirstName() {
        XCTAssertEqual(TextRenderer.firstName(from: "Alex Citizen"), "Alex")
        XCTAssertEqual(TextRenderer.firstName(from: "Citizen, Alex"), "Alex")
        XCTAssertEqual(TextRenderer.firstName(from: "  "), "")
        XCTAssertEqual(TextRenderer.firstName(from: "student01"), "student01")
    }
}

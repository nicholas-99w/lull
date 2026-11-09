import XCTest

@testable import LullCore

final class ConfigParserTests: XCTestCase {
    let branding = "/Library/Application Support/Lull/Branding"
    var parser: ConfigParser {
        ConfigParser(
            images: ImagePathValidator(
                brandingDirectory: branding, maxBytes: 1_000,
                files: FakeFiles(sizes: [branding + "/banner.png": 500, branding + "/huge.png": 5_000])))
    }

    let minimal: [String: Any] = [
        "Timezone": "Australia/Sydney",
        "Schedules": [["Name": "Weeknights", "Days": ["Mon", "Tue"], "Start": "21:30", "End": "06:30"]],
    ]

    func merged(_ extra: [String: Any]) -> [String: Any] { minimal.merging(extra) { $1 } }

    func testMinimalConfigUsesDefaults() throws {
        let r = parser.parse(minimal)
        XCTAssertTrue(r.issues.isEmpty, "\(r.issues)")
        let c = try XCTUnwrap(r.config)
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.timeZoneIdentifier, "Australia/Sydney")
        XCTAssertEqual(c.schedules.count, 1)
        XCTAssertEqual(c.schedules[0].days, [.mon, .tue])
        XCTAssertEqual(c.schedules[0].start, time("21:30"))
        XCTAssertTrue(c.schedules[0].crossesMidnight)
        XCTAssertEqual(c.warningMinutes, 15)
        XCTAssertEqual(c.warningIntervalsMinutes, [15, 10, 5, 2, 1])
        XCTAssertEqual(c.finalCountdownSeconds, 60)
        XCTAssertFalse(c.snoozeEnabled)
        XCTAssertTrue(c.exemptAdminUsers)
        XCTAssertEqual(c.timeServers, ["time.apple.com"])
        XCTAssertEqual(c.offlineBootPolicy, .forwardOnly)
        XCTAssertEqual(c.fallbackActionIfAgentMissing, .sleepDisplay)
        XCTAssertEqual(c.appearance, Appearance())
        XCTAssertEqual(c.texts, Texts())
    }

    func testFullConfigParses() throws {
        let r = parser.parse(
            merged([
                "Enabled": true,
                "DateExceptions": [["StartDate": "2026-12-19", "EndDate": "2027-01-27", "Mode": "Skip", "Note": "Summer"]],
                "WarningMinutes": 10,
                "WarningIntervalsMinutes": [1, 10, 5, 30, 5],
                "FinalCountdownSeconds": 30,
                "SnoozeEnabled": true, "SnoozeMinutes": 5, "MaxSnoozesPerWindow": 2,
                "ExemptUsernames": ["itadmin", " "], "ExemptAdminUsers": false,
                "OverrideEnabled": true, "OverrideDurationMinutes": 45, "OverrideMaxAttempts": 3,
                "OverrideLockoutMinutes": 20,
                "TimeServers": ["time.apple.com", "pool.ntp.org"], "TimeSyncIntervalMinutes": 30,
                "MaxClockDriftSeconds": 60, "OfflineBootPolicy": "LockUntilSynced",
                "FallbackActionIfAgentMissing": "None", "AgentMissingGraceSeconds": 10,
                "ShowShutdownButton": false,
                "Appearance": [
                    "BannerImagePath": "banner.png", "TitleColor": "#112233", "AccentColor": "#abc",
                    "BodyColorDark": "#FFFFFF80", "CardWidth": 700, "BackgroundOpacity": 0.5,
                    "WarningCardPosition": "TopRight", "BackgroundStyle": "Solid",
                ],
                "Texts": ["LockedTitle": "Lights out, {{firstName}}"],
            ]))
        XCTAssertTrue(r.issues.isEmpty, "\(r.issues)")
        let c = try XCTUnwrap(r.config)
        XCTAssertEqual(
            c.dateExceptions,
            [
                DateException(
                    startDate: date("2026-12-19"), endDate: date("2027-01-27"),
                    mode: .skip, note: "Summer")
            ])
        // Sorted, unique, and those above WarningMinutes dropped.
        XCTAssertEqual(c.warningIntervalsMinutes, [10, 5, 1])
        XCTAssertEqual(c.exemptUsernames, ["itadmin"])
        XCTAssertEqual(c.offlineBootPolicy, .lockUntilSynced)
        XCTAssertEqual(c.fallbackActionIfAgentMissing, FallbackAction.none)
        XCTAssertEqual(c.appearance.bannerImagePath, branding + "/banner.png")
        XCTAssertEqual(c.appearance.titleColor.light, HexColor(string: "#112233"))
        XCTAssertEqual(c.appearance.titleColor.dark, HexColor(string: "#112233"), "light-only colour applies to dark too")
        XCTAssertEqual(c.appearance.accentColor.light, HexColor(string: "#AABBCC"))
        XCTAssertEqual(c.appearance.bodyColor.light, Appearance().bodyColor.light)
        XCTAssertEqual(c.appearance.bodyColor.dark.alpha, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(c.appearance.cardWidth, 700)
        XCTAssertEqual(c.appearance.warningCardPosition, .topRight)
        XCTAssertEqual(c.appearance.backgroundStyle, .solid)
        XCTAssertEqual(c.texts.lockedTitle, "Lights out, {{firstName}}")
        XCTAssertEqual(c.texts.lockedMessage, Texts().lockedMessage)
    }

    // MARK: Errors (config rejected)

    func testMissingSchedulesIsError() {
        let r = parser.parse(["Timezone": "Australia/Sydney"])
        XCTAssertNil(r.config)
        XCTAssertEqual(r.errors.map(\.keyPath), ["Schedules"])
    }

    func testMissingSchedulesAllowedWhenDisabled() {
        XCTAssertNotNil(parser.parse(["Enabled": false]).config)
    }

    func testBadScheduleFieldsAreErrors() {
        let r = parser.parse(
            merged([
                "Schedules": [
                    ["Days": ["Mon", "Funday"], "Start": "9:30", "End": "25:00"],
                    ["Days": [], "Start": "21:00", "End": "06:00"],
                    "not a dict",
                ]
            ]))
        XCTAssertNil(r.config)
        XCTAssertEqual(
            Set(r.errors.map(\.keyPath)),
            [
                "Schedules[0].Days[1]", "Schedules[0].Start", "Schedules[0].End",
                "Schedules[1].Days", "Schedules[2]",
            ])
    }

    func testBadDateExceptionsAreErrors() {
        let r = parser.parse(
            merged([
                "DateExceptions": [
                    ["StartDate": "2026-02-30", "EndDate": "2026-03-01", "Mode": "Skip"],
                    ["StartDate": "2026-03-05", "EndDate": "2026-03-01", "Mode": "AllDay"],
                    ["StartDate": "2026-03-05", "EndDate": "2026-03-06", "Mode": "Sometimes"],
                ]
            ]))
        XCTAssertNil(r.config)
        XCTAssertEqual(
            Set(r.errors.map(\.keyPath)),
            [
                "DateExceptions[0].StartDate", "DateExceptions[1]", "DateExceptions[2].Mode",
            ])
    }

    func testBadTimeIntegrityEnumsAreErrors() {
        let r = parser.parse(merged(["OfflineBootPolicy": "Whatever", "FallbackActionIfAgentMissing": 3]))
        XCTAssertNil(r.config)
        XCTAssertEqual(Set(r.errors.map(\.keyPath)), ["OfflineBootPolicy", "FallbackActionIfAgentMissing"])
    }

    // MARK: Warnings (defaulted / clamped)

    func testWrongTypesFallBackToDefaults() throws {
        let r = parser.parse(
            merged([
                "Enabled": "yes", "WarningMinutes": "15", "SnoozeEnabled": 1, "SnoozeMinutes": true,
                "TimeServers": "time.apple.com",
            ]))
        let c = try XCTUnwrap(r.config)
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.warningMinutes, 15)
        XCTAssertFalse(c.snoozeEnabled, "integer 1 must not be accepted as a boolean")
        XCTAssertEqual(c.snoozeMinutes, 10, "boolean must not be accepted as an integer")
        XCTAssertEqual(c.timeServers, ["time.apple.com"])
        XCTAssertEqual(
            Set(r.warnings.map(\.keyPath)),
            ["Enabled", "WarningMinutes", "SnoozeEnabled", "SnoozeMinutes", "TimeServers"])
    }

    func testOutOfRangeValuesAreClamped() throws {
        let r = parser.parse(
            merged([
                "WarningMinutes": 10_000, "AgentMissingGraceSeconds": 0, "MaxClockDriftSeconds": -5,
                "Appearance": ["BackgroundOpacity": 1.5, "CardWidth": 10],
            ]))
        let c = try XCTUnwrap(r.config)
        XCTAssertEqual(c.warningMinutes, 240)
        XCTAssertEqual(c.agentMissingGraceSeconds, 1)
        XCTAssertEqual(c.maxClockDriftSeconds, 5)
        XCTAssertEqual(c.appearance.backgroundOpacity, 1)
        XCTAssertEqual(c.appearance.cardWidth, 320)
        XCTAssertEqual(r.warnings.count, 5)
    }

    func testUnknownKeysIgnoredWithWarning() throws {
        let r = parser.parse(merged(["Colour": "red", "Appearance": ["Sparkles": true], "Texts": ["Hello": "x"]]))
        XCTAssertNotNil(r.config)
        XCTAssertEqual(Set(r.warnings.map(\.keyPath)), ["Colour", "Appearance.Sparkles", "Texts.Hello"])
    }

    func testBadHexColoursDefault() throws {
        let r = parser.parse(merged(["Appearance": ["TitleColor": "#12345", "AccentColor": "blue", "BodyColor": 7]]))
        let c = try XCTUnwrap(r.config)
        XCTAssertEqual(c.appearance.titleColor, Appearance().titleColor)
        XCTAssertEqual(c.appearance.accentColor, Appearance().accentColor)
        XCTAssertEqual(c.appearance.bodyColor, Appearance().bodyColor)
        XCTAssertEqual(r.warnings.count, 3)
    }

    func testImagePathsValidated() throws {
        let r = parser.parse(
            merged([
                "Appearance": [
                    "BannerImagePath": "missing.png",
                    "LogoImagePath": "../../../../etc/passwd",
                    "BackgroundImagePath": "huge.png",
                    "BackgroundStyle": "Image",
                ]
            ]))
        let c = try XCTUnwrap(r.config)
        XCTAssertNil(c.appearance.bannerImagePath)
        XCTAssertNil(c.appearance.logoImagePath)
        XCTAssertNil(c.appearance.backgroundImagePath)
        XCTAssertEqual(c.appearance.backgroundStyle, .blur, "Image style with no image falls back to Blur")
        XCTAssertEqual(r.warnings.count, 4)
    }

    func testTimezoneFallbackOrder() throws {
        var raw = minimal
        raw["Timezone"] = nil
        XCTAssertEqual(parser.parse(raw, fallbackTimeZone: "Australia/Perth").config?.timeZoneIdentifier, "Australia/Perth")
        XCTAssertEqual(parser.parse(raw).config?.timeZoneIdentifier, "Australia/Sydney")
        XCTAssertEqual(parser.parse(raw, fallbackTimeZone: "Not/AZone").config?.timeZoneIdentifier, "Australia/Sydney")
        raw["Timezone"] = "EST"
        let r = parser.parse(raw, fallbackTimeZone: "Australia/Brisbane")
        XCTAssertEqual(r.config?.timeZoneIdentifier, "Australia/Brisbane", "abbreviations aren't IANA names")
        XCTAssertEqual(r.warnings.map(\.keyPath), ["Timezone"])
    }

    func testBadPasswordHashIsWarningAndNeverEchoed() throws {
        let secret = "pbkdf2-sha256$1000$c2FsdHNhbHQ=$aGFzaA=="
        let r = parser.parse(merged(["OverridePasswordHash": secret]))
        let c = try XCTUnwrap(r.config)
        XCTAssertNil(c.overridePasswordHash)
        XCTAssertEqual(r.warnings.map(\.keyPath), ["OverridePasswordHash"])
        XCTAssertFalse(r.issues.description.contains("c2FsdHNhbHQ"))
    }

    func testOrganizationNameAndSupportContact() throws {
        let set = try XCTUnwrap(
            parser.parse(merged(["Texts": ["OrganizationName": " Example College ", "SupportContact": "the IT Service Desk"]])).config)
        XCTAssertEqual(set.texts.organizationName, "Example College", "trimmed")
        XCTAssertEqual(set.texts.supportContact, "the IT Service Desk")

        let unset = try XCTUnwrap(parser.parse(minimal).config)
        XCTAssertEqual(unset.texts.organizationName, "your school")
        XCTAssertEqual(unset.texts.supportContact, "your IT team")

        let blank = parser.parse(merged(["Texts": ["OrganizationName": "  ", "SupportContact": ""]]))
        XCTAssertEqual(blank.config?.texts.organizationName, "your school")
        XCTAssertEqual(blank.config?.texts.supportContact, "your IT team")
        XCTAssertEqual(blank.issues, [], "blank = not set, silently")
    }

    /// What Jamf's form may write for fields an admin never filled in.
    func testEmptyStringsMeanNotSet() throws {
        let r = parser.parse(
            merged([
                "OverridePasswordHash": "", "TimeServers": [String](),
                "Appearance": ["BannerImagePath": "", "LogoImagePath": " ", "BackgroundImagePath": "", "FontName": ""],
                "Texts": ["LockedTitle": "", "SupportText": "  ", "FooterText": ""],
            ]))
        XCTAssertEqual(r.issues, [])
        let c = try XCTUnwrap(r.config)
        XCTAssertNil(c.overridePasswordHash)
        XCTAssertEqual(c.timeServers, ["time.apple.com"])
        XCTAssertNil(c.appearance.bannerImagePath)
        XCTAssertNil(c.appearance.fontName)
        XCTAssertEqual(c.texts, Texts(), "empty texts keep the defaults")
    }

    func testPerScheduleWarningMinutesKeepsLargerIntervals() throws {
        let r = parser.parse(
            merged([
                "WarningMinutes": 5,
                "Schedules": [["Days": ["Mon"], "Start": "21:30", "End": "06:30", "WarningMinutes": 10]],
            ]))
        let c = try XCTUnwrap(r.config)
        XCTAssertEqual(c.schedules[0].warningMinutes, 10)
        XCTAssertEqual(c.warningIntervalsMinutes, [10, 5, 2, 1])
    }

    // MARK: Managed (forced) keys

    func testForcedFilterInRelease() {
        let raw: [String: Any] = ["Enabled": false, "Schedules": [], "Timezone": "UTC"]
        let forced: Set = ["Schedules", "Timezone"]
        let r = ManagedKeyFilter.filter(raw, requireForced: true) { forced.contains($0) }
        XCTAssertEqual(Set(r.kept.keys), forced)
        XCTAssertEqual(r.dropped, ["Enabled"])
    }

    func testForcedFilterOffInDebug() {
        let raw: [String: Any] = ["Enabled": false]
        let r = ManagedKeyFilter.filter(raw, requireForced: false) { _ in false }
        XCTAssertEqual(r.kept.count, 1)
        XCTAssertTrue(r.dropped.isEmpty)
    }

    // MARK: Primitives

    func testHexColor() {
        XCTAssertEqual(HexColor(string: "#FFF"), HexColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(HexColor(string: "000000")?.alpha, 1)
        XCTAssertEqual(HexColor(string: "#FF000080")?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(HexColor(string: "#0A84FF")?.description, "#0A84FF")
        for bad in ["", "#", "#GG0000", "#12345", "#1234567", "#１２３", "red"] {
            XCTAssertNil(HexColor(string: bad), bad)
        }
    }

    func testTimeAndDateParsing() {
        XCTAssertEqual(TimeOfDay(string: "00:00")?.minutesSinceMidnight, 0)
        XCTAssertEqual(TimeOfDay(string: "23:59")?.minutesSinceMidnight, 1439)
        for bad in ["24:00", "9:30", "09:3", "09-30", "ab:cd", "09:60", " 09:30"] {
            XCTAssertNil(TimeOfDay(string: bad), bad)
        }
        XCTAssertNotNil(LocalDate(string: "2028-02-29"))
        for bad in ["2026-02-29", "2026-13-01", "26-01-01", "2026/01/01", "2026-1-01"] {
            XCTAssertNil(LocalDate(string: bad), bad)
        }
        XCTAssertEqual(Weekday(configString: "mon"), .mon)
        XCTAssertNil(Weekday(configString: "Monday"))
    }

    // MARK: Portal (lull-portal contract/PORTAL_API.md)

    func testPortalParses() throws {
        let r = parser.parse(merged(["Portal": ["URL": "https://lull.example.edu.au/", "PollIntervalSeconds": 120]]))
        XCTAssertTrue(r.issues.isEmpty, "\(r.issues)")
        let p = try XCTUnwrap(r.config?.portal)
        XCTAssertEqual(p.url.absoluteString, "https://lull.example.edu.au/")
        XCTAssertEqual(p.pollIntervalSeconds, 120)
    }

    func testPortalAbsentOrBlankURLMeansOff() throws {
        XCTAssertNil(try XCTUnwrap(parser.parse(minimal).config).portal)
        // Jamf writes the interval default even when the URL was never filled in.
        let r = parser.parse(merged(["Portal": ["URL": " ", "PollIntervalSeconds": 300]]))
        XCTAssertTrue(r.issues.isEmpty, "\(r.issues)")
        XCTAssertNil(try XCTUnwrap(r.config).portal)
    }

    func testBadPortalTurnsPortalOffButKeepsConfigValid() throws {
        for url in [
            "http://lull.example.edu.au", "https://", "https://lull.example.edu.au/?x=1", "https://u:p@lull.example.edu.au", "lull",
        ] {
            let r = parser.parse(merged(["Portal": ["URL": url]]))
            let c = try XCTUnwrap(r.config, url)
            XCTAssertNil(c.portal, url)
            XCTAssertEqual(r.warnings.map(\.keyPath), ["Portal.URL"], url)
        }
        let notDict = parser.parse(merged(["Portal": "https://lull.example.edu.au"]))
        XCTAssertNotNil(notDict.config)
        XCTAssertEqual(notDict.warnings.map(\.keyPath), ["Portal"])
    }

    func testPortalIntervalIsClampedAndUnknownKeysWarn() throws {
        let r = parser.parse(merged(["Portal": ["URL": "https://lull.example.edu.au", "PollIntervalSeconds": 5, "Token": "x"]]))
        XCTAssertEqual(try XCTUnwrap(r.config?.portal).pollIntervalSeconds, 60)
        XCTAssertEqual(Set(r.warnings.map(\.keyPath)), ["Portal.PollIntervalSeconds", "Portal.Token"])
    }
}

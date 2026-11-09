import LullCore
import XCTest

@testable import LullDaemonKit

/// In-memory portal that answers the engine's requests like the real one
/// (lull-portal: src/Lull.Portal/Api/DeviceApi.cs).
final class FakePortal {
    var token = "device-token-1"
    var settings = PortalAPI.SettingsPayload(
        revision: 1_000, enabled: true, schoolNights: .init(start: "22:30", end: "06:30"),
        weekend: .init(start: "23:00", end: "08:00"))
    var offline = false
    /// IT clicked "De-register device": settings and check-ins get 410.
    var deregistered = false
    var registerOverride: PortalOutcome?
    /// When set, registering with any other enrolment secret gets 401.
    var acceptedSecret: String?
    var registrations: [PortalAPI.RegisterRequest] = []
    var checkIns: [PortalAPI.CheckIn] = []
    var etag: String { "\"\(settings.revision)\"" }

    func respond(_ request: PortalRequest) -> PortalOutcome {
        if offline { return .failed("offline") }
        switch request {
        case .register(let r):
            registrations.append(r)
            if let acceptedSecret, r.enrolmentSecret != acceptedSecret { return .unauthorized }
            return registerOverride ?? .registered(.init(deviceId: "dev-1", deviceToken: token))
        case .fetchSettings(let t, let e):
            guard t == token else { return .unauthorized }
            if deregistered { return .deregistered }
            return e == etag ? .notModified : .settings(settings, etag: etag)
        case .checkIn(let t, let c):
            guard t == token else { return .unauthorized }
            if deregistered { return .deregistered }
            checkIns.append(c)
            return .checkedIn
        }
    }
}

extension Harness {
    static let portalURL = "https://lull.example.edu.au"
    static let secret = "a-test-enrolment-secret"

    static func portalConfig(_ extra: [String: Any] = [:], url: String = portalURL) -> [String: Any] {
        configDict(["Portal": ["URL": url, "PollIntervalSeconds": 60]].merging(extra) { $1 })
    }

    func writeEnrolmentSecret(mode: mode_t = 0o600, secret: String = Harness.secret) throws {
        let data = try JSONSerialization.data(withJSONObject: [PortalCredentialFile.secretKey: secret])
        try SecureFile.writeAtomically(data, to: paths.portalEnrolmentPath, mode: mode)
    }

    /// Answers requests until the engine has nothing more to ask. Returns their kinds.
    @discardableResult
    func pumpPortal(_ portal: FakePortal, limit: Int = 10) -> [String] {
        var kinds: [String] = []
        while kinds.count < limit, let (request, _) = engine.nextPortalRequest() {
            kinds.append(request.kind)
            engine.portalFinished(request, portal.respond(request))
        }
        return kinds
    }

    /// Engine registered with `portal` and holding its settings.
    func startRegistered(_ portal: FakePortal) throws -> DaemonEngine {
        try writeEnrolmentSecret()
        let e = start()
        XCTAssertEqual(pumpPortal(portal), ["register", "settings", "checkin"])
        return e
    }

    var allLoggedText: String {
        log.entries.map { "\($0.name) \($0.fields)" }.joined(separator: "\n")
    }
}

final class PortalSyncTests: XCTestCase {
    // 2026-03-02 is a Monday (a school night). Profile: daily 21:30-06:30.
    // Portal: school nights 22:30-06:30.

    func testNoPortalMeansNoRequests() {
        let h = Harness(at: local(2026, 3, 2, 22, 0))
        let e = h.start()
        XCTAssertNil(e.nextPortalRequest())
        XCTAssertNil(e.status.portal)
        XCTAssertEqual(e.status.phase, .locked)
    }

    func testRegisterFetchApplyAndCheckIn() throws {
        let h = Harness(at: local(2026, 3, 2, 22, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        try h.writeEnrolmentSecret()
        let e = h.start()
        XCTAssertEqual(e.status.phase, .locked, "profile schedule until the portal is reached")

        XCTAssertEqual(h.pumpPortal(portal), ["register", "settings", "checkin"])
        XCTAssertEqual(portal.registrations.first?.serialNumber, "C02TEST00001")
        XCTAssertEqual(portal.registrations.first?.enrolmentSecret, Harness.secret)
        XCTAssertEqual(e.status.phase, .normal, "portal says 22:30")
        XCTAssertEqual(e.activeConfig?.schedules.map(\.name), ["School nights", "Weekend"])

        let checkIn = try XCTUnwrap(portal.checkIns.last)
        XCTAssertEqual(checkIn.settingsRevision, 1_000)
        XCTAssertEqual(checkIn.phase, "normal")
        XCTAssertEqual(checkIn.schedules.first?.start, "22:30")
        XCTAssertEqual(checkIn.timeZone, "Australia/Sydney")

        let p = try XCTUnwrap(e.status.portal)
        XCTAssertEqual(p.url, Harness.portalURL)
        XCTAssertTrue(p.registered)
        XCTAssertEqual(p.deviceId, "dev-1")
        XCTAssertEqual(p.settingsSource, "portal")
        XCTAssertEqual(p.settingsRevision, 1_000)
        XCTAssertNotNil(p.lastCheckIn)
        XCTAssertNil(p.lastError)

        // Token stored root-only; secrets never logged.
        var st = stat()
        XCTAssertEqual(lstat(h.paths.portalCredentialsPath, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertTrue(h.log.names().contains("portal_registered"))
        XCTAssertTrue(h.log.names().contains("portal_settings_applied"))
        XCTAssertFalse(h.allLoggedText.contains(portal.token))
        XCTAssertFalse(h.allLoggedText.contains(Harness.secret))
        let statusJSON = String(decoding: try DaemonStatus.encoder().encode(e.status), as: UTF8.self)
        XCTAssertFalse(statusJSON.contains(portal.token))

        XCTAssertNil(e.nextPortalRequest(), "nothing more until the poll interval")
    }

    func testOptOutDuringALockUnlocksAtTheNextPoll() throws {
        let h = Harness(at: local(2026, 3, 2, 23, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        let e = try h.startRegistered(portal)
        XCTAssertEqual(e.status.phase, .locked)

        portal.settings.enabled = false
        portal.settings.revision += 1
        h.jump(30)
        XCTAssertNil(e.nextPortalRequest(), "not due yet")
        h.jump(30)
        XCTAssertEqual(h.pumpPortal(portal), ["settings", "checkin"])
        XCTAssertEqual(e.status.phase, .disabled)
        XCTAssertEqual(portal.checkIns.last?.enabled, false)
        XCTAssertEqual(portal.checkIns.last?.phase, "disabled")
    }

    func testProfileEnabledFalseStillWins() throws {
        let h = Harness(at: local(2026, 3, 2, 23, 0), config: Harness.portalConfig(["Enabled": false]))
        let e = try h.startRegistered(FakePortal())
        XCTAssertEqual(e.status.phase, .disabled)
    }

    func testUnchangedSettingsAre304AndStillCheckIn() throws {
        let h = Harness(at: local(2026, 3, 2, 20, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        let e = try h.startRegistered(portal)
        h.jump(60)
        XCTAssertEqual(h.pumpPortal(portal), ["settings", "checkin"])
        XCTAssertEqual(portal.checkIns.count, 2)
        XCTAssertEqual(e.status.portal?.settingsRevision, 1_000)
    }

    func testOfflineKeepsCachedSettingsAcrossRestart() throws {
        let h = Harness(at: local(2026, 3, 2, 22, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        _ = try h.startRegistered(portal)

        portal.offline = true
        let e = h.start()  // lulld restarts with no network
        XCTAssertEqual(e.status.phase, .normal, "cached portal windows apply before any network")
        XCTAssertTrue(e.status.portal?.registered == true, "token reloaded from portal.json")
        XCTAssertEqual(h.pumpPortal(portal), ["settings"])
        XCTAssertEqual(e.status.portal?.lastError, "settings: offline")
        h.jump(31 * 60)  // 22:31: the portal's school-night window
        XCTAssertEqual(e.status.phase, .locked, "enforcement doesn't need the portal")
        XCTAssertEqual(h.log.names().filter { $0 == "portal_error" }.count, 1, "an unchanged error is logged once")
    }

    func testInvalidOrOlderSettingsAreRefusedAndReported() throws {
        let h = Harness(at: local(2026, 3, 2, 20, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        let e = try h.startRegistered(portal)

        portal.settings.revision = 2_000
        portal.settings.schoolNights = .init(start: "9:30pm", end: "06:30")
        h.jump(60)
        XCTAssertEqual(h.pumpPortal(portal), ["settings", "checkin"])
        XCTAssertEqual(e.activeConfig?.schedules.first?.start, TimeOfDay(string: "22:30"), "cached settings kept")
        XCTAssertEqual(e.status.portal?.settingsError, "schoolNights.start: \"9:30pm\" is not HH:mm")
        XCTAssertEqual(portal.checkIns.last?.settingsError, e.status.portal?.settingsError)
        XCTAssertEqual(portal.checkIns.last?.settingsRevision, 1_000)

        portal.settings = PortalAPI.SettingsPayload(
            revision: 999, enabled: false, schoolNights: .init(start: "21:00", end: "06:30"), weekend: .init(start: "23:00", end: "08:00"))
        h.jump(60)
        h.pumpPortal(portal)
        XCTAssertEqual(e.status.portal?.settingsError, "revision 999 is older than the one in force (1000)")
        XCTAssertEqual(e.activeConfig?.enabled, true)

        portal.settings.revision = 3_000
        h.jump(60)
        h.pumpPortal(portal)
        XCTAssertNil(e.status.portal?.settingsError, "a good update clears the error")
        XCTAssertEqual(e.activeConfig?.enabled, false)
    }

    func testRevokedTokenRegistersAgain() throws {
        let h = Harness(at: local(2026, 3, 2, 20, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        let e = try h.startRegistered(portal)

        portal.token = "device-token-2"  // IT reset the Mac in the portal
        h.jump(60)
        XCTAssertEqual(h.pumpPortal(portal), ["settings", "register", "settings", "checkin"])
        XCTAssertTrue(h.log.names().contains("portal_token_refused"))
        XCTAssertEqual(portal.registrations.count, 2)
        XCTAssertTrue(e.status.portal?.registered == true)
    }

    func testEnrolmentSecretWrittenAfterLulldStartsIsPickedUpAtOnce() throws {
        // A Jamf package policy: the package starts lulld, then the script (priority
        // "After") writes the secret a moment later. No waiting for the poll interval.
        let h = Harness(
            at: local(2026, 3, 2, 20, 0), config: Harness.portalConfig(["Portal": ["URL": Harness.portalURL, "PollIntervalSeconds": 300]]))
        let portal = FakePortal()
        let e = h.start()
        XCTAssertNil(e.nextPortalRequest())
        XCTAssertTrue(e.status.portal?.lastError?.hasPrefix("not enrolled") == true)
        h.run(3)
        XCTAssertNil(e.nextPortalRequest(), "nothing to do until the file appears")

        try h.writeEnrolmentSecret()
        h.run(1)
        XCTAssertEqual(h.pumpPortal(portal), ["register", "settings", "checkin"])
        XCTAssertNil(e.status.portal?.lastError)
        XCTAssertTrue(e.status.portal?.registered == true)
    }

    func testAFixedEnrolmentFileIsRetriedAtOnce() throws {
        // Written with the wrong permissions, then corrected: retried without waiting.
        let h = Harness(
            at: local(2026, 3, 2, 20, 0), config: Harness.portalConfig(["Portal": ["URL": Harness.portalURL, "PollIntervalSeconds": 300]]))
        try h.writeEnrolmentSecret(mode: 0o644)
        let e = h.start()
        XCTAssertNil(e.nextPortalRequest())
        XCTAssertTrue(e.status.portal?.lastError?.contains("accessible by group/other") == true)
        chmod(h.paths.portalEnrolmentPath, 0o600)
        h.run(1)
        XCTAssertEqual(h.pumpPortal(FakePortal()), ["register", "settings", "checkin"])
    }

    func testASecretThePortalRefusedIsRetriedOnceItChanges() throws {
        // A typo in the Jamf policy's parameter 4, then IT fixes it and re-runs the script.
        let h = Harness(
            at: local(2026, 3, 2, 20, 0), config: Harness.portalConfig(["Portal": ["URL": Harness.portalURL, "PollIntervalSeconds": 300]]))
        let portal = FakePortal()
        portal.acceptedSecret = Harness.secret
        try h.writeEnrolmentSecret(secret: "a-typo-in-the-secret")
        let e = h.start()
        XCTAssertEqual(h.pumpPortal(portal), ["register"])
        XCTAssertEqual(e.status.portal?.lastError, "the portal refused the enrolment secret")
        h.run(5)
        XCTAssertNil(e.nextPortalRequest(), "the same refused secret isn't sent again early")

        try h.writeEnrolmentSecret()
        h.run(1)
        XCTAssertEqual(h.pumpPortal(portal), ["register", "settings", "checkin"])
        XCTAssertNil(e.status.portal?.lastError)
        XCTAssertEqual(portal.registrations.count, 2)
    }

    func testReEnrollingAfterADeregistrationIsPickedUpAtOnce() throws {
        let h = Harness(
            at: local(2026, 3, 2, 20, 0), config: Harness.portalConfig(["Portal": ["URL": Harness.portalURL, "PollIntervalSeconds": 300]]))
        let portal = FakePortal()
        let e = try h.startRegistered(portal)
        portal.deregistered = true
        h.jump(300)
        h.pumpPortal(portal)
        XCTAssertNotNil(e.status.portal?.deregisteredAt)

        portal.deregistered = false
        portal.token = "device-token-new"
        h.run(3)
        XCTAssertNil(e.nextPortalRequest())
        try h.writeEnrolmentSecret()  // IT flushes and re-runs the enrolment policy
        h.run(1)
        XCTAssertEqual(h.pumpPortal(portal), ["register", "settings", "checkin"])
        XCTAssertNil(e.status.portal?.deregisteredAt)
    }

    func testAConflictWaitsForThePollInterval() throws {
        let h = Harness(at: local(2026, 3, 2, 20, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        try h.writeEnrolmentSecret()
        portal.registerOverride = .conflict
        let e = h.start()
        XCTAssertEqual(h.pumpPortal(portal), ["register"])
        XCTAssertEqual(e.status.portal?.lastError, "this Mac's serial number is already registered; ask IT to reset it in the portal")
        h.jump(59)
        XCTAssertNil(e.nextPortalRequest(), "a refused registration isn't retried early (the file didn't change)")

        portal.registerOverride = nil  // IT clicked Reset
        h.jump(1)
        XCTAssertEqual(h.pumpPortal(portal), ["register", "settings", "checkin"])
        XCTAssertNil(e.status.portal?.lastError)
    }

    func testEnrolmentSecretMustBeRootOnly() throws {
        let h = Harness(at: local(2026, 3, 2, 20, 0), config: Harness.portalConfig())
        try h.writeEnrolmentSecret(mode: 0o644)
        let e = h.start()
        XCTAssertNil(e.nextPortalRequest())
        XCTAssertTrue(e.status.portal?.lastError?.contains("accessible by group/other") == true)
    }

    func testUnsafeCredentialsFileIsIgnored() throws {
        let h = Harness(at: local(2026, 3, 2, 20, 0), config: Harness.portalConfig())
        try PortalCredentialFile.saveCredentials(
            PortalCredentials(portalURL: Harness.portalURL, deviceId: "planted", deviceToken: "planted-token"),
            path: h.paths.portalCredentialsPath)
        chmod(h.paths.portalCredentialsPath, 0o666)
        try h.writeEnrolmentSecret()
        h.start()
        XCTAssertTrue(h.log.names().contains("portal_credentials_rejected"))
        XCTAssertEqual(h.pumpPortal(FakePortal()).first, "register")
    }

    func testPhaseChangeChecksInWithoutWaitingForThePoll() throws {
        let h = Harness(at: local(2026, 3, 2, 22, 29, 50), config: Harness.portalConfig())
        let portal = FakePortal()
        let e = try h.startRegistered(portal)
        XCTAssertEqual(e.status.phase, .warning)
        h.run(10)  // 22:30
        XCTAssertEqual(e.status.phase, .locked)
        XCTAssertEqual(h.pumpPortal(portal), ["checkin"])
        XCTAssertEqual(portal.checkIns.last?.phase, "locked")
    }

    func testAnotherPortalDoesNotInheritSettings() throws {
        let h = Harness(at: local(2026, 3, 2, 22, 0), config: Harness.portalConfig())
        let e = try h.startRegistered(FakePortal())
        XCTAssertEqual(e.status.phase, .normal)

        h.source.raw = RawConfig(values: Harness.portalConfig(url: "https://other.example.edu.au"), source: .managed)
        h.run(5)
        XCTAssertEqual(e.status.phase, .locked, "back to the profile's schedule")
        XCTAssertEqual(e.status.portal?.registered, false)
        XCTAssertEqual(e.nextPortalRequest()?.request.kind, "register")
    }

    func testLockDownNowLocksAtTheNextPollAndEnds() throws {
        // Monday 16:00: no schedule window until 22:30.
        let h = Harness(at: local(2026, 3, 2, 16, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        let e = try h.startRegistered(portal)
        XCTAssertEqual(e.status.phase, .normal)

        portal.settings.revision += 1
        portal.settings.lockFrom = local(2026, 3, 2, 16, 0, 30)
        portal.settings.lockUntil = local(2026, 3, 2, 17, 0)
        h.jump(60)
        XCTAssertEqual(h.pumpPortal(portal), ["settings", "checkin"])
        XCTAssertEqual(e.status.phase, .locked)
        XCTAssertEqual(e.status.scheduleName, "Lock down")
        XCTAssertEqual(portal.checkIns.last?.phase, "locked")
        XCTAssertEqual(portal.checkIns.last?.windowEnd, local(2026, 3, 2, 17, 0))

        h.jump(59 * 60)  // 17:01, offline the whole time
        portal.offline = true
        XCTAssertEqual(e.status.phase, .normal, "a lock-down always ends on its own")
    }

    func testOptedOutStillHonoursLockDown() throws {
        let h = Harness(at: local(2026, 3, 2, 16, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        portal.settings.enabled = false
        let e = try h.startRegistered(portal)
        XCTAssertEqual(e.status.phase, .disabled)
        XCTAssertEqual(e.status.phaseReason, "opted out in the parent portal")

        portal.settings.revision += 1
        portal.settings.lockFrom = local(2026, 3, 2, 16, 0)
        portal.settings.lockUntil = local(2026, 3, 2, 16, 30)
        h.jump(60)
        h.pumpPortal(portal)
        XCTAssertEqual(e.status.phase, .locked)
        h.jump(30 * 60)
        XCTAssertEqual(e.status.phase, .disabled)
    }

    func testDeregisteredFallsBackToTheProfileUntilEnrolledAgain() throws {
        // 22:00 Monday: the profile (21:30) says locked, the portal (22:30) says not yet.
        let h = Harness(at: local(2026, 3, 2, 22, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        let e = try h.startRegistered(portal)
        XCTAssertEqual(e.status.phase, .normal)

        portal.deregistered = true
        h.jump(60)
        XCTAssertEqual(h.pumpPortal(portal), ["settings"])
        XCTAssertEqual(e.status.phase, .locked, "back on the profile's schedule")
        XCTAssertEqual(e.activeConfig?.schedules.map(\.name), ["School night"])
        XCTAssertNil(h.store.state?.portalSettings, "cached portal settings dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.portalCredentialsPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.portalEnrolmentPath), "needs enrolling again")
        let p = try XCTUnwrap(e.status.portal)
        XCTAssertNotNil(p.deregisteredAt)
        XCTAssertNil(p.lastError, "expected state, not an error (no EA warning)")
        XCTAssertEqual(p.settingsSource, "profile")
        XCTAssertFalse(p.registered)
        XCTAssertTrue(h.log.names().contains("portal_deregistered"))

        // It doesn't register again on its own, also after a restart.
        h.jump(10 * 60)
        XCTAssertEqual(h.pumpPortal(portal), [])
        let restarted = h.start()
        XCTAssertNotNil(restarted.status.portal?.deregisteredAt)
        XCTAssertEqual(restarted.status.phase, .locked)
        XCTAssertEqual(h.pumpPortal(portal), [])
        XCTAssertNil(restarted.status.portal?.lastError)

        // Jamf runs the enrolment again: registers as a new Mac.
        try h.writeEnrolmentSecret()
        portal.deregistered = false
        portal.token = "device-token-new"
        h.jump(60)
        XCTAssertEqual(h.pumpPortal(portal), ["register", "settings", "checkin"])
        XCTAssertNil(restarted.status.portal?.deregisteredAt)
        XCTAssertEqual(restarted.status.portal?.settingsSource, "portal")
        XCTAssertEqual(restarted.status.phase, .normal)
    }

    func testDeregisteredDuringALockDownEndsIt() throws {
        let h = Harness(at: local(2026, 3, 2, 16, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        portal.settings.lockFrom = local(2026, 3, 2, 16, 0)
        portal.settings.lockUntil = local(2026, 3, 2, 18, 0)
        let e = try h.startRegistered(portal)
        XCTAssertEqual(e.status.phase, .locked)
        portal.deregistered = true
        h.jump(60)
        h.pumpPortal(portal)
        XCTAssertEqual(e.status.phase, .normal, "the portal's lock-down went with its settings")
    }

    func testReleaseNowUnlocksAndReportsIt() throws {
        let h = Harness(at: local(2026, 3, 2, 23, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        let e = try h.startRegistered(portal)
        XCTAssertEqual(e.status.phase, .locked)
        portal.settings.revision += 1
        portal.settings.releasedAt = local(2026, 3, 2, 23, 0, 30)
        h.jump(60)
        XCTAssertEqual(h.pumpPortal(portal), ["settings", "checkin"])
        XCTAssertEqual(e.status.phase, .normal)
        XCTAssertEqual(portal.checkIns.last?.phase, "normal")
        XCTAssertEqual(e.status.nextTransition, local(2026, 3, 3, 22, 30), "tomorrow's window still locks")
    }

    func testFollowingTheSchoolUsesTheProfileAndReportsIt() throws {
        // 22:00 Monday: the profile (21:30) says locked.
        let h = Harness(at: local(2026, 3, 2, 22, 0), config: Harness.portalConfig())
        let portal = FakePortal()
        portal.settings = PortalAPI.SettingsPayload(revision: 1_000, enabled: true)
        let e = try h.startRegistered(portal)
        XCTAssertEqual(e.status.phase, .locked, "IT's schedule")
        XCTAssertEqual(e.status.portal?.settingsSource, "portal", "registered, following the school")
        let c = try XCTUnwrap(portal.checkIns.last)
        XCTAssertEqual(c.profileSchedules?.map(\.name), ["School night"])
        XCTAssertEqual(c.schedules.map(\.name), ["School night"])

        // Lock-down and release still work without customising anything.
        portal.settings.revision += 1
        portal.settings.releasedAt = local(2026, 3, 2, 22, 0, 30)
        h.jump(60)
        h.pumpPortal(portal)
        XCTAssertEqual(e.status.phase, .normal, "released the school's window")
    }

    func testPortalRemovedFromProfile() throws {
        let h = Harness(at: local(2026, 3, 2, 22, 0), config: Harness.portalConfig())
        let e = try h.startRegistered(FakePortal())
        h.source.raw = RawConfig(values: configDict(), source: .managed)
        h.run(5)
        XCTAssertEqual(e.status.phase, .locked)
        XCTAssertNil(e.status.portal)
        XCTAssertNil(e.nextPortalRequest())
    }
}

/// Request building and response mapping, with no network.
final class PortalClientTests: XCTestCase {
    let base = URL(string: "https://lull.example.edu.au/lull")!
    let checkIn = PortalAPI.CheckIn.make(
        status: DaemonStatus(
            debugBuild: false, generatedAt: Date(), generatedAtContinuous: 0, bootSessionUUID: "b", phase: .normal,
            time: .init(status: .synced)),
        config: nil, settingsRevision: nil, settingsError: nil)

    func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: base, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testRequestsKeepThePathPrefixAndCarryTheToken() throws {
        let get = try PortalClient.urlRequest(for: .fetchSettings(token: "t", etag: "\"5\""), baseURL: base)
        XCTAssertEqual(get.url?.absoluteString, "https://lull.example.edu.au/lull/api/device/v1/settings")
        XCTAssertEqual(get.httpMethod, "GET")
        XCTAssertEqual(get.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(get.value(forHTTPHeaderField: "If-None-Match"), "\"5\"")
        XCTAssertNil(get.httpBody)

        let reg = try PortalClient.urlRequest(
            for: .register(.init(serialNumber: "S", hardwareUUID: "H", enrolmentSecret: "x")), baseURL: URL(string: "https://h/")!)
        XCTAssertEqual(reg.url?.absoluteString, "https://h/api/device/v1/register")
        XCTAssertNil(reg.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(reg.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let post = try PortalClient.urlRequest(for: .checkIn(token: "t", checkIn), baseURL: base)
        XCTAssertEqual(post.httpMethod, "POST")
        let body = try PortalAPI.decoder().decode(PortalAPI.CheckIn.self, from: XCTUnwrap(post.httpBody))
        XCTAssertEqual(body.phase, "normal")
    }

    func testOutcomes() throws {
        let settings = try Data(contentsOf: RemoteSettingsFixtures.url("settings.json"))
        let register = try Data(contentsOf: RemoteSettingsFixtures.url("register-response.json"))
        let fetch = PortalRequest.fetchSettings(token: "t", etag: nil)
        let reg = PortalRequest.register(.init(serialNumber: "S", hardwareUUID: "H", enrolmentSecret: "x"))

        guard
            case .settings(let p, let etag) = PortalClient.outcome(
                for: fetch, response: response(200, headers: ["ETag": "\"7\""]), data: settings)
        else { return XCTFail("expected settings") }
        XCTAssertEqual(p.revision, 1_760_000_000_000)
        XCTAssertEqual(etag, "\"7\"")
        XCTAssertEqual(PortalClient.outcome(for: fetch, response: response(304), data: Data()), .notModified)
        XCTAssertEqual(PortalClient.outcome(for: fetch, response: response(401), data: Data()), .unauthorized)
        XCTAssertEqual(PortalClient.outcome(for: fetch, response: response(302), data: Data()), .failed("settings: HTTP 302"))
        XCTAssertEqual(
            PortalClient.outcome(for: fetch, response: response(200), data: Data("<html>".utf8)),
            .failed("settings: unexpected response body"))
        XCTAssertEqual(
            PortalClient.outcome(for: reg, response: response(200), data: register),
            .registered(.init(deviceId: "3f1d2c9e-8a4b-4f7e-9d61-2b5a7c8e9f00", deviceToken: "example-device-token")))
        XCTAssertEqual(PortalClient.outcome(for: reg, response: response(409), data: Data()), .conflict)
        XCTAssertEqual(PortalClient.outcome(for: fetch, response: response(410), data: Data()), .deregistered)
        XCTAssertEqual(PortalClient.outcome(for: .checkIn(token: "t", checkIn), response: response(410), data: Data()), .deregistered)
        XCTAssertEqual(PortalClient.outcome(for: .checkIn(token: "t", checkIn), response: response(204), data: Data()), .checkedIn)
    }

    func testTransportErrorsAreDescribedWithoutDetail() {
        XCTAssertEqual(PortalClient.describe(URLError(.notConnectedToInternet)), "offline")
        XCTAssertTrue(PortalClient.describe(URLError(.serverCertificateUntrusted)).hasPrefix("TLS failed"))
    }

    func testPerformUsesTheTransport() {
        final class Recorder: PortalTransport {
            var sent: [URLRequest] = []
            func send(_ request: URLRequest, completion: @escaping (Result<(HTTPURLResponse, Data), Error>) -> Void) {
                sent.append(request)
                completion(.success((HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())))
            }
        }
        let t = Recorder()
        var result: PortalOutcome?
        PortalClient(transport: t).perform(.checkIn(token: "t", checkIn), baseURL: base) { result = $0 }
        XCTAssertEqual(result, .checkedIn)
        XCTAssertEqual(t.sent.count, 1)
    }
}

enum RemoteSettingsFixtures {
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/portal/\(name)")
    }
}

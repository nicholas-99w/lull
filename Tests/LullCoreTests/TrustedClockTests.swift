import XCTest

@testable import LullCore

final class TrustedClockTests: XCTestCase {
    let realNow = local(2026, 3, 2, 20, 0)

    func sample(_ unix: Date, at clock: FakeClock, rtt: TimeInterval = 0.05) -> TimeSyncSample {
        TimeSyncSample(
            unixTime: unix.timeIntervalSince1970, continuousSeconds: clock.continuousSeconds,
            roundTrip: rtt, server: "time.apple.com")
    }

    func makeSynced(_ clock: FakeClock, policy: OfflineBootPolicy = .forwardOnly) -> TrustedClock {
        var t = TrustedClock(clock: clock, persisted: nil, policy: policy, maxClockDriftSeconds: 30)
        XCTAssertNoThrow(try t.applySync(sample(realNow, at: clock), clock: clock).get())
        return t
    }

    // MARK: Wall clock tampering

    func testWallClockJumpsDoNotAffectTrustedTime() {
        let clock = FakeClock(wall: realNow)
        var t = makeSynced(clock)
        clock.advance(10)
        clock.setWall(realNow.addingTimeInterval(-3 * 3600))
        XCTAssertEqual(t.trustedNow(clock: clock), realNow.addingTimeInterval(10))
        let back = t.tick(clock: clock)
        XCTAssertNotNil(back)
        XCTAssertLessThan(back!.delta, -3 * 3600 + 1)

        clock.setWall(realNow.addingTimeInterval(5 * 3600))
        let fwd = t.tick(clock: clock)
        XCTAssertGreaterThan(fwd!.delta, 7 * 3600)
        XCTAssertEqual(t.lastTamperEvent, fwd)
        XCTAssertEqual(t.trustedNow(clock: clock), realNow.addingTimeInterval(10))
    }

    func testDriftThreshold() {
        let clock = FakeClock(wall: realNow)
        var t = makeSynced(clock)
        t.tick(clock: clock)
        clock.advance(1)
        clock.setWall(clock.wallNow.addingTimeInterval(30))
        XCTAssertNil(t.tick(clock: clock), "exactly at threshold is tolerated")
        clock.advance(1)
        clock.setWall(clock.wallNow.addingTimeInterval(30.5))
        XCTAssertNotNil(t.tick(clock: clock))
    }

    func testSleepIsNotTamper() {
        let clock = FakeClock(wall: realNow)
        var t = makeSynced(clock)
        t.tick(clock: clock)
        clock.advance(8 * 3600)  // lid closed overnight; continuous time keeps counting
        XCTAssertNil(t.tick(clock: clock))
        XCTAssertEqual(t.trustedNow(clock: clock), realNow.addingTimeInterval(8 * 3600))
    }

    // MARK: Restart and reboot

    func testDaemonRestartSameBootKeepsAnchor() {
        let clock = FakeClock(wall: realNow)
        let t = makeSynced(clock)
        clock.advance(60)
        let persisted = t.persistedState(clock: clock)
        clock.setWall(realNow.addingTimeInterval(-86_400))  // set the clock back, then kill the daemon
        let restarted = TrustedClock(clock: clock, persisted: persisted, policy: .forwardOnly, maxClockDriftSeconds: 30)
        XCTAssertEqual(restarted.trustedNow(clock: clock), realNow.addingTimeInterval(60))
        XCTAssertEqual(restarted.status, .synced)
        XCTAssertNotNil(restarted.lastSync)
    }

    func testOfflineRebootForwardOnlyNeverGoesBackwards() {
        let clock = FakeClock(wall: realNow)
        let t = makeSynced(clock)
        clock.advance(120)
        let persisted = t.persistedState(clock: clock)
        // Reboot offline with the wall clock wound back a day.
        clock.reboot(offFor: 60)
        clock.setWall(realNow.addingTimeInterval(-86_400))
        let after = TrustedClock(clock: clock, persisted: persisted, policy: .forwardOnly, maxClockDriftSeconds: 30)
        XCTAssertEqual(after.trustedNow(clock: clock), realNow.addingTimeInterval(120))
        XCTAssertEqual(after.status, .provisional)
        XCTAssertNil(after.lastSync)
    }

    func testOfflineRebootForwardOnlyAcceptsForwardWallClock() {
        let clock = FakeClock(wall: realNow)
        let persisted = makeSynced(clock).persistedState(clock: clock)
        clock.reboot(offFor: 3600)
        let after = TrustedClock(clock: clock, persisted: persisted, policy: .forwardOnly, maxClockDriftSeconds: 30)
        XCTAssertEqual(after.trustedNow(clock: clock), realNow.addingTimeInterval(3600))
    }

    func testOfflineRebootLockUntilSynced() {
        let clock = FakeClock(wall: realNow)
        let persisted = makeSynced(clock).persistedState(clock: clock)
        clock.reboot(offFor: 60)
        var after = TrustedClock(clock: clock, persisted: persisted, policy: .lockUntilSynced, maxClockDriftSeconds: 30)
        XCTAssertEqual(after.status, .awaitingSync)
        XCTAssertNoThrow(try after.applySync(sample(realNow.addingTimeInterval(60), at: clock), clock: clock).get())
        XCTAssertEqual(after.status, .synced)
    }

    func testFirstEverBootUsesWallClock() {
        let clock = FakeClock(wall: realNow)
        let t = TrustedClock(clock: clock, persisted: nil, policy: .forwardOnly, maxClockDriftSeconds: 30)
        XCTAssertEqual(t.trustedNow(clock: clock), realNow)
        XCTAssertEqual(t.status, .provisional)
    }

    func testMissingBootUUIDTreatedAsNewBoot() {
        let clock = FakeClock(wall: realNow, boot: "")
        let persisted = makeSynced(clock).persistedState(clock: clock)
        clock.setWall(realNow.addingTimeInterval(-3600))
        let t = TrustedClock(clock: clock, persisted: persisted, policy: .forwardOnly, maxClockDriftSeconds: 30)
        XCTAssertEqual(t.status, .provisional)
        XCTAssertEqual(t.trustedNow(clock: clock), realNow, "still never backwards")
    }

    // MARK: Sync

    func testAuthenticatedSyncCorrectsProvisionalTimeEvenBackwards() {
        let clock = FakeClock(wall: realNow.addingTimeInterval(7200))  // RTC fast by 2h
        var t = TrustedClock(clock: clock, persisted: nil, policy: .forwardOnly, maxClockDriftSeconds: 30)
        XCTAssertEqual(t.trustedNow(clock: clock), realNow.addingTimeInterval(7200))
        var s = sample(realNow, at: clock)
        // Unauthenticated SNTP can't make a 2h correction...
        XCTAssertEqual(
            t.applySync(s, clock: clock), .failure(.implausibleCorrection(correction: -7200, allowed: TrustedClock.bootEstimateAllowance)))
        XCTAssertEqual(t.status, .provisional)
        // ...the TLS-authenticated HTTPS source can.
        s.authenticated = true
        XCTAssertNoThrow(try t.applySync(s, clock: clock).get())
        XCTAssertEqual(t.trustedNow(clock: clock), realNow)
        XCTAssertEqual(t.lastSync, realNow)
    }

    /// A spoofed time server (e.g. a home router answering for time.apple.com)
    /// tries to jump trusted time past the end of a lock window.
    func testSpoofedSNTPJumpIsRejectedAfterASync() {
        let clock = FakeClock(wall: realNow)
        var t = makeSynced(clock)
        clock.advance(3600)
        for jump: TimeInterval in [9 * 3600, -3 * 3600, 60] {
            let result = t.applySync(sample(realNow.addingTimeInterval(3600 + jump), at: clock), clock: clock)
            guard case .failure(.implausibleCorrection) = result else { return XCTFail("jump \(jump) accepted") }
        }
        XCTAssertEqual(t.trustedNow(clock: clock), realNow.addingTimeInterval(3600), "unchanged")
    }

    func testRealisticDriftIsAccepted() {
        let clock = FakeClock(wall: realNow)
        var t = makeSynced(clock)
        clock.advance(3600)
        // 1s + 200 ppm of an hour = 1.72s allowed; 1.5s of drift is fine.
        let allowed = t.unauthenticatedAllowance(clock: clock)
        XCTAssertEqual(allowed, 1 + 0.0002 * 3600, accuracy: 1e-9)
        XCTAssertNoThrow(try t.applySync(sample(realNow.addingTimeInterval(3600 + 1.5), at: clock), clock: clock).get())
        // After a day without sync (offline), ~18s of drift is still plausible.
        clock.advance(86_400)
        XCTAssertNoThrow(try t.applySync(sample(realNow.addingTimeInterval(3600 + 86_400 + 1.5 + 15), at: clock), clock: clock).get())
    }

    func testOfflineBootAllowsMinutesNotHours() {
        let clock = FakeClock(wall: realNow)
        let persisted = makeSynced(clock).persistedState(clock: clock)
        clock.reboot(offFor: 3600)
        var t = TrustedClock(clock: clock, persisted: persisted, policy: .lockUntilSynced, maxClockDriftSeconds: 30)
        // RTC 90 s off: fine to correct from SNTP, releases LockUntilSynced.
        XCTAssertNoThrow(try t.applySync(sample(realNow.addingTimeInterval(3600 + 90), at: clock), clock: clock).get())
        XCTAssertEqual(t.status, .synced)

        clock.reboot(offFor: 60, boot: "boot-C")
        var t2 = TrustedClock(clock: clock, persisted: t.persistedState(clock: clock), policy: .lockUntilSynced, maxClockDriftSeconds: 30)
        guard case .failure(.implausibleCorrection) = t2.applySync(sample(realNow.addingTimeInterval(12 * 3600), at: clock), clock: clock)
        else { return XCTFail("12h SNTP jump after boot accepted") }
        XCTAssertEqual(t2.status, .awaitingSync, "stays locked until an authenticated sync confirms")
    }

    func testHTTPDateSamplesAreAuthenticated() throws {
        let s = try XCTUnwrap(HTTPDateHeader.sample(header: "Mon, 02 Mar 2026 09:00:00 GMT", sentAt: 1, receivedAt: 1.2, server: "x"))
        XCTAssertTrue(s.authenticated)
        XCTAssertFalse(
            try SNTPPacket.parseResponse(
                SNTPTests().reply(receive: 1_772_442_000, transmit: 1_772_442_000), nonce: SNTPTests().nonce, sentAt: 100,
                receivedAt: 100.1, server: "x"
            ).get().authenticated)
    }

    func testSyncRejections() {
        let clock = FakeClock(wall: realNow)
        var t = TrustedClock(clock: clock, persisted: nil, policy: .forwardOnly, maxClockDriftSeconds: 30)
        let before = t.anchor
        XCTAssertEqual(t.applySync(sample(realNow, at: clock, rtt: 6), clock: clock), .failure(.roundTripTooLong(6)))
        XCTAssertEqual(
            t.applySync(sample(Date(timeIntervalSince1970: 0), at: clock), clock: clock),
            .failure(.outOfSaneRange(0)))
        var stale = sample(realNow, at: clock)
        stale.continuousSeconds -= 120
        XCTAssertEqual(t.applySync(stale, clock: clock), .failure(.staleSample))
        XCTAssertEqual(t.anchor, before, "rejected samples leave the anchor alone")
        XCTAssertEqual(t.status, .provisional)
    }

    func testSystemClockSourceSmoke() {
        let s = SystemClockSource()
        let a = s.continuousSeconds
        XCTAssertGreaterThan(a, 0)
        XCTAssertGreaterThanOrEqual(s.continuousSeconds, a)
        XCTAssertFalse(s.bootSessionUUID.isEmpty)
        XCTAssertEqual(s.bootSessionUUID, s.bootSessionUUID)
    }
}

final class SNTPTests: XCTestCase {
    let nonce: UInt64 = 0x0123_4567_89AB_CDEF

    func reply(
        stratum: UInt8 = 2, leap: UInt8 = 0, version: UInt8 = 4, mode: UInt8 = 4,
        originate: UInt64? = nil, receive: TimeInterval, transmit: TimeInterval
    ) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 48)
        p[0] = (leap << 6) | (version << 3) | mode
        p[1] = stratum
        SNTPPacket.write64(originate ?? nonce, into: &p, at: 24)
        SNTPPacket.write64(SNTPPacket.ntpTimestamp(fromUnix: receive), into: &p, at: 32)
        SNTPPacket.write64(SNTPPacket.ntpTimestamp(fromUnix: transmit), into: &p, at: 40)
        return p
    }

    func testRequestLayout() {
        let r = SNTPPacket.request(nonce: nonce)
        XCTAssertEqual(r.count, 48)
        XCTAssertEqual(r[0], 0x23)  // LI 0, VN 4, mode 3
        XCTAssertEqual(SNTPPacket.read64(r, at: 40), nonce)
        XCTAssertTrue(r[1..<40].allSatisfy { $0 == 0 }, "no local clock leaked")
    }

    func testParsesAndCorrectsForDelay() throws {
        let server: TimeInterval = 1_772_442_000  // 2026-03-02
        // 0.2s on the wire in total, server held it for 0.05s.
        let p = reply(receive: server, transmit: server + 0.05)
        let s = try SNTPPacket.parseResponse(p, nonce: nonce, sentAt: 100, receivedAt: 100.25, server: "x").get()
        XCTAssertEqual(s.roundTrip, 0.2, accuracy: 1e-6)
        XCTAssertEqual(s.unixTime, server + 0.05 + 0.1, accuracy: 1e-6)
        XCTAssertEqual(s.continuousSeconds, 100.25)
    }

    func testRejectsBadReplies() {
        let t: TimeInterval = 1_772_442_000
        func parse(_ p: [UInt8], received: TimeInterval = 100.1) -> SNTPPacket.ValidationError? {
            if case .failure(let e) = SNTPPacket.parseResponse(p, nonce: nonce, sentAt: 100, receivedAt: received, server: "x") {
                return e
            }
            return nil
        }
        XCTAssertEqual(parse(Array(repeating: 0, count: 20)), .wrongSize(20))
        XCTAssertEqual(parse(reply(mode: 3, receive: t, transmit: t)), .notServerMode(3))
        XCTAssertEqual(parse(reply(version: 2, receive: t, transmit: t)), .unsupportedVersion(2))
        XCTAssertEqual(parse(reply(leap: 3, receive: t, transmit: t)), .unsynchronized)
        XCTAssertEqual(parse(reply(stratum: 0, receive: t, transmit: t)), .badStratum(0))  // kiss-o'-death
        XCTAssertEqual(parse(reply(stratum: 16, receive: t, transmit: t)), .badStratum(16))
        XCTAssertEqual(parse(reply(originate: 42, receive: t, transmit: t)), .originateMismatch)
        XCTAssertEqual(parse(reply(receive: t, transmit: t), received: 107), .roundTripTooLong(7))
        if case .negativeDelay = parse(reply(receive: t, transmit: t + 1)) {} else { XCTFail("expected negative delay") }
    }

    func testNTPEraRollover() {
        // 2036-02-07T06:28:16Z is where NTP era 0 wraps; 2040 must still decode correctly.
        let y2040: TimeInterval = 2_208_988_800
        let raw = SNTPPacket.ntpTimestamp(fromUnix: y2040)
        XCTAssertEqual(SNTPPacket.unixTime(fromNTP: raw), y2040, accuracy: 1e-6)
        let y2026: TimeInterval = 1_772_442_000.5
        XCTAssertEqual(SNTPPacket.unixTime(fromNTP: SNTPPacket.ntpTimestamp(fromUnix: y2026)), y2026, accuracy: 1e-6)
    }

    func testHTTPDateHeader() throws {
        let d = try XCTUnwrap(HTTPDateHeader.parse("Mon, 02 Mar 2026 09:00:00 GMT"))
        XCTAssertEqual(d, local(2026, 3, 2, 20, 0))
        XCTAssertNil(HTTPDateHeader.parse("Monday, 02-Mar-26 09:00:00 GMT"))
        XCTAssertNil(HTTPDateHeader.parse("garbage"))
        let s = try XCTUnwrap(
            HTTPDateHeader.sample(
                header: "Mon, 02 Mar 2026 09:00:00 GMT",
                sentAt: 10, receivedAt: 10.4, server: "x"))
        XCTAssertEqual(s.unixTime, d.timeIntervalSince1970 + 0.7, accuracy: 1e-6)
        XCTAssertEqual(s.roundTrip, 0.4, accuracy: 1e-6)
    }
}

import LullCore
import XCTest

@testable import LullDaemonKit

final class FilesAndLogTests: XCTestCase {
    func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1
    }

    func testStateStoreRoundTripAndPermissions() throws {
        let dir = makeTempDir()
        let paths = DaemonPaths(stateDirectory: dir + "/db", logDirectory: dir + "/log", requiredOwnerUID: getuid())
        let store = JSONStateStore(paths: paths)
        XCTAssertNil(try store.load().get())

        var state = PersistentState()
        state.lastValidTimeZone = "Australia/Sydney"
        state.snooze = SnoozeLedger(windowStart: Date(timeIntervalSince1970: 1_800_000_000), count: 1, delaySeconds: 600)
        try store.save(state)
        XCTAssertEqual(try store.load().get(), state)
        XCTAssertEqual(mode(paths.statePath), 0o600)
        XCTAssertEqual(mode(paths.stateDirectory), 0o755)

        let status = DaemonStatus(
            debugBuild: true, generatedAt: Date(timeIntervalSince1970: 1_800_000_000), generatedAtContinuous: 5,
            bootSessionUUID: "b", phase: .normal, time: .init(status: .synced))
        try store.writeStatus(status)
        XCTAssertEqual(mode(paths.statusPath), 0o644)
        let decoded = try DaemonStatus.decoder().decode(DaemonStatus.self, from: Data(contentsOf: URL(fileURLWithPath: paths.statusPath)))
        XCTAssertEqual(decoded, status)
    }

    func testCorruptStateReportsError() throws {
        let dir = makeTempDir()
        let paths = DaemonPaths(stateDirectory: dir, logDirectory: dir, requiredOwnerUID: getuid())
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: paths.statePath))
        XCTAssertThrowsError(try JSONStateStore(paths: paths).load().get())

        // The engine starts fresh and logs it rather than crashing.
        let log = MemoryEventLog()
        let clock = FakeClock(wall: local(2026, 3, 2, 12))
        _ = DaemonEngine(
            .init(clock: clock, configSource: StaticConfigSource(configDict()), store: JSONStateStore(paths: paths), log: log, paths: paths)
        )
        XCTAssertTrue(log.names().contains("state_unreadable"))
    }

    func testReadTrustedRejectsUnsafeFiles() throws {
        let dir = makeTempDir()
        let path = dir + "/secret.json"
        XCTAssertEqual(try SecureFile.readTrusted(path, owner: getuid()).get(), nil, "missing is fine")

        try SecureFile.writeAtomically(Data("x".utf8), to: path, mode: 0o600)
        XCTAssertEqual(try SecureFile.readTrusted(path, owner: getuid()).get(), Data("x".utf8))

        chmod(path, 0o640)
        XCTAssertThrowsError(try SecureFile.readTrusted(path, owner: getuid()).get())
        chmod(path, 0o600)
        XCTAssertThrowsError(try SecureFile.readTrusted(path, owner: getuid() + 1).get(), "wrong owner")

        let link = dir + "/link.json"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        XCTAssertThrowsError(try SecureFile.readTrusted(link, owner: getuid()).get(), "symlinks refused")
    }

    func testOverrideHashFileRoundTripAndErrors() throws {
        let dir = makeTempDir()
        let path = dir + "/override.json"
        try OverrideHashFile.write(testHash, path: path)
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(try OverrideHashFile.load(path: path, owner: getuid()).get(), testHash)

        try SecureFile.writeAtomically(Data(#"{"OverridePasswordHash": "pbkdf2-sha256$10$AAAA$BBBB"}"#.utf8), to: path, mode: 0o600)
        guard case .failure(.badHash(.tooFewIterations(10))) = OverrideHashFile.load(path: path, owner: getuid()) else {
            return XCTFail("expected tooFewIterations")
        }
        try SecureFile.writeAtomically(Data("[]".utf8), to: path, mode: 0o600)
        XCTAssertEqual(OverrideHashFile.load(path: path, owner: getuid()), .failure(.malformed))
    }

    func testJSONLinesLogAndRotation() throws {
        let dir = makeTempDir()
        let path = dir + "/log/lulld.log"
        let log = JSONLinesEventLog(path: path, maxBytes: 400, keep: 2)
        log.event(
            "phase_transition", category: .schedule, fields: ["from": "normal", "to": "locked", "at": Date(timeIntervalSince1970: 0)])
        let line = try String(contentsOfFile: path).split(separator: "\n").first.map(String.init) ?? ""
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["event"] as? String, "phase_transition")
        XCTAssertEqual(obj?["category"] as? String, "schedule")
        XCTAssertEqual(obj?["to"] as? String, "locked")
        XCTAssertEqual(obj?["at"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertNotNil(obj?["wall"])

        for i in 0..<30 { log.event("tick", category: .time, fields: ["i": i]) }
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: path + ".1"))
        XCTAssertTrue(fm.fileExists(atPath: path + ".2"))
        XCTAssertFalse(fm.fileExists(atPath: path + ".3"), "keeps only 2")
        XCTAssertLessThanOrEqual(try fm.attributesOfItem(atPath: path)[.size] as! Int, 400)
    }

    func testExemptionPolicy() {
        var c = LullConfig()
        c.exemptUsernames = ["ITAdmin"]
        XCTAssertTrue(ExemptionPolicy.isExempt(username: "itadmin", isAdmin: false, config: c))
        XCTAssertTrue(ExemptionPolicy.isExempt(username: "teacher", isAdmin: true, config: c))
        XCTAssertFalse(ExemptionPolicy.isExempt(username: "student", isAdmin: false, config: c))
        c.exemptAdminUsers = false
        XCTAssertFalse(ExemptionPolicy.isExempt(username: "teacher", isAdmin: true, config: c))
    }
}

/// Talks to real time servers. Opt-in so `make test` stays offline-safe:
/// `LULL_NETWORK_TESTS=1 swift test --filter NetworkTimeSyncTests`
final class NetworkTimeSyncTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LULL_NETWORK_TESTS"] == "1", "set LULL_NETWORK_TESTS=1")
    }

    func sync(_ servers: [String], https: [URL] = [], preferAuthenticated: Bool = false) -> Result<TimeSyncSample, TimeSyncError> {
        let clock = SystemClockSource()
        let syncer = NetworkTimeSync(clock: clock, httpsFallbackURLs: https)
        let done = expectation(description: "sync")
        var result: Result<TimeSyncSample, TimeSyncError>!
        syncer.sync(servers: servers, preferAuthenticated: preferAuthenticated) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return result
    }

    func testSNTPAgainstAppleAgreesWithSystemClock() throws {
        let s = try sync(["time.apple.com"]).get()
        print("SNTP \(s.server): rtt \(s.roundTrip)s, offset vs wall \(s.unixTime - Date().timeIntervalSince1970)s")
        XCTAssertEqual(s.unixTime, Date().timeIntervalSince1970, accuracy: 5)
    }

    func testHTTPSFallbackWhenSNTPFails() throws {
        let s = try sync(["unresolvable.invalid"], https: [URL(string: "https://www.apple.com/")!]).get()
        print("HTTPS \(s.server): rtt \(s.roundTrip)s, offset vs wall \(s.unixTime - Date().timeIntervalSince1970)s")
        XCTAssertEqual(s.unixTime, Date().timeIntervalSince1970, accuracy: 5)
    }

    func testPreferAuthenticatedUsesHTTPSFirst() throws {
        let s = try sync(["time.apple.com"], https: [URL(string: "https://www.apple.com/")!], preferAuthenticated: true).get()
        XCTAssertTrue(s.authenticated)
        XCTAssertTrue(s.server.hasPrefix("https://"))
        XCTAssertEqual(s.unixTime, Date().timeIntervalSince1970, accuracy: 5)
    }

    func testAllFailIsAnError() {
        guard case .failure(let e) = sync(["unresolvable.invalid"]) else { return XCTFail("expected failure") }
        XCTAssertTrue(e.description.contains("unresolvable.invalid"))
    }
}

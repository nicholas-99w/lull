import LullCore
import XCTest

@testable import LullDaemonKit

final class DaemonEngineTests: XCTestCase {

    // MARK: Config lifecycle

    func testNeverLocksWithoutEverHavingValidConfig() {
        let h = Harness(at: local(2026, 3, 2, 22, 0), config: nil)
        let e = h.start()
        XCTAssertEqual(e.status.phase, .disabled)
        XCTAssertEqual(e.status.phaseReason, "no valid configuration")
        XCTAssertEqual(e.status.config.source, "none")
        XCTAssertTrue(h.log.names().contains("config_missing"))

        h.source.raw = RawConfig(values: ["Timezone": "Australia/Sydney"], source: .managed)  // invalid: no Schedules
        h.run(6)
        XCTAssertEqual(e.status.phase, .disabled)
        XCTAssertFalse(e.status.config.currentValid)
    }

    func testLocksOnScheduleAndLogsTransitions() {
        let h = Harness(at: local(2026, 3, 2, 21, 14, 50))
        let e = h.start()
        XCTAssertEqual(e.status.phase, .normal)
        h.run(10)
        XCTAssertEqual(e.status.phase, .warning)
        XCTAssertEqual(e.status.nextTransition, local(2026, 3, 2, 21, 30))
        h.jump(15 * 60)
        XCTAssertEqual(e.status.phase, .locked)
        XCTAssertEqual(e.status.nextTransition, local(2026, 3, 3, 6, 30))
        XCTAssertEqual(e.status.scheduleName, "School night")

        let transitions = h.log.entries.filter { $0.name == "phase_transition" }.map { $0.fields["to"] as? String }
        XCTAssertEqual(transitions, ["normal", "warning", "locked"])
        XCTAssertTrue(h.log.names().contains("config_loaded"))
    }

    func testInvalidConfigKeepsLastValidAndLogsOnce() {
        let h = Harness(at: local(2026, 3, 2, 22, 0))
        let e = h.start()
        XCTAssertEqual(e.status.phase, .locked)

        h.source.raw = RawConfig(values: configDict(["Schedules": [["Days": ["Mon"], "Start": "nope", "End": "06:00"]]]), source: .managed)
        h.run(30)  // several polls
        XCTAssertEqual(e.status.phase, .locked, "still enforcing last valid config")
        XCTAssertFalse(e.status.config.currentValid)
        XCTAssertTrue(e.status.config.usingLastValid)
        XCTAssertEqual(e.status.config.errors, ["error: Schedules[0].Start: required, format HH:mm"])
        XCTAssertEqual(h.log.names().filter { $0 == "config_rejected" }.count, 1)
    }

    func testHotReloadPicksUpChangesWithinFiveSeconds() {
        let h = Harness(at: local(2026, 3, 2, 22, 0))
        let e = h.start()
        XCTAssertEqual(e.status.phase, .locked)
        h.source.raw = RawConfig(values: configDict(["Enabled": false]), source: .managed)
        h.run(5)
        XCTAssertEqual(e.status.phase, .disabled)
        XCTAssertEqual(h.log.names().filter { $0 == "config_loaded" }.count, 2)
    }

    func testRestartWithBrokenProfileUsesPersistedConfigWithoutHash() throws {
        let store = MemoryStore()
        let h1 = Harness(at: local(2026, 3, 2, 22, 0), config: configDict(["OverridePasswordHash": testHash.encoded]), store: store)
        h1.start()
        let persisted = try XCTUnwrap(store.state?.lastValidConfig)
        XCTAssertNil(persisted.overridePasswordHash, "secrets aren't copied into state.json")
        XCTAssertEqual(store.state?.lastValidTimeZone, "Australia/Sydney")

        let h2 = Harness(at: local(2026, 3, 2, 22, 5), config: ["Schedules": "garbage"], store: store)
        let e2 = h2.start()
        XCTAssertEqual(e2.status.phase, .locked)
        XCTAssertTrue(e2.status.config.usingLastValid)
    }

    func testDroppedUnforcedKeysAreReported() {
        let h = Harness()
        h.source.raw = RawConfig(values: configDict(), source: .managed, ignoredUnforcedKeys: ["Enabled"])
        let e = h.start()
        XCTAssertEqual(e.status.config.ignoredUnforcedKeys, ["Enabled"])
    }

    // MARK: Trusted time

    func testWallClockChangeDoesNotUnlock() {
        let h = Harness(at: local(2026, 3, 2, 22, 0))
        let e = h.start()
        h.syncOK(at: local(2026, 3, 2, 22, 0))
        XCTAssertEqual(e.status.phase, .locked)
        // Student (or a careless admin) sets the clock to mid-afternoon.
        h.clock.wallNow = local(2026, 3, 2, 14, 0)
        h.run(2)
        XCTAssertEqual(e.status.phase, .locked)
        XCTAssertTrue(h.log.names().contains("clock_tamper"))
        XCTAssertNotNil(e.status.time.lastTamper)
        XCTAssertEqual(e.status.time.wallClockOffsetSeconds, -8 * 3600, accuracy: 1)
    }

    func testOfflineRebootLockUntilSynced() {
        let store = MemoryStore()
        let h1 = Harness(at: local(2026, 3, 2, 12, 0), config: configDict(["OfflineBootPolicy": "LockUntilSynced"]), store: store)
        h1.start()
        h1.syncOK(at: local(2026, 3, 2, 12, 0))
        h1.engine.shutdown()

        let h2 = Harness(at: local(2026, 3, 2, 12, 10), config: configDict(["OfflineBootPolicy": "LockUntilSynced"]), store: store)
        h2.clock.reboot(offFor: 0)
        let e2 = h2.start()
        XCTAssertEqual(e2.status.phase, .locked)
        XCTAssertEqual(e2.status.time.status, .awaitingSync)
        XCTAssertTrue(e2.status.phaseReason?.contains("awaiting time sync") ?? false)

        h2.syncOK(at: local(2026, 3, 2, 12, 10))
        XCTAssertEqual(e2.status.phase, .normal)
        XCTAssertEqual(e2.status.time.status, .synced)
    }

    func testOfflineRebootForwardOnlyUsesLastKnownTrusted() {
        let store = MemoryStore()
        let h1 = Harness(at: local(2026, 3, 2, 21, 0), store: store)
        h1.start()
        h1.syncOK(at: local(2026, 3, 2, 21, 0))
        h1.jump(60 * 60)  // 22:00, locked
        h1.engine.shutdown()

        // Reboot offline with the RTC wound back to the afternoon.
        let h2 = Harness(at: local(2026, 3, 2, 15, 0), store: store)
        h2.clock.reboot(offFor: 0)
        let e2 = h2.start()
        XCTAssertEqual(e2.status.phase, .locked)
        XCTAssertEqual(e2.status.time.status, .provisional)
    }

    func testSyncScheduling() {
        let h = Harness()
        let e = h.start()
        XCTAssertTrue(e.syncDue, "sync immediately at start")
        e.syncStarted()
        XCTAssertFalse(e.syncDue, "one at a time")
        e.syncFinished(.failure(TimeSyncError("offline")))
        XCTAssertEqual(e.status.time.lastSyncError, "offline")
        XCTAssertFalse(e.syncDue)
        h.run(60)
        XCTAssertTrue(e.syncDue, "retry after a minute")
        h.syncOK(at: h.clock.wallNow)
        XCTAssertNil(e.status.time.lastSyncError)
        h.jump(59 * 60)
        XCTAssertFalse(e.syncDue)
        h.jump(60)
        XCTAssertTrue(e.syncDue, "TimeSyncIntervalMinutes default 60")
    }

    /// Spoofed SNTP while locked: rejected, logged, and the next sync goes to
    /// HTTPS first and at once; the lock never drops.
    func testSpoofedTimeServerCantUnlock() {
        let h = Harness(at: local(2026, 3, 2, 22, 0))
        let e = h.start()
        h.syncOK(at: local(2026, 3, 2, 22, 0))
        h.run(5)
        XCTAssertEqual(e.status.phase, .locked)
        e.syncStarted()
        e.syncFinished(
            .success(
                TimeSyncSample(
                    unixTime: local(2026, 3, 3, 7, 0).timeIntervalSince1970, continuousSeconds: h.clock.continuousSeconds,
                    roundTrip: 0.05, server: "time.apple.com")))
        XCTAssertEqual(e.status.phase, .locked)
        XCTAssertTrue(h.log.names().contains("time_sync_suspicious"))
        XCTAssertTrue(e.syncPrefersAuthenticated)
        XCTAssertTrue(e.syncDue, "confirm via HTTPS immediately")

        // The HTTPS attempt also fails (blocked): retry after a minute, not in a loop.
        e.syncStarted()
        e.syncFinished(
            .success(
                TimeSyncSample(
                    unixTime: local(2026, 3, 3, 7, 0).timeIntervalSince1970, continuousSeconds: h.clock.continuousSeconds,
                    roundTrip: 0.05, server: "time.apple.com")))
        XCTAssertFalse(e.syncDue)
        h.run(60)
        XCTAssertTrue(e.syncDue)
        XCTAssertEqual(e.status.phase, .locked)

        // A genuine authenticated sync clears the flag.
        e.syncStarted()
        e.syncFinished(
            .success(
                TimeSyncSample(
                    unixTime: h.clock.wallNow.timeIntervalSince1970, continuousSeconds: h.clock.continuousSeconds, roundTrip: 0.1,
                    server: "https://www.apple.com", authenticated: true)))
        XCTAssertFalse(e.syncPrefersAuthenticated)
    }

    func testRejectedSyncSampleIsAFailure() {
        let h = Harness()
        let e = h.start()
        e.syncStarted()
        e.syncFinished(
            .success(TimeSyncSample(unixTime: 0, continuousSeconds: h.clock.continuousSeconds, roundTrip: 0.1, server: "bad")))
        XCTAssertEqual(e.status.time.status, .provisional)
        XCTAssertTrue(e.status.time.lastSyncError?.hasPrefix("bad:") ?? false)
    }

    // MARK: Snooze

    func testSnoozeFlow() {
        let h = Harness(at: local(2026, 3, 2, 21, 25), config: configDict(["SnoozeEnabled": true, "SnoozeMinutes": 10]))
        let e = h.start()
        XCTAssertEqual(e.status.phase, .warning)
        XCTAssertTrue(e.status.snoozeAvailable)
        XCTAssertTrue(e.requestSnooze())
        XCTAssertFalse(e.requestSnooze(), "MaxSnoozesPerWindow default 1")
        XCTAssertEqual(e.status.snoozesUsed, 1)
        XCTAssertEqual(h.store.state?.snooze?.count, 1, "persisted immediately")
        h.jump(6 * 60)  // 21:31
        XCTAssertEqual(e.status.phase, .warning)
        XCTAssertEqual(e.status.lockStart, local(2026, 3, 2, 21, 40))
        h.jump(9 * 60)  // 21:40
        XCTAssertEqual(e.status.phase, .locked)
        XCTAssertTrue(h.log.names().contains("snooze_used"))
        // Ledger is dropped once the window has ended.
        h.jump(9 * 3600)
        XCTAssertNil(e.state.snooze)
    }

    func testSnoozeRefusedWhenNotWarning() {
        let h = Harness(at: local(2026, 3, 2, 12, 0), config: configDict(["SnoozeEnabled": true]))
        XCTAssertFalse(h.start().requestSnooze())
    }

    // MARK: Override

    func testOverrideWithRootOnlyFile() throws {
        let h = Harness(at: local(2026, 3, 2, 22, 0))
        try h.writeOverrideFile()
        let e = h.start()
        XCTAssertEqual(e.status.override.hashSource, "file")
        XCTAssertTrue(e.status.override.enabled)

        XCTAssertEqual(e.attemptOverride(passphrase: "wrong"), .rejected(attemptsRemaining: 4))
        let result = e.attemptOverride(passphrase: testPassphrase)
        XCTAssertEqual(result, .granted(until: local(2026, 3, 2, 22, 30)))
        XCTAssertEqual(e.status.phase, .overridden)
        h.jump(30 * 60)
        XCTAssertEqual(e.status.phase, .locked, "override is time-boxed")

        // Nothing secret in the log.
        for entry in h.log.entries {
            let text = "\(entry.fields)"
            XCTAssertFalse(text.contains(testPassphrase))
            XCTAssertFalse(text.contains("wrong"))
            XCTAssertFalse(text.contains(testHash.hash.base64EncodedString()))
        }
    }

    func testOverrideFileWithLoosePermissionsIsIgnored() throws {
        let h = Harness(at: local(2026, 3, 2, 22, 0))
        try h.writeOverrideFile(mode: 0o644)
        let e = h.start()
        XCTAssertEqual(e.status.override.hashSource, "none")
        XCTAssertEqual(e.attemptOverride(passphrase: testPassphrase), .unavailable("no override passphrase configured"))
        XCTAssertTrue(h.log.names().contains("override_file_rejected"))
    }

    func testOverrideFallsBackToProfileHash() {
        let h = Harness(at: local(2026, 3, 2, 22, 0), config: configDict(["OverridePasswordHash": testHash.encoded]))
        let e = h.start()
        XCTAssertEqual(e.status.override.hashSource, "profile")
        XCTAssertEqual(e.attemptOverride(passphrase: testPassphrase), .granted(until: local(2026, 3, 2, 22, 30)))
    }

    func testOverrideLockoutSurvivesRestart() throws {
        let store = MemoryStore()
        let config = configDict(["OverrideMaxAttempts": 2, "OverrideLockoutMinutes": 15])
        let h = Harness(at: local(2026, 3, 2, 22, 0), config: config, store: store)
        try h.writeOverrideFile()
        let e = h.start()
        _ = e.attemptOverride(passphrase: "a")
        XCTAssertEqual(e.attemptOverride(passphrase: "b"), .lockedOut(until: local(2026, 3, 2, 22, 15)))

        // Kill and restart the daemon in the same boot: still locked out.
        let h2 = Harness(at: h.clock.wallNow, config: config, store: store)
        h2.clock.continuousSeconds = h.clock.continuousSeconds
        try h2.writeOverrideFile()
        let e2 = h2.start()
        XCTAssertEqual(e2.attemptOverride(passphrase: testPassphrase), .lockedOut(until: local(2026, 3, 2, 22, 15)))
        XCTAssertEqual(e2.status.override.lockedOutUntil, local(2026, 3, 2, 22, 15))
    }

    func testOverrideUnavailableWhenNotLockedOrDisabled() throws {
        let h = Harness(at: local(2026, 3, 2, 12, 0))
        try h.writeOverrideFile()
        XCTAssertEqual(h.start().attemptOverride(passphrase: testPassphrase), .unavailable("not locked"))

        let h2 = Harness(at: local(2026, 3, 2, 22, 0), config: configDict(["OverrideEnabled": false]))
        try h2.writeOverrideFile()
        XCTAssertEqual(h2.start().attemptOverride(passphrase: testPassphrase), .unavailable("override disabled"))
    }

    func testOverrideWorksWhileAwaitingSync() throws {
        let h = Harness(at: local(2026, 3, 2, 12, 0), config: configDict(["OfflineBootPolicy": "LockUntilSynced"]))
        try h.writeOverrideFile()
        let e = h.start()
        XCTAssertEqual(e.status.phase, .locked)
        XCTAssertEqual(e.attemptOverride(passphrase: testPassphrase), .granted(until: local(2026, 3, 2, 12, 30)))
        XCTAssertEqual(e.status.phase, .overridden)
    }

    // MARK: Persistence and status

    func testPersistsEveryMinuteAndOnShutdown() {
        let h = Harness()
        let e = h.start()
        let initial = h.store.saves
        h.run(59)
        XCTAssertEqual(h.store.saves, initial)
        h.run(2)
        XCTAssertEqual(h.store.saves, initial + 1)
        e.shutdown()
        XCTAssertEqual(h.store.saves, initial + 2)
        XCTAssertEqual(h.store.state?.time?.lastKnownTrusted ?? 0, h.clock.wallNow.timeIntervalSince1970, accuracy: 0.001)
    }

    func testStatusWrittenOnChangeNotEveryTick() {
        let h = Harness(at: local(2026, 3, 2, 12, 0))
        h.start()
        let initial = h.store.statuses.count
        h.run(10)
        XCTAssertEqual(h.store.statuses.count, initial, "nothing changed")
        h.run(25)
        XCTAssertEqual(h.store.statuses.count, initial + 1, "30s heartbeat")
        let s = h.store.statuses.last!
        XCTAssertEqual(
            s.trustedNow(continuousSeconds: s.generatedAtContinuous + 5, bootSessionUUID: "boot-A"),
            s.generatedAt.addingTimeInterval(5))
        XCTAssertNil(s.trustedNow(continuousSeconds: h.clock.continuousSeconds, bootSessionUUID: "other-boot"))
    }

    // MARK: Debug-only hatches

    #if DEBUG
        func testDisableFileForcesDisabled() throws {
            let h = Harness(at: local(2026, 3, 2, 22, 0))
            let e = h.start()
            XCTAssertEqual(e.status.phase, .locked)
            FileManager.default.createFile(atPath: h.paths.disableFlagPath, contents: nil)
            h.run(1)
            XCTAssertEqual(e.status.phase, .disabled)
            try FileManager.default.removeItem(atPath: h.paths.disableFlagPath)
            h.run(1)
            XCTAssertEqual(e.status.phase, .locked)
        }

        func testDebugAutoRelease() {
            let h = Harness(at: local(2026, 3, 2, 22, 0))
            let e = h.start()
            h.jump(599)
            XCTAssertEqual(e.status.phase, .locked)
            h.jump(1)
            XCTAssertEqual(e.status.phase, .disabled)
            XCTAssertTrue(e.status.phaseReason?.contains("auto-released") ?? false)
            h.jump(3600)
            XCTAssertEqual(e.status.phase, .disabled, "stays released for the rest of the window")
            h.jump(8 * 3600)  // next day 07:00: window over, counter resets
            XCTAssertEqual(e.status.phase, .normal)
        }

        func testDebugTimeOffset() {
            let h = Harness(at: local(2026, 3, 2, 12, 0))
            let e = h.start()
            e.debugTimeOffset = 10 * 3600  // pretend it's 22:00
            h.run(1)
            XCTAssertEqual(e.status.phase, .locked)
        }

        func testDevPlistSourceAndTimeOffsetKey() throws {
            let dir = makeTempDir()
            let path = dir + "/dev.plist"
            var dict = configDict()
            dict["DebugTimeOffsetSeconds"] = 3600
            XCTAssertTrue((dict as NSDictionary).write(toFile: path, atomically: true))
            let src = DebugConfigSource(devPlistPath: path, fallback: StaticConfigSource(nil))
            let raw = src.load()
            XCTAssertEqual(raw.source, .dev)
            XCTAssertEqual(raw.debugTimeOffset, 3600)
            XCTAssertNil(raw.values?["DebugTimeOffsetSeconds"], "not passed to the parser")

            let missing = DebugConfigSource(devPlistPath: dir + "/nope.plist", fallback: StaticConfigSource(configDict()))
            XCTAssertEqual(missing.load().source, .managed)
        }
    #endif
}

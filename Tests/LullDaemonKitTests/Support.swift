import Foundation
import LullCore

@testable import LullDaemonKit

let sydney = TimeZone(identifier: "Australia/Sydney")!

func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = sydney
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

final class FakeClock: ClockSource, @unchecked Sendable {
    var wallNow: Date
    var continuousSeconds: TimeInterval
    var bootSessionUUID: String

    init(wall: Date, continuous: TimeInterval = 1_000, boot: String = "boot-A") {
        wallNow = wall
        continuousSeconds = continuous
        bootSessionUUID = boot
    }

    func advance(_ seconds: TimeInterval) {
        wallNow = wallNow.addingTimeInterval(seconds)
        continuousSeconds += seconds
    }

    func reboot(offFor: TimeInterval, boot: String = "boot-B") {
        wallNow = wallNow.addingTimeInterval(offFor)
        continuousSeconds = 30
        bootSessionUUID = boot
    }
}

final class MemoryStore: StateStoring {
    var state: PersistentState?
    var statuses: [DaemonStatus] = []
    var saves = 0

    func load() -> Result<PersistentState?, Error> { .success(state) }
    func save(_ state: PersistentState) throws {
        self.state = state
        saves += 1
    }
    func writeStatus(_ status: DaemonStatus) throws { statuses.append(status) }
}

/// Daily 21:30-06:30 in Sydney.
func configDict(_ extra: [String: Any] = [:]) -> [String: Any] {
    [
        "Timezone": "Australia/Sydney",
        "Schedules": [
            ["Name": "School night", "Days": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], "Start": "21:30", "End": "06:30"]
        ],
    ].merging(extra) { $1 }
}

func makeTempDir() -> String {
    let dir = NSTemporaryDirectory() + "lull-tests-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

/// A real 600k-iteration hash, computed once for the whole test run.
let testPassphrase = "correct horse battery staple"
let testHash = PassphraseHasher.makeHash(passphrase: testPassphrase)!

struct FakeDevice: DeviceIdentifying {
    var value: (serialNumber: String, hardwareUUID: String)? = ("C02TEST00001", "6B29FC40-CA47-1067-B31D-00DD010662DA")
    func identity() -> (serialNumber: String, hardwareUUID: String)? { value }
}

/// Engine harness with fakes and a temp dir for override.json / DISABLE.
final class Harness {
    let clock: FakeClock
    var device = FakeDevice()
    let source: StaticConfigSource
    let store: MemoryStore
    let log = MemoryEventLog()
    let dir = makeTempDir()
    var engine: DaemonEngine!

    var paths: DaemonPaths {
        DaemonPaths(stateDirectory: dir, logDirectory: dir + "/log", managedPreferencesDirectory: dir + "/mp", requiredOwnerUID: getuid())
    }

    init(at wall: Date = local(2026, 3, 2, 20, 0), config: [String: Any]? = configDict(), store: MemoryStore = MemoryStore()) {
        clock = FakeClock(wall: wall)
        source = StaticConfigSource(config)
        self.store = store
    }

    @discardableResult
    func start() -> DaemonEngine {
        engine = DaemonEngine(.init(clock: clock, configSource: source, store: store, log: log, paths: paths, device: device))
        return engine
    }

    /// Advance real time in 1s ticks like lulld does.
    func run(_ seconds: Int) {
        for _ in 0..<seconds {
            clock.advance(1)
            engine.tick()
        }
    }

    /// Jump time forward without ticking every second (for long gaps).
    func jump(_ seconds: TimeInterval) {
        clock.advance(seconds)
        engine.tick()
    }

    func syncOK(at real: Date) {
        engine.syncStarted()
        engine.syncFinished(
            .success(
                TimeSyncSample(
                    unixTime: real.timeIntervalSince1970, continuousSeconds: clock.continuousSeconds, roundTrip: 0.05, server: "test")))
    }

    func writeOverrideFile(mode: mode_t = 0o600) throws {
        try OverrideHashFile.write(testHash, path: paths.overrideHashPath)
        chmod(paths.overrideHashPath, mode)
    }
}

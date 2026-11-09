import Foundation

@testable import LullCore

let sydney = TimeZone(identifier: "Australia/Sydney")!

/// Builds an absolute instant from a local wall time in `tz`.
func local(
    _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0,
    tz: TimeZone = sydney
) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

func time(_ s: String) -> TimeOfDay { TimeOfDay(string: s)! }

func date(_ s: String) -> LocalDate { LocalDate(string: s)! }

/// Config with one schedule and Sydney time; tweak via the closure.
func makeConfig(
    days: Set<Weekday> = Set(Weekday.allCases),
    start: String = "21:30", end: String = "06:30",
    name: String = "School night",
    _ tweak: (inout LullConfig) -> Void = { _ in }
) -> LullConfig {
    var c = LullConfig()
    c.timeZoneIdentifier = "Australia/Sydney"
    c.schedules = [ScheduleRule(name: name, days: days, start: time(start), end: time(end))]
    tweak(&c)
    return c
}

/// In-memory file system for image validation.
struct FakeFiles: FileInspecting {
    var sizes: [String: Int]
    func regularFileSize(atPath path: String) -> Int? { sizes[path] }
}

/// Controllable clock for trusted-time tests.
final class FakeClock: ClockSource, @unchecked Sendable {
    var wallNow: Date
    var continuousSeconds: TimeInterval
    var bootSessionUUID: String

    init(wall: Date, continuous: TimeInterval = 1_000, boot: String = "boot-A") {
        wallNow = wall
        continuousSeconds = continuous
        bootSessionUUID = boot
    }

    /// Real time passes (awake or asleep): both clocks move together.
    func advance(_ seconds: TimeInterval) {
        wallNow = wallNow.addingTimeInterval(seconds)
        continuousSeconds += seconds
    }

    /// Someone runs `sudo date`: only the wall clock moves.
    func setWall(_ date: Date) { wallNow = date }

    /// Reboot after `offFor` seconds powered off; continuous clock restarts.
    func reboot(offFor: TimeInterval, boot: String = "boot-B") {
        wallNow = wallNow.addingTimeInterval(offFor)
        continuousSeconds = 30
        bootSessionUUID = boot
    }
}

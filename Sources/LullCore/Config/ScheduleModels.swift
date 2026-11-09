import Foundation

/// Day of week. Raw values match `Calendar.component(.weekday, ...)` (Sunday = 1)
/// so no mapping is needed when walking dates in the configured time zone.
public enum Weekday: Int, CaseIterable, Codable, Sendable, Comparable {
    case sun = 1, mon, tue, wed, thu, fri, sat

    /// Parses the profile spelling (`Mon` ... `Sun`). Case-insensitive so a
    /// hand-typed `mon` in Jamf doesn't silently disable a schedule.
    public init?(configString: String) {
        switch configString.trimmingCharacters(in: .whitespaces).lowercased() {
        case "mon": self = .mon
        case "tue": self = .tue
        case "wed": self = .wed
        case "thu": self = .thu
        case "fri": self = .fri
        case "sat": self = .sat
        case "sun": self = .sun
        default: return nil
        }
    }

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Wall-clock time of day in the configured time zone, parsed from `"HH:mm"`.
public struct TimeOfDay: Codable, Sendable, Hashable, Comparable {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// Strict `HH:mm` (24-hour, two-digit fields).
    public init?(string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
            parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
            let h = Int(parts[0]), let m = Int(parts[1])
        else { return nil }
        self.init(hour: h, minute: m)
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

/// A calendar date with no time zone attached (`YYYY-MM-DD`). Interpreted in
/// the configured `Timezone` by the schedule engine.
public struct LocalDate: Codable, Sendable, Hashable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        // Round-trip through a Gregorian calendar to reject e.g. 2026-02-30.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: date)
        guard c.year == year, c.month == month, c.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
            let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public var dateComponents: DateComponents { DateComponents(year: year, month: month, day: day) }
}

/// A school-holiday period from the portal, in the configured time zone: from
/// `startTime` on `startDay` (school end on the last school day) until the usual
/// downtime starts on `lastDay` (the night before school goes back), or midnight.
public struct HolidayPeriod: Codable, Sendable, Equatable {
    public var startDay: LocalDate
    public var startTime: TimeOfDay
    public var lastDay: LocalDate

    public init(startDay: LocalDate, startTime: TimeOfDay, lastDay: LocalDate) {
        self.startDay = startDay
        self.startTime = startTime
        self.lastDay = lastDay
    }

    public func covers(_ day: LocalDate) -> Bool { startDay <= day && day <= lastDay }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// One entry of `Schedules[]`.
public struct ScheduleRule: Codable, Sendable, Equatable {
    public var name: String
    /// Days on which the window **starts**.
    public var days: Set<Weekday>
    public var start: TimeOfDay
    /// If `end <= start` the window runs past midnight into the next day.
    public var end: TimeOfDay
    public var warningMinutes: Int?

    public init(name: String, days: Set<Weekday>, start: TimeOfDay, end: TimeOfDay, warningMinutes: Int? = nil) {
        self.name = name
        self.days = days
        self.start = start
        self.end = end
        self.warningMinutes = warningMinutes
    }

    public var crossesMidnight: Bool { end <= start }
}

public enum DateExceptionMode: String, Codable, Sendable {
    /// No downtime windows start on these dates.
    case skip = "Skip"
    /// Downtime for the whole of each date.
    case allDay = "AllDay"
}

/// One entry of `DateExceptions[]`. Dates are inclusive.
public struct DateException: Codable, Sendable, Equatable {
    public var startDate: LocalDate
    public var endDate: LocalDate
    public var mode: DateExceptionMode
    public var note: String

    public init(startDate: LocalDate, endDate: LocalDate, mode: DateExceptionMode, note: String = "") {
        self.startDate = startDate
        self.endDate = endDate
        self.mode = mode
        self.note = note
    }

    public func contains(_ date: LocalDate) -> Bool { startDate <= date && date <= endDate }
}

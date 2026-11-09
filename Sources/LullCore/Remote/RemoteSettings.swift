import Foundation

/// Per-device settings chosen in the Lull portal by a parent (or IT): opt out,
/// optionally customised school-night and weekend windows (nil = follow the
/// school's schedule from the profile), or an advanced schedule (windows day by
/// day) instead, a school-holiday choice, lock down now and release now. lulld
/// caches the last valid copy in state.json, so enforcement never waits for
/// the network (lull-portal contract/PORTAL_API.md).
public struct RemoteSettings: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public var start: TimeOfDay
        /// At or before `start` = ends the next day (same rule as `Schedules[]`).
        public var end: TimeOfDay

        public init(start: TimeOfDay, end: TimeOfDay) {
            self.start = start
            self.end = end
        }
    }

    /// One window of an advanced schedule, starting on `day`. `end` at or
    /// before `start` ends the next day, so the same time is a whole 24 hours.
    public struct DayWindow: Codable, Sendable, Equatable {
        public var day: Weekday
        public var start: TimeOfDay
        public var end: TimeOfDay

        public init(day: Weekday, start: TimeOfDay, end: TimeOfDay) {
            self.day = day
            self.start = start
            self.end = end
        }

        func rule(named name: String) -> ScheduleRule { ScheduleRule(name: name, days: [day], start: start, end: end) }
    }

    /// Assigned by the portal and only ever increases (it's derived from the
    /// portal's clock, so it survives a database restore). lulld never goes
    /// back to a lower revision, so a stale response can't undo a newer change.
    public var revision: Int64
    /// False = opted out of all schedules (the portal now opts out per kind
    /// instead, with `schoolNightsOff` / `weekendOff`, and sends true).
    public var enabled: Bool
    /// The parent's own times for windows starting Sun–Thu, or nil to follow
    /// the profile's (IT's) schedule for those days.
    public var schoolNights: Window?
    /// The parent's own times for windows starting Fri and Sat, or nil.
    public var weekend: Window?
    /// The parent opted out of the windows starting Sun–Thu: no downtime is
    /// scheduled on those days (their window, if any, is ignored). Optional so
    /// settings cached by an older lulld still decode; nil = false.
    public var schoolNightsOff: Bool?
    /// The parent opted out of the windows starting Fri and Sat.
    public var weekendOff: Bool?
    /// "Lock down now". May be in the past (then it has no effect).
    public var lockNow: LockNowWindow?
    /// "Release now": ends the window in progress at this instant.
    public var releasedAt: Date?
    /// The parent's own times for school holidays, or nil. Optional like the
    /// fields below, so settings cached by an older lulld still decode.
    public var holiday: Window?
    /// The parent opted out of downtime during school holidays.
    public var holidayOff: Bool?
    /// When `holiday` / `holidayOff` apply instead of the usual settings,
    /// worked out by the portal from the school's holidays and school hours.
    /// Nil when there's no holiday choice.
    public var holidayPeriods: [HolidayPeriod]?
    /// The parent's advanced schedule: these windows replace the profile's
    /// schedules and the per-kind choices (empty = no downtime). Nil = the
    /// per-kind choices apply.
    public var week: [DayWindow]?
    /// The parent's advanced schedule for school holidays, which is then the
    /// holiday choice (`holiday` / `holidayOff` are nil).
    public var holidayWeek: [DayWindow]?

    public init(
        revision: Int64, enabled: Bool, schoolNights: Window? = nil, weekend: Window? = nil, lockNow: LockNowWindow? = nil,
        releasedAt: Date? = nil, schoolNightsOff: Bool? = nil, weekendOff: Bool? = nil, holiday: Window? = nil,
        holidayOff: Bool? = nil, holidayPeriods: [HolidayPeriod]? = nil, week: [DayWindow]? = nil, holidayWeek: [DayWindow]? = nil
    ) {
        self.revision = revision
        self.enabled = enabled
        self.schoolNights = schoolNights
        self.weekend = weekend
        self.schoolNightsOff = schoolNightsOff
        self.weekendOff = weekendOff
        self.lockNow = lockNow
        self.releasedAt = releasedAt
        self.holiday = holiday
        self.holidayOff = holidayOff
        self.holidayPeriods = holidayPeriods
        self.week = week
        self.holidayWeek = holidayWeek
    }

    /// Windows are listed on the day they *start*: the night before a school day.
    public static let schoolNightDays: Set<Weekday> = [.sun, .mon, .tue, .wed, .thu]
    public static let weekendDays: Set<Weekday> = [.fri, .sat]
    public static let schoolNightsName = "School nights"
    public static let weekendName = "Weekend"
    public static let holidayName = "School holidays"
    public static let downtimeName = "Downtime"
    /// More than one window per hour of the week is never a real schedule.
    public static let maxWeekWindows = 7 * 24

    /// What replaces the usual windows during holiday periods: the parent's
    /// advanced schedule, nothing when opted out, else the parent's window
    /// every day. Nil without a holiday choice or periods (the usual settings
    /// apply throughout).
    public var holidaySchedule: HolidaySchedule? {
        guard let periods = holidayPeriods, !periods.isEmpty else { return nil }
        if let week = holidayWeek { return HolidaySchedule(periods: periods, rules: week.map { $0.rule(named: Self.holidayName) }) }
        if holidayOff == true { return HolidaySchedule(periods: periods, rules: []) }
        guard let w = holiday else { return nil }
        return HolidaySchedule(
            periods: periods, rules: [ScheduleRule(name: Self.holidayName, days: Set(Weekday.allCases), start: w.start, end: w.end)])
    }

    /// The profile's schedules with the parent's choices applied, per kind:
    /// - **opted out**: every profile window starting on its days is removed;
    /// - **customised**: those windows are replaced by the parent's one;
    /// - **follow the school**: untouched.
    /// Rules spanning both kinds (e.g. Mon–Fri) keep the days of the other
    /// kind. Parent windows use the profile's global `WarningMinutes`.
    /// An advanced schedule replaces all of that with its own windows.
    public func schedules(over profile: [ScheduleRule]) -> [ScheduleRule] {
        if let week { return week.map { $0.rule(named: Self.downtimeName) } }
        let schoolOff = schoolNightsOff == true, weekendOffNow = weekendOff == true
        var taken = Set<Weekday>()
        if schoolOff || schoolNights != nil { taken.formUnion(Self.schoolNightDays) }
        if weekendOffNow || weekend != nil { taken.formUnion(Self.weekendDays) }
        var rules: [ScheduleRule] = profile.compactMap { rule in
            var r = rule
            r.days.subtract(taken)
            return r.days.isEmpty ? nil : r
        }
        if !schoolOff, let w = schoolNights {
            rules.append(ScheduleRule(name: Self.schoolNightsName, days: Self.schoolNightDays, start: w.start, end: w.end))
        }
        if !weekendOffNow, let w = weekend {
            rules.append(ScheduleRule(name: Self.weekendName, days: Self.weekendDays, start: w.start, end: w.end))
        }
        return rules
    }
}

public enum RemoteSettingsError: Error, Equatable, CustomStringConvertible {
    case invalidRevision(Int64)
    case invalidTime(field: String, value: String)
    /// Start == end would be a 24-hour lock every day; the portal never offers it.
    case emptyWindow(field: String)
    /// Only one of lockFrom/lockUntil, end not after start, or longer than 24 h.
    case invalidLockNow(String)
    /// Not a `YYYY-MM-DD` date (or `YYYY-MM-DDTHH:mm` date and time).
    case invalidDate(field: String, value: String)
    /// A holiday period whose last day isn't after its start, or that doesn't
    /// start after the previous one's last day.
    case invalidHolidayPeriod(field: String)
    /// Not `Mon` ... `Sun`.
    case invalidDay(field: String, value: String)
    /// More windows in an advanced schedule than `RemoteSettings.maxWeekWindows`.
    case tooManyWindows(field: String)

    public var description: String {
        switch self {
        case .invalidRevision(let r): return "revision \(r) is not positive"
        case .invalidTime(let field, let value): return "\(field): \"\(value)\" is not HH:mm"
        case .emptyWindow(let field): return "\(field): start and end are the same"
        case .invalidLockNow(let why): return "lock down: \(why)"
        case .invalidDate(let field, let value): return "\(field): \"\(value)\" is not a valid date"
        case .invalidHolidayPeriod(let field): return "\(field): lastDay must be after start, and after the previous period"
        case .invalidDay(let field, let value): return "\(field): \"\(value)\" is not a day (Mon ... Sun)"
        case .tooManyWindows(let field): return "\(field): more than \(RemoteSettings.maxWeekWindows) windows"
        }
    }
}

extension RemoteSettings {
    /// Validates what the portal sent. lulld is the last line of defence, so it
    /// checks shape here even though the portal validates (and applies IT's
    /// bounds) before saving.
    public static func validate(_ p: PortalAPI.SettingsPayload) -> Result<RemoteSettings, RemoteSettingsError> {
        guard p.revision > 0 else { return .failure(.invalidRevision(p.revision)) }
        func window(_ w: PortalAPI.WindowPayload?, _ field: String) -> Result<Window?, RemoteSettingsError> {
            guard let w else { return .success(nil) }  // follow the school's schedule
            guard let start = TimeOfDay(string: w.start) else { return .failure(.invalidTime(field: "\(field).start", value: w.start)) }
            guard let end = TimeOfDay(string: w.end) else { return .failure(.invalidTime(field: "\(field).end", value: w.end)) }
            guard start != end else { return .failure(.emptyWindow(field: field)) }
            return .success(Window(start: start, end: end))
        }
        var lockNow: LockNowWindow?
        switch (p.lockFrom, p.lockUntil) {
        case (nil, nil): break
        case (let from?, let until?):
            guard until > from else { return .failure(.invalidLockNow("lockUntil is not after lockFrom")) }
            guard until.timeIntervalSince(from) <= LockNowWindow.maxDuration else {
                return .failure(.invalidLockNow("longer than 24 hours"))
            }
            lockNow = LockNowWindow(start: from, end: until)
        default: return .failure(.invalidLockNow("lockFrom and lockUntil must both be set"))
        }
        // An advanced schedule's windows: the same start and end is a whole day, not a mistake.
        func dayWindows(_ list: [PortalAPI.WeekWindowPayload]?, _ field: String) -> Result<[DayWindow]?, RemoteSettingsError> {
            guard let list else { return .success(nil) }
            guard list.count <= maxWeekWindows else { return .failure(.tooManyWindows(field: field)) }
            var windows: [DayWindow] = []
            for (i, w) in list.enumerated() {
                let f = "\(field)[\(i)]"
                guard let day = Weekday(configString: w.day) else { return .failure(.invalidDay(field: "\(f).day", value: w.day)) }
                guard let start = TimeOfDay(string: w.start) else { return .failure(.invalidTime(field: "\(f).start", value: w.start)) }
                guard let end = TimeOfDay(string: w.end) else { return .failure(.invalidTime(field: "\(f).end", value: w.end)) }
                windows.append(DayWindow(day: day, start: start, end: end))
            }
            return .success(windows)
        }
        let week: [DayWindow]?, holidayWeek: [DayWindow]?
        switch (dayWindows(p.week, "week"), dayWindows(p.holidayWeek, "holidayWeek")) {
        case (.failure(let e), _), (_, .failure(let e)): return .failure(e)
        case (.success(let w), .success(let h)): (week, holidayWeek) = (w, h)
        }
        var holidayPeriods: [HolidayPeriod] = []
        for (i, period) in (p.holidayPeriods ?? []).enumerated() {
            let field = "holidayPeriods[\(i)]"
            let parts = period.start.split(separator: "T", omittingEmptySubsequences: false)
            guard parts.count == 2, let startDay = LocalDate(string: String(parts[0])),
                let startTime = TimeOfDay(string: String(parts[1]))
            else { return .failure(.invalidDate(field: "\(field).start", value: period.start)) }
            guard let lastDay = LocalDate(string: period.lastDay) else {
                return .failure(.invalidDate(field: "\(field).lastDay", value: period.lastDay))
            }
            // In order and apart, so each day belongs to at most one period.
            guard startDay < lastDay, holidayPeriods.last.map({ $0.lastDay < startDay }) ?? true else {
                return .failure(.invalidHolidayPeriod(field: field))
            }
            holidayPeriods.append(HolidayPeriod(startDay: startDay, startTime: startTime, lastDay: lastDay))
        }
        return window(p.schoolNights, "schoolNights").flatMap { school in
            window(p.weekend, "weekend").flatMap { weekend in
                window(p.holiday, "holiday").map { holiday in
                    // What means nothing is dropped, so equality stays meaningful: an advanced schedule's
                    // simple choices (sent for older lulld builds), an opted-out window, periods without a choice.
                    let simple = week == nil
                    let holidayOff = holidayWeek == nil && p.holidayOff == true
                    let holiday = holidayWeek != nil || holidayOff ? nil : holiday
                    let hasChoice = holidayWeek != nil || holidayOff || holiday != nil
                    let schoolOff = simple && p.schoolNightsOff == true, weekendOff = simple && p.weekendOff == true
                    return RemoteSettings(
                        revision: p.revision, enabled: p.enabled,
                        schoolNights: simple && !schoolOff ? school : nil, weekend: simple && !weekendOff ? weekend : nil,
                        lockNow: lockNow, releasedAt: p.releasedAt,
                        schoolNightsOff: schoolOff ? true : nil, weekendOff: weekendOff ? true : nil,
                        holiday: holiday, holidayOff: holidayOff ? true : nil,
                        holidayPeriods: hasChoice && !holidayPeriods.isEmpty ? holidayPeriods : nil,
                        week: week, holidayWeek: hasChoice && !holidayPeriods.isEmpty ? holidayWeek : nil)
                }
            }
        }
    }

    public enum Update: Equatable, Sendable {
        /// Newer than the cached copy (or nothing cached): use it.
        case apply
        /// Same revision and content as the cached copy.
        case unchanged
        /// Older than the cached copy: a stale or replayed response. Keep the cache.
        case rollback(cached: Int64, offered: Int64)
        /// Same revision, different content: a portal bug. Keep the cache rather than guess.
        case revisionReused(Int64)
    }

    public static func update(from cached: RemoteSettings?, to offered: RemoteSettings) -> Update {
        guard let cached else { return .apply }
        if offered.revision > cached.revision { return .apply }
        if offered.revision < cached.revision { return .rollback(cached: cached.revision, offered: offered.revision) }
        return offered == cached ? .unchanged : .revisionReused(offered.revision)
    }
}

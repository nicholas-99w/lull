import Foundation

/// Snoozes used for one downtime window. Persisted by the daemon so killing it
/// doesn't hand out fresh snoozes.
public struct SnoozeLedger: Codable, Sendable, Equatable {
    /// Identifies the window (its unsnoozed start).
    public var windowStart: Date
    public var count: Int
    public var delaySeconds: TimeInterval
    /// End of the window; once passed, the ledger can be discarded.
    public var windowEnd: Date?

    public init(windowStart: Date, count: Int = 0, delaySeconds: TimeInterval = 0, windowEnd: Date? = nil) {
        self.windowStart = windowStart
        self.count = count
        self.delaySeconds = delaySeconds
        self.windowEnd = windowEnd
    }

    public func isExpired(at now: Date) -> Bool { windowEnd.map { now >= $0 } ?? false }
}

/// What the schedule says should be happening at an instant.
public struct PhaseEvaluation: Sendable, Equatable {
    /// `normal`, `warning`, `locked` or `disabled`. The daemon layers
    /// `overridden`/`exempt` on top.
    public var phase: LullPhase
    /// Current window when locked or snoozed inside it, otherwise the next one.
    public var window: DowntimeWindow?
    /// When the lock engages for `window` (window start plus any snooze).
    public var lockStart: Date?
    public var secondsUntilLock: TimeInterval?
    public var secondsUntilUnlock: TimeInterval?
    public var showWarningCard: Bool
    public var inFinalCountdown: Bool
    public var snoozeAvailable: Bool
    public var scheduleName: String

    static let disabled = PhaseEvaluation(
        phase: .disabled, window: nil, lockStart: nil, secondsUntilLock: nil, secondsUntilUnlock: nil,
        showWarningCard: false, inFinalCountdown: false, snoozeAvailable: false, scheduleName: "")
}

/// Pure schedule maths. All calendar work uses the configured time zone via
/// `Calendar`, never fixed UTC offsets, so DST transitions come out right.
///
/// Semantics:
/// - A schedule's window starts on each listed day; `End <= Start` ends next day.
/// - Times that don't exist (DST spring-forward gap) resolve to the next valid
///   instant; repeated times (fall-back) use the first occurrence.
/// - `Skip` exceptions suppress windows that *start* on those dates. `AllDay`
///   locks each date from local midnight to the next midnight; if a date is in
///   both kinds, `AllDay` wins (fail closed).
/// - During a portal holiday period (`config.holidaySchedule`) the parent's
///   holiday rules replace the usual ones (none if they opted out): on the
///   start day from the period's start time, on the days in between, and on
///   the last day until its first usual window starts (else midnight).
///   `DateExceptions` still apply first.
/// - Overlapping or touching windows merge into one.
/// - A portal "Lock down now" (`config.lockNow`) is one more window between two
///   exact instants. It isn't affected by `Skip`, and it applies even when the
///   schedules are off (`enabled = false` because the parent opted out);
///   `LullConfig.applying(_:)` never sets it when the profile disables Lull.
/// - A portal "Release now" (`config.releasedAt`) cuts the merged window that
///   contains that instant short at it; windows after it are untouched.
public struct ScheduleEngine: Sendable {
    public let config: LullConfig
    public let calendar: Calendar
    /// How long an interval warning card stays up (~20s).
    public static let warningCardDisplaySeconds: TimeInterval = 20

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public init(config: LullConfig) {
        self.config = config
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = config.timeZone
        self.calendar = cal
    }

    // MARK: - Evaluation

    public func evaluate(at now: Date, snooze ledger: SnoozeLedger? = nil) -> PhaseEvaluation {
        guard config.enabled || config.lockNow != nil else { return .disabled }
        let (current, next) = currentAndNextWindow(at: now)
        // Schedules off and no lock-down in progress: nothing to warn about.
        if !config.enabled && current == nil { return .disabled }

        func lockStart(for w: DowntimeWindow) -> Date {
            let delay = ledger?.windowStart == w.start ? ledger!.delaySeconds : 0
            return min(w.start.addingTimeInterval(delay), w.end)
        }

        var target = next
        if let w = current {
            let ls = lockStart(for: w)
            if now >= ls && ls < w.end {
                return PhaseEvaluation(
                    phase: .locked, window: w, lockStart: ls, secondsUntilLock: 0,
                    secondsUntilUnlock: w.end.timeIntervalSince(now),
                    showWarningCard: false, inFinalCountdown: false, snoozeAvailable: false,
                    scheduleName: w.scheduleName(at: now))
            }
            // Snoozed inside the window: the lock is still ahead. If the snooze
            // used up the whole window there is nothing left to lock for it.
            if ls < w.end { target = w }
        }

        guard let w = target else {
            return PhaseEvaluation(
                phase: .normal, window: nil, lockStart: nil, secondsUntilLock: nil, secondsUntilUnlock: nil,
                showWarningCard: false, inFinalCountdown: false, snoozeAvailable: false, scheduleName: "")
        }
        let ls = lockStart(for: w)
        let untilLock = ls.timeIntervalSince(now)
        let notice = TimeInterval((w.warningMinutes ?? config.warningMinutes) * 60)
        let warning = untilLock <= notice
        let finalCountdown = warning && untilLock <= TimeInterval(config.finalCountdownSeconds)
        let intervalHit = config.warningIntervalsMinutes.contains { minutes in
            let t = TimeInterval(minutes * 60)
            return t <= notice && untilLock <= t && untilLock > t - Self.warningCardDisplaySeconds
        }
        let used = ledger?.windowStart == w.start ? ledger!.count : 0
        return PhaseEvaluation(
            phase: warning ? .warning : .normal, window: w, lockStart: ls,
            secondsUntilLock: untilLock,
            secondsUntilUnlock: w.end.timeIntervalSince(now),
            showWarningCard: warning && (finalCountdown || intervalHit),
            inFinalCountdown: finalCountdown,
            snoozeAvailable: warning && config.snoozeEnabled && used < config.maxSnoozesPerWindow,
            scheduleName: w.scheduleName(at: ls))
    }

    /// Records a snooze if one is allowed now. Returns nil if not.
    /// Snoozing delays the lock by `SnoozeMinutes` from the current lock start,
    /// never past the window end.
    public func snooze(at now: Date, ledger: SnoozeLedger?) -> SnoozeLedger? {
        let eval = evaluate(at: now, snooze: ledger)
        guard eval.phase == .warning, eval.snoozeAvailable, let w = eval.window else { return nil }
        var l = ledger?.windowStart == w.start ? ledger! : SnoozeLedger(windowStart: w.start, windowEnd: w.end)
        l.count += 1
        l.delaySeconds = min(l.delaySeconds + TimeInterval(config.snoozeMinutes * 60), w.duration)
        return l
    }

    // MARK: - Windows

    /// Merged windows intersecting `[from, to)`. Windows touching the edges of the
    /// range may be truncated if they are part of a longer merged run; use
    /// `currentAndNextWindow` when exact bounds matter.
    public func windows(from: Date, to: Date) -> [DowntimeWindow] {
        guard config.enabled || config.lockNow != nil, from < to else { return [] }
        var raw: [DowntimeWindow] = []
        if config.enabled {
            var day = addDays(localDate(of: from), -1)
            let last = addDays(localDate(of: to), 1)
            while day <= last {
                raw += windowsStarting(on: day)
                day = addDays(day, 1)
            }
        }
        if let l = config.lockNow, l.end > l.start {
            // No warning period: the parent asked for it now.
            raw.append(DowntimeWindow(start: l.start, end: l.end, name: LockNowWindow.name, warningMinutes: 0))
        }
        var merged = Self.merge(raw)
        if let r = config.releasedAt {
            merged = merged.compactMap { w in
                guard w.contains(r) else { return w }
                var cut = w
                cut.truncate(at: r)
                return cut.end > cut.start ? cut : nil
            }
        }
        return merged.filter { $0.end > from && $0.start < to }
    }

    /// The window containing `now` (if any) and the next one starting after `now`.
    /// Widens the search range until neither result is cut off by it, so long
    /// holiday exceptions and multi-day `AllDay` runs report true bounds.
    public func currentAndNextWindow(at now: Date) -> (current: DowntimeWindow?, next: DowntimeWindow?) {
        let backSteps = [2, 35, 400]
        let forwardSteps = [8, 64, 400]
        var b = 0
        var f = 0
        while true {
            let fromDay = addDays(localDate(of: now), -backSteps[b])
            let toDay = addDays(localDate(of: now), forwardSteps[f])
            let from = startOfDay(fromDay)
            let to = startOfDay(toDay)
            let all = windows(from: from, to: to)
            let current = all.first { $0.contains(now) }
            let next = all.first { $0.start > now }

            let generatedFrom = startOfDay(addDays(fromDay, -1))
            let needBack = (current.map { $0.start <= generatedFrom } ?? false) && b < backSteps.count - 1
            let cutAtEnd = [current, next].compactMap { $0 }.contains { $0.end >= to }
            let needForward = (cutAtEnd || next == nil) && f < forwardSteps.count - 1
            if !needBack && !needForward { return (current, next) }
            if needBack { b += 1 }
            if needForward { f += 1 }
        }
    }

    func windowsStarting(on day: LocalDate) -> [DowntimeWindow] {
        let exceptions = config.dateExceptions.filter { $0.contains(day) }
        let allDay = exceptions.first { $0.mode == .allDay }
        let skip = exceptions.contains { $0.mode == .skip }
        var result: [DowntimeWindow] = []
        if let allDay {
            let name = allDay.note.isEmpty ? "Downtime" : allDay.note
            result.append(DowntimeWindow(start: startOfDay(day), end: startOfDay(addDays(day, 1)), name: name))
        } else if skip {
            return []
        }
        let usual = windows(of: config.schedules, startingOn: day)
        guard let holiday = config.holidaySchedule, let period = holiday.period(covering: day) else { return result + usual }
        let holidayWindows = windows(of: holiday.rules, startingOn: day)
        if day == period.startDay {
            // School is on until the period starts: usual windows before it, holiday ones from it.
            let from = instant(day, period.startTime)
            return result + usual.filter { $0.start < from } + holidayWindows.compactMap { $0.clipped(from: from, to: $0.end) }
        }
        if day == period.lastDay {
            // The night before school follows the usual settings; holiday windows stop where they start.
            let until = usual.map(\.start).min() ?? startOfDay(addDays(day, 1))
            return result + usual + holidayWindows.compactMap { $0.clipped(from: $0.start, to: until) }
        }
        return result + holidayWindows
    }

    private func windows(of rules: [ScheduleRule], startingOn day: LocalDate) -> [DowntimeWindow] {
        let weekday = weekday(of: day)
        return rules.filter { $0.days.contains(weekday) }.compactMap { rule in
            let start = instant(day, rule.start)
            let end = instant(rule.crossesMidnight ? addDays(day, 1) : day, rule.end)
            guard end > start else { return nil }
            return DowntimeWindow(start: start, end: end, name: rule.name, warningMinutes: rule.warningMinutes)
        }
    }

    static func merge(_ windows: [DowntimeWindow]) -> [DowntimeWindow] {
        var out: [DowntimeWindow] = []
        for w in windows.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, w.start <= last.end {
                out[out.count - 1].merge(w)
            } else {
                out.append(w)
            }
        }
        return out
    }

    // MARK: - Calendar helpers (configured time zone)

    public func localDate(of date: Date) -> LocalDate {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return LocalDate(year: c.year!, month: c.month!, day: c.day!)!
    }

    /// Pure date arithmetic; time zone doesn't matter so use UTC.
    func addDays(_ day: LocalDate, _ n: Int) -> LocalDate {
        let cal = Self.utcCalendar
        let d = cal.date(byAdding: .day, value: n, to: cal.date(from: day.dateComponents)!)!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return LocalDate(year: c.year!, month: c.month!, day: c.day!)!
    }

    func weekday(of day: LocalDate) -> Weekday {
        let cal = Self.utcCalendar
        return Weekday(rawValue: cal.component(.weekday, from: cal.date(from: day.dateComponents)!))!
    }

    func startOfDay(_ day: LocalDate) -> Date {
        // Build from midday, which exists on every date in every zone, then let
        // Calendar find the real start (handles zones whose DST shift is at midnight).
        var c = day.dateComponents
        c.hour = 12
        return calendar.startOfDay(for: calendar.date(from: c)!)
    }

    func instant(_ day: LocalDate, _ time: TimeOfDay) -> Date {
        let dayStart = startOfDay(day)
        if time.minutesSinceMidnight == 0 { return dayStart }
        let match = DateComponents(hour: time.hour, minute: time.minute, second: 0)
        return calendar.nextDate(
            after: dayStart, matching: match,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward
        ) ?? dayStart.addingTimeInterval(TimeInterval(time.minutesSinceMidnight * 60))
    }
}

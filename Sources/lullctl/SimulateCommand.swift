#if DEBUG
    import Foundation
    import LullCore

    /// Debug-only: evaluate a config at an arbitrary time without a daemon.
    enum SimulateCommand {
        static func run(configPath: String, at: String, windows count: Int) {
            var raw = loadPlist(configPath)
            raw.removeValue(forKey: LullConstants.debugTimeOffsetKey)
            let result = ConfigParser().parse(raw)
            for issue in result.issues { print(issue) }
            guard let config = result.config else { fail("config is invalid") }
            guard let instant = parseTime(at, timeZone: config.timeZone) else {
                fail(
                    "can't parse --at '\(at)' (use 2026-10-04T21:30:00+11:00 or 2026-10-04T21:30; local times inside a DST gap don't exist)",
                    code: 64)
            }
            let engine = ScheduleEngine(config: config)
            let ev = engine.evaluate(at: instant)
            let fmt = DateFormatter()
            fmt.timeZone = config.timeZone
            fmt.dateFormat = "EEE yyyy-MM-dd HH:mm:ss zzz"

            print("at:              \(fmt.string(from: instant))")
            print("phase:           \(ev.phase.rawValue)")
            if !ev.scheduleName.isEmpty { print("schedule:        \(ev.scheduleName)") }
            if let w = ev.window {
                print("window:          \(fmt.string(from: w.start)) -> \(fmt.string(from: w.end)) (\(StatusCommand.duration(w.duration)))")
            }
            if let s = ev.secondsUntilLock, ev.phase != .locked { print("until lock:      \(StatusCommand.duration(s))") }
            if let s = ev.secondsUntilUnlock, ev.phase == .locked { print("until unlock:    \(StatusCommand.duration(s))") }
            print("warning card:    \(ev.showWarningCard)\(ev.inFinalCountdown ? " (final countdown)" : "")")
            print("snooze offered:  \(ev.snoozeAvailable)")

            if count > 0 {
                print("next \(count) window(s):")
                var from = instant
                for _ in 0..<count {
                    guard let w = engine.currentAndNextWindow(at: from).next else { break }
                    print("  \(fmt.string(from: w.start)) -> \(fmt.string(from: w.end))  \(w.scheduleName(at: w.start))")
                    from = w.end
                }
            }
        }

        static func parseTime(_ s: String, timeZone: TimeZone) -> Date? {
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: s) { return d }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
                f.dateFormat = format
                if let d = f.date(from: s) { return d }
            }
            return nil
        }
    }
#endif

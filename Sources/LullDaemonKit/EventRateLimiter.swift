import Foundation

/// Caps how often one noisy event (per key, e.g. "agent_connected/501") is
/// logged, so a student killing the agent in a loop can't rotate tamper
/// evidence (clock_tamper, agent_missing, fallback...) out of lulld.log.
/// Suppressed occurrences are counted and reported on the next logged one.
struct EventRateLimiter {
    enum Decision: Equatable {
        case log(suppressed: Int)
        case suppress
    }

    var limit = 10
    var period: TimeInterval = 60
    private var windows: [String: (start: TimeInterval, count: Int, suppressed: Int)] = [:]

    mutating func admit(_ key: String, now: TimeInterval) -> Decision {
        var w = windows[key] ?? (now, 0, 0)
        if now - w.start >= period { w = (now, 0, w.suppressed) }
        if w.count < limit {
            let suppressed = w.suppressed
            w.count += 1
            w.suppressed = 0
            windows[key] = w
            return .log(suppressed: suppressed)
        }
        w.suppressed += 1
        windows[key] = w
        return .suppress
    }
}

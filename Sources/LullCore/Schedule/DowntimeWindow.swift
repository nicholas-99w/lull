import Foundation

public enum LullPhase: String, Codable, Sendable, CaseIterable {
    case normal
    case warning
    case locked
    /// Admin override in effect. Set by the daemon, not the schedule engine.
    case overridden
    /// Console user is exempt. Set by the daemon per session.
    case exempt
    /// `Enabled = false`, or the Debug-only DISABLE file.
    case disabled
}

/// A concrete downtime interval `[start, end)` in absolute time. Overlapping or
/// touching windows from different schedules/exceptions are merged into one;
/// `segments` keeps the originals so we can name the part that's active.
public struct DowntimeWindow: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var name: String
        public var warningMinutes: Int?
    }

    public var start: Date
    public var end: Date
    public var segments: [Segment]

    public init(start: Date, end: Date, name: String, warningMinutes: Int? = nil) {
        self.start = start
        self.end = end
        self.segments = [Segment(start: start, end: end, name: name, warningMinutes: warningMinutes)]
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public func contains(_ date: Date) -> Bool { start <= date && date < end }

    /// The segment that starts the window decides the notice period.
    public var warningMinutes: Int? { segments.first?.warningMinutes }

    /// Name of the segment active at `date` (the earliest-starting one if several overlap),
    /// or of the first segment if `date` is before the window.
    public func scheduleName(at date: Date) -> String {
        segments.first(where: { $0.start <= date && date < $0.end })?.name ?? segments.first?.name ?? ""
    }

    /// Fraction of the window elapsed at `date`, 0...1.
    public func progress(at date: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }

    /// Ends the window at `instant` (a "Release now"), dropping segments that
    /// would start after it.
    mutating func truncate(at instant: Date) {
        end = min(end, instant)
        segments = segments.filter { $0.start < end }.map { s in
            var s = s
            s.end = min(s.end, end)
            return s
        }
    }

    /// This (single-schedule) window limited to `[from, to)`, or nil if nothing is left.
    func clipped(from: Date, to: Date) -> DowntimeWindow? {
        let s = max(start, from), e = min(end, to)
        guard e > s, let first = segments.first else { return nil }
        return DowntimeWindow(start: s, end: e, name: first.name, warningMinutes: first.warningMinutes)
    }

    mutating func merge(_ other: DowntimeWindow) {
        start = min(start, other.start)
        end = max(end, other.end)
        segments = (segments + other.segments).sorted { $0.start < $1.start }
    }
}

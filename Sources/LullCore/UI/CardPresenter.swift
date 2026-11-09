import Foundation

/// Final strings and numbers for one card, so SwiftUI views stay dumb and the
/// logic is unit-tested.
public struct CardContent: Sendable, Equatable {
    public var title: String
    public var message: String
    /// e.g. "Available again in 5h 32m" / "Locks in 4m 30s". nil when hidden.
    public var countdown: String?
    /// Spoken by VoiceOver instead of the abbreviated countdown.
    public var countdownAccessibility: String?
    /// 0...1, nil when hidden.
    public var progress: Double?
    public var unlockLabel: String?
    public var footer: String?
    public var support: String?
    public var snoozeLabel: String
    public var overrideLabel: String
    public var shutdownLabel: String
}

public enum CardPresenter {
    public enum Kind: Sendable { case lock, warning }

    public static func content(
        for state: DisplayState, kind: Kind, now: Date, userFullName: String, locale: Locale = .current
    ) -> CardContent {
        let tz = TimeZone(identifier: state.timeZoneIdentifier) ?? TimeZone(identifier: LullConstants.defaultTimeZoneIdentifier)!
        let renderer = TextRenderer(timeZone: tz, locale: locale)
        let target: Date? = kind == .lock ? state.windowEnd : (state.lockStart ?? state.windowStart)
        let remaining = target.map { max(0, $0.timeIntervalSince(now)) }
        let ctx = TextContext(
            windowStart: state.lockStart ?? state.windowStart, windowEnd: state.windowEnd,
            secondsRemaining: remaining.map { Int($0.rounded(.up)) }, scheduleName: state.scheduleName, userFullName: userFullName,
            organizationName: state.texts.organizationName, supportContact: state.texts.supportContact)
        func render(_ s: String) -> String { renderer.render(s, context: ctx) }
        func nonEmpty(_ s: String) -> String? {
            let r = render(s).trimmingCharacters(in: .whitespacesAndNewlines)
            return r.isEmpty ? nil : r
        }
        let t = state.texts
        let a = state.appearance

        var countdown: String?
        var spoken: String?
        var progress: Double?
        switch kind {
        case .lock:
            if a.showCountdown, let remaining {
                countdown = UIStrings.availableAgainIn(formatDuration(remaining, locale: locale))
                spoken = UIStrings.availableAgainIn(formatDuration(remaining, locale: locale, style: .full))
            }
            if a.showProgress, let start = state.windowStart, let end = state.windowEnd {
                progress = DowntimeWindow(start: start, end: end, name: "").progress(at: now)
            }
        case .warning:
            if a.showCountdown, let remaining {
                countdown = UIStrings.locksIn(formatDuration(remaining, locale: locale))
                spoken = UIStrings.locksIn(formatDuration(remaining, locale: locale, style: .full))
            }
            // During the final countdown the bar fills up to the lock.
            if a.showProgress, state.inFinalCountdown, let remaining, state.finalCountdownSeconds > 0 {
                progress = min(max(1 - remaining / Double(state.finalCountdownSeconds), 0), 1)
            }
        }

        return CardContent(
            title: render(kind == .lock ? t.lockedTitle : t.warningTitle),
            message: render(kind == .lock ? t.lockedMessage : t.warningMessage),
            countdown: countdown, countdownAccessibility: spoken, progress: progress,
            // Without a window (e.g. locked awaiting time sync) there's no end time to show.
            unlockLabel: kind == .lock && state.windowEnd != nil ? nonEmpty(t.unlockLabel) : nil,
            footer: nonEmpty(t.footerText), support: nonEmpty(t.supportText),
            snoozeLabel: render(t.snoozeButtonLabel), overrideLabel: render(t.overrideButtonLabel),
            shutdownLabel: render(t.shutdownButtonLabel))
    }

    /// "5h 32m", "4m 30s", "45s" (localised). Seconds are shown under ten
    /// minutes, where they matter; hours never show seconds.
    public static func formatDuration(
        _ seconds: TimeInterval, locale: Locale = .current, style: DateComponentsFormatter.UnitsStyle = .abbreviated
    ) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let f = DateComponentsFormatter()
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        f.calendar = cal
        f.unitsStyle = style
        f.zeroFormattingBehavior = .dropLeading
        switch s {
        case 3600...: f.allowedUnits = [.hour, .minute]
        case 600...: f.allowedUnits = [.minute]
        case 60...: f.allowedUnits = [.minute, .second]
        default: f.allowedUnits = [.second]
        }
        return f.string(from: TimeInterval(s)) ?? "\(s)s"
    }
}

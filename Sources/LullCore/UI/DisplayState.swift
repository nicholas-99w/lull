import Foundation

/// Everything the agent needs to draw, as published by the daemon, including
/// the resolved appearance and texts. The agent never reads config or
/// decides phase itself; it renders this.
///
/// Times are trusted times. The agent extrapolates between updates with its own
/// continuous clock (see `AgentModel`), never the wall clock.
public struct DisplayState: Codable, Sendable, Equatable {
    public var phase: LullPhase
    /// Daemon's trusted time when this state was produced.
    public var trustedNow: Date
    public var windowStart: Date?
    public var windowEnd: Date?
    /// When the lock engages (window start plus any snooze).
    public var lockStart: Date?
    public var scheduleName: String
    public var showWarningCard: Bool
    public var inFinalCountdown: Bool
    public var finalCountdownSeconds: Int
    public var snoozeAvailable: Bool
    public var overrideAvailable: Bool
    public var shutdownAvailable: Bool
    public var timeZoneIdentifier: String
    public var appearance: Appearance
    /// Templates; tokens are rendered by `CardPresenter` every second.
    public var texts: Texts

    public init(
        phase: LullPhase, trustedNow: Date, windowStart: Date? = nil, windowEnd: Date? = nil, lockStart: Date? = nil,
        scheduleName: String = "", showWarningCard: Bool = false, inFinalCountdown: Bool = false,
        finalCountdownSeconds: Int = 60, snoozeAvailable: Bool = false, overrideAvailable: Bool = false,
        shutdownAvailable: Bool = true, timeZoneIdentifier: String = LullConstants.defaultTimeZoneIdentifier,
        appearance: Appearance = Appearance(), texts: Texts = Texts()
    ) {
        self.phase = phase
        self.trustedNow = trustedNow
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.lockStart = lockStart
        self.scheduleName = scheduleName
        self.showWarningCard = showWarningCard
        self.inFinalCountdown = inFinalCountdown
        self.finalCountdownSeconds = finalCountdownSeconds
        self.snoozeAvailable = snoozeAvailable
        self.overrideAvailable = overrideAvailable
        self.shutdownAvailable = shutdownAvailable
        self.timeZoneIdentifier = timeZoneIdentifier
        self.appearance = appearance
        self.texts = texts
    }

    /// Builds the payload from the daemon's view of the world.
    /// - Parameter phase: the resolved phase (may differ from `evaluation.phase`,
    ///   e.g. `locked` while awaiting a time sync, or `overridden`).
    public static func make(
        phase: LullPhase, evaluation: PhaseEvaluation?, config: LullConfig, now: Date, overrideAvailable: Bool
    ) -> DisplayState {
        DisplayState(
            phase: phase, trustedNow: now, windowStart: evaluation?.window?.start, windowEnd: evaluation?.window?.end,
            lockStart: evaluation?.lockStart, scheduleName: evaluation?.scheduleName ?? "",
            showWarningCard: phase == .warning && (evaluation?.showWarningCard ?? false),
            inFinalCountdown: phase == .warning && (evaluation?.inFinalCountdown ?? false),
            finalCountdownSeconds: config.finalCountdownSeconds,
            snoozeAvailable: phase == .warning && (evaluation?.snoozeAvailable ?? false),
            overrideAvailable: overrideAvailable && config.overrideEnabled,
            shutdownAvailable: config.showShutdownButton, timeZoneIdentifier: config.timeZoneIdentifier,
            appearance: config.appearance, texts: config.texts)
    }
}

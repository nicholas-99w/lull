import Foundation

public enum OfflineBootPolicy: String, Codable, Sendable, CaseIterable {
    case forwardOnly = "ForwardOnly"
    case lockUntilSynced = "LockUntilSynced"
}

public enum FallbackAction: String, Codable, Sendable, CaseIterable {
    case none = "None"
    case sleepDisplay = "SleepDisplay"
}

public enum BackgroundStyle: String, Codable, Sendable, CaseIterable {
    case blur = "Blur"
    case solid = "Solid"
    case image = "Image"
}

public enum BannerContentMode: String, Codable, Sendable, CaseIterable {
    case fill
    case fit
}

public enum WarningCardPosition: String, Codable, Sendable, CaseIterable {
    case topCenter = "TopCenter"
    case topRight = "TopRight"
    case center = "Center"
}

/// `Appearance` dict. Image paths are already resolved to absolute paths under
/// the Branding directory, or nil if absent/invalid.
public struct Appearance: Codable, Sendable, Equatable {
    public var bannerImagePath: String?
    public var bannerHeight: Double = 180
    public var bannerContentMode: BannerContentMode = .fill
    public var logoImagePath: String?
    public var backgroundStyle: BackgroundStyle = .blur
    public var backgroundColor = ThemedColor("#000000")
    public var backgroundOpacity: Double = 0.85
    public var backgroundImagePath: String?
    public var cardBackgroundColor = ThemedColor("#FFFFFF", dark: "#1C1C1E")
    public var cardCornerRadius: Double = 16
    public var cardWidth: Double = 640
    public var titleColor = ThemedColor("#1D1D1F", dark: "#F5F5F7")
    public var bodyColor = ThemedColor("#3A3A3C", dark: "#D1D1D6")
    public var accentColor = ThemedColor("#0A84FF")
    public var countdownColor = ThemedColor("#1D1D1F", dark: "#F5F5F7")
    public var progressTrackColor = ThemedColor("#E5E5EA", dark: "#3A3A3C")
    public var fontName: String?
    public var titleFontSize: Double = 28
    public var bodyFontSize: Double = 15
    public var showCountdown = true
    public var showProgress = true
    public var showBannerInWarning = false
    public var warningCardPosition: WarningCardPosition = .topCenter

    public init() {}

    /// Allowed ranges; out-of-range values are clamped with a warning.
    public enum Range {
        public static let bannerHeight: ClosedRange<Double> = 0...600
        public static let backgroundOpacity: ClosedRange<Double> = 0...1
        public static let cardCornerRadius: ClosedRange<Double> = 0...64
        public static let cardWidth: ClosedRange<Double> = 320...1200
        public static let titleFontSize: ClosedRange<Double> = 10...96
        public static let bodyFontSize: ClosedRange<Double> = 8...64
    }
}

/// `Texts` dict. Values may contain `{{tokens}}`; see `TextRenderer`.
/// These defaults are the only user-facing strings that live outside the profile.
public struct Texts: Codable, Sendable, Equatable {
    /// `{{organizationName}}`. The fallback reads naturally mid-sentence, so the
    /// default messages make sense before a school sets its own name.
    public var organizationName = Texts.defaultOrganizationName
    /// `{{supportContact}}`, e.g. "the IT Service Desk (ext. 1234)".
    public var supportContact = Texts.defaultSupportContact
    public var warningTitle = "Downtime starts soon"
    public var warningMessage = "This Mac will lock at {{startTime}}. Please save your work."
    public var lockedTitle = "Time to unplug"
    public var lockedMessage = "Devices at {{organizationName}} are unavailable during downtime hours."
    public var unlockLabel = "Back online at {{endTime}}"
    public var footerText = ""
    public var supportText = "Need help? Contact {{supportContact}}."
    public var overrideButtonLabel = "Admin override"
    public var snoozeButtonLabel = "Snooze"
    public var shutdownButtonLabel = "Shut Down"

    public static let defaultOrganizationName = "your school"
    public static let defaultSupportContact = "your IT team"

    public init() {}
}

/// `Portal` dict: lets parents and IT change this Mac's schedule in the Lull
/// portal (lull-portal contract/PORTAL_API.md). Nil = the profile alone decides, as before.
public struct PortalConfig: Codable, Sendable, Equatable {
    /// Base URL, always https.
    public var url: URL
    public var pollIntervalSeconds = 300

    public init(url: URL, pollIntervalSeconds: Int = 300) {
        self.url = url
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    public enum Range {
        public static let pollIntervalSeconds: ClosedRange<Int> = 60...3600
    }
}

/// A parent's "Lock down now": downtime between two exact instants. Comes only
/// from the portal (never the profile) and is at most `maxDuration` long.
public struct LockNowWindow: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// lulld refuses anything longer, so a portal bug can't lock a Mac for days.
    public static let maxDuration: TimeInterval = 24 * 3600
    /// Shown as the schedule name on the lock screen and in status.
    public static let name = "Lock down"
}

/// A parent's school-holiday choice from the portal: during these periods
/// these rules replace the usual schedules (`ScheduleEngine.windowsStarting(on:)`).
/// No rules = opted out. `DateExceptions` still apply first.
public struct HolidaySchedule: Codable, Sendable, Equatable {
    public var periods: [HolidayPeriod]
    public var rules: [ScheduleRule]

    public init(periods: [HolidayPeriod], rules: [ScheduleRule]) {
        self.periods = periods
        self.rules = rules
    }

    public func period(covering day: LocalDate) -> HolidayPeriod? { periods.first { $0.covers(day) } }
}

/// Fully validated configuration. Every field has a usable value; the parser
/// is responsible for defaults and clamping.
public struct LullConfig: Codable, Sendable, Equatable {
    // General
    public var enabled = true
    public var timeZoneIdentifier: String = LullConstants.defaultTimeZoneIdentifier
    public var schedules: [ScheduleRule] = []
    public var dateExceptions: [DateException] = []

    // Warning / grace
    public var warningMinutes = 15
    /// Sorted descending, unique, all within `1...warningMinutes`.
    public var warningIntervalsMinutes = [15, 10, 5, 2, 1]
    public var finalCountdownSeconds = 60
    public var snoozeEnabled = false
    public var snoozeMinutes = 10
    public var maxSnoozesPerWindow = 1

    // Scope
    public var exemptUsernames: [String] = []
    public var exemptAdminUsers = true

    // Admin override
    public var overrideEnabled = true
    public var overrideDurationMinutes = 30
    public var overrideMaxAttempts = 5
    public var overrideLockoutMinutes = 15
    /// From the profile key. The daemon prefers `/var/db/lull/override.json`.
    public var overridePasswordHash: PassphraseHash?

    // Time integrity
    public var timeServers = ["time.apple.com"]
    public var timeSyncIntervalMinutes = 60
    public var maxClockDriftSeconds = 30
    public var offlineBootPolicy: OfflineBootPolicy = .forwardOnly

    // Enforcement
    public var fallbackActionIfAgentMissing: FallbackAction = .sleepDisplay
    public var agentMissingGraceSeconds = 5
    public var showShutdownButton = true

    public var appearance = Appearance()
    public var texts = Texts()

    // Remote management
    public var portal: PortalConfig?
    /// Set by `applying(_:)` from portal settings; nil in a parsed profile.
    public var lockNow: LockNowWindow?
    /// A parent's "Release now": the downtime window in progress at this
    /// instant ends at it. Later windows are unaffected. From the portal only.
    public var releasedAt: Date?
    /// A parent's school-holiday choice, from the portal only.
    public var holidaySchedule: HolidaySchedule?

    public init() {}

    /// Validated by the parser, so the force unwrap can only fail if a
    /// hand-built config is wrong; fall back rather than crash the daemon.
    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: LullConstants.defaultTimeZoneIdentifier)!
    }

    /// Allowed ranges for integer keys; out-of-range values are clamped with a warning.
    public enum Range {
        public static let warningMinutes: ClosedRange<Int> = 0...240
        public static let finalCountdownSeconds: ClosedRange<Int> = 0...600
        public static let snoozeMinutes: ClosedRange<Int> = 1...120
        public static let maxSnoozesPerWindow: ClosedRange<Int> = 0...10
        public static let overrideDurationMinutes: ClosedRange<Int> = 1...720
        public static let overrideMaxAttempts: ClosedRange<Int> = 1...100
        public static let overrideLockoutMinutes: ClosedRange<Int> = 1...1440
        public static let timeSyncIntervalMinutes: ClosedRange<Int> = 5...1440
        public static let maxClockDriftSeconds: ClosedRange<Int> = 5...3600
        public static let agentMissingGraceSeconds: ClosedRange<Int> = 1...120
    }
}

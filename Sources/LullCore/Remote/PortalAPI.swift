import Foundation

/// Wire format between lulld and the Lull portal (lull-portal contract/PORTAL_API.md).
/// JSON fixtures in Tests/Fixtures/portal/ are decoded by both the Swift and
/// the portal's tests, so the two sides can't drift apart.
public enum PortalAPI {
    /// Bump only for incompatible changes; it is part of every path.
    public static let version = 1

    public enum Path {
        public static let register = "api/device/v1/register"
        public static let settings = "api/device/v1/settings"
        public static let checkIn = "api/device/v1/checkin"
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Registration

    /// Sent once, when lulld has no device token. Contains the enrolment
    /// secret: never log or persist this value.
    public struct RegisterRequest: Codable, Sendable, Equatable {
        public var serialNumber: String
        public var hardwareUUID: String
        public var enrolmentSecret: String
        public var version: String

        public init(serialNumber: String, hardwareUUID: String, enrolmentSecret: String, version: String = LullConstants.version) {
            self.serialNumber = serialNumber
            self.hardwareUUID = hardwareUUID
            self.enrolmentSecret = enrolmentSecret
            self.version = version
        }
    }

    /// `deviceToken` is a bearer secret, stored only in the root-only portal.json.
    public struct RegisterResponse: Codable, Sendable, Equatable {
        public var deviceId: String
        public var deviceToken: String

        public init(deviceId: String, deviceToken: String) {
            self.deviceId = deviceId
            self.deviceToken = deviceToken
        }
    }

    // MARK: Settings (portal -> Mac)

    public struct WindowPayload: Codable, Sendable, Equatable {
        /// `HH:mm`, in the profile's `Timezone`.
        public var start: String
        public var end: String

        public init(start: String, end: String) {
            self.start = start
            self.end = end
        }
    }

    /// One window of an advanced schedule: `day` (`Mon` ... `Sun`) is the day
    /// it starts; times as `WindowPayload`, except that the same start and end
    /// is a whole 24 hours.
    public struct WeekWindowPayload: Codable, Sendable, Equatable {
        public var day: String
        public var start: String
        public var end: String

        public init(day: String, start: String, end: String) {
            self.day = day
            self.start = start
            self.end = end
        }
    }

    /// Unvalidated; see `RemoteSettings.validate(_:)`.
    public struct SettingsPayload: Codable, Sendable, Equatable {
        public var revision: Int64
        public var enabled: Bool
        /// nil = follow the school's (profile's) schedule for these days.
        public var schoolNights: WindowPayload?
        public var weekend: WindowPayload?
        /// "Lock down now": both set, or both absent. ISO 8601, whole seconds.
        public var lockFrom: Date?
        public var lockUntil: Date?
        /// "Release now": the window in progress at this instant ends there.
        public var releasedAt: Date?
        /// Opted out of the schedules for these days (omitted = false).
        public var schoolNightsOff: Bool?
        public var weekendOff: Bool?
        /// The parent's times for school holidays (nil = none).
        public var holiday: WindowPayload?
        /// Opted out of downtime during school holidays (omitted = false).
        public var holidayOff: Bool?
        /// When `holiday` / `holidayOff` apply instead of the usual settings.
        public var holidayPeriods: [HolidayPeriodPayload]?
        /// An advanced schedule: replaces the profile's schedules and the per-kind choices.
        public var week: [WeekWindowPayload]?
        /// An advanced schedule for school holidays: replaces `holiday` / `holidayOff`.
        public var holidayWeek: [WeekWindowPayload]?

        public init(
            revision: Int64, enabled: Bool, schoolNights: WindowPayload? = nil, weekend: WindowPayload? = nil, lockFrom: Date? = nil,
            lockUntil: Date? = nil, releasedAt: Date? = nil, schoolNightsOff: Bool? = nil, weekendOff: Bool? = nil,
            holiday: WindowPayload? = nil, holidayOff: Bool? = nil, holidayPeriods: [HolidayPeriodPayload]? = nil,
            week: [WeekWindowPayload]? = nil, holidayWeek: [WeekWindowPayload]? = nil
        ) {
            self.revision = revision
            self.enabled = enabled
            self.schoolNights = schoolNights
            self.weekend = weekend
            self.lockFrom = lockFrom
            self.lockUntil = lockUntil
            self.releasedAt = releasedAt
            self.schoolNightsOff = schoolNightsOff
            self.weekendOff = weekendOff
            self.holiday = holiday
            self.holidayOff = holidayOff
            self.holidayPeriods = holidayPeriods
            self.week = week
            self.holidayWeek = holidayWeek
        }
    }

    /// A school-holiday period, in the profile's `Timezone`: `start` is
    /// `YYYY-MM-DDTHH:mm` (school end on the last school day), `lastDay` is
    /// `YYYY-MM-DD` (the day before school goes back).
    public struct HolidayPeriodPayload: Codable, Sendable, Equatable {
        public var start: String
        public var lastDay: String

        public init(start: String, lastDay: String) {
            self.start = start
            self.lastDay = lastDay
        }
    }

    // MARK: Check-in (Mac -> portal)

    public struct ScheduleSummary: Codable, Sendable, Equatable {
        public var name: String
        /// `Mon` ... `Sun`, Monday first.
        public var days: [String]
        public var start: String
        public var end: String

        public init(_ rule: ScheduleRule) {
            name = rule.name
            days = Weekday.mondayFirst.filter(rule.days.contains).map(\.configString)
            start = rule.start.configString
            end = rule.end.configString
        }
    }

    public struct UserSummary: Codable, Sendable, Equatable {
        public var username: String
        /// The account's full name, which the portal shows for the student
        /// (omitted when it has none).
        public var fullName: String?
        public var exempt: Bool
        public var agentConnected: Bool

        public init(username: String, fullName: String? = nil, exempt: Bool, agentConnected: Bool) {
            self.username = username
            self.fullName = fullName
            self.exempt = exempt
            self.agentConnected = agentConnected
        }
    }

    /// What the Mac is actually enforcing, for the portal's status view. A
    /// subset of `DaemonStatus`; no secrets. Times are lulld's trusted times.
    public struct CheckIn: Codable, Sendable, Equatable {
        public var version: String
        public var debugBuild: Bool
        public var reportedAt: Date
        public var phase: String
        public var phaseReason: String?
        public var scheduleName: String
        public var windowStart: Date?
        public var windowEnd: Date?
        public var nextTransition: Date?
        public var timeZone: String?
        /// Effective (profile + portal) values.
        public var enabled: Bool?
        public var schedules: [ScheduleSummary]
        /// The school's baseline from the profile (IT, per year/device group),
        /// so the portal can show it and pre-fill "Customise".
        public var profileSchedules: [ScheduleSummary]?
        /// Portal revision in force, or nil while the profile's schedules apply.
        public var settingsRevision: Int64?
        /// Why the last settings from the portal were refused, if they were.
        public var settingsError: String?
        public var configValid: Bool
        public var configErrors: [String]
        public var timeStatus: String
        /// GUI sessions on the Mac. The portal pins the first non-exempt user
        /// as the device's primary user.
        public var users: [UserSummary]

        /// `config` is the effective config being enforced (nil if none);
        /// `profile` the profile's own config.
        public static func make(
            status: DaemonStatus, config: LullConfig?, profile: LullConfig? = nil, settingsRevision: Int64?, settingsError: String?
        ) -> CheckIn {
            CheckIn(
                version: status.version, debugBuild: status.debugBuild, reportedAt: status.generatedAt,
                phase: status.phase.rawValue, phaseReason: status.phaseReason, scheduleName: status.scheduleName,
                windowStart: status.windowStart, windowEnd: status.windowEnd, nextTransition: status.nextTransition,
                timeZone: config?.timeZoneIdentifier, enabled: config?.enabled,
                schedules: config?.schedules.map(ScheduleSummary.init) ?? [],
                profileSchedules: profile?.schedules.map(ScheduleSummary.init),
                settingsRevision: settingsRevision, settingsError: settingsError,
                configValid: status.config.currentValid, configErrors: status.config.errors,
                timeStatus: status.time.status.rawValue,
                users: status.agents.map {
                    UserSummary(username: $0.username, fullName: $0.fullName, exempt: $0.exempt, agentConnected: $0.connected)
                })
        }
    }
}

extension Weekday {
    public static let mondayFirst: [Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]

    /// Profile spelling, the inverse of `init(configString:)`.
    public var configString: String {
        switch self {
        case .mon: return "Mon"
        case .tue: return "Tue"
        case .wed: return "Wed"
        case .thu: return "Thu"
        case .fri: return "Fri"
        case .sat: return "Sat"
        case .sun: return "Sun"
        }
    }
}

extension TimeOfDay {
    /// `HH:mm`, the inverse of `init(string:)`.
    public var configString: String { String(format: "%02d:%02d", hour, minute) }
}

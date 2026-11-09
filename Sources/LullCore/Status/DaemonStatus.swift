import Foundation

/// Snapshot the daemon publishes to `/var/db/lull/status.json` (0644) and
/// `lullctl status --json`. World-readable, so it must never contain secrets.
///
/// Times are absolute *trusted* times. Readers must not compare them with
/// their own wall clock (which may have been changed); instead use
/// `trustedNow(continuousSeconds:bootSessionUUID:)` with the reader's own
/// continuous clock, which is shared system-wide.
public struct DaemonStatus: Codable, Sendable, Equatable {
    public struct ConfigInfo: Codable, Sendable, Equatable {
        /// `managed`, `dev` (Debug only) or `none`.
        public var source: String
        /// Whether the config currently delivered is valid.
        public var currentValid: Bool
        /// True when enforcing a previously valid config because the current one isn't.
        public var usingLastValid: Bool
        public var hasActiveConfig: Bool
        public var loadedAt: Date?
        public var errors: [String]
        public var warnings: [String]
        /// Keys present but not enforced by a profile (ignored in Release builds).
        public var ignoredUnforcedKeys: [String]
        public var timeZone: String?

        public init(
            source: String = "none", currentValid: Bool = false, usingLastValid: Bool = false,
            hasActiveConfig: Bool = false, loadedAt: Date? = nil, errors: [String] = [], warnings: [String] = [],
            ignoredUnforcedKeys: [String] = [], timeZone: String? = nil
        ) {
            self.source = source
            self.currentValid = currentValid
            self.usingLastValid = usingLastValid
            self.hasActiveConfig = hasActiveConfig
            self.loadedAt = loadedAt
            self.errors = errors
            self.warnings = warnings
            self.ignoredUnforcedKeys = ignoredUnforcedKeys
            self.timeZone = timeZone
        }
    }

    public struct TimeInfo: Codable, Sendable, Equatable {
        public var status: TrustedTimeStatus
        public var lastSync: Date?
        public var lastSyncServer: String?
        public var lastSyncError: String?
        /// System wall clock minus trusted time, seconds. Large values mean the
        /// clock was changed (or is simply wrong); it doesn't affect enforcement.
        public var wallClockOffsetSeconds: Double
        public var lastTamper: ClockTamperEvent?
        public var offlineBootPolicy: OfflineBootPolicy

        public init(
            status: TrustedTimeStatus, lastSync: Date? = nil, lastSyncServer: String? = nil, lastSyncError: String? = nil,
            wallClockOffsetSeconds: Double = 0, lastTamper: ClockTamperEvent? = nil,
            offlineBootPolicy: OfflineBootPolicy = .forwardOnly
        ) {
            self.status = status
            self.lastSync = lastSync
            self.lastSyncServer = lastSyncServer
            self.lastSyncError = lastSyncError
            self.wallClockOffsetSeconds = wallClockOffsetSeconds
            self.lastTamper = lastTamper
            self.offlineBootPolicy = offlineBootPolicy
        }
    }

    public struct OverrideInfo: Codable, Sendable, Equatable {
        public var enabled: Bool
        /// `file` (override.json), `profile`, or `none`. Never the hash itself.
        public var hashSource: String
        public var activeUntil: Date?
        public var lockedOutUntil: Date?

        public init(enabled: Bool = false, hashSource: String = "none", activeUntil: Date? = nil, lockedOutUntil: Date? = nil) {
            self.enabled = enabled
            self.hashSource = hashSource
            self.activeUntil = activeUntil
            self.lockedOutUntil = lockedOutUntil
        }
    }

    /// Parent portal (lull-portal contract/PORTAL_API.md). Nil when the profile has no `Portal`.
    /// Never contains the enrolment secret or the device token.
    public struct PortalInfo: Codable, Sendable, Equatable {
        public var url: String
        /// Has a device token for this portal.
        public var registered: Bool
        public var deviceId: String?
        /// `portal` when portal settings are in force, otherwise `profile`.
        public var settingsSource: String
        public var settingsRevision: Int64?
        /// Why the last settings from the portal were refused, if they were.
        public var settingsError: String?
        public var lastFetch: Date?
        public var lastCheckIn: Date?
        /// Last registration, fetch or check-in problem; cleared by success.
        public var lastError: String?
        /// IT de-registered this Mac: it uses its profile only until enrolled again.
        public var deregisteredAt: Date?

        public init(
            url: String, registered: Bool = false, deviceId: String? = nil, settingsSource: String = "profile",
            settingsRevision: Int64? = nil, settingsError: String? = nil, lastFetch: Date? = nil, lastCheckIn: Date? = nil,
            lastError: String? = nil, deregisteredAt: Date? = nil
        ) {
            self.url = url
            self.registered = registered
            self.deviceId = deviceId
            self.settingsSource = settingsSource
            self.settingsRevision = settingsRevision
            self.settingsError = settingsError
            self.lastFetch = lastFetch
            self.lastCheckIn = lastCheckIn
            self.lastError = lastError
            self.deregisteredAt = deregisteredAt
        }
    }

    /// Per GUI session: connected agents plus sessions with no agent.
    public struct AgentInfo: Codable, Sendable, Equatable {
        public var uid: Int
        public var username: String
        /// The account's full name, if it has one.
        public var fullName: String?
        public var connected: Bool
        public var exempt: Bool

        public init(uid: Int, username: String, fullName: String? = nil, connected: Bool, exempt: Bool) {
            self.uid = uid
            self.username = username
            self.fullName = fullName
            self.connected = connected
            self.exempt = exempt
        }
    }

    public var version: String
    public var debugBuild: Bool
    /// Trusted time when this snapshot was produced.
    public var generatedAt: Date
    /// Continuous clock reading at `generatedAt` (see type comment).
    public var generatedAtContinuous: TimeInterval
    public var bootSessionUUID: String

    public var phase: LullPhase
    /// Why the phase isn't simply the schedule's, e.g. "awaiting time sync".
    public var phaseReason: String?
    public var scheduleName: String
    public var windowStart: Date?
    public var windowEnd: Date?
    public var lockStart: Date?
    /// Next time the schedule phase changes (lock start, or window end when locked).
    public var nextTransition: Date?
    public var snoozeAvailable: Bool
    public var snoozesUsed: Int

    public var config: ConfigInfo
    public var time: TimeInfo
    public var override: OverrideInfo
    public var agents: [AgentInfo]
    public var portal: PortalInfo?

    public init(
        version: String = LullConstants.version, debugBuild: Bool, generatedAt: Date, generatedAtContinuous: TimeInterval,
        bootSessionUUID: String, phase: LullPhase, phaseReason: String? = nil, scheduleName: String = "",
        windowStart: Date? = nil, windowEnd: Date? = nil, lockStart: Date? = nil, nextTransition: Date? = nil,
        snoozeAvailable: Bool = false, snoozesUsed: Int = 0, config: ConfigInfo = ConfigInfo(), time: TimeInfo,
        override: OverrideInfo = OverrideInfo(), agents: [AgentInfo] = [], portal: PortalInfo? = nil
    ) {
        self.version = version
        self.debugBuild = debugBuild
        self.generatedAt = generatedAt
        self.generatedAtContinuous = generatedAtContinuous
        self.bootSessionUUID = bootSessionUUID
        self.phase = phase
        self.phaseReason = phaseReason
        self.scheduleName = scheduleName
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.lockStart = lockStart
        self.nextTransition = nextTransition
        self.snoozeAvailable = snoozeAvailable
        self.snoozesUsed = snoozesUsed
        self.config = config
        self.time = time
        self.override = override
        self.agents = agents
        self.portal = portal
    }

    /// Trusted "now" as seen by a reader, or nil if the machine rebooted since
    /// the snapshot (the continuous clock restarted, so it can't be compared).
    public func trustedNow(continuousSeconds: TimeInterval, bootSessionUUID: String) -> Date? {
        guard bootSessionUUID == self.bootSessionUUID, continuousSeconds >= generatedAtContinuous else { return nil }
        return generatedAt.addingTimeInterval(continuousSeconds - generatedAtContinuous)
    }

    /// Same snapshot with the fields that change every tick zeroed, so the
    /// daemon only rewrites the file when something meaningful changed.
    public var significantContent: DaemonStatus {
        var copy = self
        copy.generatedAt = Date(timeIntervalSince1970: 0)
        copy.generatedAtContinuous = 0
        copy.time.wallClockOffsetSeconds = (time.wallClockOffsetSeconds / 10).rounded() * 10
        return copy
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

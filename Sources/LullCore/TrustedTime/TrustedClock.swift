import Foundation

/// A point where we knew the real time: "at continuous second X it was unix time Y".
/// Trusted time is extrapolated from here using the continuous clock, so changing
/// the wall clock afterwards has no effect.
public struct TimeAnchor: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// From an SNTP or HTTPS Date sync.
        case sync
        /// Estimated at boot without network (see `OfflineBootPolicy`).
        case bootEstimate
    }

    public var trustedUnixTime: TimeInterval
    public var continuousSecondsAtSample: TimeInterval
    public var bootSessionUUID: String
    public var source: Source

    public init(
        trustedUnixTime: TimeInterval, continuousSecondsAtSample: TimeInterval,
        bootSessionUUID: String, source: Source
    ) {
        self.trustedUnixTime = trustedUnixTime
        self.continuousSecondsAtSample = continuousSecondsAtSample
        self.bootSessionUUID = bootSessionUUID
        self.source = source
    }
}

/// What the daemon persists in state.json (and reloads on start).
public struct PersistedTimeState: Codable, Sendable, Equatable {
    public var anchor: TimeAnchor
    public var lastKnownTrusted: TimeInterval
    public var lastSync: TimeInterval?

    public init(anchor: TimeAnchor, lastKnownTrusted: TimeInterval, lastSync: TimeInterval?) {
        self.anchor = anchor
        self.lastKnownTrusted = lastKnownTrusted
        self.lastSync = lastSync
    }
}

/// Logged as a `clock_tamper` event.
public struct ClockTamperEvent: Codable, Sendable, Equatable {
    /// Wall time we expected (previous wall + elapsed continuous time).
    public var expectedWall: Date
    public var observedWall: Date
    /// observed - expected, seconds. Positive means the clock was moved forward.
    public var delta: TimeInterval
    public var trustedTime: Date
}

/// A time measurement from the network, already corrected for round-trip delay
/// by the protocol layer (`SNTPPacket` / `HTTPDate`).
public struct TimeSyncSample: Sendable, Equatable {
    /// Best estimate of real unix time at `continuousSeconds`.
    public var unixTime: TimeInterval
    public var continuousSeconds: TimeInterval
    public var roundTrip: TimeInterval
    public var server: String
    /// True when the source is authenticated (HTTPS: TLS proves it came from
    /// the server). SNTP is not: anyone controlling the network can answer.
    public var authenticated: Bool

    public init(
        unixTime: TimeInterval, continuousSeconds: TimeInterval, roundTrip: TimeInterval, server: String,
        authenticated: Bool = false
    ) {
        self.unixTime = unixTime
        self.continuousSeconds = continuousSeconds
        self.roundTrip = roundTrip
        self.server = server
        self.authenticated = authenticated
    }
}

public enum TimeSyncRejection: Error, Equatable, CustomStringConvertible {
    case roundTripTooLong(TimeInterval)
    case outOfSaneRange(TimeInterval)
    case staleSample
    /// An unauthenticated source tried to move trusted time further than clock
    /// drift can explain. Needs confirmation from an authenticated source.
    case implausibleCorrection(correction: TimeInterval, allowed: TimeInterval)

    public var description: String {
        switch self {
        case .implausibleCorrection(let c, let a):
            return
                "unauthenticated correction of \(Int(c.rounded()))s exceeds the \(Int(a.rounded()))s drift allowance; needs HTTPS confirmation"
        case .roundTripTooLong(let rtt): return "round trip too long (\(rtt)s)"
        case .outOfSaneRange(let t): return "time outside sane range (\(t))"
        case .staleSample: return "sample is from before the current boot or anchor"
        }
    }
}

public enum TrustedTimeStatus: String, Codable, Sendable {
    /// Anchored to a network sync this boot (or earlier in the same boot session).
    case synced
    /// No sync yet this boot; using `max(wall, lastKnownTrusted)` (ForwardOnly).
    case provisional
    /// No sync yet this boot and policy is LockUntilSynced: daemon must lock.
    case awaitingSync
}

/// The trusted-time engine. Owned by the daemon; pure apart from the
/// injected `ClockSource`.
public struct TrustedClock: Sendable {
    public static let maxRoundTrip: TimeInterval = 5
    /// 2024-01-01T00:00:00Z. Anything earlier is a broken or spoofed server.
    public static let saneMinimum: TimeInterval = 1_704_067_200
    /// 2100-01-01T00:00:00Z.
    public static let saneMaximum: TimeInterval = 4_102_444_800

    public private(set) var anchor: TimeAnchor
    public private(set) var lastSync: Date?
    public private(set) var lastTamperEvent: ClockTamperEvent?
    public var offlineBootPolicy: OfflineBootPolicy
    public var maxClockDriftSeconds: TimeInterval

    private var lastTick: (wall: Date, continuous: TimeInterval)

    /// Starts the engine at daemon launch.
    ///
    /// - Same boot session as the persisted anchor (daemon restarted/killed):
    ///   keep the anchor, so restarting the daemon after changing the clock gains nothing.
    /// - New boot: we can't know how long the Mac was off, so start from
    ///   `max(wall, lastKnownTrusted)`: never move backwards. Moving forward may lock
    ///   early, which is acceptable. The daemon should sync immediately.
    public init(
        clock: ClockSource, persisted: PersistedTimeState?,
        policy: OfflineBootPolicy, maxClockDriftSeconds: TimeInterval
    ) {
        let wall = clock.wallNow
        let cont = clock.continuousSeconds
        let boot = clock.bootSessionUUID
        offlineBootPolicy = policy
        self.maxClockDriftSeconds = maxClockDriftSeconds
        lastTick = (wall, cont)

        if let p = persisted, !boot.isEmpty, p.anchor.bootSessionUUID == boot,
            cont >= p.anchor.continuousSecondsAtSample
        {
            anchor = p.anchor
            lastSync = p.anchor.source == .sync ? p.lastSync.map(Date.init(timeIntervalSince1970:)) : nil
        } else {
            let base = max(wall.timeIntervalSince1970, persisted?.lastKnownTrusted ?? 0)
            anchor = TimeAnchor(
                trustedUnixTime: base, continuousSecondsAtSample: cont,
                bootSessionUUID: boot, source: .bootEstimate)
            lastSync = nil
        }
    }

    public func trustedNow(clock: ClockSource) -> Date {
        let elapsed = clock.continuousSeconds - anchor.continuousSecondsAtSample
        return Date(timeIntervalSince1970: anchor.trustedUnixTime + elapsed)
    }

    public var status: TrustedTimeStatus {
        if anchor.source == .sync { return .synced }
        return offlineBootPolicy == .lockUntilSynced ? .awaitingSync : .provisional
    }

    /// Call about once a second. Detects wall-clock jumps by comparing how far
    /// the wall clock moved with how far the continuous clock moved. Sleep moves
    /// both equally, so it isn't flagged. The wall clock is never used for
    /// trusted time anyway; this is for logging and `lullctl status`.
    @discardableResult
    public mutating func tick(clock: ClockSource) -> ClockTamperEvent? {
        let wall = clock.wallNow
        let cont = clock.continuousSeconds
        let expected = lastTick.wall.addingTimeInterval(cont - lastTick.continuous)
        let delta = wall.timeIntervalSince(expected)
        lastTick = (wall, cont)
        guard abs(delta) > maxClockDriftSeconds else { return nil }
        let event = ClockTamperEvent(
            expectedWall: expected, observedWall: wall, delta: delta,
            trustedTime: trustedNow(clock: clock))
        lastTamperEvent = event
        return event
    }

    /// How far an *unauthenticated* (SNTP) sample may move trusted time.
    ///
    /// SNTP can be spoofed by anyone who controls the network (e.g. a student's
    /// home router answering for time.apple.com), so it may only correct what a
    /// real clock could plausibly have drifted. After a sync this boot that's
    /// small: 1s plus 200 ppm of the time since (crystal drift is typically
    /// < 50 ppm). After an offline boot the anchor is the RTC (which standard
    /// users can't set) or the last trusted time, so allow a few minutes. Larger
    /// corrections need the authenticated HTTPS source. A spoofer can therefore
    /// creep time by at most ~0.7s per hour of sync interval.
    public static let syncDriftBase: TimeInterval = 1
    public static let syncDriftRate: Double = 0.000_2
    public static let bootEstimateAllowance: TimeInterval = 120

    public func unauthenticatedAllowance(clock: ClockSource) -> TimeInterval {
        switch anchor.source {
        case .sync: return Self.syncDriftBase + Self.syncDriftRate * max(0, clock.continuousSeconds - anchor.continuousSecondsAtSample)
        case .bootEstimate: return Self.bootEstimateAllowance
        }
    }

    /// Re-anchors on a good network sample. An authenticated sample is
    /// authoritative and may move trusted time by any amount (e.g. undoing an
    /// over-eager ForwardOnly boot); an unauthenticated one only within
    /// `unauthenticatedAllowance`.
    public mutating func applySync(_ sample: TimeSyncSample, clock: ClockSource) -> Result<Date, TimeSyncRejection> {
        guard sample.roundTrip >= 0, sample.roundTrip <= Self.maxRoundTrip else {
            return .failure(.roundTripTooLong(sample.roundTrip))
        }
        guard sample.unixTime >= Self.saneMinimum, sample.unixTime <= Self.saneMaximum else {
            return .failure(.outOfSaneRange(sample.unixTime))
        }
        let cont = clock.continuousSeconds
        guard sample.continuousSeconds <= cont, cont - sample.continuousSeconds <= 60 else {
            return .failure(.staleSample)
        }
        if !sample.authenticated {
            let current = anchor.trustedUnixTime + (sample.continuousSeconds - anchor.continuousSecondsAtSample)
            let correction = sample.unixTime - current
            let allowed = unauthenticatedAllowance(clock: clock)
            guard abs(correction) <= allowed else {
                return .failure(.implausibleCorrection(correction: correction, allowed: allowed))
            }
        }
        anchor = TimeAnchor(
            trustedUnixTime: sample.unixTime, continuousSecondsAtSample: sample.continuousSeconds,
            bootSessionUUID: clock.bootSessionUUID, source: .sync)
        let now = trustedNow(clock: clock)
        lastSync = now
        return .success(now)
    }

    /// Snapshot to persist every minute and on clean shutdown.
    public func persistedState(clock: ClockSource) -> PersistedTimeState {
        PersistedTimeState(
            anchor: anchor,
            lastKnownTrusted: trustedNow(clock: clock).timeIntervalSince1970,
            lastSync: lastSync?.timeIntervalSince1970)
    }
}

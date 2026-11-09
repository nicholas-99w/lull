import CryptoKit
import Foundation
import LullCore

/// The daemon's brain: config, trusted time, phase, persistence, status.
///
/// Not thread-safe by design: `lulld` drives it from one serial queue. Every
/// input (clock, config, files, network results) is injected, so the whole
/// lifecycle is unit-tested with fakes and never needs launchd or root.
public final class DaemonEngine {
    public struct Dependencies {
        public var clock: ClockSource
        public var configSource: ConfigSource
        public var store: StateStoring
        public var log: EventLogging
        public var paths: DaemonPaths
        public var parser: ConfigParser
        public var device: DeviceIdentifying

        public init(
            clock: ClockSource, configSource: ConfigSource, store: StateStoring, log: EventLogging, paths: DaemonPaths,
            parser: ConfigParser = ConfigParser(), device: DeviceIdentifying = SystemDeviceIdentity()
        ) {
            self.clock = clock
            self.configSource = configSource
            self.store = store
            self.log = log
            self.paths = paths
            self.parser = parser
            self.device = device
        }
    }

    public enum Timing {
        public static let configPollInterval: TimeInterval = 5
        public static let persistInterval: TimeInterval = 60
        public static let statusHeartbeat: TimeInterval = 30
        /// After a failed sync, retry sooner than the normal interval.
        public static let syncRetryInterval: TimeInterval = 60
        /// After a failed portal call, retry sooner than the poll interval.
        public static let portalRetryInterval: TimeInterval = 60
    }

    let deps: Dependencies
    public private(set) var state: PersistentState
    public private(set) var trusted: TrustedClock
    /// The profile's config (current if valid, otherwise last valid). Includes
    /// the profile hash when the current profile delivered one. Persisted as
    /// `lastValidConfig`; never includes portal settings.
    public private(set) var profileConfig: LullConfig?
    public private(set) var status: DaemonStatus

    private var configInfo = DaemonStatus.ConfigInfo()
    private var lastConfigFingerprint: ConfigFingerprint?
    private var overrideFileHash: PassphraseHash?
    private var overrideFileIssue: String?
    private var lastPhase: LullPhase?
    private var lastPhaseReason: String?
    private var lastResolved: Resolved?
    private var agentInfos: [DaemonStatus.AgentInfo] = []
    private var lastConfigPoll: TimeInterval = -.infinity
    private var lastPersist: TimeInterval = -.infinity
    private var lastStatusWrite: TimeInterval = -.infinity
    private var lastWrittenStatus: DaemonStatus?
    private var nextSyncDue: TimeInterval
    private var syncInFlight = false
    private var lastSyncServer: String?
    private var lastSyncError: String?

    // Parent portal (lull-portal contract/PORTAL_API.md). Network work happens in lulld's
    // PortalClient; the engine only decides what to ask for and applies results.
    private var portalCredentials: PortalCredentials?
    private var portalInFlight = false
    private var nextPortalFetch: TimeInterval
    private var portalCheckInPending = false
    private var portalETag: String?
    private var portalLastFetch: Date?
    private var portalLastCheckIn: Date?
    private var portalLastError: String?
    private var portalSettingsError: String?
    /// Why lulld isn't registered yet, so it can try again as soon as that's
    /// fixed rather than a whole poll interval later (see `enrolmentFixed()`).
    private var enrolmentWait = EnrolmentWait.none

    private enum EnrolmentWait: Equatable {
        /// Nothing to watch: retry at the normal time (e.g. after a network error or a conflict).
        case none
        /// No usable secret (file missing, or refused locally, e.g. its permissions).
        case forSecret
        /// The portal refused this secret (SHA-256, kept in memory only).
        case forDifferentSecret(Data)
    }

    #if DEBUG
        /// Debug-only: shifts trusted time for testing schedules (seconds).
        public var debugTimeOffset: TimeInterval = 0
        /// Debug-only: use this portal (http allowed, for a local test portal)
        /// whether or not the profile has a `Portal` dict.
        public var debugPortalURL: URL?
        private var debugConfigTimeOffset: TimeInterval?
        private var debugLockedSince: TimeInterval?
    #endif

    public init(_ deps: Dependencies) {
        self.deps = deps
        let clock = deps.clock
        switch deps.store.load() {
        case .success(let s): state = s ?? PersistentState()
        case .failure(let e):
            // Root-only file; corruption means a crash mid-write or disk trouble.
            // Starting fresh is safe: trusted time falls back to the wall clock
            // (and ForwardOnly can't go back further than that).
            state = PersistentState()
            deps.log.event("state_unreadable", category: .config, level: .error, fields: ["error": "\(e)"])
        }
        profileConfig = state.lastValidConfig
        let config = state.lastValidConfig ?? LullConfig()
        trusted = TrustedClock(
            clock: clock, persisted: state.time, policy: config.offlineBootPolicy,
            maxClockDriftSeconds: TimeInterval(config.maxClockDriftSeconds))
        nextSyncDue = clock.continuousSeconds
        nextPortalFetch = clock.continuousSeconds
        status = DaemonStatus(
            debugBuild: Self.isDebugBuild, generatedAt: trusted.trustedNow(clock: clock),
            generatedAtContinuous: clock.continuousSeconds, bootSessionUUID: clock.bootSessionUUID,
            phase: .disabled, time: DaemonStatus.TimeInfo(status: trusted.status))

        deps.log.event(
            "daemon_start", category: .time,
            fields: [
                "version": LullConstants.version, "debugBuild": Self.isDebugBuild,
                "trustedTime": trusted.trustedNow(clock: clock), "timeStatus": trusted.status.rawValue,
                "anchorSource": trusted.anchor.source.rawValue,
            ])
        loadPortalCredentials()
        reloadConfig()
        tick()
    }

    public static var isDebugBuild: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    /// Trusted time used for all decisions (plus the Debug-only offset).
    public var now: Date {
        var t = trusted.trustedNow(clock: deps.clock)
        #if DEBUG
            t = t.addingTimeInterval(debugTimeOffset + (debugConfigTimeOffset ?? 0))
        #endif
        return t
    }

    // MARK: - Tick

    /// Call about once a second.
    public func tick() {
        let cont = deps.clock.continuousSeconds
        if let tamper = trusted.tick(clock: deps.clock) {
            deps.log.event(
                "clock_tamper", category: .time, level: .error,
                fields: [
                    "expectedWall": tamper.expectedWall, "observedWall": tamper.observedWall, "delta": tamper.delta,
                    "trustedTime": tamper.trustedTime,
                ])
        }
        if cont - lastConfigPoll >= Timing.configPollInterval {
            reloadConfig()
        }
        updatePhase()
        if cont - lastPersist >= Timing.persistInterval {
            persist()
        }
        writeStatusIfNeeded()
    }

    // MARK: - Config

    /// Re-reads config and override.json. Cheap; also called on file-system events.
    public func reloadConfig() {
        lastConfigPoll = deps.clock.continuousSeconds
        loadOverrideFile()
        let raw = deps.configSource.load()
        #if DEBUG
            debugConfigTimeOffset = raw.debugTimeOffset
        #endif

        guard let values = raw.values else {
            // No profile at all. Keep enforcing the last valid config (a student
            // can't remove a device profile; decommissioning is done by the
            // uninstaller or by pushing Enabled=false).
            let fingerprint = ConfigFingerprint(config: nil, errors: [], warnings: [], source: .none, ignored: raw.ignoredUnforcedKeys)
            if fingerprint != lastConfigFingerprint {
                lastConfigFingerprint = fingerprint
                deps.log.event(
                    "config_missing", category: .config, level: .error,
                    fields: ["usingLastValid": state.lastValidConfig != nil])
            }
            configInfo = DaemonStatus.ConfigInfo(
                source: ConfigSourceKind.none.rawValue, currentValid: false, usingLastValid: profileConfig != nil,
                hasActiveConfig: profileConfig != nil, loadedAt: configInfo.loadedAt,
                errors: ["no configuration profile found for \(LullConstants.preferenceDomain)"],
                ignoredUnforcedKeys: raw.ignoredUnforcedKeys, timeZone: profileConfig?.timeZoneIdentifier)
            return
        }

        let result = deps.parser.parse(values, fallbackTimeZone: state.lastValidTimeZone)
        let errors = result.errors.map(\.description)
        let warnings = result.warnings.map(\.description)
        // Detect changes by parsed outcome, so polling every 5s doesn't spam the log.
        let fingerprint = ConfigFingerprint(
            config: result.config, errors: errors, warnings: warnings, source: raw.source, ignored: raw.ignoredUnforcedKeys)
        let changed = fingerprint != lastConfigFingerprint
        lastConfigFingerprint = fingerprint

        if let config = result.config {
            if changed {
                let previous = profileConfig
                profileConfig = config
                var persisted = config
                persisted.overridePasswordHash = nil
                state.lastValidConfig = persisted
                state.lastValidTimeZone = config.timeZoneIdentifier
                trusted.offlineBootPolicy = config.offlineBootPolicy
                trusted.maxClockDriftSeconds = TimeInterval(config.maxClockDriftSeconds)
                if previous?.timeServers != config.timeServers {
                    nextSyncDue = deps.clock.continuousSeconds
                }
                if previous?.portal != config.portal {
                    // New or changed portal: contact it now, not at the old poll time.
                    nextPortalFetch = deps.clock.continuousSeconds
                    portalETag = nil
                }
                configInfo.loadedAt = now
                deps.log.event(
                    "config_loaded", category: .config,
                    fields: [
                        "source": raw.source.rawValue, "warnings": warnings, "ignoredUnforcedKeys": raw.ignoredUnforcedKeys,
                        "schedules": config.schedules.count, "enabled": config.enabled, "timeZone": config.timeZoneIdentifier,
                    ])
                persist()
            }
        } else if changed {
            deps.log.event(
                "config_rejected", category: .config, level: .error,
                fields: ["source": raw.source.rawValue, "errors": errors, "usingLastValid": profileConfig != nil])
        }
        configInfo = DaemonStatus.ConfigInfo(
            source: raw.source.rawValue, currentValid: result.isValid, usingLastValid: !result.isValid && profileConfig != nil,
            hasActiveConfig: profileConfig != nil, loadedAt: configInfo.loadedAt, errors: errors, warnings: warnings,
            ignoredUnforcedKeys: raw.ignoredUnforcedKeys, timeZone: profileConfig?.timeZoneIdentifier)
    }

    private func loadOverrideFile() {
        switch OverrideHashFile.load(path: deps.paths.overrideHashPath, owner: deps.paths.requiredOwnerUID) {
        case .success(let hash):
            overrideFileHash = hash
            if overrideFileIssue != nil {
                deps.log.event("override_file_ok", category: .override)
            }
            overrideFileIssue = nil
        case .failure(let e):
            overrideFileHash = nil
            if overrideFileIssue != e.description {
                deps.log.event("override_file_rejected", category: .override, level: .error, fields: ["reason": e.description])
            }
            overrideFileIssue = e.description
        }
    }

    /// Compared with Equatable rather than encoded: `Set` (schedule days) has no
    /// stable encoding order, which would make every poll look like a change.
    struct ConfigFingerprint: Equatable {
        var config: LullConfig?
        var errors: [String]
        var warnings: [String]
        var source: ConfigSourceKind
        var ignored: [String]
    }

    // MARK: - Phase

    private struct Resolved {
        var phase: LullPhase
        var reason: String?
        var evaluation: PhaseEvaluation?
    }

    private func resolvePhase(at now: Date) -> Resolved {
        guard let config = activeConfig else {
            // Never had a valid config: never lock.
            return Resolved(phase: .disabled, reason: "no valid configuration")
        }
        #if DEBUG
            if FileManager.default.fileExists(atPath: deps.paths.disableFlagPath) {
                return Resolved(phase: .disabled, reason: "DEBUG: DISABLE file present")
            }
        #endif
        guard config.enabled || config.lockNow != nil else { return Resolved(phase: .disabled, reason: disabledReason) }

        if let l = state.snooze, l.isExpired(at: now) {
            state.snooze = nil
        }
        let ev = ScheduleEngine(config: config).evaluate(at: now, snooze: state.snooze)
        var r = Resolved(phase: ev.phase, reason: ev.phase == .disabled ? disabledReason : nil, evaluation: ev)

        // LockUntilSynced: locked until the first successful sync this boot.
        // The admin override still works.
        let awaitingSync = trusted.status == .awaitingSync
        if awaitingSync && ev.phase != .locked && ev.phase != .disabled {
            r.phase = .locked
            r.reason = "awaiting time sync (OfflineBootPolicy=LockUntilSynced)"
        }
        if r.phase == .locked {
            if state.overrideGate.isGranted(at: now) {
                r.phase = .overridden
                r.reason = "admin override"
            }
        } else if state.overrideGate.grantedUntil != nil {
            // Lock is over: a grant must not carry into the next window.
            state.overrideGate.revoke()
        }
        return r
    }

    private var disabledReason: String {
        profileConfig?.enabled == false ? "Enabled is false" : "opted out in the parent portal"
    }

    private func updatePhase() {
        let now = self.now
        var r = resolvePhase(at: now)

        #if DEBUG
            // Debug-only: never stay locked longer than debugMaxLockSeconds
            // (continuous time, so clock changes can't extend it).
            let cont = deps.clock.continuousSeconds
            if r.phase == .locked {
                let since = debugLockedSince ?? cont
                debugLockedSince = since
                if cont - since >= LullConstants.debugMaxLockSeconds {
                    r.phase = .disabled
                    r.reason = "DEBUG: auto-released after \(Int(LullConstants.debugMaxLockSeconds))s"
                }
            } else {
                debugLockedSince = nil
            }
        #endif

        if r.phase != lastPhase || r.reason != lastPhaseReason {
            deps.log.event(
                "phase_transition", category: .schedule,
                fields: [
                    "from": lastPhase?.rawValue ?? "start", "to": r.phase.rawValue, "reason": r.reason ?? "",
                    "trustedTime": now, "scheduleName": r.evaluation?.scheduleName ?? "",
                ])
            lastPhase = r.phase
            lastPhaseReason = r.reason
            // Let parents see a lock/unlock straight away, not at the next poll.
            portalCheckInPending = true
        }
        lastResolved = r
        status = buildStatus(r, now: now)
    }

    // MARK: - Agent-facing state

    /// Device-wide phase after all rules (schedule, sync policy, override, Debug hatches).
    public var phase: LullPhase { lastPhase ?? .disabled }

    /// What one GUI session's agent should show. Exemption is per session,
    /// decided here and never by the agent.
    public func displayState(exempt: Bool) -> DisplayState {
        let now = self.now
        guard let r = lastResolved, let config = activeConfig else {
            return DisplayState(phase: .disabled, trustedNow: now)
        }
        var phase = r.phase
        if exempt && [.warning, .locked, .overridden].contains(phase) { phase = .exempt }
        return DisplayState.make(
            phase: phase, evaluation: r.evaluation, config: config, now: now, overrideAvailable: status.override.enabled)
    }

    /// Connected-agent summary for status.json, supplied by the XPC hub.
    public func updateAgents(_ agents: [DaemonStatus.AgentInfo]) {
        guard agents != agentInfos else { return }
        agentInfos = agents
        status.agents = agents
        writeStatusIfNeeded()
    }

    public enum PowerAction: String, Sendable {
        case shutdown
        case sleep
    }

    /// Whether a lock-screen power request is allowed right now. Only while
    /// locked (that's the only place the buttons exist), only for a session
    /// that isn't exempt, and shutdown only if `ShowShutdownButton` is on.
    /// Logs the request either way.
    public func authorizePowerAction(_ action: PowerAction, uid: uid_t, username: String, exempt: Bool) -> Bool {
        let allowed: Bool
        switch action {
        case .shutdown: allowed = !exempt && phase == .locked && (activeConfig?.showShutdownButton ?? false)
        case .sleep: allowed = !exempt && phase == .locked
        }
        deps.log.event(
            "power_request", category: .supervisor,
            fields: ["action": action.rawValue, "uid": Int(uid), "username": username, "allowed": allowed])
        if allowed && action == .shutdown {
            // Persist lastKnownTrusted now; SIGTERM may not give us time.
            persist()
        }
        return allowed
    }

    // MARK: - Actions (called over XPC by AgentHub)

    /// Returns true if a snooze was granted.
    @discardableResult
    public func requestSnooze() -> Bool {
        guard let config = activeConfig, lastPhase == .warning else { return false }
        let now = self.now
        guard let ledger = ScheduleEngine(config: config).snooze(at: now, ledger: state.snooze) else { return false }
        state.snooze = ledger
        deps.log.event(
            "snooze_used", category: .schedule,
            fields: ["count": ledger.count, "delaySeconds": ledger.delaySeconds, "windowStart": ledger.windowStart])
        persist()
        updatePhase()
        writeStatusIfNeeded(force: true)
        return true
    }

    /// The passphrase is used for verification only and never stored or logged.
    public func attemptOverride(passphrase: String) -> OverrideResult {
        guard let config = activeConfig, config.overrideEnabled else { return .unavailable("override disabled") }
        guard lastPhase == .locked || lastPhase == .overridden else { return .unavailable("not locked") }
        guard let hash = overrideHash else { return .unavailable("no override passphrase configured") }
        let now = self.now
        let outcome = state.overrideGate.attempt(at: now, policy: OverrideGate.Policy(config: config)) {
            PassphraseHasher.verify(passphrase: passphrase, against: hash)
        }
        let response: OverrideResult
        var fields: [String: Any] = ["hashSource": overrideHashSource]
        switch outcome {
        case .granted(let until):
            response = .granted(until: until)
            fields["result"] = "granted"
            fields["until"] = until
        case .rejected(let remaining):
            response = .rejected(attemptsRemaining: remaining)
            fields["result"] = "rejected"
            fields["attemptsRemaining"] = remaining
        case .lockedOut(let until):
            response = .lockedOut(until: until)
            fields["result"] = "locked_out"
            fields["until"] = until
        }
        deps.log.event("override_attempt", category: .override, level: .default, fields: fields)
        persist()
        updatePhase()
        writeStatusIfNeeded(force: true)
        return response
    }

    /// File first (root-only), then profile.
    var overrideHash: PassphraseHash? { overrideFileHash ?? activeConfig?.overridePasswordHash }

    var overrideHashSource: String {
        overrideFileHash != nil ? "file" : (activeConfig?.overridePasswordHash != nil ? "profile" : "none")
    }

    // MARK: - Time sync

    /// True when the driver should start a network sync.
    public var syncDue: Bool { !syncInFlight && deps.clock.continuousSeconds >= nextSyncDue }

    public var timeServers: [String] { activeConfig?.timeServers ?? LullConfig().timeServers }

    /// Set after SNTP proposed an implausible correction (possible spoofing):
    /// the next syncs try the TLS-authenticated HTTPS source first. Cleared by
    /// any accepted sync.
    public private(set) var syncPrefersAuthenticated = false
    private var syncStartedPreferringAuthenticated = false

    public func syncStarted() {
        syncInFlight = true
        syncStartedPreferringAuthenticated = syncPrefersAuthenticated
    }

    public func syncFinished(_ result: Result<TimeSyncSample, TimeSyncError>) {
        syncInFlight = false
        let cont = deps.clock.continuousSeconds
        let interval = TimeInterval((activeConfig?.timeSyncIntervalMinutes ?? 60) * 60)
        switch result {
        case .success(let sample):
            let before = trusted.trustedNow(clock: deps.clock)
            switch trusted.applySync(sample, clock: deps.clock) {
            case .success(let t):
                lastSyncServer = sample.server
                lastSyncError = nil
                syncPrefersAuthenticated = false
                nextSyncDue = cont + interval
                deps.log.event(
                    "time_sync", category: .time,
                    fields: [
                        "result": "ok", "server": sample.server, "roundTrip": sample.roundTrip,
                        "authenticated": sample.authenticated,
                        "correction": t.timeIntervalSince(before),
                        "wallClockOffset": deps.clock.wallNow.timeIntervalSince(t),
                    ])
                persist()
            case .failure(.implausibleCorrection(let correction, let allowed)):
                // Possibly a spoofed time server (e.g. a home router answering
                // for time.apple.com). Don't apply it; confirm via HTTPS now.
                deps.log.event(
                    "time_sync_suspicious", category: .time, level: .error,
                    fields: [
                        "server": sample.server, "correction": correction, "allowed": allowed,
                        "proposedTime": Date(timeIntervalSince1970: sample.unixTime),
                    ])
                lastSyncError = "\(sample.server): correction of \(Int(correction))s rejected (unauthenticated); confirming via HTTPS"
                let alreadyTried = syncStartedPreferringAuthenticated
                syncPrefersAuthenticated = true
                // Retry at once unless this attempt already tried HTTPS first.
                nextSyncDue = alreadyTried ? cont + min(Timing.syncRetryInterval, interval) : cont
            case .failure(let rejection):
                syncFailed("\(sample.server): \(rejection)", cont: cont, interval: interval)
            }
        case .failure(let e):
            syncFailed(e.description, cont: cont, interval: interval)
        }
        updatePhase()
        writeStatusIfNeeded(force: true)
    }

    private func syncFailed(_ reason: String, cont: TimeInterval, interval: TimeInterval) {
        lastSyncError = reason
        nextSyncDue = cont + min(Timing.syncRetryInterval, interval)
        deps.log.event("time_sync", category: .time, level: .error, fields: ["result": "failed", "error": reason])
    }

    // MARK: - Config in force

    /// What is enforced: the profile with this Mac's portal settings applied
    /// (`LullConfig.applying(_:)`). Nil if there has never been a valid profile.
    public var activeConfig: LullConfig? {
        guard var base = profileConfig else { return nil }
        base.portal = portalConfig
        return base.applying(cachedPortalSettings)
    }

    /// The portal lulld talks to, if any.
    public var portalConfig: PortalConfig? {
        #if DEBUG
            if let debugPortalURL {
                return PortalConfig(url: debugPortalURL, pollIntervalSeconds: profileConfig?.portal?.pollIntervalSeconds ?? 60)
            }
        #endif
        return profileConfig?.portal
    }

    /// Cached settings, only if they came from the current portal.
    var cachedPortalSettings: RemoteSettings? {
        guard let portal = portalConfig, let cached = state.portalSettings, cached.portalURL == portal.url.absoluteString
        else { return nil }
        return cached.settings
    }

    // MARK: - Parent portal

    /// The next portal call to make, or nil. lulld calls this every tick and
    /// performs at most one request at a time.
    public func nextPortalRequest() -> (request: PortalRequest, baseURL: URL)? {
        guard !portalInFlight, let portal = portalConfig else { return nil }
        let cont = deps.clock.continuousSeconds
        let url = portal.url
        guard let creds = portalCredentials, creds.portalURL == url.absoluteString else {
            guard cont >= nextPortalFetch || enrolmentFixed() else { return nil }
            enrolmentWait = .none
            guard let register = makeRegisterRequest() else {
                nextPortalFetch = cont + TimeInterval(portal.pollIntervalSeconds)
                return nil
            }
            portalInFlight = true
            return (.register(register), url)
        }
        if cont >= nextPortalFetch {
            portalInFlight = true
            return (.fetchSettings(token: creds.deviceToken, etag: portalETag), url)
        }
        if portalCheckInPending {
            portalCheckInPending = false
            portalInFlight = true
            let checkIn = PortalAPI.CheckIn.make(
                status: status, config: activeConfig, profile: profileConfig, settingsRevision: cachedPortalSettings?.revision,
                settingsError: portalSettingsError)
            return (.checkIn(token: creds.deviceToken, checkIn), url)
        }
        return nil
    }

    /// Whether the reason for waiting has gone, so registering should be tried
    /// now rather than at the poll interval. A Jamf package policy usually starts
    /// lulld (postinstall) before its script writes the secret. Re-reads the
    /// small root-only file each tick while waiting: local only, no network,
    /// and no timing state to get wrong.
    private func enrolmentFixed() -> Bool {
        guard enrolmentWait != .none,
            case .success(let secret?) = PortalCredentialFile.loadEnrolmentSecret(
                path: deps.paths.portalEnrolmentPath, owner: deps.paths.requiredOwnerUID)
        else { return false }
        if case .forDifferentSecret(let refused) = enrolmentWait { return Self.fingerprint(secret) != refused }
        return true
    }

    private static func fingerprint(_ secret: String) -> Data { Data(SHA256.hash(data: Data(secret.utf8))) }

    private func makeRegisterRequest() -> PortalAPI.RegisterRequest? {
        let secret: String
        switch PortalCredentialFile.loadEnrolmentSecret(path: deps.paths.portalEnrolmentPath, owner: deps.paths.requiredOwnerUID) {
        case .success(let s?): secret = s
        case .success(nil) where state.portalDeregisteredAt != nil:
            // De-registered by IT, and not enrolled again yet: expected, not an error.
            enrolmentWait = .forSecret
            return nil
        case .success(nil):
            enrolmentWait = .forSecret
            portalError("not enrolled: no enrolment secret at \(deps.paths.portalEnrolmentPath) (run the Jamf enrolment script)")
            return nil
        case .failure(let e):
            enrolmentWait = .forSecret
            portalError("enrolment secret refused: \(e)")
            return nil
        }
        guard let id = deps.device.identity() else {
            portalError("could not read this Mac's serial number")
            return nil
        }
        return PortalAPI.RegisterRequest(serialNumber: id.serialNumber, hardwareUUID: id.hardwareUUID, enrolmentSecret: secret)
    }

    /// Result of the request from `nextPortalRequest()`.
    public func portalFinished(_ request: PortalRequest, _ outcome: PortalOutcome) {
        portalInFlight = false
        guard let portal = portalConfig else { return }
        let cont = deps.clock.continuousSeconds
        let interval = TimeInterval(portal.pollIntervalSeconds)
        let retry = cont + min(Timing.portalRetryInterval, interval)
        let url = portal.url.absoluteString

        switch (request, outcome) {
        case (.register, .registered(let r)):
            let creds = PortalCredentials(portalURL: url, deviceId: r.deviceId, deviceToken: r.deviceToken)
            do {
                try PortalCredentialFile.saveCredentials(creds, path: deps.paths.portalCredentialsPath)
            } catch {
                // Keep going in memory; we'll register again after a restart.
                deps.log.event("portal_credentials_save_failed", category: .portal, level: .error, fields: ["error": "\(error)"])
            }
            portalCredentials = creds
            portalETag = nil
            nextPortalFetch = cont
            if state.portalDeregisteredAt != nil {
                state.portalDeregisteredAt = nil
                persist()
            }
            portalOK()
            deps.log.event("portal_registered", category: .portal, fields: ["portal": url, "deviceId": r.deviceId])
        case (.register, .conflict):
            portalError("this Mac's serial number is already registered; ask IT to reset it in the portal")
            nextPortalFetch = cont + interval
        case (.register(let req), .unauthorized):
            portalError("the portal refused the enrolment secret")
            nextPortalFetch = cont + interval
            enrolmentWait = .forDifferentSecret(Self.fingerprint(req.enrolmentSecret))

        case (.fetchSettings, .settings(let payload, let etag)):
            portalLastFetch = now
            applyPortalSettings(payload, etag: etag, portalURL: url)
            nextPortalFetch = cont + interval
            portalCheckInPending = true
            portalOK()
        case (.fetchSettings, .notModified):
            portalLastFetch = now
            nextPortalFetch = cont + interval
            portalCheckInPending = true
            portalOK()

        case (.checkIn, .checkedIn):
            portalLastCheckIn = now
            portalOK()

        case (_, .deregistered):
            portalDeregistered()

        case (_, .unauthorized):
            // Token revoked (e.g. IT reset this Mac, or the portal lost it):
            // forget it and register again.
            deps.log.event("portal_token_refused", category: .portal, level: .error, fields: ["request": request.kind])
            PortalCredentialFile.deleteCredentials(path: deps.paths.portalCredentialsPath)
            portalCredentials = nil
            portalETag = nil
            nextPortalFetch = cont
        case (.checkIn, .failed(let reason)):
            // Retry soon via a (cheap, usually 304) fetch round, which checks in again.
            portalError("checkin: \(reason)")
            nextPortalFetch = min(nextPortalFetch, retry)
        case (_, .failed(let reason)):
            portalError("\(request.kind): \(reason)")
            nextPortalFetch = retry
            // Same host: don't try a check-in until a fetch gets through (it checks in then).
            portalCheckInPending = false
        default:
            portalError("\(request.kind): unexpected response")
            nextPortalFetch = retry
        }
        updatePhase()
        writeStatusIfNeeded(force: true)
    }

    /// IT removed this Mac from the portal: forget everything from it and fall
    /// back to the profile (plist) config. The enrolment secret goes too, so it
    /// only comes back under portal management after the Jamf enrolment runs again.
    private func portalDeregistered() {
        PortalCredentialFile.deleteCredentials(path: deps.paths.portalCredentialsPath)
        PortalCredentialFile.deleteEnrolmentSecret(path: deps.paths.portalEnrolmentPath)
        enrolmentWait = .forSecret  // re-enrolling (the Jamf policy again) is picked up at once
        let hadSettings = state.portalSettings != nil
        portalCredentials = nil
        portalETag = nil
        portalSettingsError = nil
        state.portalSettings = nil
        state.portalDeregisteredAt = now
        persist()
        portalOK()
        deps.log.event(
            "portal_deregistered", category: .portal, level: .error,
            fields: ["portal": portalConfig?.url.absoluteString ?? "", "droppedSettings": hadSettings])
        // Try again (finds no enrolment secret and waits) at the normal pace.
        nextPortalFetch = deps.clock.continuousSeconds + TimeInterval(portalConfig?.pollIntervalSeconds ?? 300)
    }

    private func applyPortalSettings(_ payload: PortalAPI.SettingsPayload, etag: String?, portalURL: String) {
        let offered: RemoteSettings
        switch RemoteSettings.validate(payload) {
        case .success(let s): offered = s
        case .failure(let e):
            rejectPortalSettings(e.description, revision: payload.revision)
            return
        }
        switch RemoteSettings.update(from: cachedPortalSettings, to: offered) {
        case .apply:
            let previous = cachedPortalSettings
            state.portalSettings = CachedPortalSettings(portalURL: portalURL, settings: offered)
            portalSettingsError = nil
            portalETag = etag
            persist()
            deps.log.event(
                "portal_settings_applied", category: .portal,
                fields: [
                    "revision": Int(offered.revision), "previousRevision": previous.map { Int($0.revision) } ?? 0,
                    "enabled": offered.enabled,
                    "schoolNights": offered.schoolNightsOff == true
                        ? "off" : offered.schoolNights.map { "\($0.start.configString)-\($0.end.configString)" } ?? "school",
                    "weekend": offered.weekendOff == true
                        ? "off" : offered.weekend.map { "\($0.start.configString)-\($0.end.configString)" } ?? "school",
                ])
        case .unchanged:
            portalSettingsError = nil
            portalETag = etag
        case .rollback(let cached, let offeredRevision):
            rejectPortalSettings("revision \(offeredRevision) is older than the one in force (\(cached))", revision: offeredRevision)
        case .revisionReused(let r):
            rejectPortalSettings("revision \(r) was reused with different settings", revision: r)
        }
    }

    /// Keeps the cached settings. No ETag is kept, so the next poll fetches in full.
    private func rejectPortalSettings(_ reason: String, revision: Int64) {
        if portalSettingsError != reason {
            deps.log.event(
                "portal_settings_rejected", category: .portal, level: .error,
                fields: ["reason": reason, "revision": Int(revision), "usingCached": cachedPortalSettings != nil])
        }
        portalSettingsError = reason
        portalETag = nil
    }

    private func portalError(_ message: String) {
        if message != portalLastError {
            deps.log.event("portal_error", category: .portal, level: .error, fields: ["error": message])
        }
        portalLastError = message
        status.portal = portalInfo
    }

    private func portalOK() {
        if portalLastError != nil { deps.log.event("portal_ok", category: .portal) }
        portalLastError = nil
    }

    private func loadPortalCredentials() {
        switch PortalCredentialFile.loadCredentials(path: deps.paths.portalCredentialsPath, owner: deps.paths.requiredOwnerUID) {
        case .success(let c): portalCredentials = c
        case .failure(let e):
            // An unsafe or broken file is ignored (and replaced when we register again).
            portalCredentials = nil
            deps.log.event("portal_credentials_rejected", category: .portal, level: .error, fields: ["reason": e.description])
        }
    }

    private var portalInfo: DaemonStatus.PortalInfo? {
        guard let portal = portalConfig else { return nil }
        let url = portal.url.absoluteString
        let creds = portalCredentials?.portalURL == url ? portalCredentials : nil
        let cached = cachedPortalSettings
        return DaemonStatus.PortalInfo(
            url: url, registered: creds != nil, deviceId: creds?.deviceId, settingsSource: cached == nil ? "profile" : "portal",
            settingsRevision: cached?.revision, settingsError: portalSettingsError, lastFetch: portalLastFetch,
            lastCheckIn: portalLastCheckIn, lastError: portalLastError, deregisteredAt: state.portalDeregisteredAt)
    }

    // MARK: - Persistence and status

    public func persist() {
        lastPersist = deps.clock.continuousSeconds
        state.time = trusted.persistedState(clock: deps.clock)
        do {
            try deps.store.save(state)
        } catch {
            deps.log.event("state_save_failed", category: .config, level: .error, fields: ["error": "\(error)"])
        }
    }

    /// Clean shutdown (SIGTERM from launchd): persist `lastKnownTrusted`.
    public func shutdown() {
        persist()
        deps.log.event("daemon_stop", category: .time, fields: ["trustedTime": now])
    }

    private func writeStatusIfNeeded(force: Bool = false) {
        let cont = deps.clock.continuousSeconds
        let significantChange = lastWrittenStatus?.significantContent != status.significantContent
        guard force || significantChange || cont - lastStatusWrite >= Timing.statusHeartbeat else { return }
        do {
            try deps.store.writeStatus(status)
            lastWrittenStatus = status
            lastStatusWrite = cont
        } catch {
            deps.log.event("status_write_failed", category: .config, level: .error, fields: ["error": "\(error)"])
        }
    }

    private func buildStatus(_ r: Resolved, now: Date) -> DaemonStatus {
        let clock = deps.clock
        let ev = r.evaluation
        let config = activeConfig
        var nextTransition: Date?
        if let ev, let w = ev.window {
            nextTransition = ev.phase == .locked ? w.end : ev.lockStart
        }
        let gate = state.overrideGate
        return DaemonStatus(
            debugBuild: Self.isDebugBuild, generatedAt: now, generatedAtContinuous: clock.continuousSeconds,
            bootSessionUUID: clock.bootSessionUUID, phase: r.phase, phaseReason: r.reason,
            scheduleName: ev?.scheduleName ?? "", windowStart: ev?.window?.start, windowEnd: ev?.window?.end,
            lockStart: ev?.lockStart, nextTransition: nextTransition,
            snoozeAvailable: r.phase == .warning && (ev?.snoozeAvailable ?? false),
            snoozesUsed: state.snooze.map { $0.windowStart == ev?.window?.start ? $0.count : 0 } ?? 0,
            config: configInfo,
            time: DaemonStatus.TimeInfo(
                status: trusted.status, lastSync: trusted.lastSync, lastSyncServer: lastSyncServer, lastSyncError: lastSyncError,
                wallClockOffsetSeconds: clock.wallNow.timeIntervalSince(trusted.trustedNow(clock: clock)),
                lastTamper: trusted.lastTamperEvent, offlineBootPolicy: trusted.offlineBootPolicy),
            override: DaemonStatus.OverrideInfo(
                enabled: (config?.overrideEnabled ?? false) && overrideHash != nil, hashSource: overrideHashSource,
                activeUntil: gate.isGranted(at: now) ? gate.grantedUntil : nil,
                lockedOutUntil: gate.isLockedOut(at: now) ? gate.lockedOutUntil : nil),
            agents: agentInfos, portal: portalInfo)
    }
}

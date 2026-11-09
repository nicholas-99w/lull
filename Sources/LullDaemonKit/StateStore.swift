import Foundation
import LullCore

/// Everything the daemon carries across restarts and reboots (`state.json`, 0600).
public struct PersistentState: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var time: PersistedTimeState?
    /// Last valid config with the override hash stripped: secrets stay in the
    /// profile/override.json only. Used if the current profile is invalid.
    public var lastValidConfig: LullConfig?
    /// Fallback for a missing `Timezone` key.
    public var lastValidTimeZone: String?
    public var snooze: SnoozeLedger?
    /// Persisted so killing the daemon doesn't reset failed attempts or lockout.
    public var overrideGate = OverrideGate()
    /// Last valid settings from the parent portal, so they apply offline.
    public var portalSettings: CachedPortalSettings?
    /// When IT de-registered this Mac (portal answered 410). Cleared by the
    /// next successful registration, i.e. after the Mac is enrolled again.
    public var portalDeregisteredAt: Date?

    public init() {}
}

/// Portal settings tied to the portal they came from: a different `Portal.URL`
/// never inherits them (and its revisions start afresh).
public struct CachedPortalSettings: Codable, Sendable, Equatable {
    public var portalURL: String
    public var settings: RemoteSettings

    public init(portalURL: String, settings: RemoteSettings) {
        self.portalURL = portalURL
        self.settings = settings
    }
}

public protocol StateStoring: AnyObject {
    func load() -> Result<PersistentState?, Error>
    func save(_ state: PersistentState) throws
    func writeStatus(_ status: DaemonStatus) throws
}

public final class JSONStateStore: StateStoring {
    let paths: DaemonPaths

    public init(paths: DaemonPaths) { self.paths = paths }

    public func load() -> Result<PersistentState?, Error> {
        guard let data = FileManager.default.contents(atPath: paths.statePath) else { return .success(nil) }
        do {
            return .success(try Self.decoder.decode(PersistentState.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    public func save(_ state: PersistentState) throws {
        try SecureFile.ensureDirectory(paths.stateDirectory, mode: 0o755)
        try SecureFile.writeAtomically(try Self.encoder.encode(state), to: paths.statePath, mode: 0o600)
    }

    public func writeStatus(_ status: DaemonStatus) throws {
        try SecureFile.ensureDirectory(paths.stateDirectory, mode: 0o755)
        try SecureFile.writeAtomically(try DaemonStatus.encoder().encode(status), to: paths.statusPath, mode: 0o644)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

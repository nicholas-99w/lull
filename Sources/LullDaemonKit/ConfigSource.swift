import CoreFoundation
import Foundation
import LullCore

public enum ConfigSourceKind: String, Sendable {
    case managed
    case dev
    case none
}

/// Raw config as delivered, before parsing.
public struct RawConfig {
    /// nil when nothing is configured at all (no profile, no dev plist).
    public var values: [String: Any]?
    public var source: ConfigSourceKind
    /// Keys present but ignored because no profile enforces them.
    public var ignoredUnforcedKeys: [String]
    #if DEBUG
        /// Debug-only time offset from the dev plist (`DebugTimeOffsetSeconds`).
        public var debugTimeOffset: TimeInterval?
    #endif

    public init(values: [String: Any]?, source: ConfigSourceKind, ignoredUnforcedKeys: [String] = []) {
        self.values = values
        self.source = source
        self.ignoredUnforcedKeys = ignoredUnforcedKeys
    }
}

public protocol ConfigSource: AnyObject {
    func load() -> RawConfig
}

/// Reads the preference domain (`au.com.nickit.lull`) via CFPreferences. In Release, `requireForced` is true and
/// only keys a configuration profile enforces (`CFPreferencesAppValueIsForced`)
/// are used.
///
/// VERIFY on a managed Mac: that a root LaunchDaemon sees device-scoped
/// managed preferences (`/Library/Managed Preferences/<domain>.plist`) through
/// `CFPreferencesCopyAppValue` and that `CFPreferencesAppValueIsForced` is true
/// for them. Listed in Docs/TESTING.md.
public final class ManagedPreferencesSource: ConfigSource {
    let domain: CFString
    let requireForced: Bool

    public init(domain: String = LullConstants.preferenceDomain, requireForced: Bool) {
        self.domain = domain as CFString
        self.requireForced = requireForced
    }

    public func load() -> RawConfig {
        // Drop cached values so profile changes are seen on the next poll.
        CFPreferencesAppSynchronize(domain)
        var values: [String: Any] = [:]
        // Ask for each known key rather than listing the domain: key-list APIs
        // don't reliably include managed (forced) values.
        for key in ConfigParser.generalKeys {
            if let v = CFPreferencesCopyAppValue(key as CFString, domain) {
                values[key] = v
            }
        }
        let filtered = ManagedKeyFilter.filter(values, requireForced: requireForced) {
            CFPreferencesAppValueIsForced($0 as CFString, self.domain)
        }
        return RawConfig(
            values: filtered.kept.isEmpty ? nil : filtered.kept, source: .managed, ignoredUnforcedKeys: filtered.dropped)
    }
}

#if DEBUG
    /// Debug only: if the dev plist exists it replaces managed preferences
    /// entirely (Docs/DEVELOPMENT.md > Dev safety). Otherwise falls back to managed prefs
    /// without the forced-only rule.
    public final class DebugConfigSource: ConfigSource {
        let devPlistPath: String
        let fallback: ConfigSource

        public init(devPlistPath: String, fallback: ConfigSource) {
            self.devPlistPath = devPlistPath
            self.fallback = fallback
        }

        public static var defaultDevPlistPath: String {
            NSHomeDirectory() + "/Library/Preferences/" + LullConstants.debugDevConfigFileName
        }

        public func load() -> RawConfig {
            guard FileManager.default.fileExists(atPath: devPlistPath) else { return fallback.load() }
            guard var dict = NSDictionary(contentsOfFile: devPlistPath) as? [String: Any] else {
                // Present but unreadable: report an empty dev config so the
                // parser rejects it (keeping the last valid config) rather than
                // silently switching to managed prefs.
                return RawConfig(values: [:], source: .dev)
            }
            let offset = dict.removeValue(forKey: LullConstants.debugTimeOffsetKey) as? NSNumber
            var raw = RawConfig(values: dict, source: .dev)
            raw.debugTimeOffset = offset?.doubleValue
            return raw
        }
    }
#endif

/// Fixed config; for tests.
public final class StaticConfigSource: ConfigSource {
    public var raw: RawConfig

    public init(_ values: [String: Any]?, source: ConfigSourceKind = .managed) {
        raw = RawConfig(values: values, source: values == nil ? .none : source)
    }

    public func load() -> RawConfig { raw }
}

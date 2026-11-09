import Foundation

/// Drops top-level keys that aren't enforced by a configuration profile.
///
/// In Release builds the daemon passes `requireForced: true` and an `isForced`
/// backed by `CFPreferencesAppValueIsForced`, so a user (or a stray
/// `defaults write`) can't change behaviour with unmanaged preferences. The
/// predicate is injected so this is testable without real managed prefs.
public enum ManagedKeyFilter {
    public struct Result {
        public let kept: [String: Any]
        /// Sorted names of keys that were present but not forced.
        public let dropped: [String]
    }

    public static func filter(
        _ raw: [String: Any],
        requireForced: Bool,
        isForced: (String) -> Bool
    ) -> Result {
        guard requireForced else { return Result(kept: raw, dropped: []) }
        var kept: [String: Any] = [:]
        var dropped: [String] = []
        for (key, value) in raw {
            if isForced(key) { kept[key] = value } else { dropped.append(key) }
        }
        return Result(kept: kept, dropped: dropped.sorted())
    }
}

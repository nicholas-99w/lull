import Foundation

/// Identifiers and paths that every component derives from (bundle ID prefix, labels, paths).
/// Change `bundleIDPrefix` here and in `Config/Signing.xcconfig` / `project.yml` together.
public enum LullConstants {
    /// Reported by lulld, lullctl, the status file and the portal. lulld and
    /// lullctl have no Info.plist, so this can't come from the bundle; it must
    /// match MARKETING_VERSION in project.yml (checked by ShippedConfigTests
    /// and Scripts/make-release.sh).
    public static let version = "1.0.0"

    public static let bundleIDPrefix = "au.com.nickit"
    public static let preferenceDomain = "\(bundleIDPrefix).lull"
    public static let daemonLabel = "\(bundleIDPrefix).lulld"
    public static let agentLabel = "\(bundleIDPrefix).lull"
    public static let logSubsystem = "\(bundleIDPrefix).lull"

    public static let defaultTimeZoneIdentifier = "Australia/Sydney"

    public static let installRoot = "/Library/Application Support/Lull"
    public static let brandingDirectory = installRoot + "/Branding"
    public static let stateDirectory = "/var/db/lull"
    public static let statePath = stateDirectory + "/state.json"
    public static let overrideHashPath = stateDirectory + "/override.json"
    /// World-readable status snapshot for `lullctl status` and Jamf EAs. No secrets.
    public static let statusPath = stateDirectory + "/status.json"
    public static let logDirectory = "/var/log/lull"
    public static let logPath = logDirectory + "/lulld.log"
    public static let managedPreferencesDirectory = "/Library/Managed Preferences"

    /// Minimum PBKDF2 iterations accepted for the override hash.
    public static let minimumPBKDF2Iterations = 600_000

    /// Largest branding image the agent will try to load. Bigger files are
    /// treated as invalid so a bad profile can't make the lock screen stall.
    public static let maxBrandingImageBytes = 20 * 1024 * 1024

    #if DEBUG
        // Debug-only escape hatches (Docs/DEVELOPMENT.md > Dev safety). Must never be
        // compiled into Release; Scripts/check-release-hatches.sh greps for them.
        // A literal (not stateDirectory + ...) so the Release hatch check can find it.
        public static let debugDisableFlagPath = "/var/db/lull/DISABLE"
        public static let debugMaxLockSeconds: TimeInterval = 600
        public static let debugDevConfigFileName = preferenceDomain + ".dev.plist"
        public static let debugTimeOffsetKey = "DebugTimeOffsetSeconds"
    #endif
}

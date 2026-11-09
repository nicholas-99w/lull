import Foundation
import LullCore

/// Every filesystem location the daemon touches, injectable so tests run in a
/// temp directory and never touch `/var/db/lull`.
public struct DaemonPaths: Sendable {
    public var stateDirectory: String
    public var statePath: String
    public var statusPath: String
    public var overrideHashPath: String
    /// Enrolment secret deployed by Jamf (root, 0600). Read only.
    public var portalEnrolmentPath: String
    /// Device token from registration (root, 0600).
    public var portalCredentialsPath: String
    public var logDirectory: String
    public var logPath: String
    public var managedPreferencesDirectory: String
    /// uid that must own `override.json` for it to be trusted (root in production).
    public var requiredOwnerUID: uid_t

    public init(
        stateDirectory: String, statusPath: String? = nil, logDirectory: String,
        managedPreferencesDirectory: String = LullConstants.managedPreferencesDirectory, requiredOwnerUID: uid_t = 0
    ) {
        self.stateDirectory = stateDirectory
        self.statePath = stateDirectory + "/state.json"
        self.statusPath = statusPath ?? stateDirectory + "/status.json"
        self.overrideHashPath = stateDirectory + "/override.json"
        self.portalEnrolmentPath = stateDirectory + "/portal-enroll.json"
        self.portalCredentialsPath = stateDirectory + "/portal.json"
        self.logDirectory = logDirectory
        self.logPath = logDirectory + "/lulld.log"
        self.managedPreferencesDirectory = managedPreferencesDirectory
        self.requiredOwnerUID = requiredOwnerUID
    }

    public static let production = DaemonPaths(
        stateDirectory: LullConstants.stateDirectory, logDirectory: LullConstants.logDirectory)

    #if DEBUG
        public var disableFlagPath: String {
            stateDirectory == LullConstants.stateDirectory ? LullConstants.debugDisableFlagPath : stateDirectory + "/DISABLE"
        }
    #endif
}

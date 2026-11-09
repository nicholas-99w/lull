import Foundation

/// Decides whether a console user is exempt. Evaluated by
/// the daemon per GUI session; the agent never decides this for itself.
public enum ExemptionPolicy {
    public static func isExempt(username: String, isAdmin: Bool, config: LullConfig) -> Bool {
        if config.exemptAdminUsers && isAdmin { return true }
        // Short names are case-insensitive on macOS (APFS/HFS+ default and
        // OpenDirectory lookups), so compare case-insensitively.
        let name = username.lowercased()
        return config.exemptUsernames.contains { $0.lowercased() == name }
    }
}

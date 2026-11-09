import Darwin
import Foundation
import SystemConfiguration

/// A logged-in GUI (Aqua) session.
public struct GUISession: Equatable, Sendable {
    public var uid: uid_t
    public var username: String
    /// The session currently shown on the physical display (fast user switching).
    public var onConsole: Bool

    public init(uid: uid_t, username: String, onConsole: Bool) {
        self.uid = uid
        self.username = username
        self.onConsole = onConsole
    }
}

public protocol SessionProviding: AnyObject {
    func guiSessions() -> [GUISession]
}

/// Reads `State:/Users/ConsoleUser` from the System Configuration dynamic store,
/// whose `SessionInfo` array lists every GUI session, including switched-out
/// fast-user-switching sessions.
///
/// VERIFY on the test Mac (Docs/TESTING.md D2): the `SessionInfo` keys
/// (`kCGSSessionUserIDKey`, `kCGSSessionUserNameKey`, `kCGSSessionOnConsoleKey`,
/// `kCGSessionLoginDoneKey`) are long-standing but not formally documented.
public final class DynamicStoreSessions: SessionProviding {
    private let store: SCDynamicStore?

    public init() {
        store = SCDynamicStoreCreate(nil, "lulld" as CFString, nil, nil)
    }

    public func guiSessions() -> [GUISession] {
        guard let store,
            let value = SCDynamicStoreCopyValue(store, "State:/Users/ConsoleUser" as CFString) as? [String: Any],
            let infos = value["SessionInfo"] as? [[String: Any]]
        else { return [] }
        return Self.parse(infos)
    }

    static func parse(_ infos: [[String: Any]]) -> [GUISession] {
        infos.compactMap { info in
            guard let uidNumber = info["kCGSSessionUserIDKey"] as? NSNumber else { return nil }
            let uid = uid_t(uidNumber.uint32Value)
            let name = info["kCGSSessionUserNameKey"] as? String ?? ""
            // loginwindow's own session (uid 0 or name "loginwindow") isn't a user.
            guard uid != 0, name != "loginwindow" else { return nil }
            // Sessions still logging in have no agent yet; launchd starts it.
            if let done = info["kCGSessionLoginDoneKey"] as? Bool, !done { return nil }
            let onConsole = (info["kCGSSessionOnConsoleKey"] as? Bool) ?? false
            return GUISession(uid: uid, username: name, onConsole: onConsole)
        }
    }
}

/// Username and admin-group lookups for exemption decisions, and full names for the portal.
public protocol UserDirectory: AnyObject {
    func username(for uid: uid_t) -> String?
    /// The account's full name ("Jane Smith"), or nil if it has none.
    func fullName(for uid: uid_t) -> String?
    func isAdmin(uid: uid_t) -> Bool
}

public final class SystemUserDirectory: UserDirectory {
    public init() {}

    public func username(for uid: uid_t) -> String? {
        guard let pw = getpwuid(uid) else { return nil }
        return String(cString: pw.pointee.pw_name)
    }

    /// `pw_gecos`, which on macOS is the account's full name (its RealName).
    public func fullName(for uid: uid_t) -> String? {
        guard let pw = getpwuid(uid), let gecos = pw.pointee.pw_gecos else { return nil }
        let name = String(cString: gecos).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Membership of the local `admin` group (gid 80) via the membership API
    /// (`mbr_check_membership`), which resolves nested and directory-service
    /// groups. It lives in libSystem but isn't exported to Swift, so it's
    /// looked up with dlsym; this avoids loading a framework (e.g.
    /// Collaboration, which drags in Contacts) into a root daemon.
    public func isAdmin(uid: uid_t) -> Bool {
        typealias UIDToUUID = @convention(c) (uid_t, UnsafeMutablePointer<UInt8>) -> Int32
        typealias GIDToUUID = @convention(c) (gid_t, UnsafeMutablePointer<UInt8>) -> Int32
        typealias CheckMembership = @convention(c) (UnsafePointer<UInt8>, UnsafePointer<UInt8>, UnsafeMutablePointer<Int32>) -> Int32
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let u = dlsym(rtldDefault, "mbr_uid_to_uuid"), let g = dlsym(rtldDefault, "mbr_gid_to_uuid"),
            let c = dlsym(rtldDefault, "mbr_check_membership")
        else { return false }
        var user = [UInt8](repeating: 0, count: 16)
        var group = [UInt8](repeating: 0, count: 16)
        var member: Int32 = 0
        guard unsafeBitCast(u, to: UIDToUUID.self)(uid, &user) == 0,
            unsafeBitCast(g, to: GIDToUUID.self)(80, &group) == 0,
            unsafeBitCast(c, to: CheckMembership.self)(user, group, &member) == 0
        else { return false }
        return member != 0
    }
}

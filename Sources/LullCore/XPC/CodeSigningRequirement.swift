import Darwin
import Foundation
import Security

/// Code-signing requirements both ends of the XPC connection apply to the
/// other (SECURITY.md > How the parts trust each other).
///
/// **No Developer ID is needed.** Each side pins the *exact build* of its peer:
/// it reads the peer's installed binary from the root-owned install folder,
/// computes its code directory hash (cdhash) and requires the connecting
/// process to match it. A look-alike ad-hoc signed with the same identifier
/// (which anyone can make with `codesign -s - -i ...`) has a different cdhash
/// and is refused. This is stronger than Team ID pinning, which accepts
/// anything that team ever signed.
///
/// Upgrades replace both binaries; the pin is recomputed for every new
/// connection, so it always matches what is currently installed.
///
/// If the process is signed with a Team ID, the team is required as well.
public enum CodeSigningRequirement {
    public static let agentIdentifier = LullConstants.agentLabel  // Lull.app bundle id
    public static let daemonIdentifier = LullConstants.daemonLabel
    public static let installedAgentPath = LullConstants.installRoot + "/Lull.app"
    public static let installedDaemonPath = LullConstants.installRoot + "/bin/lulld"

    /// Requirement text. `cdhash` is 40 hex characters (20 bytes).
    public static func string(identifier: String, teamID: String?, cdhash: String? = nil) -> String {
        var clauses = ["identifier \"\(identifier)\""]
        if let teamID, !teamID.isEmpty {
            clauses.append("anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"")
        }
        if let cdhash { clauses.append("cdhash H\"\(cdhash)\"") }
        return clauses.joined(separator: " and ")
    }

    public struct PeerPin: Equatable, Sendable {
        public var requirement: String
        /// False when the installed peer couldn't be hashed and we fell back
        /// to identifier (+ Team ID) only. The daemon logs this loudly.
        public var pinned: Bool
        public var problem: String?

        public init(requirement: String, pinned: Bool, problem: String? = nil) {
            self.requirement = requirement
            self.pinned = pinned
            self.problem = problem
        }
    }

    /// Requirement for a peer installed at `installedPath`.
    ///
    /// - Parameter requiredOwner: every path component from `installedPath` up
    ///   to `/` must be owned by this uid and not group/other-writable;
    ///   otherwise a user could swap the file the pin is computed from.
    ///   Tests pass their own uid.
    ///
    /// Falls back to identifier-only (not to refusing everything) if the peer
    /// can't be hashed: refusing would leave the Mac with no lock screen at
    /// all, and the fallback still requires the identifier (and Team ID, if any).
    public static func pinned(identifier: String, installedPath: String, requiredOwner: uid_t = 0) -> PeerPin {
        let team = ownTeamIdentifier()
        // For a bundle, the executable inside it must be protected too.
        var paths = [installedPath]
        if let exe = Bundle(path: installedPath)?.executablePath { paths.append(exe) }
        if let problem = paths.lazy.compactMap({ insecurePathProblem($0, owner: requiredOwner) }).first {
            return PeerPin(requirement: string(identifier: identifier, teamID: team), pinned: false, problem: problem)
        }
        guard let hash = cdhash(ofCodeAt: installedPath) else {
            return PeerPin(
                requirement: string(identifier: identifier, teamID: team), pinned: false,
                problem: "can't read code signature of \(installedPath)")
        }
        return PeerPin(requirement: string(identifier: identifier, teamID: team, cdhash: hash), pinned: true, problem: nil)
    }

    /// cdhash of the code at `path` (a bundle or a bare executable), as hex.
    ///
    /// Lull ships arm64 only, so there is one slice and its cdhash is what the
    /// running peer presents (see Docs/TESTING.md). For a
    /// universal binary, `kSecCodeInfoUnique` would report the native slice.
    public static func cdhash(ofCodeAt path: String) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }
        // Only pin code whose signature is intact.
        guard SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
            let dict = info as? [String: Any],
            let unique = dict[kSecCodeInfoUnique as String] as? Data, unique.count == 20
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// nil if `path` and every parent directory is owned by `owner` and not
    /// writable by group or other; otherwise a description of the first problem.
    public static func insecurePathProblem(_ path: String, owner: uid_t) -> String? {
        var current = (path as NSString).standardizingPath
        while true {
            var st = stat()
            guard lstat(current, &st) == 0 else { return "\(current) is missing" }
            // System dirs above the install root (e.g. /Library/Application Support,
            // root:admin) are root-owned; anything else must belong to `owner`.
            if st.st_uid != owner && st.st_uid != 0 { return "\(current) is not owned by uid \(owner)" }
            if st.st_mode & 0o022 != 0 && (st.st_mode & S_IFMT) != S_IFLNK {
                // Sticky world-writable dirs like /private/tmp can't be ours to trust either.
                return "\(current) is writable by group or other"
            }
            if current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// Team ID of the running process's signature, or nil if ad-hoc/unsigned.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// True if `requirement` compiles; used by tests and as a startup sanity check.
    public static func isValid(_ requirement: String) -> Bool {
        var req: SecRequirement?
        return SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess
    }

    /// True if the code at `path` satisfies `requirement` (static check; tests and diagnostics).
    public static func code(at path: String, satisfies requirement: String) -> Bool {
        var staticCode: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
            let staticCode, SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req
        else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], req) == errSecSuccess
    }
}

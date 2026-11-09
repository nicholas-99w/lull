import Darwin
import Foundation

/// Small, careful file helpers for root-owned state.
public enum SecureFile {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case io(String)
        case insecure(String)

        public var description: String {
            switch self {
            case .io(let s): return s
            case .insecure(let s): return s
            }
        }
    }

    /// Creates `path` (and parents) with `mode` if missing. Existing directories
    /// are left alone apart from mode, which is reset so a loosened directory is
    /// tightened again on the next start.
    public static func ensureDirectory(_ path: String, mode: mode_t) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        guard chmod(path, mode) == 0 else { throw Failure.io("chmod \(path): \(String(cString: strerror(errno)))") }
    }

    /// Writes via a temp file in the same directory, fixes the mode, then
    /// `rename(2)`s it into place, so readers never see a half-written file
    /// and the file is never briefly readable with the wrong permissions.
    public static func writeAtomically(_ data: Data, to path: String, mode: mode_t) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/." + (path as NSString).lastPathComponent + ".\(getpid()).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw Failure.io("open \(tmp): \(String(cString: strerror(errno)))") }
        var ok = fchmod(fd, mode) == 0
        if ok {
            ok = data.withUnsafeBytes { buf -> Bool in
                var offset = 0
                while offset < buf.count {
                    let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
        }
        ok = (fsync(fd) == 0) && ok
        close(fd)
        guard ok, rename(tmp, path) == 0 else {
            let err = String(cString: strerror(errno))
            unlink(tmp)
            throw Failure.io("write \(path): \(err)")
        }
    }

    /// Reads a file that holds a secret (or controls security), refusing it
    /// unless it is a regular file owned by `owner` with no group/other access.
    /// Otherwise a standard user who could write it could, e.g., set their own
    /// override passphrase.
    public static func readTrusted(_ path: String, owner: uid_t) -> Result<Data?, Failure> {
        var st = stat()
        if lstat(path, &st) != 0 {
            return errno == ENOENT ? .success(nil) : .failure(.io("stat \(path): \(String(cString: strerror(errno)))"))
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.insecure("\(path) is not a regular file")) }
        guard st.st_uid == owner else { return .failure(.insecure("\(path) is not owned by uid \(owner)")) }
        guard st.st_mode & 0o077 == 0 else {
            return .failure(.insecure("\(path) is accessible by group/other (mode \(String(st.st_mode & 0o777, radix: 8)))"))
        }
        guard let data = FileManager.default.contents(atPath: path) else { return .failure(.io("read \(path) failed")) }
        return .success(data)
    }
}

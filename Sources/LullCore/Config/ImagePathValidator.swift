import Foundation

/// Read-only file checks, behind a protocol so validation is testable without a disk.
public protocol FileInspecting: Sendable {
    /// Size in bytes of a regular file at `path`, or nil if it is missing or not a regular file.
    func regularFileSize(atPath path: String) -> Int?
}

public struct LocalFileInspector: FileInspecting {
    public init() {}

    public func regularFileSize(atPath path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            attrs[.type] as? FileAttributeType == .typeRegular,
            let size = attrs[.size] as? NSNumber
        else { return nil }
        return size.intValue
    }
}

public enum ImagePathError: Error, Equatable, CustomStringConvertible {
    case empty
    case outsideBrandingDirectory
    case missing
    case tooLarge(bytes: Int)

    public var description: String {
        switch self {
        case .empty: return "path is empty"
        case .outsideBrandingDirectory: return "path must be inside the Branding directory"
        case .missing: return "file not found or not a regular file"
        case .tooLarge(let bytes): return "file is too large (\(bytes) bytes)"
        }
    }
}

/// Branding images must live under `INSTALL_ROOT/Branding/` (root-owned, deployed
/// by the admin) so a profile typo or a user-writable path can't be used to put
/// arbitrary content on the lock screen. Corrupt image data is detected by the
/// agent when it decodes the file; here we only check location and size.
public struct ImagePathValidator: Sendable {
    public let brandingDirectory: String
    public let maxBytes: Int
    public let files: FileInspecting

    public init(
        brandingDirectory: String = LullConstants.brandingDirectory,
        maxBytes: Int = LullConstants.maxBrandingImageBytes,
        files: FileInspecting = LocalFileInspector()
    ) {
        self.brandingDirectory = brandingDirectory
        self.maxBytes = maxBytes
        self.files = files
    }

    /// Relative paths are resolved against the Branding directory.
    public func resolve(_ path: String) -> Result<String, ImagePathError> {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let root = (brandingDirectory as NSString).standardizingPath
        let joined = trimmed.hasPrefix("/") ? trimmed : (root as NSString).appendingPathComponent(trimmed)
        // standardizingPath collapses `..`, so `Branding/../../etc/x` is caught by the prefix check.
        let full = (joined as NSString).standardizingPath
        guard full.hasPrefix(root + "/") else { return .failure(.outsideBrandingDirectory) }
        guard let size = files.regularFileSize(atPath: full) else { return .failure(.missing) }
        guard size <= maxBytes else { return .failure(.tooLarge(bytes: size)) }
        return .success(full)
    }
}

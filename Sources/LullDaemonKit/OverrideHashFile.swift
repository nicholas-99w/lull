import Foundation
import LullCore

/// `/var/db/lull/override.json`: `{"OverridePasswordHash": "pbkdf2-sha256$..."}`.
///
/// Preferred over the profile key because only root can read it, so standard
/// users can't copy the hash for offline guessing.
public enum OverrideHashFile {
    public static let key = "OverridePasswordHash"

    public enum LoadError: Error, CustomStringConvertible, Equatable {
        case file(SecureFile.Failure)
        case malformed
        case badHash(PassphraseHash.ParseError)

        // Never includes the file contents.
        public var description: String {
            switch self {
            case .file(let f): return f.description
            case .malformed: return "expected a JSON object with \(OverrideHashFile.key)"
            case .badHash(let e): return e.description
            }
        }
    }

    /// nil when the file doesn't exist.
    public static func load(path: String, owner: uid_t) -> Result<PassphraseHash?, LoadError> {
        switch SecureFile.readTrusted(path, owner: owner) {
        case .failure(let f): return .failure(.file(f))
        case .success(nil): return .success(nil)
        case .success(let data?):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let s = obj[key] as? String
            else { return .failure(.malformed) }
            switch PassphraseHash.parse(s) {
            case .success(let h): return .success(h)
            case .failure(let e): return .failure(.badHash(e))
            }
        }
    }

    public static func write(_ hash: PassphraseHash, path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [key: hash.encoded], options: [.sortedKeys])
        try SecureFile.writeAtomically(data, to: path, mode: 0o600)
    }
}

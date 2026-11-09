import CommonCrypto
import Foundation
import Security

/// `pbkdf2-sha256$<iterations>$<salt_b64>$<hash_b64>`.
///
/// `description` deliberately hides the salt and hash so a stray `print` or
/// log interpolation can't leak them (SECURITY.md > Secrets).
public struct PassphraseHash: Codable, Sendable, Equatable, CustomStringConvertible {
    public static let scheme = "pbkdf2-sha256"
    public static let saltLength = 16
    public static let hashLength = 32

    public let iterations: Int
    public let salt: Data
    public let hash: Data

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case malformed
        case unsupportedScheme
        case tooFewIterations(Int)
        case badSalt
        case badHash

        public var description: String {
            switch self {
            case .malformed: return "expected pbkdf2-sha256$iterations$salt_b64$hash_b64"
            case .unsupportedScheme: return "unsupported scheme (expected pbkdf2-sha256)"
            case .tooFewIterations(let n): return "iterations \(n) below minimum \(LullConstants.minimumPBKDF2Iterations)"
            case .badSalt: return "salt is not valid base64 of at least 8 bytes"
            case .badHash: return "hash is not valid base64 of \(PassphraseHash.hashLength) bytes"
            }
        }
    }

    init(iterations: Int, salt: Data, hash: Data) {
        self.iterations = iterations
        self.salt = salt
        self.hash = hash
    }

    public static func parse(_ string: String) -> Result<PassphraseHash, ParseError> {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return .failure(.malformed) }
        guard parts[0] == scheme else { return .failure(.unsupportedScheme) }
        guard let iterations = Int(parts[1]) else { return .failure(.malformed) }
        guard iterations >= LullConstants.minimumPBKDF2Iterations, iterations <= UInt32.max else {
            return .failure(.tooFewIterations(iterations))
        }
        guard let salt = Data(base64Encoded: String(parts[2])), salt.count >= 8 else { return .failure(.badSalt) }
        guard let hash = Data(base64Encoded: String(parts[3])), hash.count == hashLength else { return .failure(.badHash) }
        return .success(PassphraseHash(iterations: iterations, salt: salt, hash: hash))
    }

    /// The canonical string form, for `lullctl hash-passphrase` output only.
    public var encoded: String {
        "\(Self.scheme)$\(iterations)$\(salt.base64EncodedString())$\(hash.base64EncodedString())"
    }

    public var description: String { "\(Self.scheme)$\(iterations)$<redacted>" }

    // Codable as the encoded string so persisted files match the profile format.
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        switch Self.parse(s) {
        case .success(let h): self = h
        case .failure(let e):
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: e.description))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(encoded)
    }
}

/// PBKDF2-HMAC-SHA256 via CommonCrypto. Verification is done by the daemon only.
public enum PassphraseHasher {
    /// Creates a new hash with a random salt.
    public static func makeHash(
        passphrase: String,
        iterations: Int = LullConstants.minimumPBKDF2Iterations
    ) -> PassphraseHash? {
        guard iterations >= LullConstants.minimumPBKDF2Iterations else { return nil }
        var salt = Data(count: PassphraseHash.saltLength)
        let status = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, PassphraseHash.saltLength, $0.baseAddress!)
        }
        guard status == errSecSuccess,
            let derived = derive(passphrase: passphrase, salt: salt, iterations: iterations)
        else { return nil }
        return PassphraseHash(iterations: iterations, salt: salt, hash: derived)
    }

    public static func verify(passphrase: String, against stored: PassphraseHash) -> Bool {
        guard let derived = derive(passphrase: passphrase, salt: stored.salt, iterations: stored.iterations) else {
            return false
        }
        return constantTimeEquals(derived, stored.hash)
    }

    /// Normalised to NFC first so the same passphrase typed via different input
    /// methods (precomposed vs combining accents) derives the same key.
    static func derive(
        passphrase: String, salt: Data, iterations: Int,
        length: Int = PassphraseHash.hashLength
    ) -> Data? {
        guard iterations > 0, iterations <= UInt32.max else { return nil }
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        // Empty passphrases are never valid (and would give a nil base address below).
        guard !password.isEmpty else { return nil }
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                password.withUnsafeBufferPointer { pwPtr in
                    pwPtr.baseAddress!.withMemoryRebound(to: CChar.self, capacity: password.count) { pw in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            pw, password.count,
                            saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            UInt32(iterations),
                            outPtr.bindMemory(to: UInt8.self).baseAddress, length)
                    }
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    /// Compares every byte regardless of where the first difference is, so timing
    /// doesn't reveal how much of a guess matched.
    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }
}

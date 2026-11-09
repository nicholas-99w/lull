import Darwin
import Foundation
import LullCore
import LullDaemonKit

enum HashCommand {
    /// Below this, a profile-delivered hash (readable by local users) is
    /// realistically guessable offline; see SECURITY.md.
    static let recommendedMinimumLength = 16

    static func run(fromStdin: Bool, write: Bool) {
        let passphrase: String
        if fromStdin {
            guard let line = readLine(strippingNewline: true) else { fail("no passphrase on stdin") }
            passphrase = line
        } else {
            guard let first = prompt("Override passphrase: "), let second = prompt("Again: ") else {
                fail("no terminal to read the passphrase from (use --stdin)")
            }
            guard first == second else { fail("passphrases don't match") }
            passphrase = first
        }
        guard !passphrase.isEmpty else { fail("passphrase is empty") }
        if passphrase.count < recommendedMinimumLength {
            FileHandle.standardError.write(
                Data(
                    ("lullctl: warning: passphrase is shorter than \(recommendedMinimumLength) characters; "
                        + "if delivered in a profile, local users can read the hash and guess offline\n").utf8))
        }
        guard let hash = PassphraseHasher.makeHash(passphrase: passphrase) else { fail("hashing failed") }

        if write {
            guard getuid() == 0 else { fail("--write needs root (sudo)") }
            do {
                try SecureFile.ensureDirectory(LullConstants.stateDirectory, mode: 0o755)
                try OverrideHashFile.write(hash, path: LullConstants.overrideHashPath)
            } catch {
                fail("writing \(LullConstants.overrideHashPath): \(error)")
            }
            FileHandle.standardError.write(Data("wrote \(LullConstants.overrideHashPath) (0600)\n".utf8))
        } else {
            // The admin asked for it: this is the one place the hash is printed.
            print(hash.encoded)
        }
    }

    /// Reads without echo from the controlling terminal.
    static func prompt(_ text: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard readpassphrase(text, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { return nil }
        defer { _ = buffer.withUnsafeMutableBufferPointer { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return String(cString: buffer)
    }
}

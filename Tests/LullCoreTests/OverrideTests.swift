import XCTest

@testable import LullCore

final class PassphraseHashTests: XCTestCase {
    func testRoundTripWithRealIterations() throws {
        let hash = try XCTUnwrap(PassphraseHasher.makeHash(passphrase: "correct horse battery staple"))
        XCTAssertEqual(hash.iterations, 600_000)
        XCTAssertEqual(hash.salt.count, 16)
        let parsed = try PassphraseHash.parse(hash.encoded).get()
        XCTAssertEqual(parsed, hash)
        XCTAssertTrue(PassphraseHasher.verify(passphrase: "correct horse battery staple", against: parsed))
        XCTAssertFalse(PassphraseHasher.verify(passphrase: "correct horse battery stapler", against: parsed))
        XCTAssertFalse(PassphraseHasher.verify(passphrase: "", against: parsed))
    }

    func testKnownVector() throws {
        // PBKDF2-HMAC-SHA256("password", "salt", 1 iteration), RFC 7914 §11.
        let out = try XCTUnwrap(
            PassphraseHasher.derive(
                passphrase: "password", salt: Data("salt".utf8),
                iterations: 1, length: 32))
        XCTAssertEqual(
            out.map { String(format: "%02x", $0) }.joined(),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testUnicodeNormalisation() throws {
        let salt = Data(repeating: 7, count: 16)
        let composed = try XCTUnwrap(PassphraseHasher.derive(passphrase: "caf\u{E9}", salt: salt, iterations: 1))
        let decomposed = try XCTUnwrap(PassphraseHasher.derive(passphrase: "cafe\u{301}", salt: salt, iterations: 1))
        XCTAssertEqual(composed, decomposed)
    }

    func testParseRejections() {
        let salt = Data(repeating: 1, count: 16).base64EncodedString()
        let hash = Data(repeating: 2, count: 32).base64EncodedString()
        XCTAssertEqual(PassphraseHash.parse("nope").failure, .malformed)
        XCTAssertEqual(PassphraseHash.parse("bcrypt$600000$\(salt)$\(hash)").failure, .unsupportedScheme)
        XCTAssertEqual(PassphraseHash.parse("pbkdf2-sha256$599999$\(salt)$\(hash)").failure, .tooFewIterations(599_999))
        XCTAssertEqual(PassphraseHash.parse("pbkdf2-sha256$abc$\(salt)$\(hash)").failure, .malformed)
        XCTAssertEqual(PassphraseHash.parse("pbkdf2-sha256$600000$!!$\(hash)").failure, .badSalt)
        XCTAssertEqual(PassphraseHash.parse("pbkdf2-sha256$600000$\(salt)$AAAA").failure, .badHash)
        XCTAssertNotNil(try? PassphraseHash.parse("pbkdf2-sha256$600000$\(salt)$\(hash)").get())
        XCTAssertNil(PassphraseHasher.makeHash(passphrase: "x", iterations: 1000))
        XCTAssertNil(PassphraseHasher.makeHash(passphrase: ""))
    }

    func testDescriptionRedactsSecrets() throws {
        let salt = Data(repeating: 1, count: 16).base64EncodedString()
        let hash = Data(repeating: 2, count: 32).base64EncodedString()
        let h = try PassphraseHash.parse("pbkdf2-sha256$600000$\(salt)$\(hash)").get()
        XCTAssertFalse("\(h)".contains(salt))
        XCTAssertFalse("\(h)".contains(hash))
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(PassphraseHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(PassphraseHasher.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(PassphraseHasher.constantTimeEquals(Data([1, 2]), Data([1, 2, 3])))
        // Slices with non-zero start indices.
        let big = Data([9, 1, 2, 3])
        XCTAssertTrue(PassphraseHasher.constantTimeEquals(big[1...], Data([1, 2, 3])))
    }
}

final class OverrideGateTests: XCTestCase {
    let policy = OverrideGate.Policy(maxAttempts: 3, lockout: 15 * 60, grantDuration: 30 * 60)
    let t0 = local(2026, 3, 2, 22)

    func testGrantAndExpiry() {
        var g = OverrideGate()
        XCTAssertEqual(g.attempt(at: t0, policy: policy) { true }, .granted(until: t0.addingTimeInterval(1800)))
        XCTAssertTrue(g.isGranted(at: t0.addingTimeInterval(1799)))
        XCTAssertFalse(g.isGranted(at: t0.addingTimeInterval(1800)))
        g.revoke()
        XCTAssertFalse(g.isGranted(at: t0))
    }

    func testLockoutAfterMaxAttempts() {
        var g = OverrideGate()
        XCTAssertEqual(g.attempt(at: t0, policy: policy) { false }, .rejected(attemptsRemaining: 2))
        XCTAssertEqual(g.attempt(at: t0, policy: policy) { false }, .rejected(attemptsRemaining: 1))
        let until = t0.addingTimeInterval(900)
        XCTAssertEqual(g.attempt(at: t0, policy: policy) { false }, .lockedOut(until: until))

        // During lockout even the right passphrase isn't checked.
        var checked = false
        XCTAssertEqual(
            g.attempt(at: t0.addingTimeInterval(899), policy: policy) {
                checked = true; return true
            },
            .lockedOut(until: until))
        XCTAssertFalse(checked)
        XCTAssertTrue(g.isLockedOut(at: t0.addingTimeInterval(899)))

        // After lockout, attempts reset.
        XCTAssertEqual(g.attempt(at: until, policy: policy) { false }, .rejected(attemptsRemaining: 2))
        XCTAssertEqual(g.attempt(at: until, policy: policy) { true }, .granted(until: until.addingTimeInterval(1800)))
        XCTAssertEqual(g.failedAttempts, 0)
    }

    func testStateSurvivesPersistence() throws {
        var g = OverrideGate()
        _ = g.attempt(at: t0, policy: policy) { false }
        let data = try JSONEncoder().encode(g)
        let restored = try JSONDecoder().decode(OverrideGate.self, from: data)
        XCTAssertEqual(restored, g)
        XCTAssertEqual(restored.failedAttempts, 1)
    }

    func testPolicyFromConfig() {
        var c = LullConfig()
        c.overrideMaxAttempts = 4
        c.overrideLockoutMinutes = 2
        c.overrideDurationMinutes = 10
        XCTAssertEqual(OverrideGate.Policy(config: c), OverrideGate.Policy(maxAttempts: 4, lockout: 120, grantDuration: 600))
    }
}

extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e }; return nil }
}

import Foundation

/// Attempt counting, lockout and time-boxed grants for the admin override.
///
/// Times are trusted time from the daemon, and the daemon persists this value,
/// so neither changing the clock nor killing the daemon resets the lockout.
/// The passphrase check itself is injected (`verify`) so this logic is tested
/// without paying for 600k PBKDF2 iterations per case, and so this type never
/// sees the passphrase or hash.
public struct OverrideGate: Codable, Sendable, Equatable {
    public struct Policy: Sendable, Equatable {
        public var maxAttempts: Int
        public var lockout: TimeInterval
        public var grantDuration: TimeInterval

        public init(maxAttempts: Int, lockout: TimeInterval, grantDuration: TimeInterval) {
            self.maxAttempts = maxAttempts
            self.lockout = lockout
            self.grantDuration = grantDuration
        }

        public init(config: LullConfig) {
            self.init(
                maxAttempts: config.overrideMaxAttempts,
                lockout: TimeInterval(config.overrideLockoutMinutes * 60),
                grantDuration: TimeInterval(config.overrideDurationMinutes * 60))
        }
    }

    public enum Outcome: Sendable, Equatable {
        case granted(until: Date)
        case rejected(attemptsRemaining: Int)
        case lockedOut(until: Date)
    }

    public private(set) var failedAttempts = 0
    public private(set) var lockedOutUntil: Date?
    public private(set) var grantedUntil: Date?

    public init() {}

    public func isGranted(at now: Date) -> Bool { grantedUntil.map { now < $0 } ?? false }

    public func isLockedOut(at now: Date) -> Bool { lockedOutUntil.map { now < $0 } ?? false }

    public mutating func attempt(at now: Date, policy: Policy, verify: () -> Bool) -> Outcome {
        if let until = lockedOutUntil {
            // Don't even run the check while locked out: no oracle for guessing.
            if now < until { return .lockedOut(until: until) }
            lockedOutUntil = nil
            failedAttempts = 0
        }
        if verify() {
            failedAttempts = 0
            let until = now.addingTimeInterval(policy.grantDuration)
            grantedUntil = until
            return .granted(until: until)
        }
        failedAttempts += 1
        if failedAttempts >= policy.maxAttempts {
            let until = now.addingTimeInterval(policy.lockout)
            lockedOutUntil = until
            failedAttempts = 0
            return .lockedOut(until: until)
        }
        return .rejected(attemptsRemaining: policy.maxAttempts - failedAttempts)
    }

    /// Ends an active grant early (e.g. when the downtime window ends).
    public mutating func revoke() { grantedUntil = nil }
}

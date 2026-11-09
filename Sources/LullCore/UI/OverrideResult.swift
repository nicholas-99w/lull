import Foundation

/// Outcome of an admin-override attempt, sent from the daemon to the agent.
/// Carries no secret material.
public enum OverrideResult: Codable, Sendable, Equatable {
    case granted(until: Date)
    case rejected(attemptsRemaining: Int)
    case lockedOut(until: Date)
    case unavailable(String)
}

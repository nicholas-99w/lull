import Foundation

/// A problem found while parsing config. `errors` make the whole config invalid
/// (the daemon keeps the last valid one); `warnings` mean a value was defaulted,
/// clamped or ignored. Messages never contain secret values.
public struct ConfigIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }

    public let severity: Severity
    /// Dotted key path, e.g. `Schedules[1].Start` or `Appearance.TitleColor`.
    public let keyPath: String
    public let message: String

    public init(_ severity: Severity, _ keyPath: String, _ message: String) {
        self.severity = severity
        self.keyPath = keyPath
        self.message = message
    }

    public var description: String { "\(severity.rawValue): \(keyPath): \(message)" }
}

public struct ConfigParseResult: Sendable {
    /// Nil when there is at least one error.
    public let config: LullConfig?
    public let issues: [ConfigIssue]

    public var errors: [ConfigIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ConfigIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { config != nil }
}

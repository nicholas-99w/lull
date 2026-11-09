import Foundation

/// Values available to `{{token}}` substitution in `Texts`.
public struct TextContext: Sendable, Equatable {
    public var windowStart: Date?
    public var windowEnd: Date?
    /// Seconds until the next transition (lock when warning, unlock when locked).
    public var secondsRemaining: Int?
    public var scheduleName: String
    /// Console user's full name (e.g. from `pw_gecos`).
    public var userFullName: String
    public var organizationName: String
    public var supportContact: String

    public init(
        windowStart: Date? = nil, windowEnd: Date? = nil, secondsRemaining: Int? = nil,
        scheduleName: String = "", userFullName: String = "", organizationName: String = Texts.defaultOrganizationName,
        supportContact: String = Texts.defaultSupportContact
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.secondsRemaining = secondsRemaining
        self.scheduleName = scheduleName
        self.userFullName = userFullName
        self.organizationName = organizationName
        self.supportContact = supportContact
    }
}

/// Replaces `{{startTime}}`, `{{endTime}}`, `{{minutesRemaining}}`,
/// `{{secondsRemaining}}`, `{{scheduleName}}`, `{{firstName}}`,
/// `{{organizationName}}` and `{{supportContact}}`.
/// Times are shown in the configured time zone (not the system one) using the
/// user's locale. Unknown tokens are left as-is so typos are visible in testing.
public struct TextRenderer: Sendable {
    public let timeZone: TimeZone
    public let locale: Locale

    public init(timeZone: TimeZone, locale: Locale = .current) {
        self.timeZone = timeZone
        self.locale = locale
    }

    public func render(_ template: String, context: TextContext) -> String {
        guard template.contains("{{") else { return template }
        var values: [String: String] = [
            "scheduleName": context.scheduleName,
            "firstName": Self.firstName(from: context.userFullName),
            "organizationName": context.organizationName,
            "supportContact": context.supportContact,
            "startTime": context.windowStart.map(formatTime) ?? "",
            "endTime": context.windowEnd.map(formatTime) ?? "",
        ]
        if let s = context.secondsRemaining {
            let seconds = max(s, 0)
            values["secondsRemaining"] = String(seconds)
            // Round up so "1 minute" is shown until the final second, never "0".
            values["minutesRemaining"] = String((seconds + 59) / 60)
        } else {
            values["secondsRemaining"] = ""
            values["minutesRemaining"] = ""
        }
        var out = template
        for (token, value) in values {
            out = out.replacingOccurrences(of: "{{\(token)}}", with: value)
        }
        return out
    }

    public func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// First word of the full name; handles "Last, First" directory formats.
    public static func firstName(from fullName: String) -> String {
        let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = trimmed.firstIndex(of: ",") {
            let after = trimmed[trimmed.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if let first = after.split(separator: " ").first { return String(first) }
        }
        return trimmed.split(separator: " ").first.map(String.init) ?? ""
    }
}

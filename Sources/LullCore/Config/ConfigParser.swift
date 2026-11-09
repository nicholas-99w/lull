import Foundation

/// Turns a raw managed-preferences dictionary into a validated `LullConfig`.
///
/// Policy:
/// - Structural problems that affect *when* the Mac locks (schedules, exceptions,
///   enums for time integrity) are errors: the daemon keeps the last valid config.
/// - Cosmetic problems (appearance, texts) and out-of-range numbers are warnings:
///   the value is defaulted or clamped.
/// - A missing/invalid `Timezone` falls back to `fallbackTimeZone` (the last valid
///   value from state.json), then `DEFAULT_TIMEZONE`, with a warning.
/// - Unknown keys are ignored with a warning.
public struct ConfigParser: Sendable {
    public let images: ImagePathValidator

    public init(images: ImagePathValidator = ImagePathValidator()) {
        self.images = images
    }

    public static let generalKeys: Set<String> = [
        "Enabled", "Timezone", "Schedules", "DateExceptions",
        "WarningMinutes", "WarningIntervalsMinutes", "FinalCountdownSeconds",
        "SnoozeEnabled", "SnoozeMinutes", "MaxSnoozesPerWindow",
        "ExemptUsernames", "ExemptAdminUsers",
        "OverrideEnabled", "OverrideDurationMinutes", "OverrideMaxAttempts",
        "OverrideLockoutMinutes", "OverridePasswordHash",
        "TimeServers", "TimeSyncIntervalMinutes", "MaxClockDriftSeconds", "OfflineBootPolicy",
        "FallbackActionIfAgentMissing", "AgentMissingGraceSeconds", "ShowShutdownButton",
        "Appearance", "Texts", "Portal",
    ]

    static let portalKeys: Set<String> = ["URL", "PollIntervalSeconds"]

    static let colorKeys = [
        "BackgroundColor", "CardBackgroundColor", "TitleColor", "BodyColor",
        "AccentColor", "CountdownColor", "ProgressTrackColor",
    ]

    static let appearanceKeys: Set<String> = Set(
        [
            "BannerImagePath", "BannerHeight", "BannerContentMode", "LogoImagePath",
            "BackgroundStyle", "BackgroundOpacity", "BackgroundImagePath",
            "CardCornerRadius", "CardWidth", "FontName", "TitleFontSize", "BodyFontSize",
            "ShowCountdown", "ShowProgress", "ShowBannerInWarning", "WarningCardPosition",
        ] + colorKeys + colorKeys.map { $0 + "Dark" })

    static let textKeys: [(String, WritableKeyPath<Texts, String>)] = [
        ("OrganizationName", \.organizationName), ("SupportContact", \.supportContact),
        ("WarningTitle", \.warningTitle), ("WarningMessage", \.warningMessage),
        ("LockedTitle", \.lockedTitle), ("LockedMessage", \.lockedMessage),
        ("UnlockLabel", \.unlockLabel), ("FooterText", \.footerText),
        ("SupportText", \.supportText), ("OverrideButtonLabel", \.overrideButtonLabel),
        ("SnoozeButtonLabel", \.snoozeButtonLabel), ("ShutdownButtonLabel", \.shutdownButtonLabel),
    ]

    /// Empty strings are treated as "not set" for optional string values
    /// (texts, image paths, font, hash): Jamf's Application & Custom Settings
    /// form may write "" for fields an admin left alone.
    static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func parse(_ raw: [String: Any], fallbackTimeZone: String? = nil) -> ConfigParseResult {
        var ctx = Context(raw: raw)
        var c = LullConfig()

        for key in raw.keys.sorted() where !Self.generalKeys.contains(key) {
            ctx.warn(key, "unknown key ignored")
        }

        // General
        ctx.bool("Enabled") { c.enabled = $0 }
        c.timeZoneIdentifier = resolveTimeZone(&ctx, fallback: fallbackTimeZone)
        parseSchedules(&ctx, into: &c)
        parseDateExceptions(&ctx, into: &c)

        // Warning / grace
        ctx.int("WarningMinutes", range: LullConfig.Range.warningMinutes) { c.warningMinutes = $0 }
        parseWarningIntervals(&ctx, into: &c)
        ctx.int("FinalCountdownSeconds", range: LullConfig.Range.finalCountdownSeconds) { c.finalCountdownSeconds = $0 }
        ctx.bool("SnoozeEnabled") { c.snoozeEnabled = $0 }
        ctx.int("SnoozeMinutes", range: LullConfig.Range.snoozeMinutes) { c.snoozeMinutes = $0 }
        ctx.int("MaxSnoozesPerWindow", range: LullConfig.Range.maxSnoozesPerWindow) { c.maxSnoozesPerWindow = $0 }

        // Scope
        ctx.stringArray("ExemptUsernames") { names in
            c.exemptUsernames = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        ctx.bool("ExemptAdminUsers") { c.exemptAdminUsers = $0 }

        // Admin override
        ctx.bool("OverrideEnabled") { c.overrideEnabled = $0 }
        ctx.int("OverrideDurationMinutes", range: LullConfig.Range.overrideDurationMinutes) { c.overrideDurationMinutes = $0 }
        ctx.int("OverrideMaxAttempts", range: LullConfig.Range.overrideMaxAttempts) { c.overrideMaxAttempts = $0 }
        ctx.int("OverrideLockoutMinutes", range: LullConfig.Range.overrideLockoutMinutes) { c.overrideLockoutMinutes = $0 }
        if let s = ctx.stringValue("OverridePasswordHash"), !Self.isBlank(s) {
            // A bad hash disables the profile-delivered override rather than
            // invalidating the config: enforcement must not depend on it.
            // Never echo the value: it is a secret.
            switch PassphraseHash.parse(s) {
            case .success(let hash): c.overridePasswordHash = hash
            case .failure(let error): ctx.warn("OverridePasswordHash", "ignored: \(error)")
            }
        }

        // Time integrity
        if let servers = ctx.stringArrayValue("TimeServers") {
            let cleaned = servers.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Empty = not set (see isBlank); keep the default servers.
            if !cleaned.isEmpty { c.timeServers = cleaned }
        }
        ctx.int("TimeSyncIntervalMinutes", range: LullConfig.Range.timeSyncIntervalMinutes) { c.timeSyncIntervalMinutes = $0 }
        ctx.int("MaxClockDriftSeconds", range: LullConfig.Range.maxClockDriftSeconds) { c.maxClockDriftSeconds = $0 }
        ctx.enumValue("OfflineBootPolicy", OfflineBootPolicy.self, severity: .error) { c.offlineBootPolicy = $0 }

        // Enforcement
        ctx.enumValue("FallbackActionIfAgentMissing", FallbackAction.self, severity: .error) { c.fallbackActionIfAgentMissing = $0 }
        ctx.int("AgentMissingGraceSeconds", range: LullConfig.Range.agentMissingGraceSeconds) { c.agentMissingGraceSeconds = $0 }
        ctx.bool("ShowShutdownButton") { c.showShutdownButton = $0 }

        if let value = raw["Appearance"] {
            if let dict = PlistValue.dictionary(value) {
                c.appearance = parseAppearance(dict, ctx: &ctx)
            } else {
                ctx.warn("Appearance", "expected a dictionary; using defaults")
            }
        }
        if let value = raw["Texts"] {
            if let dict = PlistValue.dictionary(value) {
                c.texts = parseTexts(dict, ctx: &ctx)
            } else {
                ctx.warn("Texts", "expected a dictionary; using defaults")
            }
        }

        parsePortal(&ctx, into: &c)

        // Intervals only make sense up to the (possibly per-schedule) notice period;
        // keep those ≤ the largest notice in use and let the engine filter per window.
        let maxNotice = ([c.warningMinutes] + c.schedules.compactMap(\.warningMinutes)).max() ?? c.warningMinutes
        c.warningIntervalsMinutes = c.warningIntervalsMinutes.filter { $0 <= maxNotice }

        return ConfigParseResult(config: ctx.hasErrors ? nil : c, issues: ctx.issues)
    }

    // MARK: - Sections

    private func resolveTimeZone(_ ctx: inout Context, fallback: String?) -> String {
        let fallbackID =
            fallback.flatMap { TimeZone(identifier: $0) != nil ? $0 : nil }
            ?? LullConstants.defaultTimeZoneIdentifier
        guard let value = ctx.raw["Timezone"] else {
            ctx.warn("Timezone", "missing; using \(fallbackID)")
            return fallbackID
        }
        // TimeZone(identifier:) also accepts abbreviations like "EST"; require an
        // IANA name (contains "/" or is UTC/GMT) so schedules follow DST rules.
        guard let s = PlistValue.string(value),
            TimeZone(identifier: s) != nil,
            s.contains("/") || s == "UTC" || s == "GMT"
        else {
            ctx.warn("Timezone", "not a valid IANA time zone; using \(fallbackID)")
            return fallbackID
        }
        return s
    }

    private func parseSchedules(_ ctx: inout Context, into c: inout LullConfig) {
        guard let value = ctx.raw["Schedules"] else {
            if c.enabled { ctx.error("Schedules", "required") }
            return
        }
        guard let items = PlistValue.array(value) else {
            ctx.error("Schedules", "expected an array")
            return
        }
        if items.isEmpty { ctx.warn("Schedules", "empty; no downtime will be enforced") }
        for (i, item) in items.enumerated() {
            let path = "Schedules[\(i)]"
            guard let d = PlistValue.dictionary(item) else {
                ctx.error(path, "expected a dictionary")
                continue
            }
            for key in d.keys.sorted() where !["Name", "Days", "Start", "End", "WarningMinutes"].contains(key) {
                ctx.warn("\(path).\(key)", "unknown key ignored")
            }
            let name = d["Name"].flatMap(PlistValue.string) ?? "Schedule \(i + 1)"
            var days = Set<Weekday>()
            if let rawDays = d["Days"].flatMap(PlistValue.array), !rawDays.isEmpty {
                for (j, rawDay) in rawDays.enumerated() {
                    if let s = PlistValue.string(rawDay), let day = Weekday(configString: s) {
                        days.insert(day)
                    } else {
                        ctx.error("\(path).Days[\(j)]", "expected one of Mon, Tue, Wed, Thu, Fri, Sat, Sun")
                    }
                }
            } else {
                ctx.error("\(path).Days", "required non-empty array")
            }
            let start = d["Start"].flatMap(PlistValue.string).flatMap(TimeOfDay.init(string:))
            if start == nil { ctx.error("\(path).Start", "required, format HH:mm") }
            let end = d["End"].flatMap(PlistValue.string).flatMap(TimeOfDay.init(string:))
            if end == nil { ctx.error("\(path).End", "required, format HH:mm") }
            var warning: Int?
            if let w = d["WarningMinutes"] {
                if let n = PlistValue.int(w) {
                    warning = ctx.clamp(n, to: LullConfig.Range.warningMinutes, key: "\(path).WarningMinutes")
                } else {
                    ctx.warn("\(path).WarningMinutes", "expected an integer; using global WarningMinutes")
                }
            }
            if let start, let end {
                c.schedules.append(ScheduleRule(name: name, days: days, start: start, end: end, warningMinutes: warning))
            }
        }
    }

    private func parseDateExceptions(_ ctx: inout Context, into c: inout LullConfig) {
        guard let value = ctx.raw["DateExceptions"] else { return }
        guard let items = PlistValue.array(value) else {
            ctx.error("DateExceptions", "expected an array")
            return
        }
        for (i, item) in items.enumerated() {
            let path = "DateExceptions[\(i)]"
            guard let d = PlistValue.dictionary(item) else {
                ctx.error(path, "expected a dictionary")
                continue
            }
            let start = d["StartDate"].flatMap(PlistValue.string).flatMap(LocalDate.init(string:))
            if start == nil { ctx.error("\(path).StartDate", "required, format YYYY-MM-DD") }
            let end = d["EndDate"].flatMap(PlistValue.string).flatMap(LocalDate.init(string:))
            if end == nil { ctx.error("\(path).EndDate", "required, format YYYY-MM-DD") }
            let mode = d["Mode"].flatMap(PlistValue.string).flatMap(DateExceptionMode.init(rawValue:))
            if mode == nil { ctx.error("\(path).Mode", "required, Skip or AllDay") }
            let note = d["Note"].flatMap(PlistValue.string) ?? ""
            guard let start, let end, let mode else { continue }
            guard start <= end else {
                ctx.error(path, "EndDate is before StartDate")
                continue
            }
            c.dateExceptions.append(DateException(startDate: start, endDate: end, mode: mode, note: note))
        }
    }

    /// Problems here are warnings that switch portal management off, never
    /// errors: a typo in the URL must not stop the profile's own schedule.
    private func parsePortal(_ ctx: inout Context, into c: inout LullConfig) {
        guard let value = ctx.raw["Portal"] else { return }
        guard let d = PlistValue.dictionary(value) else {
            ctx.warn("Portal", "expected a dictionary; portal management off")
            return
        }
        var sub = ctx.nested(d, prefix: "Portal")
        defer { ctx.absorb(sub) }
        for key in d.keys.sorted() where !Self.portalKeys.contains(key) {
            sub.warn(key, "unknown key ignored")
        }
        // Blank = not set: Jamf writes the PollIntervalSeconds default even when
        // an admin never filled in the URL.
        guard let s = sub.stringValue("URL"), !Self.isBlank(s) else { return }
        guard let url = Self.portalURL(s) else {
            sub.warn("URL", "expected an https URL with a host and no query; portal management off")
            return
        }
        var portal = PortalConfig(url: url)
        sub.int("PollIntervalSeconds", range: PortalConfig.Range.pollIntervalSeconds) { portal.pollIntervalSeconds = $0 }
        c.portal = portal
    }

    /// https only: the device token travels in a header, and TLS (system trust
    /// store) is what stops a student's network from serving fake settings.
    static func portalURL(_ s: String) -> URL? {
        guard let comps = URLComponents(string: s.trimmingCharacters(in: .whitespaces)),
            comps.scheme?.lowercased() == "https", let host = comps.host, !host.isEmpty,
            comps.user == nil, comps.password == nil, comps.query == nil, comps.fragment == nil,
            let url = comps.url
        else { return nil }
        return url
    }

    private func parseWarningIntervals(_ ctx: inout Context, into c: inout LullConfig) {
        guard let value = ctx.raw["WarningIntervalsMinutes"] else { return }
        guard let items = PlistValue.array(value) else {
            ctx.warn("WarningIntervalsMinutes", "expected an array of integers; using default")
            return
        }
        var result = Set<Int>()
        for (i, item) in items.enumerated() {
            if let n = PlistValue.int(item), n >= 1 {
                result.insert(n)
            } else {
                ctx.warn("WarningIntervalsMinutes[\(i)]", "expected a positive integer; ignored")
            }
        }
        c.warningIntervalsMinutes = result.sorted(by: >)
    }

    private func parseAppearance(_ d: [String: Any], ctx: inout Context) -> Appearance {
        var a = Appearance()
        var sub = ctx.nested(d, prefix: "Appearance")
        defer { ctx.absorb(sub) }

        for key in d.keys.sorted() where !Self.appearanceKeys.contains(key) {
            sub.warn(key, "unknown key ignored")
        }

        func image(_ key: String) -> String? {
            guard let path = sub.stringValue(key), !Self.isBlank(path) else { return nil }
            switch images.resolve(path) {
            case .success(let full): return full
            case .failure(let error):
                sub.warn(key, "\(error); image not shown")
                return nil
            }
        }
        a.bannerImagePath = image("BannerImagePath")
        a.logoImagePath = image("LogoImagePath")
        a.backgroundImagePath = image("BackgroundImagePath")

        sub.double("BannerHeight", range: Appearance.Range.bannerHeight) { a.bannerHeight = $0 }
        sub.enumValue("BannerContentMode", BannerContentMode.self, severity: .warning) { a.bannerContentMode = $0 }
        sub.enumValue("BackgroundStyle", BackgroundStyle.self, severity: .warning) { a.backgroundStyle = $0 }
        if a.backgroundStyle == .image && a.backgroundImagePath == nil {
            sub.warn("BackgroundStyle", "Image style without a usable BackgroundImagePath; using Blur")
            a.backgroundStyle = .blur
        }
        sub.double("BackgroundOpacity", range: Appearance.Range.backgroundOpacity) { a.backgroundOpacity = $0 }
        sub.double("CardCornerRadius", range: Appearance.Range.cardCornerRadius) { a.cardCornerRadius = $0 }
        sub.double("CardWidth", range: Appearance.Range.cardWidth) { a.cardWidth = $0 }
        sub.string("FontName") { name in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            a.fontName = trimmed.isEmpty ? nil : trimmed
        }
        sub.double("TitleFontSize", range: Appearance.Range.titleFontSize) { a.titleFontSize = $0 }
        sub.double("BodyFontSize", range: Appearance.Range.bodyFontSize) { a.bodyFontSize = $0 }
        sub.bool("ShowCountdown") { a.showCountdown = $0 }
        sub.bool("ShowProgress") { a.showProgress = $0 }
        sub.bool("ShowBannerInWarning") { a.showBannerInWarning = $0 }
        sub.enumValue("WarningCardPosition", WarningCardPosition.self, severity: .warning) { a.warningCardPosition = $0 }

        let colorPaths: [(String, WritableKeyPath<Appearance, ThemedColor>)] = [
            ("BackgroundColor", \.backgroundColor), ("CardBackgroundColor", \.cardBackgroundColor),
            ("TitleColor", \.titleColor), ("BodyColor", \.bodyColor), ("AccentColor", \.accentColor),
            ("CountdownColor", \.countdownColor), ("ProgressTrackColor", \.progressTrackColor),
        ]
        for (key, path) in colorPaths {
            let light = sub.color(key)
            let dark = sub.color(key + "Dark")
            // A light colour without a dark variant applies to both, so an admin
            // who only sets TitleColor doesn't get our default dark title instead.
            if let light {
                a[keyPath: path] = ThemedColor(light: light, dark: dark ?? light)
            } else if let dark {
                a[keyPath: path].dark = dark
            }
        }
        return a
    }

    private func parseTexts(_ d: [String: Any], ctx: inout Context) -> Texts {
        var t = Texts()
        var sub = ctx.nested(d, prefix: "Texts")
        defer { ctx.absorb(sub) }
        let known = Set(Self.textKeys.map(\.0))
        for key in d.keys.sorted() where !known.contains(key) {
            sub.warn(key, "unknown key ignored")
        }
        // An empty or whitespace-only text means "not set": Jamf's form can write
        // "" for fields an admin never touched, which must not blank a title or
        // leave holes like "Contact ." in the default messages.
        for (key, path) in Self.textKeys {
            sub.string(key) { value in
                if !Self.isBlank(value) { t[keyPath: path] = value }
            }
        }
        t.organizationName = t.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        t.supportContact = t.supportContact.trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }
}

// MARK: - Parsing context

extension ConfigParser {
    /// Collects issues and does the typed read + warn-on-mismatch dance for each key.
    struct Context {
        let raw: [String: Any]
        var prefix = ""
        var issues: [ConfigIssue] = []

        init(raw: [String: Any]) { self.raw = raw }

        var hasErrors: Bool { issues.contains { $0.severity == .error } }

        func path(_ key: String) -> String { prefix.isEmpty ? key : "\(prefix).\(key)" }
        mutating func warn(_ key: String, _ message: String) { issues.append(.init(.warning, path(key), message)) }
        mutating func error(_ key: String, _ message: String) { issues.append(.init(.error, path(key), message)) }

        func nested(_ d: [String: Any], prefix: String) -> Context {
            var c = Context(raw: d)
            c.prefix = path(prefix)
            return c
        }

        mutating func absorb(_ other: Context) { issues += other.issues }

        mutating func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>, key: String) -> T {
            let clamped = min(max(value, range.lowerBound), range.upperBound)
            if clamped != value { warn(key, "\(value) out of range \(range); using \(clamped)") }
            return clamped
        }

        mutating func bool(_ key: String, _ apply: (Bool) -> Void) {
            guard let v = raw[key] else { return }
            if let b = PlistValue.bool(v) { apply(b) } else { warn(key, "expected a boolean; using default") }
        }

        mutating func int(_ key: String, range: ClosedRange<Int>, _ apply: (Int) -> Void) {
            guard let v = raw[key] else { return }
            if let n = PlistValue.int(v) { apply(clamp(n, to: range, key: key)) } else { warn(key, "expected an integer; using default") }
        }

        mutating func double(_ key: String, range: ClosedRange<Double>, _ apply: (Double) -> Void) {
            guard let v = raw[key] else { return }
            if let n = PlistValue.double(v) { apply(clamp(n, to: range, key: key)) } else { warn(key, "expected a number; using default") }
        }

        mutating func stringValue(_ key: String) -> String? {
            guard let v = raw[key] else { return nil }
            if let s = PlistValue.string(v) { return s }
            warn(key, "expected a string; using default")
            return nil
        }

        mutating func string(_ key: String, _ apply: (String) -> Void) {
            if let s = stringValue(key) { apply(s) }
        }

        mutating func stringArrayValue(_ key: String) -> [String]? {
            guard let v = raw[key] else { return nil }
            guard let items = PlistValue.array(v) else {
                warn(key, "expected an array of strings; using default")
                return nil
            }
            let strings = items.compactMap(PlistValue.string)
            if strings.count != items.count { warn(key, "non-string entries ignored") }
            return strings
        }

        mutating func stringArray(_ key: String, _ apply: ([String]) -> Void) {
            if let s = stringArrayValue(key) { apply(s) }
        }

        mutating func enumValue<E: RawRepresentable & CaseIterable>(
            _ key: String, _ type: E.Type, severity: ConfigIssue.Severity, _ apply: (E) -> Void
        ) where E.RawValue == String {
            guard let v = raw[key] else { return }
            if let s = PlistValue.string(v), let e = E(rawValue: s) {
                apply(e)
            } else {
                let allowed = E.allCases.map(\.rawValue).joined(separator: ", ")
                if severity == .error {
                    error(key, "expected one of \(allowed)")
                } else {
                    warn(key, "expected one of \(allowed); using default")
                }
            }
        }

        mutating func color(_ key: String) -> HexColor? {
            guard let v = raw[key] else { return nil }
            if let s = PlistValue.string(v), let c = HexColor(string: s) { return c }
            warn(key, "expected a hex colour like #RRGGBB; using default")
            return nil
        }
    }
}

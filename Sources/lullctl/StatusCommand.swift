import Foundation
import LullCore

enum StatusCommand {
    /// Older than this (by the continuous clock) means the daemon has stopped writing.
    static let staleAfter: TimeInterval = 90

    static func run(path: String, json: Bool) {
        guard let data = FileManager.default.contents(atPath: path) else {
            fail("no status at \(path) (is lulld running?)")
        }
        guard let status = try? DaemonStatus.decoder().decode(DaemonStatus.self, from: data) else {
            fail("\(path): unreadable status")
        }
        if json {
            // Pass through exactly what the daemon wrote, for EAs and scripts.
            FileHandle.standardOutput.write(data)
            print()
            return
        }
        print(render(status, clock: SystemClockSource()))
    }

    static func render(_ s: DaemonStatus, clock: ClockSource) -> String {
        // Work out "now" from the daemon's trusted time and the shared
        // continuous clock, never from this process's wall clock.
        let now = s.trustedNow(continuousSeconds: clock.continuousSeconds, bootSessionUUID: clock.bootSessionUUID)
        let age = now.map { $0.timeIntervalSince(s.generatedAt) }
        let tz = s.config.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let fmt = DateFormatter()
        fmt.timeZone = tz
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        func date(_ d: Date?) -> String { d.map(fmt.string(from:)) ?? "-" }
        func remaining(_ d: Date?) -> String {
            guard let d, let now else { return "" }
            return " (in \(duration(d.timeIntervalSince(now))))"
        }

        var lines: [String] = []
        lines.append("lulld \(s.version)\(s.debugBuild ? " (DEBUG build)" : "")")
        if let age, age > staleAfter {
            lines.append("WARNING: status is \(Int(age))s old; lulld may not be running")
        } else if age == nil {
            lines.append("WARNING: status is from a previous boot; lulld may not be running")
        }
        lines.append("phase:          \(s.phase.rawValue)\(s.phaseReason.map { " (\($0))" } ?? "")")
        if !s.scheduleName.isEmpty { lines.append("schedule:       \(s.scheduleName)") }
        lines.append("window:         \(date(s.windowStart)) -> \(date(s.windowEnd))")
        lines.append("next change:    \(date(s.nextTransition))\(remaining(s.nextTransition))")
        if s.snoozesUsed > 0 || s.snoozeAvailable {
            lines.append("snooze:         used \(s.snoozesUsed), available now: \(s.snoozeAvailable)")
        }
        lines.append("trusted time:   \(date(now)) [\(s.time.status.rawValue)]")
        lines.append("last sync:      \(date(s.time.lastSync))\(s.time.lastSyncServer.map { " via \($0)" } ?? "")")
        if let e = s.time.lastSyncError { lines.append("sync error:     \(e)") }
        lines.append("wall offset:    \(String(format: "%+.1f", s.time.wallClockOffsetSeconds))s (system clock minus trusted)")
        lines.append("offline boot:   \(s.time.offlineBootPolicy.rawValue)")
        if let t = s.time.lastTamper {
            lines.append("last tamper:    \(date(t.observedWall)) wall, delta \(String(format: "%+.0f", t.delta))s")
        }
        let c = s.config
        lines.append(
            "config:         source=\(c.source) currentValid=\(c.currentValid) usingLastValid=\(c.usingLastValid) "
                + "timezone=\(c.timeZone ?? "-")")
        for e in c.errors { lines.append("  \(e)") }
        for w in c.warnings { lines.append("  \(w)") }
        if !c.ignoredUnforcedKeys.isEmpty {
            lines.append("  ignored (not enforced by a profile): \(c.ignoredUnforcedKeys.joined(separator: ", "))")
        }
        let o = s.override
        lines.append("override:       enabled=\(o.enabled) hash=\(o.hashSource)")
        if let u = o.activeUntil { lines.append("  active until \(date(u))") }
        if let u = o.lockedOutUntil { lines.append("  locked out until \(date(u))") }
        if let p = s.portal {
            lines.append(
                "portal:         \(p.url) registered=\(p.registered) settings=\(p.settingsSource)"
                    + (p.settingsRevision.map { " revision=\($0)" } ?? ""))
            lines.append("  last fetch \(date(p.lastFetch)), last check-in \(date(p.lastCheckIn))")
            if let d = p.deregisteredAt {
                lines.append(
                    "  de-registered by IT \(date(d)); using the profile only. Run the enrolment policy to manage it from the portal again")
            }
            if let e = p.lastError { lines.append("  error: \(e)") }
            if let e = p.settingsError { lines.append("  settings refused: \(e)") }
        }
        if s.agents.isEmpty {
            lines.append("agents:         none (no one logged in)")
        } else {
            for a in s.agents {
                let name = a.fullName.map { " (\($0))" } ?? ""
                lines.append("agent:          uid \(a.uid) \(a.username)\(name) connected=\(a.connected) exempt=\(a.exempt)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}

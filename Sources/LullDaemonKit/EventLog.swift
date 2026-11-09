import Foundation
import LullCore
import os

/// os.Logger categories.
public enum LogCategory: String, Sendable, CaseIterable {
    case schedule, time, xpc, supervisor, override, config, portal
}

public protocol EventLogging: AnyObject {
    /// `fields` must never contain passphrases or hashes (SECURITY.md > Secrets).
    func event(_ name: String, category: LogCategory, level: OSLogType, fields: [String: Any])
}

extension EventLogging {
    public func event(_ name: String, category: LogCategory, fields: [String: Any] = [:]) {
        event(name, category: category, level: .default, fields: fields)
    }
}

/// Writes each event to the unified log and as one JSON object per line to
/// `/var/log/lull/lulld.log`, rotating by size (`.1` ... `.N`).
public final class JSONLinesEventLog: EventLogging {
    let path: String
    let maxBytes: Int
    let keep: Int
    private let loggers: [LogCategory: Logger]
    private let wallClock: () -> Date

    public init(path: String, maxBytes: Int = 5 * 1024 * 1024, keep: Int = 5, wallClock: @escaping () -> Date = Date.init) {
        self.path = path
        self.maxBytes = maxBytes
        self.keep = keep
        self.wallClock = wallClock
        var l: [LogCategory: Logger] = [:]
        for c in LogCategory.allCases { l[c] = Logger(subsystem: LullConstants.logSubsystem, category: c.rawValue) }
        loggers = l
    }

    public func event(_ name: String, category: LogCategory, level: OSLogType, fields: [String: Any]) {
        var record = fields.mapValues(Self.jsonSafe)
        record["event"] = name
        record["category"] = category.rawValue
        record["wall"] = Self.iso.string(from: wallClock())
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
            var line = String(data: data, encoding: .utf8)
        else { return }
        // Fields are already scrubbed of secrets by callers; public so they are
        // readable in `log show` on a managed Mac without a profile to unredact.
        loggers[category]?.log(level: level, "\(line, privacy: .public)")
        line += "\n"
        append(Data(line.utf8))
    }

    private func append(_ data: Data) {
        let dir = (path as NSString).deletingLastPathComponent
        try? SecureFile.ensureDirectory(dir, mode: 0o755)
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size + data.count > maxBytes {
            rotate()
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: data)
    }

    func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: "\(path).\(keep)")
        if keep > 1 {
            for i in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: "\(path).\(i)") {
                try? fm.moveItem(atPath: "\(path).\(i)", toPath: "\(path).\(i + 1)")
            }
        }
        try? fm.moveItem(atPath: path, toPath: "\(path).1")
    }

    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let d as Date: return iso.string(from: d)
        case let s as String: return s
        case let b as Bool: return b
        case let i as Int: return i
        case let d as Double: return d.isFinite ? d : String(describing: d)
        case let a as [Any]: return a.map(jsonSafe)
        case let m as [String: Any]: return m.mapValues(jsonSafe)
        default: return String(describing: value)
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Collects events in memory; for tests.
public final class MemoryEventLog: EventLogging {
    public struct Entry {
        public let name: String
        public let category: LogCategory
        public let fields: [String: Any]
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public func event(_ name: String, category: LogCategory, level: OSLogType, fields: [String: Any]) {
        entries.append(Entry(name: name, category: category, fields: fields))
    }

    public func names() -> [String] { entries.map(\.name) }
}

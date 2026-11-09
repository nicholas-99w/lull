import Foundation

/// Runs system tools by absolute path (never via a shell, never PATH lookup).
public protocol CommandRunning: AnyObject {
    /// Returns the exit status, or nil if the tool couldn't be launched or timed out.
    @discardableResult
    func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Int32?
    /// Like `run`, also returning standard output.
    func output(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, stdout: String)?
}

public final class ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        return p.terminationStatus
    }

    public func output(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> (status: Int32, stdout: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Drain the pipe on another thread so a large output can't fill it and
        // block the child, while this thread enforces the timeout. Reading here
        // instead would block until the child exits, defeating the timeout and
        // stalling every command queued behind it (including the sleep fallback).
        let output = OutputBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        // The child has exited; EOF follows unless a descendant still holds the pipe.
        guard readDone.wait(timeout: .now() + 1) == .success else { return nil }
        return (p.terminationStatus, String(decoding: output.data, as: UTF8.self))
    }

    /// Written by the reader thread before it signals, read only after the wait.
    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }
}

/// Records commands instead of running them; for tests.
public final class RecordingRunner: CommandRunning {
    public private(set) var commands: [[String]] = []
    /// Exit status to return per command (by joined command line); default 0.
    public var results: [String: Int32] = [:]

    public init() {}

    /// Standard output per command (by joined command line); default "".
    public var outputs: [String: String] = [:]

    public func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Int32? {
        let cmd = [path] + arguments
        commands.append(cmd)
        return results[cmd.joined(separator: " ")] ?? 0
    }

    public func output(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, stdout: String)? {
        let key = ([path] + arguments).joined(separator: " ")
        guard let status = run(path, arguments, timeout: timeout) else { return nil }
        return (status, outputs[key] ?? "")
    }
}

/// The system commands lulld uses, in one place so they're easy to audit.
public enum SystemCommands {
    public static let launchctl = "/bin/launchctl"
    public static let pmset = "/usr/bin/pmset"
    public static let shutdown = "/sbin/shutdown"

    public static func agentPlistPath(label: String) -> String { "/Library/LaunchAgents/\(label).plist" }

    public enum AgentJobState: Equatable {
        case notLoaded
        /// Loaded from Lull's own root-owned plist.
        case ours
        /// A job with Lull's label loaded from somewhere else (e.g. a student's
        /// plist in ~/Library/LaunchAgents running another program). Recovery
        /// must replace it rather than kickstart it.
        case hijacked(path: String?)
    }

    /// Where the job with `label` in the user's GUI domain was loaded from,
    /// from `launchctl print` (non-zero exit = not loaded; the top-level
    /// `path = …` line names the plist; format checked on macOS 26).
    /// VERIFY on the test Mac (Docs/TESTING.md C15): that `path` identifies a
    /// hijacking job's own plist, not Lull's.
    public static func agentJob(_ r: CommandRunning, uid: uid_t, label: String) -> AgentJobState {
        guard let out = r.output(launchctl, ["print", "gui/\(uid)/\(label)"], timeout: 5), out.status == 0 else {
            return .notLoaded
        }
        let path = out.stdout.split(separator: "\n").first { $0.hasPrefix("\tpath = ") }
            .map { String($0.dropFirst("\tpath = ".count)).trimmingCharacters(in: .whitespaces) }
        return path == agentPlistPath(label: label) ? .ours : .hijacked(path: path)
    }

    /// Unload a job from the user's GUI domain (root can do this for any user).
    public static func bootoutAgent(_ r: CommandRunning, uid: uid_t, label: String) -> Bool {
        r.run(launchctl, ["bootout", "gui/\(uid)/\(label)"], timeout: 10) == 0
    }

    /// Restart (kill if running) the agent in the user's GUI domain.
    public static func kickstartAgent(_ r: CommandRunning, uid: uid_t, label: String) -> Bool {
        r.run(launchctl, ["kickstart", "-k", "gui/\(uid)/\(label)"], timeout: 10) == 0
    }

    /// Clear a `launchctl disable` on the agent in the user's GUI domain. A user
    /// can disable their own job; disabled jobs can't be bootstrapped or
    /// started, so recovery must re-enable first (needs root, which lulld is).
    public static func enableAgent(_ r: CommandRunning, uid: uid_t, label: String) -> Bool {
        r.run(launchctl, ["enable", "gui/\(uid)/\(label)"], timeout: 5) == 0
    }

    /// Reload the agent job after the user `bootout`-ed it.
    public static func bootstrapAgent(_ r: CommandRunning, uid: uid_t, label: String) -> Bool {
        r.run(launchctl, ["bootstrap", "gui/\(uid)", agentPlistPath(label: label)], timeout: 10) == 0
    }

    public static func sleepDisplay(_ r: CommandRunning) -> Bool { r.run(pmset, ["displaysleepnow"], timeout: 5) == 0 }

    public static func sleepSystem(_ r: CommandRunning) -> Bool { r.run(pmset, ["sleepnow"], timeout: 5) == 0 }

    /// Forced shutdown (by design): apps are not asked to save, so a student
    /// can always turn the Mac off; the lock screen warns and offers Sleep first.
    public static func shutdownNow(_ r: CommandRunning) -> Bool { r.run(shutdown, ["-h", "now"], timeout: 10) == 0 }
}

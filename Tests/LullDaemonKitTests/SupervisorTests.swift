import LullCore
import XCTest

@testable import LullDaemonKit

final class SupervisorTests: XCTestCase {
    let student = GUISession(uid: 501, username: "student", onConsole: true)
    let switchedOut = GUISession(uid: 502, username: "sibling", onConsole: false)

    func run(
        _ sup: inout Supervisor, at t: TimeInterval, phase: LullPhase = .locked, alive: Bool = false, exempt: Bool = false,
        session: GUISession? = nil, fallback: FallbackAction = .sleepDisplay
    ) -> [Supervisor.Action] {
        sup.evaluate(
            now: t, phase: phase, observations: [.init(session: session ?? student, exempt: exempt, alive: alive)], grace: 5,
            fallback: fallback)
    }

    /// Evaluates once per second (like lulld) from `from` to `to`, returning the actions per second.
    func timeline(
        _ s: inout Supervisor, _ from: Int, _ to: Int, alive: (Int) -> Bool = { _ in false }
    ) -> [Int: [Supervisor.Action]] {
        var out: [Int: [Supervisor.Action]] = [:]
        for t in from...to { out[t] = run(&s, at: TimeInterval(t), alive: alive(t)) }
        return out
    }

    func testLockedMissingAgentRecoveryAndFallback() {
        var s = Supervisor()
        let a = timeline(&s, 100, 150)
        XCTAssertEqual(a[100], [.log(event: "agent_missing", uid: 501, username: "student", missingSeconds: 0)])
        XCTAssertEqual(a[104], [], "within grace")
        XCTAssertEqual(a[105], [.recoverAgent(uid: 501, username: "student")])
        XCTAssertEqual(a[107], [], "retry spacing")
        XCTAssertEqual(a[110], [.recoverAgent(uid: 501, username: "student")])
        // Display sleep after max(3 x grace, 10s) = 15s, repeating every 10s.
        XCTAssertFalse(a[114]!.contains(.sleepDisplay))
        XCTAssertTrue(a[115]!.contains(.sleepDisplay))
        XCTAssertFalse(a[120]!.contains(.sleepDisplay))
        XCTAssertTrue(a[125]!.contains(.sleepDisplay))
        // Escalate to system sleep 15s later (30s missing), repeating every 20s.
        XCTAssertFalse(a[129]!.contains(.sleepSystem))
        XCTAssertTrue(a[130]!.contains(.sleepSystem))
        XCTAssertFalse(a[130]!.contains(.sleepDisplay))
        XCTAssertTrue(a[130]!.contains(.log(event: "fallback_sleep_system", uid: 501, username: "student", missingSeconds: 30)))
        XCTAssertFalse(a[131]!.contains(.sleepSystem))
        XCTAssertTrue(a[150]!.contains(.sleepSystem))
        // Restored only after 10s of continuous life.
        let b = timeline(&s, 151, 161) { _ in true }
        for t in 151...160 { XCTAssertEqual(b[t], [], "t=\(t)") }
        XCTAssertEqual(b[161], [.log(event: "agent_restored", uid: 501, username: "student", missingSeconds: 51)])
    }

    /// `pkill` in a loop: the agent is briefly alive between kills. That must
    /// not reset the missing timer, or the fallback would never fire.
    func testKillLoopCantStarveTheFallback() {
        var s = Supervisor()
        var all: [Supervisor.Action] = []
        for t in 0...40 { all += run(&s, at: TimeInterval(t), alive: t % 3 == 0) }
        XCTAssertTrue(all.contains(.sleepDisplay))
        XCTAssertTrue(all.contains(.sleepSystem))
        XCTAssertFalse(all.contains { if case .log("agent_restored", _, _, _) = $0 { return true } else { return false } })
    }

    /// Waking from sleep: agents reconnect within seconds. The sleep itself
    /// must not count as "missing" and trigger a fallback on wake.
    func testWakeDoesNotTriggerFallback() {
        var s = Supervisor()
        _ = run(&s, at: 0, alive: true)
        _ = run(&s, at: 1)  // agent's last ack is stale just before sleep
        let onWake = run(&s, at: 8 * 3600)  // continuous clock jumped over the night
        XCTAssertFalse(onWake.contains(.sleepDisplay))
        XCTAssertFalse(onWake.contains(.sleepSystem))
        XCTAssertFalse(onWake.contains(.recoverAgent(uid: 501, username: "student")), "grace restarts at wake")
        XCTAssertEqual(run(&s, at: 8 * 3600 + 2, alive: true), [])
    }

    func testWarningRecoversButNeverFallsBack() {
        var s = Supervisor()
        var all: [Supervisor.Action] = []
        for t in stride(from: 0.0, through: 60, by: 1) { all += run(&s, at: t, phase: .warning) }
        XCTAssertTrue(all.contains(.recoverAgent(uid: 501, username: "student")))
        XCTAssertFalse(all.contains(.sleepDisplay))
    }

    func testNormalPhaseOnlyRecoversAfterAMinuteQuietly() {
        var s = Supervisor()
        var all: [Supervisor.Action] = []
        for t in stride(from: 0.0, through: 59, by: 1) { all += run(&s, at: t, phase: .normal) }
        XCTAssertEqual(all, [], "no logs, no recovery for the first minute (launchd KeepAlive handles crashes)")
        XCTAssertEqual(run(&s, at: 60, phase: .normal), [.recoverAgent(uid: 501, username: "student")])
    }

    func testExemptAndDisabledPhasesDoNothing() {
        var s = Supervisor()
        for t in stride(from: 0.0, through: 30, by: 1) { XCTAssertEqual(run(&s, at: t, exempt: true), []) }
        var d = Supervisor()
        var all: [Supervisor.Action] = []
        for t in stride(from: 0.0, through: 30, by: 1) { all += run(&d, at: t, phase: .overridden) }
        XCTAssertFalse(all.contains(.sleepDisplay))
    }

    func testNoFallbackForSwitchedOutSessionOrWhenConfiguredNone() {
        var s = Supervisor()
        var all: [Supervisor.Action] = []
        for t in stride(from: 0.0, through: 30, by: 1) { all += run(&s, at: t, session: switchedOut) }
        XCTAssertTrue(all.contains(.recoverAgent(uid: 502, username: "sibling")))
        XCTAssertFalse(all.contains(.sleepDisplay), "sleeping the display doesn't help a session that isn't on it")

        var n = Supervisor()
        all = []
        for t in stride(from: 0.0, through: 30, by: 1) { all += run(&n, at: t, fallback: FallbackAction.none) }
        XCTAssertFalse(all.contains(.sleepDisplay))
    }

    func testLoggedOutSessionIsForgotten() {
        var s = Supervisor()
        _ = run(&s, at: 0)
        _ = s.evaluate(now: 1, phase: .locked, observations: [], grace: 5, fallback: .sleepDisplay)
        XCTAssertEqual(run(&s, at: 50), [.log(event: "agent_missing", uid: 501, username: "student", missingSeconds: 0)], "starts fresh")
    }

    func testSessionInfoParsing() {
        let infos: [[String: Any]] = [
            ["kCGSSessionUserIDKey": 0, "kCGSSessionUserNameKey": "loginwindow", "kCGSSessionOnConsoleKey": false],
            [
                "kCGSSessionUserIDKey": 501, "kCGSSessionUserNameKey": "student", "kCGSSessionOnConsoleKey": true,
                "kCGSessionLoginDoneKey": true,
            ],
            [
                "kCGSSessionUserIDKey": 502, "kCGSSessionUserNameKey": "sibling", "kCGSSessionOnConsoleKey": false,
                "kCGSessionLoginDoneKey": true,
            ],
            ["kCGSSessionUserIDKey": 503, "kCGSSessionUserNameKey": "arriving", "kCGSessionLoginDoneKey": false],
            ["kCGSSessionUserNameKey": "no uid"],
        ]
        XCTAssertEqual(
            DynamicStoreSessions.parse(infos),
            [GUISession(uid: 501, username: "student", onConsole: true), GUISession(uid: 502, username: "sibling", onConsole: false)])
    }

    func testSystemCommandsAreAbsolutePathsAndExact() {
        let r = RecordingRunner()
        r.results["/bin/launchctl print gui/501/au.com.nickit.lull"] = 113
        XCTAssertEqual(SystemCommands.agentJob(r, uid: 501, label: "au.com.nickit.lull"), .notLoaded)
        _ = SystemCommands.enableAgent(r, uid: 501, label: "au.com.nickit.lull")
        _ = SystemCommands.bootstrapAgent(r, uid: 501, label: "au.com.nickit.lull")
        _ = SystemCommands.kickstartAgent(r, uid: 501, label: "au.com.nickit.lull")
        _ = SystemCommands.bootoutAgent(r, uid: 501, label: "au.com.nickit.lull")
        _ = SystemCommands.sleepDisplay(r)
        _ = SystemCommands.sleepSystem(r)
        _ = SystemCommands.shutdownNow(r)
        XCTAssertEqual(
            r.commands,
            [
                ["/bin/launchctl", "print", "gui/501/au.com.nickit.lull"],
                ["/bin/launchctl", "enable", "gui/501/au.com.nickit.lull"],
                ["/bin/launchctl", "bootstrap", "gui/501", "/Library/LaunchAgents/au.com.nickit.lull.plist"],
                ["/bin/launchctl", "kickstart", "-k", "gui/501/au.com.nickit.lull"],
                ["/bin/launchctl", "bootout", "gui/501/au.com.nickit.lull"],
                ["/usr/bin/pmset", "displaysleepnow"],
                ["/usr/bin/pmset", "sleepnow"],
                ["/sbin/shutdown", "-h", "now"],
            ])
    }

    /// The job's origin, from real `launchctl print` output (format checked on macOS 26).
    func testAgentJobOrigin() {
        let r = RecordingRunner()
        let key = "/bin/launchctl print gui/501/au.com.nickit.lull"
        r.outputs[key] =
            "gui/501/au.com.nickit.lull = {\n\tactive count = 1\n\tpath = /Library/LaunchAgents/au.com.nickit.lull.plist\n\tstate = running\n\tprogram = /Library/Application Support/Lull/Lull.app/Contents/MacOS/Lull\n}\n"
        XCTAssertEqual(SystemCommands.agentJob(r, uid: 501, label: "au.com.nickit.lull"), .ours)
        r.outputs[key] =
            "gui/501/au.com.nickit.lull = {\n\tpath = /Users/student/Library/LaunchAgents/x.plist\n\tprogram = /usr/bin/yes\n}\n"
        XCTAssertEqual(
            SystemCommands.agentJob(r, uid: 501, label: "au.com.nickit.lull"),
            .hijacked(path: "/Users/student/Library/LaunchAgents/x.plist"))
        r.outputs[key] = "gui/501/au.com.nickit.lull = {\n\tprogram = /usr/bin/yes\n}\n"  // `launchctl submit`: no plist
        XCTAssertEqual(SystemCommands.agentJob(r, uid: 501, label: "au.com.nickit.lull"), .hijacked(path: nil))
    }

    func testEventRateLimiter() {
        var l = EventRateLimiter()
        let decisions = (0..<15).map { l.admit("agent_connected/501", now: TimeInterval($0)) }
        XCTAssertEqual(decisions.filter { $0 != .suppress }.count, 10)
        XCTAssertEqual(l.admit("agent_connected/502", now: 15), .log(suppressed: 0), "per key")
        XCTAssertEqual(l.admit("agent_connected/501", now: 61), .log(suppressed: 5), "reports what it dropped")
    }
}

final class SystemUserDirectoryTests: XCTestCase {
    /// Smoke test against the real directory: root is in admin; a uid that
    /// doesn't exist isn't.
    func testRealLookups() {
        let d = SystemUserDirectory()
        XCTAssertEqual(d.username(for: 0), "root")
        XCTAssertTrue(d.isAdmin(uid: 0))
        XCTAssertFalse(d.isAdmin(uid: 987_654))
        XCTAssertNil(d.username(for: 987_654))
        XCTAssertEqual(d.fullName(for: 0), "System Administrator")
        XCTAssertNil(d.fullName(for: 987_654))
        // The developer running the tests: compare with `id -Gn`.
        let me = getuid()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        p.arguments = ["-Gn"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let groups = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(d.isAdmin(uid: me), groups.contains("admin"))
    }
}

import LullCore
import XCTest

@testable import LullDaemonKit

final class FakeSessions: SessionProviding {
    var sessions: [GUISession] = []
    func guiSessions() -> [GUISession] { sessions }
}

final class FakeUsers: UserDirectory {
    var names: [uid_t: String] = [:]
    var fullNames: [uid_t: String] = [:]
    var admins: Set<uid_t> = []
    func username(for uid: uid_t) -> String? { names[uid] }
    func fullName(for uid: uid_t) -> String? { fullNames[uid] }
    func isAdmin(uid: uid_t) -> Bool { admins.contains(uid) }
}

/// Plays the agent: records pushes and acks them.
final class TestAgent: NSObject, LullAgentXPC {
    private let lock = NSLock()
    private var _states: [DisplayState] = []
    var states: [DisplayState] {
        lock.lock()
        defer { lock.unlock() }
        return _states
    }

    /// What the fake agent reports about its overlay.
    var presenting = true

    func update(state: Data, reply: @escaping (Bool) -> Void) {
        if let s = XPCCoding.decode(DisplayState.self, from: state) {
            lock.lock()
            _states.append(s)
            lock.unlock()
        }
        reply(presenting)
    }
}

/// Real AgentHub over a real (anonymous, in-process) XPC connection. Covers
/// the interface, JSON payloads and request handling without launchd or root.
final class AgentHubTests: XCTestCase {
    let queue = DispatchQueue(label: "test.daemon")
    let me = getuid()
    var h: Harness!
    var hub: AgentHub!
    var users = FakeUsers()
    var sessions = FakeSessions()
    var runner = RecordingRunner()
    var listener: NSXPCListener!
    var connection: NSXPCConnection!
    var agent = TestAgent()

    var peerPin: (() -> CodeSigningRequirement.PeerPin)?

    func start(config: [String: Any] = configDict(), at time: Date = local(2026, 3, 2, 22, 0)) throws {
        try XCTSkipIf(me == 0, "agents are refused for uid 0")
        h = Harness(at: time, config: config)
        users.names[me] = "student"
        sessions.sessions = [GUISession(uid: me, username: "student", onConsole: true)]
        queue.sync {
            h.start()
            hub = AgentHub(
                .init(queue: queue, clock: h.clock, sessions: sessions, users: users, runner: runner, log: h.log, peerPin: peerPin),
                engine: h.engine)
        }
        listener = NSXPCListener.anonymous()
        listener.delegate = hub
        listener.resume()
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = XPCInterfaces.daemon()
        connection.exportedInterface = XPCInterfaces.agent()
        connection.exportedObject = agent
        connection.resume()
    }

    override func tearDown() {
        connection?.invalidate()
        listener?.invalidate()
    }

    var daemon: LullDaemonXPC {
        connection.remoteObjectProxyWithErrorHandler { XCTFail("XPC error: \($0)") } as! LullDaemonXPC
    }

    func call<T>(_ body: (@escaping (T) -> Void) -> Void) -> T {
        let done = expectation(description: "reply")
        var value: T!
        body {
            value = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return value
    }

    func hello() -> DisplayState? {
        XPCCoding.decode(DisplayState.self, from: call { self.daemon.hello(agentVersion: "test", reply: $0) })
    }

    func tick(_ seconds: Int = 1) {
        for _ in 0..<seconds {
            queue.sync {
                h.clock.advance(1)
                h.engine.tick()
                hub.tick()
            }
        }
    }

    /// Lets queued XPC deliveries and hub hops run.
    func settle() {
        Thread.sleep(forTimeInterval: 0.2)
        queue.sync {}
    }

    // MARK: Tests

    func testHelloReturnsSessionStateAndAgentIsListed() throws {
        try start()
        let s = try XCTUnwrap(hello())
        XCTAssertEqual(s.phase, .locked)
        XCTAssertEqual(s.windowEnd, local(2026, 3, 3, 6, 30))
        XCTAssertEqual(s.timeZoneIdentifier, "Australia/Sydney")
        tick()
        settle()
        XCTAssertEqual(h.engine.status.agents, [.init(uid: Int(me), username: "student", connected: true, exempt: false)])
        XCTAssertTrue(h.log.names().contains("agent_connected"))
    }

    func testFullNamesAreListedAndRefreshedEveryMinute() throws {
        users.fullNames[me] = "Jane Smith"
        try start()
        _ = hello()
        tick()
        settle()
        XCTAssertEqual(h.engine.status.agents.first?.fullName, "Jane Smith")
        users.fullNames[me] = "Janet Smith"  // renamed while logged in
        tick(5)
        XCTAssertEqual(h.engine.status.agents.first?.fullName, "Jane Smith", "cached")
        tick(60)
        XCTAssertEqual(h.engine.status.agents.first?.fullName, "Janet Smith")
    }

    func testExemptUsernameAndAdminSeeExempt() throws {
        try start(config: configDict(["ExemptUsernames": ["Student"]]))
        XCTAssertEqual(hello()?.phase, .exempt)

        try start(config: configDict(["ExemptAdminUsers": true]))
        users.admins = [me]
        XCTAssertEqual(hello()?.phase, .exempt)
    }

    func testHeartbeatPushesEverySecondWhileLockedAndAcksKeepAgentAlive() throws {
        try start()
        _ = hello()
        tick(3)
        settle()
        XCTAssertGreaterThanOrEqual(agent.states.count, 3, "heartbeat while locked")
        XCTAssertTrue(agent.states.allSatisfy { $0.phase == .locked })
        tick(10)
        settle()
        XCTAssertFalse(runner.commands.contains { $0.contains("kickstart") }, "acking agent is never restarted")
    }

    func testNoHeartbeatWhenNormal() throws {
        try start(at: local(2026, 3, 2, 12, 0))
        _ = hello()
        tick(5)
        settle()
        XCTAssertEqual(agent.states.count, 0, "nothing changed, so nothing pushed")
    }

    func testOverrideOverXPCAndPushOfNewPhase() throws {
        try start()
        try h.writeOverrideFile()
        queue.sync { h.engine.reloadConfig() }
        _ = hello()  // requests are only served for registered (pinned) agents
        tick()
        let bad = XPCCoding.decode(OverrideResult.self, from: call { self.daemon.attemptOverride(passphrase: "nope", reply: $0) })
        XCTAssertEqual(bad, .rejected(attemptsRemaining: 4))
        let good = XPCCoding.decode(OverrideResult.self, from: call { self.daemon.attemptOverride(passphrase: testPassphrase, reply: $0) })
        XCTAssertEqual(good, .granted(until: local(2026, 3, 2, 22, 30, 1)))
        settle()
        XCTAssertEqual(agent.states.last?.phase, .overridden)
    }

    func testShutdownAndSleepOnlyWhenLocked() throws {
        try start()
        _ = hello()
        tick()
        XCTAssertTrue(call { self.daemon.requestSleep(reply: $0) })
        XCTAssertTrue(call { self.daemon.requestShutdown(reply: $0) })
        Thread.sleep(forTimeInterval: 1.2)  // commands run 0.5s after the reply
        XCTAssertTrue(runner.commands.contains(["/usr/bin/pmset", "sleepnow"]))
        XCTAssertTrue(runner.commands.contains(["/sbin/shutdown", "-h", "now"]))
        XCTAssertEqual(h.log.entries.filter { $0.name == "power_request" }.count, 2)
    }

    func testPowerRefusedWhenNotLockedOrDisabledByConfig() throws {
        try start(at: local(2026, 3, 2, 12, 0))
        _ = hello()
        tick()
        XCTAssertFalse(call { self.daemon.requestShutdown(reply: $0) })
        XCTAssertFalse(call { self.daemon.requestSleep(reply: $0) })

        try start(config: configDict(["ShowShutdownButton": false]))
        _ = hello()
        tick()
        XCTAssertFalse(call { self.daemon.requestShutdown(reply: $0) })
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(runner.commands.contains(["/sbin/shutdown", "-h", "now"]))
    }

    func testSnoozeOverXPC() throws {
        try start(config: configDict(["SnoozeEnabled": true]), at: local(2026, 3, 2, 21, 25))
        _ = hello()
        tick()
        XCTAssertTrue(call { self.daemon.requestSnooze(reply: $0) })
        XCTAssertFalse(call { self.daemon.requestSnooze(reply: $0) })
        settle()
        XCTAssertEqual(agent.states.last?.lockStart, local(2026, 3, 2, 21, 40))
    }

    func testSupervisesSessionWithNoAgent() throws {
        try start()
        _ = hello()
        // A second logged-in user whose agent was killed/unloaded.
        sessions.sessions.append(GUISession(uid: 4242, username: "other", onConsole: false))
        runner.results["/bin/launchctl print gui/4242/au.com.nickit.lull"] = 113  // not loaded
        tick(6)
        Thread.sleep(forTimeInterval: 0.3)
        // Disabled-then-unloaded job: enable before bootstrap, in that order.
        let enable = runner.commands.firstIndex(of: ["/bin/launchctl", "enable", "gui/4242/au.com.nickit.lull"])
        let bootstrap = runner.commands.firstIndex(
            of: ["/bin/launchctl", "bootstrap", "gui/4242", "/Library/LaunchAgents/au.com.nickit.lull.plist"])
        XCTAssertNotNil(enable)
        XCTAssertNotNil(bootstrap)
        XCTAssertLessThan(enable ?? .max, bootstrap ?? .min)
        settle()
        XCTAssertTrue(h.log.names().contains("agent_missing"))
        XCTAssertTrue(h.log.names().contains("agent_recovery"))
        XCTAssertTrue(h.engine.status.agents.contains(.init(uid: 4242, username: "other", connected: false, exempt: false)))
    }

    func testDisconnectIsNoticed() throws {
        try start()
        _ = hello()
        connection.invalidate()
        settle()
        tick()
        settle()
        XCTAssertTrue(h.log.names().contains("agent_disconnected"))
        XCTAssertEqual(h.engine.status.agents.first?.connected, false)
    }

    // MARK: cdhash pinning on a live connection

    /// Identifier and cdhash of this test process (the XPC peer in these tests).
    func selfSignature() throws -> (identifier: String, cdhash: String) {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), [], &staticCode), errSecSuccess)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(try XCTUnwrap(staticCode), [], &info), errSecSuccess)
        let dict = try XCTUnwrap(info as? [String: Any])
        let unique = try XCTUnwrap(dict[kSecCodeInfoUnique as String] as? Data)
        return (try XCTUnwrap(dict[kSecCodeInfoIdentifier as String] as? String), unique.map { String(format: "%02x", $0) }.joined())
    }

    func testPinnedPeerIsAccepted() throws {
        let me = try selfSignature()
        peerPin = {
            .init(requirement: CodeSigningRequirement.string(identifier: me.identifier, teamID: nil, cdhash: me.cdhash), pinned: true)
        }
        try start()
        XCTAssertEqual(hello()?.phase, .locked, "running process matches its own cdhash pin")
    }

    func testWrongCdhashIsRefusedOnTheWire() throws {
        let me = try selfSignature()
        let wrong = String(me.cdhash.reversed())
        peerPin = {
            .init(requirement: CodeSigningRequirement.string(identifier: me.identifier, teamID: nil, cdhash: wrong), pinned: true)
        }
        try start()
        let failed = expectation(description: "connection rejected")
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in failed.fulfill() } as! LullDaemonXPC
        proxy.hello(agentVersion: "test") { _ in XCTFail("a peer failing the pin must get no reply") }
        wait(for: [failed], timeout: 5)
    }

    func testUnpinnedFallbackIsLogged() throws {
        peerPin = { .init(requirement: #"identifier "nope""#, pinned: false, problem: "can't read code signature") }
        try start()
        let failed = expectation(description: "rejected")
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in failed.fulfill() } as! LullDaemonXPC
        proxy.hello(agentVersion: "test") { _ in }
        wait(for: [failed], timeout: 5)
        settle()
        XCTAssertTrue(h.log.names().contains("xpc_peer_pin_unavailable"))
    }

    // MARK: Anti-tamper hardening

    /// A connection that never says hello (e.g. a look-alike rejected by the
    /// pin) is not an agent: it must not keep the session "alive".
    func testConnectionWithoutHelloDoesNotCountAsAlive() throws {
        try start()
        // Connected (setUp) but never call hello.
        runner.results["/bin/launchctl print gui/\(me)/au.com.nickit.lull"] = 113
        tick(6)
        Thread.sleep(forTimeInterval: 0.3)
        settle()
        XCTAssertTrue(h.log.names().contains("agent_missing"))
        XCTAssertTrue(
            runner.commands.contains(["/bin/launchctl", "bootstrap", "gui/\(me)", "/Library/LaunchAgents/au.com.nickit.lull.plist"]))
        XCTAssertFalse(h.log.names().contains("agent_connected"), "only logged after hello")
        XCTAssertEqual(h.engine.status.agents.first?.connected, false)
    }

    /// Hidden (or otherwise not presenting) overlay: acks say so, the session
    /// counts as missing and the agent is restarted.
    func testAgentNotPresentingIsRecovered() throws {
        try start()
        _ = hello()
        agent.presenting = false
        runner.outputs["/bin/launchctl print gui/\(me)/au.com.nickit.lull"] =
            "x = {\n\tpath = /Library/LaunchAgents/au.com.nickit.lull.plist\n}\n"
        for _ in 0..<8 {
            tick()
            settle()
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(runner.commands.contains(["/bin/launchctl", "kickstart", "-k", "gui/\(me)/au.com.nickit.lull"]))
    }

    func testHijackedLabelIsReplaced() throws {
        try start()
        sessions.sessions.append(GUISession(uid: 4243, username: "other", onConsole: false))
        runner.outputs["/bin/launchctl print gui/4243/au.com.nickit.lull"] =
            "x = {\n\tpath = /Users/other/Library/LaunchAgents/evil.plist\n\tprogram = /usr/bin/yes\n}\n"
        tick(6)
        Thread.sleep(forTimeInterval: 0.3)
        settle()
        let bootout = runner.commands.firstIndex(of: ["/bin/launchctl", "bootout", "gui/4243/au.com.nickit.lull"])
        let bootstrap = runner.commands.firstIndex(
            of: ["/bin/launchctl", "bootstrap", "gui/4243", "/Library/LaunchAgents/au.com.nickit.lull.plist"])
        XCTAssertNotNil(bootout)
        XCTAssertNotNil(bootstrap)
        XCTAssertLessThan(bootout ?? .max, bootstrap ?? .min)
        XCTAssertFalse(runner.commands.contains(["/bin/launchctl", "kickstart", "-k", "gui/4243/au.com.nickit.lull"]))
        XCTAssertTrue(h.log.names().contains("agent_label_hijacked"))
    }
}

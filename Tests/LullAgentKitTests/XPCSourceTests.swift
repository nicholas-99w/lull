import LullCore
import XCTest

@testable import LullAgentKit

/// Plays lulld over a real anonymous XPC connection.
final class FakeDaemon: NSObject, NSXPCListenerDelegate, LullDaemonXPC {
    let listener = NSXPCListener.anonymous()
    var agentConnection: NSXPCConnection?
    var state = Fixtures.lockedState()
    var calls: [String] = []
    var overrideReply: OverrideResult = .rejected(attemptsRemaining: 4)
    var receivedPassphrases: [String] = []

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = XPCInterfaces.daemon()
        c.exportedObject = self
        c.remoteObjectInterface = XPCInterfaces.agent()
        c.resume()
        agentConnection = c
        return true
    }

    func push(_ s: DisplayState, acked: @escaping (Bool) -> Void) {
        let proxy = agentConnection?.remoteObjectProxy as? LullAgentXPC
        proxy?.update(state: XPCCoding.encode(s)!, reply: acked)
    }

    func hello(agentVersion: String, reply: @escaping (Data?) -> Void) {
        calls.append("hello")
        reply(XPCCoding.encode(state))
    }
    func requestSnooze(reply: @escaping (Bool) -> Void) { calls.append("snooze"); reply(true) }
    func attemptOverride(passphrase: String, reply: @escaping (Data?) -> Void) {
        receivedPassphrases.append(passphrase)
        reply(XPCCoding.encode(overrideReply))
    }
    func requestShutdown(reply: @escaping (Bool) -> Void) { calls.append("shutdown"); reply(true) }
    func requestSleep(reply: @escaping (Bool) -> Void) { calls.append("sleep"); reply(true) }
}

@MainActor
final class XPCSourceTests: XCTestCase {
    func makeSource(_ daemon: FakeDaemon) -> XPCDisplayStateSource {
        XPCDisplayStateSource(connectionForTesting: NSXPCConnection(listenerEndpoint: daemon.listener.endpoint))
    }

    func testHelloAndPushesReachOnUpdate() async {
        let daemon = FakeDaemon()
        let source = makeSource(daemon)
        var received: [DisplayState] = []
        let first = expectation(description: "hello state")
        source.onUpdate = { s in
            received.append(s)
            if received.count == 1 { first.fulfill() }
        }
        source.start()
        await fulfillment(of: [first], timeout: 5)
        XCTAssertEqual(received.first, Fixtures.lockedState())

        var next = Fixtures.lockedState()
        next.phase = .normal
        let pushed = expectation(description: "push delivered")
        let acked = expectation(description: "push acked")
        source.onUpdate = { s in if s.phase == .normal { pushed.fulfill() } }
        daemon.push(next) { presenting in
            XCTAssertTrue(presenting, "no check installed = presenting")
            acked.fulfill()
        }
        await fulfillment(of: [pushed, acked], timeout: 5)
    }

    /// The ack is sent after the state is applied on the main thread and carries
    /// the overlay check, so lulld learns about a hidden or hung lock screen.
    func testAckCarriesPresentingCheck() async {
        let daemon = FakeDaemon()
        let source = makeSource(daemon)
        var applied = false
        source.onUpdate = { _ in applied = true }
        source.presentingCheck = { applied ? false : true }
        source.start()
        let acked = expectation(description: "ack")
        daemon.push(Fixtures.lockedState()) { presenting in
            XCTAssertFalse(presenting, "check ran after the state was applied")
            acked.fulfill()
        }
        await fulfillment(of: [acked], timeout: 5)
    }

    func testActionsAndOverrideResult() async {
        let daemon = FakeDaemon()
        let source = makeSource(daemon)
        source.start()
        let done = expectation(description: "override reply")
        var result: OverrideResult?
        source.attemptOverride(passphrase: "secret phrase") {
            result = $0
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(result, .rejected(attemptsRemaining: 4))
        XCTAssertEqual(daemon.receivedPassphrases, ["secret phrase"])

        source.requestSnooze()
        source.requestShutdown()
        source.requestSleep()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(daemon.calls.filter { $0 != "hello" }, ["snooze", "shutdown", "sleep"])
    }

    func testOverrideFailsCleanlyWithoutDaemon() async {
        let daemon = FakeDaemon()
        let source = makeSource(daemon)
        daemon.listener.invalidate()
        source.start()
        let done = expectation(description: "reply")
        var result: OverrideResult?
        source.attemptOverride(passphrase: "x") {
            result = $0
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(result, .unavailable("no connection to lulld"))
    }
}

@MainActor
final class StaleDaemonTests: XCTestCase {
    /// Never trap people: with the daemon gone, the agent releases the lock
    /// once the last known window has ended (and not before).
    func testReleasesAfterWindowEndWhenDaemonUnreachable() {
        let clock = TestClock()
        let model = AgentModel(clock: clock, imageLoader: { _ in BrandingImages() })
        let c = AgentCoordinator(source: StubSource(), model: model)
        model.apply(Fixtures.lockedState())  // window ends 8.5h after "now"
        XCTAssertTrue(c.shouldLock(model.state!))
        clock.continuousSeconds += 3600
        model.tick()
        XCTAssertTrue(c.shouldLock(model.state!), "still inside the window")
        clock.continuousSeconds += 8 * 3600
        model.tick()
        XCTAssertFalse(c.shouldLock(model.state!), "window over and no word from the daemon")

        // A fresh update from the daemon is authoritative again.
        model.apply(Fixtures.lockedState(now: Fixtures.windowEnd.addingTimeInterval(60)))
        XCTAssertTrue(c.shouldLock(model.state!))
    }

    /// Slept during the warning (or normal) phase and woke after the lock time:
    /// lock from the last known window before the daemon's refresh arrives.
    func testWakePastLockStartLocksImmediately() {
        let clock = TestClock()
        let model = AgentModel(clock: clock, imageLoader: { _ in BrandingImages() })
        let c = AgentCoordinator(source: StubSource(), model: model)
        var warning = Fixtures.warningState(secondsToLock: 300)
        model.apply(warning)
        XCTAssertFalse(c.shouldLock(model.state!))
        clock.continuousSeconds += 3600  // lid closed for an hour
        model.tick()
        XCTAssertTrue(c.shouldLock(model.state!), "lock time passed while asleep")
        clock.continuousSeconds += 10 * 3600
        model.tick()
        XCTAssertFalse(c.shouldLock(model.state!), "window over too")

        // Fresh state from the daemon wins (e.g. an exception made it normal).
        warning.phase = .normal
        warning.trustedNow = Fixtures.windowStart.addingTimeInterval(60)
        model.apply(warning)
        XCTAssertFalse(c.shouldLock(model.state!), "fresh state isn't overridden")

        var exempt = Fixtures.lockedState()
        exempt.phase = .exempt
        model.apply(exempt)
        clock.continuousSeconds += 30
        model.tick()
        XCTAssertFalse(c.shouldLock(model.state!), "exempt users never locked")
    }
}

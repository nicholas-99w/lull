import Foundation
import LullCore

/// The daemon's side of XPC: accepts agent connections, pushes each session its
/// `DisplayState`, serves agent requests, and supervises agents.
///
/// All state is confined to `queue` (the daemon's serial queue, which also owns
/// the engine). XPC callbacks arrive on private queues and hop onto it.
/// launchctl/pmset/shutdown run on `commandQueue` so they never stall ticks.
public final class AgentHub: NSObject, NSXPCListenerDelegate {
    public struct Dependencies {
        public var queue: DispatchQueue
        public var clock: ClockSource
        public var sessions: SessionProviding
        public var users: UserDirectory
        public var runner: CommandRunning
        public var log: EventLogging
        public var agentLabel: String
        /// Requirement each agent connection must meet, computed per connection
        /// from the installed Lull.app (cdhash pin). nil only in tests.
        public var peerPin: (() -> CodeSigningRequirement.PeerPin)?

        public init(
            queue: DispatchQueue, clock: ClockSource, sessions: SessionProviding, users: UserDirectory, runner: CommandRunning,
            log: EventLogging, agentLabel: String = LullConstants.agentLabel,
            peerPin: (() -> CodeSigningRequirement.PeerPin)? = nil
        ) {
            self.queue = queue
            self.clock = clock
            self.sessions = sessions
            self.users = users
            self.runner = runner
            self.log = log
            self.agentLabel = agentLabel
            self.peerPin = peerPin
        }
    }

    /// An agent acked a push within this window (seconds) = alive.
    public static let livenessWindow: TimeInterval = 3

    final class Agent {
        let id: Int
        let connection: NSXPCConnection
        let uid: uid_t
        let username: String
        var lastAck: TimeInterval
        /// Last ack said the overlay is up whenever it should be.
        var presenting = true
        var lastPushed: DisplayState?
        var lastPushAt: TimeInterval = -.infinity

        init(id: Int, connection: NSXPCConnection, uid: uid_t, username: String, now: TimeInterval) {
            self.id = id
            self.connection = connection
            self.uid = uid
            self.username = username
            lastAck = now
        }
    }

    let deps: Dependencies
    let engine: DaemonEngine
    let commandQueue: DispatchQueue
    private var agents: [Int: Agent] = [:]
    /// Accepted connections that haven't said hello yet. They don't count as
    /// agents (or as alive): hello can only arrive after the connection's
    /// code-signing pin has passed, so a look-alike never leaves this list.
    private var pending: [Int: (connection: NSXPCConnection, uid: uid_t)] = [:]
    private var eventLimiter = EventRateLimiter()
    // Touched from the listener's queue, so guarded by a lock rather than `queue`.
    private let idLock = NSLock()
    private var nextID = 1
    private var supervisor = Supervisor()
    private var enforcingSince: TimeInterval?
    private var lastPinProblem: String?
    private var adminCache: [uid_t: (isAdmin: Bool, at: TimeInterval)] = [:]
    private var fullNameCache: [uid_t: (name: String?, at: TimeInterval)] = [:]

    /// Must be created on `deps.queue`.
    public init(_ deps: Dependencies, engine: DaemonEngine) {
        self.deps = deps
        self.engine = engine
        commandQueue = DispatchQueue(label: "\(LullConstants.daemonLabel).commands")
    }

    // MARK: - Connections

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The listener already required the agent's identifier. Here we pin the
        // exact installed build (cdhash), recomputed per connection so an
        // upgrade is picked up immediately. A look-alike signed with the same
        // identifier fails this check and the connection is invalidated.
        if let pin = deps.peerPin?() {
            connection.setCodeSigningRequirement(pin.requirement)
            if !pin.pinned {
                let problem = pin.problem ?? "unknown"
                deps.queue.async { [self] in
                    if problem != lastPinProblem {
                        lastPinProblem = problem
                        deps.log.event(
                            "xpc_peer_pin_unavailable", category: .xpc, level: .error,
                            fields: ["problem": problem, "requirement": pin.requirement])
                    }
                }
            }
        }
        let uid = connection.effectiveUserIdentifier
        guard uid != 0 else { return false }  // agents run as the logged-in user, never root
        idLock.lock()
        let id = nextID
        nextID += 1
        idLock.unlock()
        connection.exportedInterface = XPCInterfaces.daemon()
        connection.exportedObject = DaemonService(hub: self, agentID: id)
        connection.remoteObjectInterface = XPCInterfaces.agent()
        connection.invalidationHandler = { [weak self] in
            self?.deps.queue.async { self?.disconnected(id) }
        }
        connection.interruptionHandler = connection.invalidationHandler
        deps.queue.async { [self] in pending[id] = (connection, uid) }
        connection.resume()
        return true
    }

    private func disconnected(_ id: Int) {
        pending[id] = nil
        guard let a = agents.removeValue(forKey: id) else { return }
        logLimited("agent_disconnected", uid: a.uid, fields: ["uid": Int(a.uid), "username": a.username])
        publishAgentInfo()
    }

    /// Connection churn (an agent killed in a loop) must not flood the log and
    /// rotate tamper evidence out; see EventRateLimiter.
    private func logLimited(_ event: String, uid: uid_t, fields: [String: Any]) {
        let now = deps.clock.continuousSeconds
        switch eventLimiter.admit("\(event)/\(uid)", now: now) {
        case .log(let suppressed):
            var f = fields
            if suppressed > 0 { f["suppressedSinceLast"] = suppressed }
            deps.log.event(event, category: .xpc, fields: f)
        case .suppress:
            break
        }
    }

    /// Test seam: register an already-configured in-process connection.
    func agent(_ id: Int) -> Agent? { agents[id] }

    // MARK: - Tick

    /// Call on `queue` after `engine.tick()`, about once a second.
    public func tick() {
        let now = deps.clock.continuousSeconds
        let phase = engine.phase
        let enforcing = phase == .warning || phase == .locked
        if enforcing { enforcingSince = enforcingSince ?? now } else { enforcingSince = nil }

        for a in agents.values { push(a, now: now, enforcing: enforcing) }
        // One dynamic-store read per tick, shared by supervision and status.
        let sessions = deps.sessions.guiSessions()
        supervise(sessions, now: now, phase: phase, enforcing: enforcing)
        publishAgentInfo(sessions)
    }

    /// Push immediately (after an action changed state).
    func pushAll() {
        let now = deps.clock.continuousSeconds
        for a in agents.values { push(a, now: now, enforcing: false, force: true) }
    }

    private func push(_ a: Agent, now: TimeInterval, enforcing: Bool, force: Bool = false) {
        let state = engine.displayState(exempt: isExempt(uid: a.uid, username: a.username, now: now))
        // Compare without the timestamp; heartbeat every second while enforcing.
        var comparable = state
        comparable.trustedNow = .distantPast
        let changed = comparable != a.lastPushed
        guard force || changed || (enforcing && now - a.lastPushAt >= 1) else { return }
        guard let data = XPCCoding.encode(state) else { return }
        a.lastPushed = comparable
        a.lastPushAt = now
        let proxy = a.connection.remoteObjectProxyWithErrorHandler { _ in } as? LullAgentXPC
        proxy?.update(state: data) { [weak self, weak a] presenting in
            self?.deps.queue.async {
                a?.lastAck = self?.deps.clock.continuousSeconds ?? 0
                a?.presenting = presenting
            }
        }
    }

    // MARK: - Supervision

    private func supervise(_ sessions: [GUISession], now: TimeInterval, phase: LullPhase, enforcing: Bool) {
        let config = engine.activeConfig ?? LullConfig()
        let observations = sessions.map { session -> Supervisor.Observation in
            let mine = agents.values.filter { $0.uid == session.uid }
            let alive = mine.contains { a in
                // Liveness only measurable while we heartbeat; also give agents a
                // window after enforcement starts before old acks count against them.
                !enforcing || (a.presenting && now - max(a.lastAck, enforcingSince ?? now) <= Self.livenessWindow)
            }
            return .init(session: session, exempt: isExempt(uid: session.uid, username: session.username, now: now), alive: alive)
        }
        let actions = supervisor.evaluate(
            now: now, phase: phase, observations: observations, grace: TimeInterval(config.agentMissingGraceSeconds),
            fallback: config.fallbackActionIfAgentMissing)
        for action in actions { execute(action) }
    }

    private func execute(_ action: Supervisor.Action) {
        switch action {
        case .log(let event, let uid, let username, let missing):
            deps.log.event(
                event, category: .supervisor, level: event == "agent_restored" ? .default : .error,
                fields: ["uid": Int(uid), "username": username, "missingSeconds": missing])
        case .recoverAgent(let uid, let username):
            let r = deps.runner
            let label = deps.agentLabel
            commandQueue.async { [weak self] in
                // Always re-enable first: `launchctl disable` + bootout would
                // otherwise make both kickstart and bootstrap fail.
                _ = SystemCommands.enableAgent(r, uid: uid, label: label)
                let method: String
                let ok: Bool
                switch SystemCommands.agentJob(r, uid: uid, label: label) {
                case .ours:
                    // Killed, crashed or hung: restart it.
                    method = "kickstart"
                    ok = SystemCommands.kickstartAgent(r, uid: uid, label: label)
                case .notLoaded:
                    // Unloaded with `launchctl bootout`: load the plist again.
                    method = "bootstrap"
                    ok = SystemCommands.bootstrapAgent(r, uid: uid, label: label)
                case .hijacked(let path):
                    // Someone loaded their own job under our label: replace it.
                    method = "replace"
                    _ = SystemCommands.bootoutAgent(r, uid: uid, label: label)
                    ok = SystemCommands.bootstrapAgent(r, uid: uid, label: label)
                    self?.deps.queue.async {
                        self?.deps.log.event(
                            "agent_label_hijacked", category: .supervisor, level: .error,
                            fields: ["uid": Int(uid), "username": username, "path": path ?? "(none)"])
                    }
                }
                self?.deps.queue.async {
                    self?.deps.log.event(
                        "agent_recovery", category: .supervisor, level: ok ? .default : .error,
                        fields: ["uid": Int(uid), "username": username, "method": method, "ok": ok])
                }
            }
        case .sleepDisplay:
            let r = deps.runner
            commandQueue.async { _ = SystemCommands.sleepDisplay(r) }
        case .sleepSystem:
            let r = deps.runner
            commandQueue.async { _ = SystemCommands.sleepSystem(r) }
        }
    }

    // MARK: - Exemption

    func isExempt(uid: uid_t, username: String, now: TimeInterval) -> Bool {
        guard let config = engine.activeConfig else { return false }
        // Group membership can change while logged in; refresh every minute.
        let admin: Bool
        if let c = adminCache[uid], now - c.at < 60 {
            admin = c.isAdmin
        } else {
            admin = deps.users.isAdmin(uid: uid)
            adminCache[uid] = (admin, now)
        }
        return ExemptionPolicy.isExempt(username: username, isAdmin: admin, config: config)
    }

    private func publishAgentInfo(_ sessions: [GUISession]? = nil) {
        let now = deps.clock.continuousSeconds
        var infos: [DaemonStatus.AgentInfo] = []
        var covered = Set<uid_t>()
        for a in agents.values.sorted(by: { $0.id < $1.id }) {
            covered.insert(a.uid)
            infos.append(
                .init(
                    uid: Int(a.uid), username: a.username, fullName: fullName(uid: a.uid, now: now), connected: true,
                    exempt: isExempt(uid: a.uid, username: a.username, now: now)))
        }
        for s in sessions ?? deps.sessions.guiSessions() where !covered.contains(s.uid) {
            infos.append(
                .init(
                    uid: Int(s.uid), username: s.username, fullName: fullName(uid: s.uid, now: now), connected: false,
                    exempt: isExempt(uid: s.uid, username: s.username, now: now)))
        }
        engine.updateAgents(infos)
    }

    /// For the portal. Looked up at most once a minute: this runs every tick,
    /// and a directory account's lookup can go to opendirectoryd.
    private func fullName(uid: uid_t, now: TimeInterval) -> String? {
        if let c = fullNameCache[uid], now - c.at < 60 { return c.name }
        let name = deps.users.fullName(for: uid)
        fullNameCache[uid] = (name, now)
        return name
    }

    // MARK: - Requests (on queue)

    func hello(agentID: Int, version: String) -> Data? {
        let now = deps.clock.continuousSeconds
        if agents[agentID] == nil, let p = pending.removeValue(forKey: agentID) {
            // First message from this connection, so its signature pin passed:
            // only now is it an agent.
            let name = deps.users.username(for: p.uid) ?? "uid\(p.uid)"
            agents[agentID] = Agent(id: agentID, connection: p.connection, uid: p.uid, username: name, now: now)
            logLimited(
                "agent_connected", uid: p.uid,
                fields: ["uid": Int(p.uid), "username": name, "pid": Int(p.connection.processIdentifier), "version": version])
            publishAgentInfo()
        }
        guard let a = agents[agentID] else { return nil }
        a.lastAck = now
        let state = engine.displayState(exempt: isExempt(uid: a.uid, username: a.username, now: now))
        var comparable = state
        comparable.trustedNow = .distantPast
        a.lastPushed = comparable
        a.lastPushAt = now
        return XPCCoding.encode(state)
    }

    func snooze(agentID: Int) -> Bool {
        guard let a = agents[agentID], !isExempt(uid: a.uid, username: a.username, now: deps.clock.continuousSeconds) else { return false }
        let ok = engine.requestSnooze()
        pushAll()
        return ok
    }

    func override(agentID: Int, passphrase: String) -> OverrideResult {
        guard let a = agents[agentID], !isExempt(uid: a.uid, username: a.username, now: deps.clock.continuousSeconds) else {
            return .unavailable("not available for this session")
        }
        let result = engine.attemptOverride(passphrase: passphrase)
        pushAll()
        return result
    }

    func power(agentID: Int, action: DaemonEngine.PowerAction) -> Bool {
        guard let a = agents[agentID] else { return false }
        let exempt = isExempt(uid: a.uid, username: a.username, now: deps.clock.continuousSeconds)
        guard engine.authorizePowerAction(action, uid: a.uid, username: a.username, exempt: exempt) else { return false }
        let r = deps.runner
        // Let the reply reach the agent before the machine goes down.
        commandQueue.asyncAfter(deadline: .now() + 0.5) {
            switch action {
            case .shutdown: _ = SystemCommands.shutdownNow(r)
            case .sleep: _ = SystemCommands.sleepSystem(r)
            }
        }
        return true
    }
}

/// Exported object for one agent connection. Thin: hops to the daemon queue
/// and delegates to the hub, which knows which session is calling.
final class DaemonService: NSObject, LullDaemonXPC {
    weak var hub: AgentHub?
    let agentID: Int

    init(hub: AgentHub, agentID: Int) {
        self.hub = hub
        self.agentID = agentID
    }

    func hello(agentVersion: String, reply: @escaping (Data?) -> Void) {
        guard let hub else { return reply(nil) }
        hub.deps.queue.async { reply(hub.hello(agentID: self.agentID, version: agentVersion)) }
    }

    func requestSnooze(reply: @escaping (Bool) -> Void) {
        guard let hub else { return reply(false) }
        hub.deps.queue.async { reply(hub.snooze(agentID: self.agentID)) }
    }

    func attemptOverride(passphrase: String, reply: @escaping (Data?) -> Void) {
        guard let hub else { return reply(nil) }
        hub.deps.queue.async { reply(XPCCoding.encode(hub.override(agentID: self.agentID, passphrase: passphrase))) }
    }

    func requestShutdown(reply: @escaping (Bool) -> Void) {
        guard let hub else { return reply(false) }
        hub.deps.queue.async { reply(hub.power(agentID: self.agentID, action: .shutdown)) }
    }

    func requestSleep(reply: @escaping (Bool) -> Void) {
        guard let hub else { return reply(false) }
        hub.deps.queue.async { reply(hub.power(agentID: self.agentID, action: .sleep)) }
    }
}

import Foundation
import LullCore
import os

/// Real state source: connects to lulld's Mach service and receives pushes.
///
/// Reconnects automatically (the daemon may be restarting). Delivers updates on
/// the main actor.
@MainActor
public final class XPCDisplayStateSource: DisplayStateSource {
    public var onUpdate: ((DisplayState) -> Void)?
    public var presentingCheck: (() -> Bool)? {
        didSet { receiver.presenting = { [weak self] in self?.presentingCheck?() ?? true } }
    }
    /// Called when the connection is lost (and on every failed reconnect).
    public var onDisconnect: (() -> Void)?

    let serviceName: String
    /// Requirement for the daemon, recomputed on every (re)connect so an
    /// upgraded lulld is accepted. nil only in tests.
    let requirement: (() -> String)?
    private var connection: NSXPCConnection?
    private let receiver = AgentReceiver()
    private let log = Logger(subsystem: LullConstants.logSubsystem, category: "xpc")
    private var reconnectScheduled = false

    /// The daemon must be the exact lulld installed in the root-owned install
    /// folder (cdhash pin), so a fake service can't tell the agent to unlock.
    public init(
        serviceName: String = LullConstants.daemonLabel,
        requirement: (() -> String)? = {
            CodeSigningRequirement.pinned(
                identifier: CodeSigningRequirement.daemonIdentifier, installedPath: CodeSigningRequirement.installedDaemonPath
            ).requirement
        }
    ) {
        self.serviceName = serviceName
        self.requirement = requirement
        receiver.deliver = { [weak self] state in self?.onUpdate?(state) }
    }

    /// Test seam: use an existing connection (e.g. to an anonymous listener).
    init(connectionForTesting: NSXPCConnection) {
        serviceName = ""
        requirement = nil
        receiver.deliver = { [weak self] state in self?.onUpdate?(state) }
        connection = configure(connectionForTesting)
    }

    public func start() {
        if connection == nil { connect() }
        refresh()
    }

    public func refresh() {
        proxy { $0.hello(agentVersion: LullConstants.version) { data in self.deliver(data) } }
    }

    public func requestSnooze() {
        proxy { $0.requestSnooze { _ in } }
    }

    public func attemptOverride(passphrase: String, completion: @escaping (OverrideResult) -> Void) {
        let failed = OverrideResult.unavailable("no connection to lulld")
        guard let p = remote(onError: { DispatchQueue.main.async { completion(failed) } }) else {
            completion(failed)
            return
        }
        p.attemptOverride(passphrase: passphrase) { data in
            let result = XPCCoding.decode(OverrideResult.self, from: data) ?? failed
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func requestShutdown() {
        proxy { $0.requestShutdown { _ in } }
    }

    public func requestSleep() {
        proxy { $0.requestSleep { _ in } }
    }

    // MARK: - Connection

    private func connect() {
        // .privileged: the service lives in the system (LaunchDaemon) domain.
        connection = configure(NSXPCConnection(machServiceName: serviceName, options: .privileged))
        log.log("connecting to \(self.serviceName, privacy: .public)")
    }

    private func configure(_ c: NSXPCConnection) -> NSXPCConnection {
        c.remoteObjectInterface = XPCInterfaces.daemon()
        c.exportedInterface = XPCInterfaces.agent()
        c.exportedObject = receiver
        if let requirement { c.setCodeSigningRequirement(requirement()) }
        // Invalidated (daemon gone, or failed the signature check) or
        // interrupted (daemon restarted): reconnect after a short pause.
        let lost: () -> Void = { [weak self] in
            Task { @MainActor in self?.connectionLost() }
        }
        c.invalidationHandler = lost
        c.interruptionHandler = lost
        c.resume()
        return c
    }

    private func connectionLost() {
        onDisconnect?()
        guard !reconnectScheduled, !serviceName.isEmpty else { return }
        reconnectScheduled = true
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.connect()
            self.refresh()
        }
    }

    private func remote(onError: @escaping () -> Void) -> LullDaemonXPC? {
        connection?.remoteObjectProxyWithErrorHandler { _ in onError() } as? LullDaemonXPC
    }

    private func proxy(_ body: (LullDaemonXPC) -> Void) {
        if let p = remote(onError: {}) { body(p) }
    }

    private nonisolated func deliver(_ data: Data?) {
        guard let state = XPCCoding.decode(DisplayState.self, from: data) else { return }
        Task { @MainActor in self.onUpdate?(state) }
    }
}

/// Exported object receiving daemon pushes. Applies the state on the main
/// thread first, then replies with whether the overlay is presenting
/// correctly: the reply is the daemon's liveness check, so a hung main thread
/// (no reply) or a hidden overlay (false) both count as a missing lock screen.
final class AgentReceiver: NSObject, LullAgentXPC {
    var deliver: (@MainActor (DisplayState) -> Void)?
    var presenting: (@MainActor () -> Bool)?

    func update(state: Data, reply: @escaping (Bool) -> Void) {
        let decoded = XPCCoding.decode(DisplayState.self, from: state)
        Task { @MainActor in
            if let decoded { self.deliver?(decoded) }
            reply(self.presenting?() ?? true)
        }
    }
}

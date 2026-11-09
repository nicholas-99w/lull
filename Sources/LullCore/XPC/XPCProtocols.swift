import Foundation

// XPC contract between lulld (Mach service `DAEMON_LABEL`, system domain) and
// each Lull.app agent. Payloads are JSON (`XPCCoding`) rather than
// NSSecureCoding classes: one Codable model shared by both ends, trivially
// versioned, and no custom ObjC classes to allow-list.
//
// Every call is answered via a reply block so the caller learns the outcome;
// nothing here carries the override hash, only the passphrase the user typed.

/// Agent -> daemon.
@objc public protocol LullDaemonXPC {
    /// First call after connecting (and after wake). Replies with the current
    /// `DisplayState` for the caller's session.
    func hello(agentVersion: String, reply: @escaping (Data?) -> Void)
    func requestSnooze(reply: @escaping (Bool) -> Void)
    /// Replies with an encoded `OverrideResult`.
    func attemptOverride(passphrase: String, reply: @escaping (Data?) -> Void)
    func requestShutdown(reply: @escaping (Bool) -> Void)
    func requestSleep(reply: @escaping (Bool) -> Void)
}

/// Daemon -> agent.
@objc public protocol LullAgentXPC {
    /// Pushed on every change and at least every second while warning/locked.
    /// The agent replies from its main thread *after* applying the state, with
    /// whether it is presenting correctly (true unless it should be showing the
    /// lock overlay and isn't, e.g. hidden by another process). The reply is the
    /// daemon's liveness check: a suspended, hung or hidden agent is restarted.
    func update(state: Data, reply: @escaping (Bool) -> Void)
}

public enum XPCInterfaces {
    public static func daemon() -> NSXPCInterface { NSXPCInterface(with: LullDaemonXPC.self) }
    public static func agent() -> NSXPCInterface { NSXPCInterface(with: LullAgentXPC.self) }
}

public enum XPCCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return try? e.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(type, from: data)
    }
}

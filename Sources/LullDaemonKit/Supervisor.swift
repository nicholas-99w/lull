import Foundation
import LullCore

/// Decides how to respond when a GUI session's agent is missing.
/// Pure: takes the observed world, returns actions; `AgentHub` executes them.
///
/// An agent counts as alive only if it is connected *and* acknowledged a push
/// recently, so a suspended (`kill -STOP`) or hung agent is treated like a
/// killed one.
public struct Supervisor {
    public enum Action: Equatable {
        /// kickstart -k if the job is loaded, otherwise bootstrap it.
        case recoverAgent(uid: uid_t, username: String)
        case sleepDisplay
        /// Escalation: the whole Mac sleeps. Unlike display sleep, a standard
        /// user can't undo it with `caffeinate -u` (no process runs while asleep).
        /// VERIFY on the test Mac (Docs/TESTING.md C14): that a standard user's
        /// power assertions (`caffeinate -i/-s`) can't block `pmset sleepnow`.
        case sleepSystem
        case log(event: String, uid: uid_t, username: String, missingSeconds: Int)
    }

    public struct Observation {
        public var session: GUISession
        public var exempt: Bool
        /// Connected and acked within the liveness window.
        public var alive: Bool

        public init(session: GUISession, exempt: Bool, alive: Bool) {
            self.session = session
            self.exempt = exempt
            self.alive = alive
        }
    }

    public enum Timing {
        /// Outside warning/locked, launchd's KeepAlive does the work; we only
        /// step in for a job that was unloaded, so warnings can still appear.
        public static let normalPhaseGrace: TimeInterval = 60
        /// Between recovery attempts for the same session.
        public static let retryInterval: TimeInterval = 5
        /// Fallback after this many grace periods without recovery.
        public static let fallbackAfterGraces: Double = 3
        public static let minimumFallbackDelay: TimeInterval = 10
        /// Repeat display sleep while still missing (any input wakes it).
        public static let fallbackRepeat: TimeInterval = 10
        /// Still missing this long after display sleep started: put the Mac to
        /// sleep instead. Display sleep alone is defeated by a loop of
        /// `caffeinate -u` plus a loop killing the agent.
        public static let escalateAfterFallback: TimeInterval = 15
        public static let systemSleepRepeat: TimeInterval = 20
        /// An agent counts as restored only after being alive this long, so a
        /// kill loop (agent briefly alive between kills) can't keep resetting
        /// the missing timer and starve the fallback.
        public static let restoredAfterAlive: TimeInterval = 10
        /// A gap between evaluations longer than this means the Mac slept:
        /// start the timers again so a normal wake never triggers a fallback.
        public static let sleepGap: TimeInterval = 5
    }

    private var missingSince: [uid_t: TimeInterval] = [:]
    private var aliveSince: [uid_t: TimeInterval] = [:]
    private var lastRecovery: [uid_t: TimeInterval] = [:]
    private var lastFallback: TimeInterval = -.infinity
    private var lastSystemSleep: TimeInterval = -.infinity
    private var lastEvaluation: TimeInterval?

    public init() {}

    /// - Parameters:
    ///   - now: continuous-clock seconds.
    ///   - phase: device-wide phase from the engine.
    public mutating func evaluate(
        now: TimeInterval, phase: LullPhase, observations: [Observation], grace: TimeInterval, fallback: FallbackAction
    ) -> [Action] {
        if let last = lastEvaluation, now - last > Timing.sleepGap {
            // Woke from sleep (the continuous clock counted it): agents need a
            // moment to reconnect, so measure from now.
            for uid in missingSince.keys { missingSince[uid] = now }
            for uid in aliveSince.keys { aliveSince[uid] = now }
        }
        lastEvaluation = now
        let enforcing = phase == .warning || phase == .locked
        var actions: [Action] = []
        var seen = Set<uid_t>()

        for o in observations {
            let uid = o.session.uid
            seen.insert(uid)
            if o.exempt {
                // Exempt users may run without an agent; nothing to enforce.
                missingSince[uid] = nil
                aliveSince[uid] = nil
                lastRecovery[uid] = nil
                continue
            }
            if o.alive {
                let alive = aliveSince[uid] ?? now
                aliveSince[uid] = alive
                if let since = missingSince[uid], now - alive >= Timing.restoredAfterAlive {
                    missingSince[uid] = nil
                    lastRecovery[uid] = nil
                    actions.append(
                        .log(event: "agent_restored", uid: uid, username: o.session.username, missingSeconds: Int(alive - since)))
                }
                // Overlay up right now: nothing to do this tick.
                continue
            }
            aliveSince[uid] = nil
            let since = missingSince[uid] ?? now
            if missingSince[uid] == nil {
                missingSince[uid] = now
                if enforcing {
                    actions.append(.log(event: "agent_missing", uid: uid, username: o.session.username, missingSeconds: 0))
                }
            }
            let missing = now - since
            let threshold = enforcing ? grace : Timing.normalPhaseGrace
            if missing >= threshold, now - (lastRecovery[uid] ?? -.infinity) >= Timing.retryInterval {
                lastRecovery[uid] = now
                actions.append(.recoverAgent(uid: uid, username: o.session.username))
            }
            // Fallback only while locked, and only for the session on the
            // physical display (sleeping it does nothing for other sessions).
            guard phase == .locked, fallback == .sleepDisplay, o.session.onConsole else { continue }
            let fallbackDelay = max(grace * Timing.fallbackAfterGraces, Timing.minimumFallbackDelay)
            if missing >= fallbackDelay + Timing.escalateAfterFallback {
                if now - lastSystemSleep >= Timing.systemSleepRepeat {
                    lastSystemSleep = now
                    actions.append(.sleepSystem)
                    actions.append(
                        .log(event: "fallback_sleep_system", uid: uid, username: o.session.username, missingSeconds: Int(missing)))
                }
            } else if missing >= fallbackDelay, now - lastFallback >= Timing.fallbackRepeat {
                lastFallback = now
                actions.append(.sleepDisplay)
                actions.append(.log(event: "fallback_sleep_display", uid: uid, username: o.session.username, missingSeconds: Int(missing)))
            }
        }
        // Logged-out sessions: forget them.
        for uid in missingSince.keys where !seen.contains(uid) { missingSince[uid] = nil }
        for uid in aliveSince.keys where !seen.contains(uid) { aliveSince[uid] = nil }
        for uid in lastRecovery.keys where !seen.contains(uid) { lastRecovery[uid] = nil }
        return actions
    }
}

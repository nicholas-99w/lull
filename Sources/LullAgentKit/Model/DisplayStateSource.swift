import Foundation
import LullCore

/// Where the agent gets its state and sends user actions: `XPCDisplayStateSource`
/// in production, `MockDisplayStateSource` in Debug demo mode.
///
/// All callbacks are delivered on the main queue.
@MainActor
public protocol DisplayStateSource: AnyObject {
    var onUpdate: ((DisplayState) -> Void)? { get set }
    /// Asked after each daemon push: is the overlay up whenever it should be?
    /// Sent back to the daemon as the liveness answer.
    var presentingCheck: (() -> Bool)? { get set }
    func start()
    /// Ask for fresh state now (e.g. after wake).
    func refresh()
    func requestSnooze()
    /// The passphrase is passed straight through for the daemon to verify; the
    /// agent never sees the hash.
    func attemptOverride(passphrase: String, completion: @escaping (OverrideResult) -> Void)
    /// Forced shutdown, performed by the daemon.
    func requestShutdown()
    /// Sleep the Mac (keeps open apps and documents), performed by the daemon.
    func requestSleep()
}

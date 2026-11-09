import AppKit
import Carbon.HIToolbox

/// Decides whether the agent may quit (no quit path, but never block
/// logout/restart/shutdown).
///
/// Without this, any process can send the agent a Quit Apple Event (e.g.
/// `osascript -e 'quit app "Lull"'` after the user approves the Automation
/// prompt for Terminal) and the lock screen disappears until launchd restarts it.
/// The system's own quit at logout/restart/shutdown carries a reason
/// (`kAEQuitReason`), which ordinary quit requests don't.
/// VERIFY on the test Mac (Docs/TESTING.md E8): that these reasons reach the
/// agent at logout, restart and shutdown.
public enum QuitPolicy {
    /// Quit reasons the system sends when the session is ending.
    static let sessionEndingReasons: Set<OSType> = [
        OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog), OSType(kAEShowShutdownDialog),
        OSType(kAERestart), OSType(kAEShutDown),
    ]

    public static func allowsQuit(quitReason: OSType?, powerOffPending: Bool) -> Bool {
        if powerOffPending { return true }
        guard let reason = quitReason else { return false }
        return sessionEndingReasons.contains(reason)
    }

    /// The reason on the Apple Event currently being handled, if any.
    public static func currentQuitReason() -> OSType? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return nil }
        let keyword = AEKeyword(kAEQuitReason)
        let d = event.attributeDescriptor(forKeyword: keyword) ?? event.paramDescriptor(forKeyword: keyword)
        guard let code = d?.enumCodeValue, code != 0 else { return nil }
        return code
    }
}

import AppKit
import LullAgentKit
import LullCore
import os

// Lull.app: per-session LaunchAgent (LSUIElement). A thin renderer of daemon
// state; all behaviour lives in LullAgentKit.
//
// DEV SAFETY: never run this on a daily-driver Mac (Docs/DEVELOPMENT.md > Dev safety). It locks the
// screen whenever lulld says so, and Debug demo mode shows a real overlay; it auto-releases after 600s (or --auto-release N),
// quits when /var/db/lull/DISABLE exists, and Ctrl-Opt-Cmd-Shift-L releases it.

let log = Logger(subsystem: LullConstants.logSubsystem, category: "agent")

@main
enum LullAgentMain {
    @MainActor
    static func main() {
        #if !DEBUG
            // Refuse debugger attachment in Release, so a
            // local user can't attach to the agent and tear down its windows.
            Hardening.denyDebuggerAttach()
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: AgentCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No menu at all: no Quit/Hide/Close items to trigger by key equivalent.
        NSApp.mainMenu = NSMenu()
        #if DEBUG
            if let demo = DemoOptions.parse(CommandLine.arguments) {
                let source = MockDisplayStateSource(
                    scenario: demo.scenario, appearance: demo.appearance, texts: demo.texts, lockDuration: demo.lockSeconds)
                let c = AgentCoordinator(source: source)
                if let s = demo.autoReleaseSeconds { c.debugMaxLockSeconds = s }
                c.start()
                coordinator = c
                return
            }
        #endif
        let c = AgentCoordinator(source: XPCDisplayStateSource())
        c.start()
        coordinator = c
        log.log("agent started; connecting to lulld")
    }

    private var powerOffPending = false
    private var powerOffObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Logout/restart/shutdown is announced here before the system asks us to quit.
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.powerOffPending = true }
        }
    }

    // Only the system may quit us, and only when the session is ending:
    // logout/restart/shutdown must never be blocked. Any other
    // quit request (e.g. an Apple Event from osascript) is refused. A user
    // can't reach Quit otherwise (no menu, Cmd-Q swallowed, Dock and Force
    // Quit disabled), and launchd's KeepAlive restarts the agent if it is killed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = QuitPolicy.currentQuitReason()
        if QuitPolicy.allowsQuit(quitReason: reason, powerOffPending: powerOffPending) { return .terminateNow }
        log.log("refused quit request (reason \(reason.map { String($0) } ?? "none", privacy: .public))")
        return .terminateCancel
    }
}

#if DEBUG
    struct DemoOptions {
        var scenario: MockDisplayStateSource.Scenario
        var appearance = Fixtures.brandedAppearance
        var texts = Fixtures.demoTexts
        var lockSeconds: TimeInterval = 180
        var autoReleaseSeconds: TimeInterval?

        /// `--demo cycle|warning|locked|awaiting [--demo-config <plist>] [--lock-seconds N] [--auto-release N]`
        static func parse(_ argv: [String]) -> DemoOptions? {
            func value(_ flag: String) -> String? {
                argv.firstIndex(of: flag).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
            }
            guard let name = value("--demo") else { return nil }
            guard let scenario = MockDisplayStateSource.Scenario(rawValue: name) else {
                let all = MockDisplayStateSource.Scenario.allCases.map(\.rawValue).joined(separator: "|")
                FileHandle.standardError.write(Data("Lull: --demo must be one of \(all)\n".utf8))
                exit(64)
            }
            var o = DemoOptions(scenario: scenario)
            if let path = value("--demo-config") {
                // Demo only: preview a real config's look. The production agent
                // never reads config; it renders what the daemon sends.
                guard let raw = NSDictionary(contentsOfFile: path) as? [String: Any],
                    let config = ConfigParser().parse(raw).config
                else {
                    FileHandle.standardError.write(Data("Lull: \(path) is not a valid config\n".utf8))
                    exit(65)
                }
                o.appearance = config.appearance
                o.texts = config.texts
            }
            if let s = value("--lock-seconds").flatMap(Double.init) { o.lockSeconds = s }
            if let s = value("--auto-release").flatMap(Double.init) { o.autoReleaseSeconds = s }
            return o
        }
    }
#endif

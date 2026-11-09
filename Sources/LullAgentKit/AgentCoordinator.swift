import AppKit
import LullCore
import os

/// Wires a `DisplayStateSource` to the model and the windows, and handles
/// sleep/wake. Owns no policy: what to show comes from the daemon's state.
@MainActor
public final class AgentCoordinator {
    public let model: AgentModel
    let source: DisplayStateSource
    let overlay: OverlayController
    let warning: WarningPanelController
    private let log = Logger(subsystem: LullConstants.logSubsystem, category: "agent")
    private var timer: Timer?
    /// No update from the daemon for this long counts as "daemon unreachable".
    static let staleAfter: TimeInterval = 10
    private var observers: [NSObjectProtocol] = []

    #if DEBUG
        /// Debug-only escape hatches (Docs/DEVELOPMENT.md > Dev safety).
        public var debugMaxLockSeconds: TimeInterval = LullConstants.debugMaxLockSeconds
        private var debugLockShownAt: TimeInterval?
        private var debugReleased = false
        private var debugKeyMonitor: Any?
    #endif

    public init(source: DisplayStateSource, model: AgentModel? = nil) {
        let model = model ?? AgentModel()
        self.source = source
        self.model = model
        overlay = OverlayController(model: model)
        warning = WarningPanelController(model: model)
        model.source = source
    }

    public func start() {
        source.onUpdate = { [weak self] state in
            self?.model.apply(state)
            self?.render()
        }
        source.presentingCheck = { [weak self] in self?.isPresentingCorrectly() ?? true }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        observeSleepWake()
        #if DEBUG
            installDebugEscape()
        #endif
        source.start()
    }

    private func tick() {
        model.tick()
        #if DEBUG
            if FileManager.default.fileExists(atPath: LullConstants.debugDisableFlagPath) {
                log.log("DEBUG: DISABLE file present; quitting")
                // exit, not NSApp.terminate: QuitPolicy refuses non-system quits.
                exit(0)
            }
        #endif
        render()
        if overlay.isShown { overlay.reclaimFocus() }
    }

    /// True unless the overlay should be up and isn't actually visible (e.g.
    /// another process hid the app). Reported to the daemon with every ack.
    func isPresentingCorrectly() -> Bool {
        guard let state = model.state else { return true }
        var lock = shouldLock(state)
        #if DEBUG
            if debugReleased { lock = false }
        #endif
        guard lock else { return true }
        return overlay.isShown && overlay.isVisibleOnScreen
    }

    /// Maps phase to windows. Called on every update and every second.
    func render() {
        guard let state = model.state else {
            overlay.hide()
            warning.hide()
            return
        }
        var lock = shouldLock(state)
        #if DEBUG
            lock = debugGate(lock)
        #endif
        if lock {
            warning.hide()
            overlay.show()
        } else {
            overlay.hide()
            if state.phase == .warning && state.showWarningCard {
                warning.show()
            } else {
                warning.hide()
            }
        }
    }

    /// Whether the overlay should be up for `state`, before Debug hatches.
    func shouldLock(_ state: DisplayState) -> Bool {
        let stale = model.secondsSinceUpdate > Self.staleAfter
        switch state.phase {
        case .locked:
            // Never trap people: if we've lost the daemon, keep enforcing
            // the last known window but release it once that window has ended.
            if stale, let end = state.windowEnd, model.now >= end { return false }
            return true
        case .normal, .warning:
            // Stale state whose lock time has passed: after waking from sleep
            // (the continuous clock counts sleep, so this is immediate on wake)
            // or with the daemon unreachable. Lock now from the last known
            // window instead of showing the desktop until fresh state arrives.
            guard stale, let start = state.lockStart, let end = state.windowEnd else { return false }
            return model.now >= start && model.now < end
        case .overridden, .exempt, .disabled:
            return false
        }
    }

    // MARK: Sleep / wake

    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        // If a lock is imminent, put the overlay up *before* sleeping so it's
        // already there on the first frame after wake; the refresh on wake
        // takes it down again if the lock didn't start.
        observers.append(
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.preArmForSleep() }
            })
        for name in [
            NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
        ] {
            observers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.woke() }
                })
        }
    }

    private func preArmForSleep() {
        guard let state = model.state, state.phase == .warning || state.phase == .locked else { return }
        warning.hide()
        overlay.show()
    }

    private func woke() {
        model.tick()
        source.refresh()
        render()
    }

    // MARK: Debug-only

    #if DEBUG
        /// Auto-release after `debugMaxLockSeconds` of continuous lock, until the
        /// phase leaves `locked`.
        private func debugGate(_ lock: Bool) -> Bool {
            guard lock else {
                debugLockShownAt = nil
                debugReleased = false
                return false
            }
            if debugReleased { return false }
            let now = ProcessInfo.processInfo.systemUptime
            let since = debugLockShownAt ?? now
            debugLockShownAt = since
            if now - since >= debugMaxLockSeconds {
                log.log("DEBUG: auto-released overlay after \(Int(self.debugMaxLockSeconds))s")
                debugReleased = true
                return false
            }
            return true
        }

        /// Ctrl-Opt-Cmd-Shift-L releases the overlay (DEBUG emergency release).
        /// Not Ctrl-Opt-Cmd-Shift-. (period): macOS reserves that for sysdiagnose
        /// and intercepts it system-wide.
        private func installDebugEscape() {
            debugKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if mods.contains([.control, .option, .command, .shift]), event.charactersIgnoringModifiers?.lowercased() == "l" {
                    Task { @MainActor in
                        self?.log.log("DEBUG emergency release")
                        self?.debugReleased = true
                        self?.render()
                    }
                    return nil
                }
                return event
            }
        }
    #endif
}

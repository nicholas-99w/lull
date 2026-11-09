import AppKit
import LullCore
import SwiftUI
import os

/// Borderless full-screen window at shielding level.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // CGShieldingWindowLevel is what the system uses to cover everything,
        // including the menu bar, Dock and full-screen apps.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    // Borderless windows can't become key by default; we need key for the
    // passphrase field and to keep keyboard focus away from other apps.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// No close/quit/hide/minimise path.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if KeySwallower.shouldSwallow(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func close() {
        // Only the controller may close overlay windows (via `forceClose`).
    }

    func forceClose() {
        orderOut(nil)
        super.close()
    }

    override func miniaturize(_ sender: Any?) {}
}

enum KeySwallower {
    /// Cmd-Q/W/H/M (and their Option variants) are eaten while locked.
    static func shouldSwallow(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return ["q", "w", "h", "m"].contains(key)
    }
}

/// Owns one overlay window per screen and the locked presentation options.
@MainActor
public final class OverlayController {
    private let model: AgentModel
    private let log = Logger(subsystem: LullConstants.logSubsystem, category: "agent")
    private var windows: [OverlayWindow] = []
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    public private(set) var isShown = false

    public init(model: AgentModel) {
        self.model = model
        let nc = NotificationCenter.default
        observers.append(
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.rebuildIfShown() }
            })
        // Another process can hide us (NSRunningApplication.hide(), System
        // Events "set visible"); .disableHideApplication only removes the Hide
        // menu item. Un-hide at once.
        observers.append(
            nc.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reclaimFocus() }
            })
        // Someone else got focus (e.g. a notification click): take it back.
        observers.append(
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reclaimFocus() }
            })
    }

    public func show() {
        guard !isShown else {
            reclaimFocus()
            return
        }
        isShown = true
        buildWindows()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            KeySwallower.shouldSwallow(event) ? nil : event
        }
        reclaimFocus()
        let problems = PresentationOptionsPolicy.apply(PresentationOptionsPolicy.locked)
        if !problems.isEmpty {
            log.error("invalid presentation options: \(problems.map(\.description).joined(separator: "; "), privacy: .public)")
        }
        log.log("overlay shown on \(self.windows.count) screen(s)")
    }

    /// All overlay windows are on screen and the app isn't hidden.
    public var isVisibleOnScreen: Bool {
        !NSApp.isHidden && !windows.isEmpty && windows.allSatisfy(\.isVisible)
    }

    public func hide() {
        guard isShown else { return }
        isShown = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSApp.presentationOptions = []
        windows.forEach { $0.forceClose() }
        windows = []
        log.log("overlay hidden")
    }

    /// Re-asserts front-most, key and active. Called on show, on resign-active
    /// and from the coordinator's 1s tick.
    /// VERIFY on the test Mac (Docs/TESTING.md C16): that `unhideWithoutActivation`
    /// restores an overlay hidden by another process.
    public func reclaimFocus() {
        guard isShown else { return }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        for w in windows { w.orderFrontRegardless() }
        windows.first?.makeKey()
        if !NSApp.isActive {
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // Options only take effect while we're active, and other apps can change
        // them when they're frontmost, so re-apply each time.
        if NSApp.presentationOptions != PresentationOptionsPolicy.locked {
            PresentationOptionsPolicy.apply(PresentationOptionsPolicy.locked)
        }
    }

    private func rebuildIfShown() {
        guard isShown else { return }
        windows.forEach { $0.forceClose() }
        windows = []
        buildWindows()
        reclaimFocus()
        log.log("screens changed; overlay rebuilt on \(self.windows.count) screen(s)")
    }

    private func buildWindows() {
        // screens.first is the primary display (the one with the menu bar).
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = OverlayWindow(screen: screen)
            let host = NSHostingView(rootView: LockScreenView(model: model, isPrimary: i == 0))
            host.frame = NSRect(origin: .zero, size: screen.frame.size)
            host.autoresizingMask = [.width, .height]
            w.contentView = host
            w.orderFrontRegardless()
            windows.append(w)
        }
    }
}

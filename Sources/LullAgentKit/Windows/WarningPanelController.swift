import AppKit
import LullCore
import SwiftUI

/// Non-activating floating panel for the warning card: it appears over
/// whatever the user is doing (including full-screen apps) without stealing focus.
@MainActor
public final class WarningPanelController {
    private let model: AgentModel
    private var panel: NSPanel?
    private var host: NSHostingView<WarningCardView>?
    public private(set) var isShown = false

    public init(model: AgentModel) { self.model = model }

    public func show() {
        if panel == nil { makePanel() }
        guard let panel, let host else { return }
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        if !isShown {
            panel.orderFrontRegardless()
            isShown = true
        }
    }

    public func hide() {
        guard isShown else { return }
        panel?.orderOut(nil)
        isShown = false
    }

    private func makePanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        // Above normal and full-screen app windows, below the lock overlay.
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        let h = NSHostingView(rootView: WarningCardView(model: model))
        p.contentView = h
        panel = p
        host = h
    }

    private func origin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.screens.first else { return .zero }
        let f = screen.visibleFrame
        switch model.state?.appearance.warningCardPosition ?? .topCenter {
        case .topCenter: return NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height)
        case .topRight: return NSPoint(x: f.maxX - size.width, y: f.maxY - size.height)
        case .center: return NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)
        }
    }
}

import AppKit

/// The presentation options used while locked, and a validator for them.
///
/// `NSApp.presentationOptions = x` raises `NSInvalidArgumentException` for an
/// invalid combination, which Swift can't catch, so we check first. Rules from
/// Apple's "Kiosk Mode" technote ("Valid Combinations of Settings",
/// developer.apple.com/library/archive/technotes/KioskMode):
///  1. autoHideDock and hideDock are mutually exclusive.
///  2. autoHideMenuBar and hideMenuBar are mutually exclusive.
///  3. hideMenuBar requires hideDock; autoHideMenuBar requires hideDock or autoHideDock.
///  4. disableProcessSwitching, disableForceQuit, disableSessionTermination and
///     disableMenuBarTransparency require hideDock or autoHideDock.
/// Plus (NSApplication.h): autoHideToolbar may only be used with fullScreen.
public enum PresentationOptionsPolicy {
    /// Deliberately *not* `.disableSessionTermination`: users must
    /// always be able to shut down or restart.
    public static let locked: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableHideApplication, .disableAppleMenu,
    ]

    public enum Violation: Equatable, CustomStringConvertible {
        case dockModesExclusive
        case menuBarModesExclusive
        case hideMenuBarNeedsHideDock
        case autoHideMenuBarNeedsDockHidden
        case needsDockHidden(String)
        case autoHideToolbarNeedsFullScreen

        public var description: String {
            switch self {
            case .dockModesExclusive: return "autoHideDock and hideDock are mutually exclusive"
            case .menuBarModesExclusive: return "autoHideMenuBar and hideMenuBar are mutually exclusive"
            case .hideMenuBarNeedsHideDock: return "hideMenuBar requires hideDock"
            case .autoHideMenuBarNeedsDockHidden: return "autoHideMenuBar requires hideDock or autoHideDock"
            case .needsDockHidden(let o): return "\(o) requires hideDock or autoHideDock"
            case .autoHideToolbarNeedsFullScreen: return "autoHideToolbar requires fullScreen"
            }
        }
    }

    public static func violations(_ o: NSApplication.PresentationOptions) -> [Violation] {
        var v: [Violation] = []
        let dockHidden = o.contains(.hideDock) || o.contains(.autoHideDock)
        if o.contains(.hideDock) && o.contains(.autoHideDock) { v.append(.dockModesExclusive) }
        if o.contains(.hideMenuBar) && o.contains(.autoHideMenuBar) { v.append(.menuBarModesExclusive) }
        if o.contains(.hideMenuBar) && !o.contains(.hideDock) { v.append(.hideMenuBarNeedsHideDock) }
        if o.contains(.autoHideMenuBar) && !dockHidden { v.append(.autoHideMenuBarNeedsDockHidden) }
        let needDock: [(NSApplication.PresentationOptions, String)] = [
            (.disableProcessSwitching, "disableProcessSwitching"), (.disableForceQuit, "disableForceQuit"),
            (.disableSessionTermination, "disableSessionTermination"),
            (.disableMenuBarTransparency, "disableMenuBarTransparency"),
        ]
        for (opt, name) in needDock where o.contains(opt) && !dockHidden { v.append(.needsDockHidden(name)) }
        if o.contains(.autoHideToolbar) && !o.contains(.fullScreen) { v.append(.autoHideToolbarNeedsFullScreen) }
        return v
    }

    /// Applies `options` only if valid; otherwise falls back to the safest valid
    /// subset (hide Dock + menu bar) and returns the violations for logging.
    @MainActor @discardableResult
    public static func apply(_ options: NSApplication.PresentationOptions) -> [Violation] {
        let problems = violations(options)
        NSApp.presentationOptions = problems.isEmpty ? options : [.hideDock, .hideMenuBar]
        return problems
    }
}

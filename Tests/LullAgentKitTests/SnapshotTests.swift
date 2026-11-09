import AppKit
import LullCore
import SwiftUI
import XCTest

@testable import LullAgentKit

/// Renders views to PNG offscreen with ImageRenderer (no windows), for eyeballing
/// the design without running the agent. Opt-in:
///   LULL_SNAPSHOTS=1 swift test --filter SnapshotTests   # writes /tmp/lull-snapshots/*.png
/// NSVisualEffectView blur can't render offscreen, so lock screens use a solid backdrop here.
@MainActor
final class SnapshotTests: XCTestCase {
    let dir = "/tmp/lull-snapshots"

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LULL_SNAPSHOTS"] == "1", "set LULL_SNAPSHOTS=1")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func render<V: View>(_ view: V, _ name: String, size: CGSize? = nil, dark: Bool = false) throws {
        let content =
            view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size?.width, height: size?.height)
        let r = ImageRenderer(content: content)
        r.scale = 1
        let image = try XCTUnwrap(r.nsImage, name)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func solid(_ s: DisplayState) -> DisplayState {
        var s = s
        s.appearance.backgroundStyle = .solid
        s.appearance.backgroundOpacity = 1
        if s.appearance.backgroundColor == Appearance().backgroundColor {
            s.appearance.backgroundColor = ThemedColor("#2A3140")
        }
        return s
    }

    func testLockScreens() throws {
        let size = CGSize(width: 1280, height: 800)
        try render(
            LockScreenView(model: PreviewModels.model(solid(Fixtures.lockedState(branded: false))), isPrimary: true), "lock-default-light",
            size: size)
        try render(
            LockScreenView(model: PreviewModels.model(solid(Fixtures.lockedState(branded: false))), isPrimary: true), "lock-default-dark",
            size: size, dark: true)
        try render(
            LockScreenView(model: PreviewModels.branded(solid(Fixtures.lockedState())), isPrimary: true), "lock-branded-light", size: size)
        try render(
            LockScreenView(model: PreviewModels.branded(solid(Fixtures.lockedState())), isPrimary: true), "lock-branded-dark", size: size,
            dark: true)
        try render(
            LockScreenView(model: PreviewModels.model(solid(Fixtures.awaitingSyncState)), isPrimary: true), "lock-awaiting-sync", size: size
        )
        try render(
            LockScreenView(model: PreviewModels.branded(solid(Fixtures.lockedState(texts: Fixtures.configuredTexts))), isPrimary: true),
            "lock-configured-org", size: size)
        try render(
            LockScreenView(
                model: PreviewModels.branded(
                    solid(Fixtures.lockedState()),
                    sheet: OverrideSheetState(message: UIStrings.overrideRejected(attemptsRemaining: 2), isError: true)),
                isPrimary: true), "lock-override-sheet", size: size)
        try render(
            LockScreenView(
                model: PreviewModels.model(solid(Fixtures.lockedState()), images: Fixtures.brandedImages, confirmingShutdown: true),
                isPrimary: true),
            "lock-shutdown-confirm", size: size, dark: true)
        try render(
            LockScreenView(model: PreviewModels.branded(solid(Fixtures.lockedState())), isPrimary: true), "lock-small-screen",
            size: CGSize(width: 800, height: 600))
    }

    func testWarningCards() throws {
        try render(
            WarningCardView(model: PreviewModels.model(Fixtures.warningState(secondsToLock: 600, branded: false, snooze: false))),
            "warning-default-light")
        try render(WarningCardView(model: PreviewModels.branded(Fixtures.warningState(secondsToLock: 300))), "warning-branded-snooze")
        try render(
            WarningCardView(model: PreviewModels.branded(Fixtures.warningState(secondsToLock: 42))), "warning-final-countdown-dark",
            dark: true)
    }
}

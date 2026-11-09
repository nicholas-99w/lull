import AppKit
import LullCore
import SwiftUI
import XCTest

@testable import LullAgentKit

/// Renders the screenshots used in the published docs (Docs/images). Opt-in:
///   LULL_DOC_SCREENSHOTS=Docs/images swift test --filter DocScreenshotTests
/// Rendered offscreen from the real views with generic sample branding.
/// Offscreen rendering can't draw the blurred-desktop backdrop, so lock screens
/// use a solid backdrop close to how Blur looks over a typical desktop.
@MainActor
final class DocScreenshotTests: XCTestCase {
    var dir = ""

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment["LULL_DOC_SCREENSHOTS"] ?? ""
        try XCTSkipIf(env.isEmpty, "set LULL_DOC_SCREENSHOTS=<output dir>")
        dir = env
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func render<V: View>(_ view: V, _ name: String, size: CGSize? = nil, dark: Bool = false, scale: CGFloat = 1) throws {
        let r = ImageRenderer(
            content: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size?.width, height: size?.height))
        r.scale = scale
        let image = try XCTUnwrap(r.nsImage, name)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    /// Stand-in for the blur backdrop (see type comment).
    func backdrop(_ s: DisplayState, _ hex: String = "#232838") -> DisplayState {
        var s = s
        if s.appearance.backgroundStyle == .blur {
            s.appearance.backgroundStyle = .solid
            s.appearance.backgroundOpacity = 1
            s.appearance.backgroundColor = ThemedColor(hex)
        }
        return s
    }

    var branded: Texts {
        var t = Fixtures.configuredTexts
        t.lockedTitle = "Time to rest, {{firstName}}"
        return t
    }

    let screen = CGSize(width: 1280, height: 800)

    func testLockScreens() throws {
        // Nothing configured but a schedule: built-in look and wording.
        try render(
            LockScreenView(model: PreviewModels.model(backdrop(Fixtures.lockedState(branded: false))), isPrimary: true), "lock-default",
            size: screen)
        // Branded: banner, logo, colours, OrganizationName/SupportContact.
        let b = backdrop(Fixtures.lockedState(texts: branded), "#0B1F3A")
        try render(LockScreenView(model: PreviewModels.branded(b), isPrimary: true), "lock-branded-light", size: screen)
        try render(LockScreenView(model: PreviewModels.branded(b), isPrimary: true), "lock-branded-dark", size: screen, dark: true)
        // Solid background, no banner, larger type, square-ish card.
        var minimal = Fixtures.lockedState(branded: false, texts: Fixtures.configuredTexts)
        minimal.appearance.backgroundStyle = .solid
        minimal.appearance.backgroundColor = ThemedColor("#3B3F8F")
        minimal.appearance.backgroundOpacity = 1
        minimal.appearance.cardCornerRadius = 6
        minimal.appearance.cardWidth = 560
        minimal.appearance.titleFontSize = 34
        minimal.appearance.accentColor = ThemedColor("#FFD27A")
        minimal.appearance.countdownColor = ThemedColor("#3B3F8F")
        try render(
            LockScreenView(model: PreviewModels.model(minimal, images: BrandingImages(logo: Fixtures.makeLogo())), isPrimary: true),
            "lock-solid-minimal", size: screen)
        try render(
            LockScreenView(model: PreviewModels.model(b, images: Fixtures.brandedImages, confirmingShutdown: true), isPrimary: true),
            "lock-shutdown-confirm", size: screen)
        try render(
            LockScreenView(model: PreviewModels.branded(b), isPrimary: true), "lock-small-screen", size: CGSize(width: 800, height: 600))
    }

    func testWarningCards() throws {
        try render(
            WarningCardView(model: PreviewModels.model(Fixtures.warningState(secondsToLock: 600, branded: false, snooze: false))),
            "warning-default", scale: 2)
        try render(
            WarningCardView(model: PreviewModels.branded(Fixtures.warningState(secondsToLock: 300, texts: branded))), "warning-branded",
            scale: 2)
        try render(
            WarningCardView(model: PreviewModels.branded(Fixtures.warningState(secondsToLock: 42, texts: branded))),
            "warning-final-countdown",
            dark: true, scale: 2)
    }
}

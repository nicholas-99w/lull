import AppKit
import LullCore
import XCTest

@testable import LullAgentKit

// These tests never create windows: an overlay must not appear on the dev Mac.

final class PresentationOptionsTests: XCTestCase {
    func testLockedOptionsAreValidAndAllowShutdown() {
        XCTAssertEqual(PresentationOptionsPolicy.violations(PresentationOptionsPolicy.locked), [])
        XCTAssertFalse(PresentationOptionsPolicy.locked.contains(.disableSessionTermination), "users must be able to shut down")
        for o: NSApplication.PresentationOptions in [
            .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableHideApplication, .disableAppleMenu,
        ] {
            XCTAssertTrue(PresentationOptionsPolicy.locked.contains(o))
        }
    }

    func testInvalidCombinations() {
        typealias V = PresentationOptionsPolicy.Violation
        func v(_ o: NSApplication.PresentationOptions) -> [V] { PresentationOptionsPolicy.violations(o) }
        XCTAssertEqual(v([.hideDock, .autoHideDock]), [.dockModesExclusive])
        XCTAssertEqual(v([.hideDock, .hideMenuBar, .autoHideMenuBar]), [.menuBarModesExclusive])
        XCTAssertEqual(v([.hideMenuBar]), [.hideMenuBarNeedsHideDock])
        XCTAssertEqual(v([.autoHideDock, .hideMenuBar]), [.hideMenuBarNeedsHideDock])
        XCTAssertEqual(v([.autoHideMenuBar]), [.autoHideMenuBarNeedsDockHidden])
        XCTAssertEqual(v([.disableProcessSwitching]), [.needsDockHidden("disableProcessSwitching")])
        XCTAssertEqual(v([.disableForceQuit, .disableSessionTermination]).count, 2)
        XCTAssertEqual(v([.autoHideDock, .disableForceQuit]), [])
        XCTAssertEqual(v([.autoHideToolbar]), [.autoHideToolbarNeedsFullScreen])
        XCTAssertEqual(v([]), [])
    }
}

final class KeySwallowerTests: XCTestCase {
    func key(_ chars: String, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
    }

    func testSwallowsQuitCloseHideMinimise() {
        for c in ["q", "w", "h", "m", "Q"] {
            XCTAssertTrue(KeySwallower.shouldSwallow(key(c, .command)), c)
            XCTAssertTrue(KeySwallower.shouldSwallow(key(c, [.command, .option])), c)
        }
        XCTAssertFalse(KeySwallower.shouldSwallow(key("q", [])), "typing q in the passphrase field")
        XCTAssertFalse(KeySwallower.shouldSwallow(key("a", .command)))
    }
}

/// Clock whose continuous time we control; wall time deliberately wrong.
final class TestClock: ClockSource, @unchecked Sendable {
    var wallNow = Date(timeIntervalSince1970: 0)
    var continuousSeconds: TimeInterval = 100
    var bootSessionUUID = "b"
}

@MainActor
final class StubSource: DisplayStateSource {
    var onUpdate: ((DisplayState) -> Void)?
    var presentingCheck: (() -> Bool)?
    var snoozes = 0
    var shutdowns = 0
    var passphrases: [String] = []
    var pending: ((OverrideResult) -> Void)?
    func start() {}
    func refresh() {}
    func requestSnooze() { snoozes += 1 }
    func attemptOverride(passphrase: String, completion: @escaping (OverrideResult) -> Void) {
        passphrases.append(passphrase)
        pending = completion
    }
    func requestShutdown() { shutdowns += 1 }
    var sleeps = 0
    func requestSleep() { sleeps += 1 }
}

@MainActor
final class AgentModelTests: XCTestCase {
    func testCountdownUsesContinuousClockNotWall() {
        let clock = TestClock()
        let m = AgentModel(
            userFullName: "Alex Citizen", locale: Locale(identifier: "en_AU"), clock: clock, imageLoader: { _ in BrandingImages() })
        m.apply(Fixtures.lockedState())
        XCTAssertEqual(m.content(.lock)?.countdown, "Available again in 8h 30m")
        clock.wallNow = Date(timeIntervalSince1970: 9_999_999_999)  // wall clock changed
        clock.continuousSeconds += 3600
        m.tick()
        XCTAssertEqual(m.now, Fixtures.lockedNow.addingTimeInterval(3600))
        XCTAssertEqual(m.content(.lock)?.countdown, "Available again in 7h 30m")
    }

    func testOverrideFlow() {
        let source = StubSource()
        let m = AgentModel(clock: TestClock(), imageLoader: { _ in BrandingImages() })
        m.source = source
        m.apply(Fixtures.lockedState())
        m.showOverride()
        m.submitOverride("")
        XCTAssertTrue(source.passphrases.isEmpty, "empty passphrase isn't sent")
        m.submitOverride("guess")
        XCTAssertEqual(m.overrideSheet?.busy, true)
        m.submitOverride("again")
        XCTAssertEqual(source.passphrases, ["guess"], "no second request while one is in flight")

        source.pending?(.rejected(attemptsRemaining: 2))
        XCTAssertEqual(m.overrideSheet?.message, "Incorrect passphrase. 2 attempts remaining.")
        XCTAssertEqual(m.overrideSheet?.busy, false)

        m.submitOverride("x")
        source.pending?(.lockedOut(until: Fixtures.lockedNow.addingTimeInterval(900)))
        XCTAssertEqual(m.overrideSheet?.lockedOut, true)
        XCTAssertTrue(m.overrideSheet?.message?.hasPrefix("Too many attempts. Try again at") ?? false)

        m.overrideSheet = OverrideSheetState()
        m.submitOverride("right")
        source.pending?(.granted(until: Fixtures.lockedNow.addingTimeInterval(1800)))
        XCTAssertNil(m.overrideSheet, "sheet closes on success")
    }

    func testSheetsCloseWhenNoLongerLocked() {
        let m = AgentModel(clock: TestClock(), imageLoader: { _ in BrandingImages() })
        m.apply(Fixtures.lockedState())
        m.showOverride()
        m.confirmingShutdown = true
        var s = Fixtures.lockedState()
        s.phase = .overridden
        m.apply(s)
        XCTAssertNil(m.overrideSheet)
        XCTAssertFalse(m.confirmingShutdown)
    }

    func testImagesReloadOnlyWhenAppearanceChanges() {
        var loads = 0
        let m = AgentModel(
            clock: TestClock(),
            imageLoader: { _ in
                loads += 1; return BrandingImages()
            })
        m.apply(Fixtures.lockedState())
        m.apply(Fixtures.lockedState(now: Fixtures.lockedNow.addingTimeInterval(1)))
        XCTAssertEqual(loads, 1)
        m.apply(Fixtures.lockedState(branded: false))
        XCTAssertEqual(loads, 2)
    }

    func testActionsForwardToSource() {
        let source = StubSource()
        let m = AgentModel(clock: TestClock(), imageLoader: { _ in BrandingImages() })
        m.source = source
        m.snooze()
        m.shutdown()
        m.sleep()
        XCTAssertEqual(source.snoozes, 1)
        XCTAssertEqual(source.shutdowns, 1)
        XCTAssertEqual(source.sleeps, 1)
    }
}

final class BrandingImageLoaderTests: XCTestCase {
    func tempFile(_ data: Data) -> String {
        let path = NSTemporaryDirectory() + "lull-img-" + UUID().uuidString
        FileManager.default.createFile(atPath: path, contents: data)
        return path
    }

    func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testLoadsValidImage() {
        let img = BrandingImageLoader.load(tempFile(png(width: 40, height: 10)))
        XCTAssertEqual(img?.size, NSSize(width: 40, height: 10))
    }

    func testRejectsMissingCorruptOversizedAndHuge() {
        XCTAssertNil(BrandingImageLoader.load(nil as String?))
        XCTAssertNil(BrandingImageLoader.load("/nonexistent/banner.png"))
        XCTAssertNil(BrandingImageLoader.load(tempFile(Data("not an image".utf8))), "corrupt")
        XCTAssertNil(BrandingImageLoader.load(tempFile(Data())), "empty")
        XCTAssertNil(BrandingImageLoader.load(tempFile(png(width: 40, height: 10)), maxBytes: 10), "too many bytes")
        XCTAssertNil(BrandingImageLoader.load(tempFile(png(width: 9000, height: 1))), "too many pixels")
        XCTAssertNil(BrandingImageLoader.load(NSTemporaryDirectory()), "directory")
    }
}

@MainActor
final class MockSourceTests: XCTestCase {
    func testCycleTimeline() {
        let src = MockDisplayStateSource(scenario: .cycle, lockDuration: 120)
        let t0 = Date()
        XCTAssertEqual(src.state(at: t0).phase, .warning)
        XCTAssertTrue(src.state(at: t0).showWarningCard, "card for the first 20s")
        XCTAssertFalse(src.state(at: t0.addingTimeInterval(30)).showWarningCard)
        XCTAssertTrue(src.state(at: t0.addingTimeInterval(30)).snoozeAvailable)
        XCTAssertFalse(src.state(at: t0.addingTimeInterval(55)).inFinalCountdown)
        XCTAssertTrue(src.state(at: t0.addingTimeInterval(65)).inFinalCountdown)
        XCTAssertTrue(src.state(at: t0.addingTimeInterval(65)).showWarningCard)
        XCTAssertEqual(src.state(at: t0.addingTimeInterval(125)).phase, .locked)
        XCTAssertEqual(src.state(at: t0.addingTimeInterval(125 + 120)).phase, .normal)
    }

    func testAwaitingHasNoWindow() {
        let s = MockDisplayStateSource(scenario: .awaiting).state(at: Date())
        XCTAssertEqual(s.phase, .locked)
        XCTAssertNil(s.windowEnd)
    }
}

final class QuitPolicyTests: XCTestCase {
    func code(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

    func testOnlySessionEndingQuitsAreAllowed() {
        XCTAssertFalse(QuitPolicy.allowsQuit(quitReason: nil, powerOffPending: false), "osascript 'quit app' has no reason")
        XCTAssertFalse(QuitPolicy.allowsQuit(quitReason: code("abcd"), powerOffPending: false))
        for reason in ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"] {
            XCTAssertTrue(QuitPolicy.allowsQuit(quitReason: code(reason), powerOffPending: false), reason)
        }
        XCTAssertTrue(QuitPolicy.allowsQuit(quitReason: nil, powerOffPending: true), "after willPowerOff")
    }
}

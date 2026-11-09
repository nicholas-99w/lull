import Foundation
import LullCore
import SwiftUI

/// Observable view state for the agent's SwiftUI views.
///
/// The countdown advances between daemon updates using the continuous clock
/// (`mach_continuous_time`, which keeps counting through sleep), anchored to the
/// daemon's trusted time, so changing the wall clock can't change what's shown.
@MainActor
public final class AgentModel: ObservableObject {
    @Published public private(set) var state: DisplayState?
    @Published public private(set) var now: Date
    @Published public private(set) var images = BrandingImages()
    @Published public var overrideSheet: OverrideSheetState?
    @Published public var confirmingShutdown = false

    public let userFullName: String
    public let locale: Locale
    private let clock: ClockSource
    private var anchor: (trusted: Date, continuous: TimeInterval)
    private var imagesFor: Appearance?
    private let imageLoader: (Appearance) -> BrandingImages
    weak var source: DisplayStateSource?

    public init(
        userFullName: String = NSFullUserName(), locale: Locale = .current, clock: ClockSource = SystemClockSource(),
        imageLoader: @escaping (Appearance) -> BrandingImages = BrandingImageLoader.load
    ) {
        self.userFullName = userFullName
        self.locale = locale
        self.clock = clock
        self.imageLoader = imageLoader
        let epoch = Date(timeIntervalSince1970: 0)
        now = epoch
        anchor = (epoch, clock.continuousSeconds)
    }

    public func apply(_ newState: DisplayState) {
        anchor = (newState.trustedNow, clock.continuousSeconds)
        now = newState.trustedNow
        if imagesFor != newState.appearance {
            imagesFor = newState.appearance
            images = imageLoader(newState.appearance)
        }
        if newState.phase != .locked {
            overrideSheet = nil
            confirmingShutdown = false
        }
        state = newState
    }

    /// How long since the daemon last sent state (continuous clock).
    public var secondsSinceUpdate: TimeInterval { clock.continuousSeconds - anchor.continuous }

    /// Called every second to advance the countdown.
    public func tick() {
        now = anchor.trusted.addingTimeInterval(clock.continuousSeconds - anchor.continuous)
    }

    public func content(_ kind: CardPresenter.Kind) -> CardContent? {
        state.map { CardPresenter.content(for: $0, kind: kind, now: now, userFullName: userFullName, locale: locale) }
    }

    public var timeZone: TimeZone {
        state.flatMap { TimeZone(identifier: $0.timeZoneIdentifier) } ?? .current
    }

    // MARK: Actions

    public func snooze() { source?.requestSnooze() }

    public func shutdown() { source?.requestShutdown() }

    public func sleep() { source?.requestSleep() }

    public func showOverride() { overrideSheet = OverrideSheetState() }

    public func cancelOverride() { overrideSheet = nil }

    public func submitOverride(_ passphrase: String) {
        guard var sheet = overrideSheet, !sheet.busy, !passphrase.isEmpty else { return }
        sheet.busy = true
        sheet.message = nil
        overrideSheet = sheet
        source?.attemptOverride(passphrase: passphrase) { [weak self] result in
            self?.overrideFinished(result)
        }
    }

    func overrideFinished(_ result: OverrideResult) {
        guard overrideSheet != nil else { return }
        let fmt = DateFormatter()
        fmt.timeZone = timeZone
        fmt.locale = locale
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        var sheet = OverrideSheetState()
        switch result {
        case .granted:
            overrideSheet = nil
            return
        case .rejected(let remaining):
            sheet.message = UIStrings.overrideRejected(attemptsRemaining: remaining)
        case .lockedOut(let until):
            sheet.message = UIStrings.overrideLockedOut(until: fmt.string(from: until))
            sheet.lockedOut = true
        case .unavailable:
            sheet.message = UIStrings.overrideUnavailable
            sheet.lockedOut = true
        }
        sheet.isError = true
        overrideSheet = sheet
    }
}

public struct OverrideSheetState: Equatable {
    public var busy = false
    public var message: String?
    public var isError = false
    /// Input disabled (locked out or unavailable).
    public var lockedOut = false

    public init(busy: Bool = false, message: String? = nil, isError: Bool = false, lockedOut: Bool = false) {
        self.busy = busy
        self.message = message
        self.isError = isError
        self.lockedOut = lockedOut
    }
}

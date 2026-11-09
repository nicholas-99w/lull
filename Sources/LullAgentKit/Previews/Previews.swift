#if DEBUG
    import LullCore
    import SwiftUI

    /// Static state source for previews and snapshot tests.
    @MainActor
    final class PreviewSource: DisplayStateSource {
        var onUpdate: ((DisplayState) -> Void)?
        var presentingCheck: (() -> Bool)?
        func start() {}
        func refresh() {}
        func requestSnooze() {}
        func attemptOverride(passphrase: String, completion: @escaping (OverrideResult) -> Void) {}
        func requestShutdown() {}
        func requestSleep() {}
    }

    @MainActor
    public enum PreviewModels {
        public static func model(
            _ state: DisplayState, images: BrandingImages = BrandingImages(), sheet: OverrideSheetState? = nil,
            confirmingShutdown: Bool = false
        ) -> AgentModel {
            let m = AgentModel(userFullName: "Alex Citizen", locale: Locale(identifier: "en_AU"), imageLoader: { _ in images })
            m.apply(state)
            m.overrideSheet = sheet
            m.confirmingShutdown = confirmingShutdown
            return m
        }

        public static func branded(_ state: DisplayState, sheet: OverrideSheetState? = nil) -> AgentModel {
            model(state, images: Fixtures.brandedImages, sheet: sheet)
        }
    }

    // MARK: Lock screen

    struct LockScreen_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                LockScreenView(model: PreviewModels.model(Fixtures.lockedState(branded: false)), isPrimary: true)
                    .previewDisplayName("Lock: defaults, light")
                LockScreenView(model: PreviewModels.model(Fixtures.lockedState(branded: false)), isPrimary: true)
                    .preferredColorScheme(.dark)
                    .previewDisplayName("Lock: defaults, dark")
                LockScreenView(model: PreviewModels.branded(Fixtures.lockedState()), isPrimary: true)
                    .previewDisplayName("Lock: branded, light")
                LockScreenView(model: PreviewModels.branded(Fixtures.lockedState()), isPrimary: true)
                    .preferredColorScheme(.dark)
                    .previewDisplayName("Lock: branded, dark")
                LockScreenView(model: PreviewModels.branded(Fixtures.lockedState(texts: Fixtures.configuredTexts)), isPrimary: true)
                    .previewDisplayName("Lock: OrganizationName + SupportContact set")
                LockScreenView(model: PreviewModels.branded(Fixtures.lockedState(texts: Fixtures.configuredTexts)), isPrimary: true)
                    .previewDisplayName("Lock: OrganizationName + SupportContact set")
                LockScreenView(model: PreviewModels.model(Fixtures.awaitingSyncState), isPrimary: true)
                    .previewDisplayName("Lock: awaiting time sync (no window)")
                LockScreenView(model: PreviewModels.branded(Fixtures.lockedState()), isPrimary: false)
                    .previewDisplayName("Secondary display (backdrop only)")
                LockScreenView(model: solidModel, isPrimary: true)
                    .previewDisplayName("Lock: solid background, no progress")
            }
            .frame(width: 1280, height: 800)
        }

        static var solidModel: AgentModel {
            var s = Fixtures.lockedState()
            s.appearance.backgroundStyle = .solid
            s.appearance.backgroundOpacity = 1
            s.appearance.showProgress = false
            return PreviewModels.branded(s)
        }
    }

    struct OverrideSheet_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                LockScreenView(model: PreviewModels.branded(Fixtures.lockedState(), sheet: OverrideSheetState()), isPrimary: true)
                    .previewDisplayName("Override: entry")
                LockScreenView(
                    model: PreviewModels.branded(
                        Fixtures.lockedState(),
                        sheet: OverrideSheetState(message: UIStrings.overrideRejected(attemptsRemaining: 2), isError: true)),
                    isPrimary: true
                )
                .preferredColorScheme(.dark)
                .previewDisplayName("Override: wrong passphrase, dark")
                LockScreenView(
                    model: PreviewModels.branded(
                        Fixtures.lockedState(),
                        sheet: OverrideSheetState(message: UIStrings.overrideLockedOut(until: "10:15 pm"), isError: true, lockedOut: true)),
                    isPrimary: true
                )
                .previewDisplayName("Override: locked out")
                LockScreenView(
                    model: PreviewModels.model(Fixtures.lockedState(), images: Fixtures.brandedImages, confirmingShutdown: true),
                    isPrimary: true
                )
                .previewDisplayName("Shut down confirmation")
            }
            .frame(width: 1280, height: 800)
        }
    }

    // MARK: Warning

    struct WarningCard_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                WarningCardView(model: PreviewModels.model(Fixtures.warningState(secondsToLock: 600, branded: false, snooze: false)))
                    .previewDisplayName("Warning: 10 min, defaults")
                WarningCardView(model: PreviewModels.model(Fixtures.warningState(secondsToLock: 600, branded: false, snooze: false)))
                    .preferredColorScheme(.dark)
                    .previewDisplayName("Warning: 10 min, defaults, dark")
                WarningCardView(model: PreviewModels.branded(Fixtures.warningState(secondsToLock: 300)))
                    .previewDisplayName("Warning: branded with banner + snooze")
                WarningCardView(model: PreviewModels.branded(Fixtures.warningState(secondsToLock: 42)))
                    .preferredColorScheme(.dark)
                    .previewDisplayName("Warning: final countdown, dark")
            }
            .padding()
            .background(Color.gray.opacity(0.3))
        }
    }
#endif

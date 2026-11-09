import LullCore
import SwiftUI

/// Root view of each overlay window. The primary display gets the card and the
/// controls; other displays get the backdrop only.
public struct LockScreenView: View {
    @ObservedObject var model: AgentModel
    let isPrimary: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AgentModel, isPrimary: Bool) {
        self.model = model
        self.isPrimary = isPrimary
    }

    public var body: some View {
        let appearance = model.state?.appearance ?? Appearance()
        ZStack {
            BackdropView(appearance: appearance, image: model.images.background)
            if isPrimary, let state = model.state, let content = model.content(.lock) {
                GeometryReader { geo in
                    // Never wider than the screen allows; on short screens fall back
                    // to the compact card rather than scrolling or clipping.
                    let width = min(appearance.cardWidth, geo.size.width - 48)
                    ViewThatFits(in: .vertical) {
                        CardView(content: content, appearance: appearance, images: model.images, width: width)
                        CardView(
                            content: content, appearance: appearance, images: model.images, width: width,
                            bannerHeight: min(appearance.bannerHeight, 96), compact: true)
                        CardView(
                            content: content, appearance: appearance, images: model.images, width: width, showBanner: false, compact: true)
                    }
                    // Keep clear of the bottom-corner controls.
                    .padding(.vertical, 72)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                }
                controls(state: state, content: content)
                if let sheet = model.overrideSheet {
                    OverrideSheetView(model: model, sheet: sheet, appearance: appearance)
                        .transition(.opacity)
                } else if model.confirmingShutdown {
                    ShutdownConfirmView(model: model, label: content.shutdownLabel, appearance: appearance)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.overrideSheet != nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.confirmingShutdown)
    }

    /// Quiet bottom-corner controls: admin override link and Shut Down.
    @ViewBuilder
    private func controls(state: DisplayState, content: CardContent) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                Spacer()
                if state.overrideAvailable && state.phase == .locked {
                    Button {
                        model.showOverride()
                    } label: {
                        Text(content.overrideLabel).underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                }
                if state.shutdownAvailable {
                    Button(content.shutdownLabel) { model.confirmingShutdown = true }
                        .controlSize(.large)
                }
            }
            .padding(24)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Inline confirmation (a real dialog would be a separate sheet window, which
/// is unreliable on a shielding-level borderless window).
struct ShutdownConfirmView: View {
    @ObservedObject var model: AgentModel
    let label: String
    let appearance: Appearance
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { model.confirmingShutdown = false }
            VStack(alignment: .leading, spacing: 14) {
                Text(UIStrings.shutdownConfirmTitle)
                    .font(appearance.font(size: appearance.bodyFontSize * 1.3, weight: .semibold))
                    .foregroundStyle(appearance.titleColor.color(for: scheme))
                    .accessibilityAddTraits(.isHeader)
                Text(UIStrings.shutdownConfirmMessage)
                    .font(appearance.font(size: appearance.bodyFontSize, weight: .medium))
                    .foregroundStyle(appearance.bodyColor.color(for: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(UIStrings.shutdownSleepAlternative)
                    .font(appearance.font(size: appearance.bodyFontSize * 0.93))
                    .foregroundStyle(appearance.bodyColor.color(for: scheme).opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(UIStrings.cancel) { model.confirmingShutdown = false }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    // Sleep is the safe choice, so it's the default (Return).
                    Button(UIStrings.sleep) {
                        model.confirmingShutdown = false
                        model.sleep()
                    }
                    .keyboardShortcut(.defaultAction)
                    Button(label, role: .destructive) {
                        model.confirmingShutdown = false
                        model.shutdown()
                    }
                }
            }
            .padding(24)
            .frame(width: 440)
            .background(appearance.cardBackgroundColor.color(for: scheme))
            .clipShape(RoundedRectangle(cornerRadius: min(appearance.cardCornerRadius, 14), style: .continuous))
            .compositingGroup()
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        }
    }
}

import LullCore
import SwiftUI

/// Floating, non-blocking warning card. Hosted in a non-activating panel.
public struct WarningCardView: View {
    @ObservedObject var model: AgentModel
    @Environment(\.colorScheme) private var scheme

    public init(model: AgentModel) { self.model = model }

    public static let maxWidth: Double = 420

    public var body: some View {
        if let state = model.state, let content = model.content(.warning) {
            let a = state.appearance
            CardView(
                content: content, appearance: a, images: model.images, width: min(a.cardWidth, Self.maxWidth),
                showBanner: a.showBannerInWarning, bannerHeight: min(a.bannerHeight, 96), compact: true, showFooter: false
            ) {
                if state.snoozeAvailable {
                    HStack {
                        Spacer()
                        Button(content.snoozeLabel) { model.snooze() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(a.accentColor.color(for: scheme))
                    }
                }
            }
            // Room for the shadow inside the panel.
            .padding(24)
        }
    }
}

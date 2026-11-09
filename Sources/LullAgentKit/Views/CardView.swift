import LullCore
import SwiftUI

/// The rounded card shared by the lock screen and the warning: full-width
/// banner, optional logo, title, message, status area (countdown, progress,
/// unlock label) and footer. Modelled on the general layout of Jamf Setup
/// Manager's window without using any Jamf assets.
public struct CardView<Accessory: View>: View {
    let content: CardContent
    let appearance: Appearance
    let images: BrandingImages
    let width: Double
    let showBanner: Bool
    let bannerHeight: Double
    let compact: Bool
    /// Support/footer text. Always on for the lock screen: support text must
    /// stay visible even in the compact fallback ("never trap people").
    let showFooter: Bool
    let accessory: Accessory

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        content: CardContent, appearance: Appearance, images: BrandingImages, width: Double, showBanner: Bool = true,
        bannerHeight: Double? = nil, compact: Bool = false, showFooter: Bool = true, @ViewBuilder accessory: () -> Accessory
    ) {
        self.content = content
        self.appearance = appearance
        self.images = images
        self.width = width
        self.showBanner = showBanner
        self.bannerHeight = bannerHeight ?? appearance.bannerHeight
        self.compact = compact
        self.showFooter = showFooter
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showBanner, let banner = images.banner, bannerHeight > 0 {
                BannerView(image: banner, height: bannerHeight, mode: appearance.bannerContentMode)
            }
            VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                if let logo = images.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: compact ? 28 : 44, alignment: .leading)
                        .accessibilityHidden(true)
                }
                Text(content.title)
                    .font(appearance.font(size: compact ? appearance.titleFontSize * 0.7 : appearance.titleFontSize, weight: .semibold))
                    .foregroundStyle(appearance.titleColor.color(for: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !content.message.isEmpty {
                    Text(content.message)
                        .font(appearance.font(size: appearance.bodyFontSize))
                        .foregroundStyle(appearance.bodyColor.color(for: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                statusArea
                accessory
                footer
            }
            .padding(compact ? 20 : 28)
        }
        .frame(width: width, alignment: .leading)
        .background(appearance.cardBackgroundColor.color(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: appearance.cardCornerRadius, style: .continuous))
        // Flatten first, otherwise every child (e.g. the banner) casts its own shadow onto the card.
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: compact ? 16 : 30, y: compact ? 6 : 12)
    }

    @ViewBuilder private var statusArea: some View {
        if content.countdown != nil || content.progress != nil || content.unlockLabel != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let countdown = content.countdown {
                    Text(countdown)
                        .font(appearance.font(size: appearance.bodyFontSize * (compact ? 1.15 : 1.35), weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(appearance.countdownColor.color(for: scheme))
                        .accessibilityLabel(content.countdownAccessibility ?? countdown)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if let progress = content.progress {
                    ProgressBar(
                        fraction: progress, fill: appearance.accentColor.color(for: scheme),
                        track: appearance.progressTrackColor.color(for: scheme), animated: !reduceMotion)
                }
                if let unlock = content.unlockLabel {
                    Text(unlock)
                        .font(appearance.font(size: appearance.bodyFontSize * 0.93))
                        .foregroundStyle(appearance.bodyColor.color(for: scheme).opacity(0.85))
                }
            }
            .padding(.top, compact ? 0 : 4)
        }
    }

    @ViewBuilder private var footer: some View {
        if showFooter, content.support != nil || content.footer != nil {
            VStack(alignment: .leading, spacing: 4) {
                Divider().padding(.bottom, 6)
                if let support = content.support {
                    Text(support)
                }
                if let footer = content.footer {
                    Text(footer).opacity(0.8)
                }
            }
            .font(appearance.font(size: max(appearance.bodyFontSize * 0.8, 10)))
            .foregroundStyle(appearance.bodyColor.color(for: scheme).opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension CardView where Accessory == EmptyView {
    public init(
        content: CardContent, appearance: Appearance, images: BrandingImages, width: Double, showBanner: Bool = true,
        bannerHeight: Double? = nil, compact: Bool = false, showFooter: Bool = true
    ) {
        self.init(
            content: content, appearance: appearance, images: images, width: width, showBanner: showBanner,
            bannerHeight: bannerHeight, compact: compact, showFooter: showFooter
        ) { EmptyView() }
    }
}

struct BannerView: View {
    let image: NSImage
    let height: Double
    let mode: BannerContentMode

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: mode == .fill ? .fill : .fit)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .accessibilityHidden(true)
    }
}

/// Thin capsule progress bar; a custom view so colours follow the config exactly.
struct ProgressBar: View {
    let fraction: Double
    let fill: Color
    let track: Color
    let animated: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(geo.size.width * fraction, fraction > 0 ? 6 : 0))
            }
        }
        .frame(height: 6)
        .animation(animated ? .linear(duration: 0.9) : nil, value: fraction)
        .accessibilityElement()
        .accessibilityLabel(UIStrings.downtimeProgress)
        .accessibilityValue(UIStrings.percent(fraction))
    }
}

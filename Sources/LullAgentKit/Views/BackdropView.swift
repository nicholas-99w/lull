import AppKit
import LullCore
import SwiftUI

/// Full-screen backdrop behind the lock card: blurred desktop, solid
/// colour or admin image. With Reduce Transparency on, macOS renders the blur
/// as an opaque material, which is acceptable.
public struct BackdropView: View {
    let appearance: Appearance
    let image: NSImage?
    @Environment(\.colorScheme) private var scheme

    public init(appearance: Appearance, image: NSImage?) {
        self.appearance = appearance
        self.image = image
    }

    public var body: some View {
        let tint = appearance.backgroundColor.color(for: scheme)
        ZStack {
            switch appearance.backgroundStyle {
            case .blur:
                VisualEffectBlur()
                tint.opacity(appearance.backgroundOpacity * 0.6)
            case .solid:
                tint.opacity(appearance.backgroundOpacity)
            case .image:
                // Opaque base so a transparent image can't reveal the desktop.
                Color.black
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
                tint.opacity(appearance.backgroundOpacity * 0.4)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// `NSVisualEffectView` blurring what's behind the window (SwiftUI's materials
/// only blur within the window).
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

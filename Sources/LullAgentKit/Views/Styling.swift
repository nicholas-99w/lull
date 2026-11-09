import AppKit
import LullCore
import SwiftUI

extension HexColor {
    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

extension ThemedColor {
    /// The configured light or dark variant for the current appearance.
    public func color(for scheme: ColorScheme) -> Color { (scheme == .dark ? dark : light).color }
}

extension Appearance {
    /// Configured font if it's installed, otherwise the system font. Never fails:
    /// a typo in `FontName` must not break the lock screen.
    public func font(size: Double, weight: Font.Weight = .regular) -> Font {
        if let name = fontName, NSFont(name: name, size: size) != nil {
            return Font.custom(name, size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight)
    }
}

/// Decoded branding images for the current appearance.
public struct BrandingImages {
    public var banner: NSImage?
    public var logo: NSImage?
    public var background: NSImage?

    public init(banner: NSImage? = nil, logo: NSImage? = nil, background: NSImage? = nil) {
        self.banner = banner
        self.logo = logo
        self.background = background
    }
}

/// Loads admin-deployed images defensively: missing, oversized or corrupt files
/// give nil and the card simply omits the image ("fail gracefully").
public enum BrandingImageLoader {
    /// Largest decoded dimension; bigger images are rejected rather than
    /// risking memory pressure on the lock screen.
    public static let maxPixelDimension = 8192

    public static func load(_ path: String?, maxBytes: Int = LullConstants.maxBrandingImageBytes) -> NSImage? {
        guard let path, let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            attrs[.type] as? FileAttributeType == .typeRegular,
            let size = attrs[.size] as? Int, size > 0, size <= maxBytes,
            let data = FileManager.default.contents(atPath: path),
            let rep = NSBitmapImageRep(data: data),
            rep.pixelsWide > 0, rep.pixelsHigh > 0,
            rep.pixelsWide <= maxPixelDimension, rep.pixelsHigh <= maxPixelDimension
        else { return nil }
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    public static func load(_ appearance: Appearance) -> BrandingImages {
        BrandingImages(
            banner: load(appearance.bannerImagePath), logo: load(appearance.logoImagePath),
            background: appearance.backgroundStyle == .image ? load(appearance.backgroundImagePath) : nil)
    }
}

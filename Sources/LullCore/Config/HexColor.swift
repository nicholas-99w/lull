import Foundation

/// An sRGB colour parsed from `#RGB`, `#RRGGBB` or `#RRGGBBAA` (leading `#` optional).
/// Kept as plain numbers so `LullCore` has no AppKit/SwiftUI dependency.
public struct HexColor: Codable, Sendable, Hashable, CustomStringConvertible {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        self.red = clamp(red)
        self.green = clamp(green)
        self.blue = clamp(blue)
        self.alpha = clamp(alpha)
    }

    public init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy(\.isHexDigit), s.allSatisfy(\.isASCII) else { return nil }
        let expanded: String
        switch s.count {
        case 3: expanded = s.map { "\($0)\($0)" }.joined() + "FF"
        case 6: expanded = s + "FF"
        case 8: expanded = s
        default: return nil
        }
        guard let value = UInt32(expanded, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            alpha: Double(value & 0xFF) / 255
        )
    }

    public var description: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
    }
}

/// A colour with an optional dark-appearance variant (`*Dark` keys).
public struct ThemedColor: Codable, Sendable, Hashable {
    public var light: HexColor
    public var dark: HexColor

    public init(light: HexColor, dark: HexColor? = nil) {
        self.light = light
        self.dark = dark ?? light
    }

    public init(_ light: String, dark: String? = nil) {
        // Only used for compile-time defaults, which are known-good.
        self.init(light: HexColor(string: light)!, dark: dark.flatMap { HexColor(string: $0) })
    }
}

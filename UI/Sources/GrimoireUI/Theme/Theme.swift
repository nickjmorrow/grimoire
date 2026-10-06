import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
public typealias PlatformFont = NSFont
#elseif canImport(UIKit)
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
public typealias PlatformFont = UIFont
#endif

public struct Theme: Codable, Sendable, Equatable {
    public enum Appearance: String, Codable, Sendable { case dark, light }

    public var name: String
    public var appearance: Appearance
    public var colors: Colors
    public var fonts: Fonts
    public var spacing: Spacing
    public var radius: Double

    /// Every value is a hex string "#RGB", "#RRGGBB" or "#RRGGBBAA".
    public struct Colors: Codable, Sendable, Equatable {
        public var background, surface, surfaceRaised, text, textDim, textFaint, accent, link, tag, bullet,
                   selection, code, codeBackground, border, success, warning, danger: String
    }

    public struct Fonts: Codable, Sendable, Equatable {
        public var bodySize: Double
        public var titleSize: Double
        public var codeSize: Double
        public var lineHeightMultiple: Double
        public var family: String?      // nil = system
        public var codeFamily: String?  // nil = system monospaced
    }

    public struct Spacing: Codable, Sendable, Equatable {
        public var indent: Double
        public var blockGap: Double
        public var pagePadding: Double
    }

    public static let midnightSun: Theme = bundled("midnight-sun")
    public static let midnightSunLight: Theme = bundled("midnight-sun-light")

    private static func bundled(_ resource: String) -> Theme {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let theme = try? JSONDecoder().decode(Theme.self, from: data)
        else { fatalError("Bundled theme \(resource).json is missing or invalid") }
        return theme
    }
}

public enum HexColor {
    /// Parses "#RGB", "#RRGGBB" or "#RRGGBBAA" (leading # optional). Returns nil when invalid.
    public static func rgba(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 { digits = digits.flatMap { [$0, $0] }.map(String.init).joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return (Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255, alpha)
    }
}

extension Theme.Colors {
    /// Invalid hex falls back to magenta so a typo in a theme file is visible, not a crash.
    public func platformColor(_ keyPath: KeyPath<Theme.Colors, String>) -> PlatformColor {
        let c = HexColor.rgba(self[keyPath: keyPath]) ?? (1, 0, 1, 1)
        return PlatformColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    public func swiftUI(_ keyPath: KeyPath<Theme.Colors, String>) -> Color {
        let c = HexColor.rgba(self[keyPath: keyPath]) ?? (1, 0, 1, 1)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}

extension Theme {
    public func bodyFont() -> PlatformFont { font(family: fonts.family, size: fonts.bodySize, weight: .regular, mono: false) }
    public func titleFont() -> PlatformFont { font(family: fonts.family, size: fonts.titleSize, weight: .bold, mono: false) }
    public func codeFont() -> PlatformFont { font(family: fonts.codeFamily, size: fonts.codeSize, weight: .regular, mono: true) }

    private func font(family: String?, size: Double, weight: PlatformFont.Weight, mono: Bool) -> PlatformFont {
        if let family, let custom = PlatformFont(name: family, size: size) { return custom }
        return mono ? PlatformFont.monospacedSystemFont(ofSize: size, weight: weight)
                    : PlatformFont.systemFont(ofSize: size, weight: weight)
    }
}

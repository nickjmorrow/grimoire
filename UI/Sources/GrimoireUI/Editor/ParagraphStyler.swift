import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Applies the theme and live Markdown styling to one block paragraph. Only visual attributes are touched,
/// never the block identity attributes.
public enum ParagraphStyler {
    static let visualKeys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .strikethroughStyle, .underlineStyle, .underlineColor, .kern]

    public static func baseAttributes(theme: Theme) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = theme.fonts.lineHeightMultiple
        style.paragraphSpacing = theme.spacing.blockGap
        return [.font: theme.bodyFont(), .foregroundColor: theme.colors.platformColor(\.text), .paragraphStyle: style]
    }

    /// Restyles the paragraph occupying `range` (including its newline).
    public static func apply(to storage: NSMutableAttributedString, range: NSRange, theme: Theme) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let ns = storage.string as NSString
        var textRange = range
        if ns.character(at: NSMaxRange(range) - 1) == 0x0A { textRange.length -= 1 }
        let text = ns.substring(with: textRange)

        for k in visualKeys { storage.removeAttribute(k, range: range) }
        storage.addAttributes([.font: theme.bodyFont(), .foregroundColor: theme.colors.platformColor(\.text)], range: range)

        let spans = MarkdownStyler.spans(for: text)
        // Whole-paragraph traits first (headings, quotes, fenced code), then inline spans on top.
        var headingLevel = 0
        for s in spans { if case let .heading(n) = s.style { headingLevel = n } }
        if headingLevel > 0 {
            let scale: [CGFloat] = [1.0, 1.55, 1.35, 1.2, 1.1, 1.0, 1.0]
            storage.addAttribute(.font, value: font(theme, bold: true, italic: false, mono: false, scale: scale[min(headingLevel, 6)]), range: textRange)
        }
        for s in spans {
            let r = NSRange(location: textRange.location + s.range.location, length: s.range.length)
            guard r.length > 0, NSMaxRange(r) <= NSMaxRange(textRange) else { continue }
            style(s.style, in: r, storage: storage, theme: theme, headingScale: headingLevel > 0)
        }
    }

    static func font(_ theme: Theme, bold: Bool, italic: Bool, mono: Bool, scale: CGFloat = 1) -> PlatformFont {
        let base = mono ? theme.codeFont() : theme.bodyFont()
        let size = base.pointSize * scale
        #if canImport(AppKit)
        var f = NSFont(descriptor: base.fontDescriptor, size: size) ?? base
        let fm = NSFontManager.shared
        if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
        #else
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let d = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        return UIFont(descriptor: d, size: size)
        #endif
    }

    private static func currentFont(_ storage: NSAttributedString, at i: Int, _ theme: Theme) -> PlatformFont {
        (storage.attribute(.font, at: i, effectiveRange: nil) as? PlatformFont) ?? theme.bodyFont()
    }

    private static func style(_ s: Style, in r: NSRange, storage: NSMutableAttributedString, theme: Theme, headingScale: Bool) {
        let c = theme.colors
        func color(_ k: KeyPath<Theme.Colors, String>) { storage.addAttribute(.foregroundColor, value: c.platformColor(k), range: r) }
        func trait(bold: Bool = false, italic: Bool = false) {
            storage.enumerateAttribute(.font, in: r) { v, sub, _ in
                guard let f = v as? PlatformFont else { return }
                storage.addAttribute(.font, value: withTraits(f, bold: bold, italic: italic), range: sub)
            }
        }
        switch s {
        case .bold: trait(bold: true)
        case .italic: trait(italic: true)
        case .boldItalic: trait(bold: true, italic: true)
        case .strike: storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r); color(\.textDim)
        case .code, .codeBlock:
            storage.addAttribute(.font, value: font(theme, bold: false, italic: false, mono: true), range: r)
            color(\.code)
            storage.addAttribute(.backgroundColor, value: c.platformColor(\.codeBackground), range: r)
        case .heading: break
        case .link: color(\.link)
        case .tag: color(\.tag)
        case .blockRef: color(\.textDim)
        case .url, .markdownLink:
            color(\.link)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
        case .linkTarget, .marker: color(\.textFaint)
        case .image: color(\.textDim)
        case .propertyKey: color(\.textDim); trait(bold: true)
        case .propertyValue: break
        case .taskMarker(let state):
            // The checkbox in the gutter carries the state; the word itself becomes a small quiet badge.
            color(state == .done ? \.textFaint : \.textDim)
            storage.enumerateAttribute(.font, in: r) { v, sub, _ in
                if let f = v as? PlatformFont { storage.addAttribute(.font, value: withTraits(PlatformFont(descriptor: f.fontDescriptor, size: f.pointSize * 0.72) ?? f, bold: true, italic: false), range: sub) }
            }
            storage.addAttribute(.kern, value: 0.6, range: r)
            if state == .done {
                let ns = storage.string as NSString
                var end = NSMaxRange(r)
                var lineEnd = end
                while lineEnd < ns.length, ns.character(at: lineEnd) != 0x0A, ns.character(at: lineEnd) != 0x2028 { lineEnd += 1 }
                end = lineEnd
                let rest = NSRange(location: NSMaxRange(r), length: max(0, end - NSMaxRange(r)))
                if rest.length > 0 {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: rest)
                    storage.addAttribute(.foregroundColor, value: c.platformColor(\.textDim), range: rest)
                }
            }
        case .quote: color(\.textDim); trait(italic: true)
        }
    }

    private static func withTraits(_ f: PlatformFont, bold: Bool, italic: Bool) -> PlatformFont {
        #if canImport(AppKit)
        var out = f
        let fm = NSFontManager.shared
        if bold { out = fm.convert(out, toHaveTrait: .boldFontMask) }
        if italic { out = fm.convert(out, toHaveTrait: .italicFontMask) }
        return out
        #else
        var traits = f.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        return UIFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits) ?? f.fontDescriptor, size: f.pointSize)
        #endif
    }
}

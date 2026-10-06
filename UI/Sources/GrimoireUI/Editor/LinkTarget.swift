import Foundation

/// Something a click can follow from inside a block.
public enum LinkTarget: Equatable, Sendable {
    case page(String)
    case tag(String)
    case url(URL)
    case block(String)
}

public enum LinkResolver {
    /// The link, tag, URL or block reference under UTF-16 `offset` of a block's text, if any.
    public static func target(at offset: Int, in text: String) -> LinkTarget? {
        let ns = text as NSString
        let spans = MarkdownStyler.spans(for: text)
        func slice(_ r: NSRange) -> String { ns.substring(with: r) }
        func hit(_ r: NSRange, pad: Int = 0) -> Bool { offset >= r.location - pad && offset <= NSMaxRange(r) + pad }
        for s in spans {
            switch s.style {
            case .link where hit(s.range, pad: 2):
                return .page(slice(s.range))
            case .tag where hit(s.range):
                var t = slice(s.range)
                t.removeFirst()                                           // the leading #
                if t.hasPrefix("[["), t.hasSuffix("]]") { t = String(t.dropFirst(2).dropLast(2)) }
                return .tag(t)
            case .url where hit(s.range):
                if let u = URL(string: slice(s.range)) { return .url(u) }
            case .blockRef where hit(s.range):
                return .block(String(slice(s.range).dropFirst(2).dropLast(2)))
            case .markdownLink where hit(s.range):
                if let t = spans.first(where: { $0.style == .linkTarget && $0.range.location <= NSMaxRange(s.range) + 2 && $0.range.location >= NSMaxRange(s.range) }) {
                    let raw = slice(t.range).dropFirst().dropLast()
                    if let u = URL(string: String(raw)) { return .url(u) }
                }
            default: break
            }
        }
        return nil
    }
}

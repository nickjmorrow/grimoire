import Foundation

public enum TaskMarker: String, Sendable { case todo = "TODO", doing = "DOING", done = "DONE" }

public struct PropertyLine: Equatable, Sendable {
    public var key: String
    public var value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}

public struct ParsedBlock: Equatable, Sendable {
    public var pageLinks: [String] = []
    public var tags: [String] = []
    public var blockRefs: [String] = []
    public var properties: [PropertyLine] = []
    public var task: TaskMarker?
}

public enum BlockSyntax {
    enum TokenKind { case pageLink, tagBare, tagBracket, blockRef }
    struct Token { var kind: TokenKind; var start: Int; var end: Int; var name: String }

    private static let propertyKeyChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-.")
    private static let tagStopChars = Set(",.;:!?)(]}\"'`#")

    public static func parse(_ text: String) -> ParsedBlock {
        let (tokens, props) = scan(Array(text))
        var out = ParsedBlock()
        func add(_ list: inout [String], _ s: String) { if !list.contains(s) { list.append(s) } }
        for t in tokens {
            switch t.kind {
            case .pageLink: add(&out.pageLinks, t.name)
            case .tagBare, .tagBracket: add(&out.tags, t.name)
            case .blockRef: add(&out.blockRefs, t.name)
            }
        }
        out.properties = props
        for m in [TaskMarker.todo, .doing, .done] where text.hasPrefix(m.rawValue + " ") { out.task = m }
        return out
    }

    public static func replacingPageReferences(in text: String, from old: String, to new: String) -> String {
        let chars = Array(text)
        let (tokens, _) = scan(chars)
        let oldKey = old.lowercased()
        let simple = !new.contains(where: { $0.isWhitespace || tagStopChars.contains($0) })
        var out = chars
        for t in tokens.reversed() where t.kind != .blockRef && t.name.lowercased() == oldKey {
            let replacement: String
            switch t.kind {
            case .pageLink: replacement = "[[\(new)]]"
            case .tagBracket: replacement = "#[[\(new)]]"
            case .tagBare: replacement = simple ? "#\(new)" : "#[[\(new)]]"
            case .blockRef: continue
            }
            out.replaceSubrange(t.start..<t.end, with: Array(replacement))
        }
        return String(out)
    }

    static func scan(_ c: [Character]) -> ([Token], [PropertyLine]) {
        var tokens: [Token] = [], props: [PropertyLine] = []
        let n = c.count
        var i = 0, lineStart = true, inFence = false, inCode = false

        func hasPrefix(_ s: String, at j: Int) -> Bool {
            let p = Array(s); return j + p.count <= n && Array(c[j..<j + p.count]) == p
        }
        func find(_ s: String, from j: Int) -> Int? {
            var k = j; while k < n { if hasPrefix(s, at: k) { return k }; if c[k] == "\n" { return nil }; k += 1 }; return nil
        }
        func endOfLine(_ j: Int) -> Int { var k = j; while k < n && c[k] != "\n" { k += 1 }; return k }

        while i < n {
            if lineStart {
                var j = i; while j < n && (c[j] == " " || c[j] == "\t") { j += 1 }
                if hasPrefix("```", at: j) {
                    inFence.toggle(); inCode = false
                    i = min(n, endOfLine(j) + 1); continue
                }
                if inFence { i = min(n, endOfLine(i) + 1); continue }
                var k = j; while k < n && propertyKeyChars.contains(c[k]) { k += 1 }
                if k > j, hasPrefix("::", at: k), k + 2 == n || c[k + 2] == " " || c[k + 2] == "\n" {
                    let eol = endOfLine(k + 2)
                    let value = String(c[min(k + 2, eol)..<eol]).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { props.append(PropertyLine(key: String(c[j..<k]), value: value)) }
                    i = min(eol, k + 3); lineStart = false; continue
                }
            }
            let ch = c[i]
            if ch == "\n" { lineStart = true; inCode = false; i += 1; continue }
            lineStart = false
            if ch == "`" { inCode.toggle(); i += 1; continue }
            if inCode { i += 1; continue }
            if hasPrefix("[[", at: i), let e = find("]]", from: i + 2) {
                let inner = String(c[i + 2..<e]).trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty, !inner.contains("[[") {
                    tokens.append(Token(kind: .pageLink, start: i, end: e + 2, name: inner)); i = e + 2; continue
                }
            }
            if hasPrefix("((", at: i), let e = find("))", from: i + 2) {
                let inner = String(c[i + 2..<e])
                if UUID(uuidString: inner) != nil {
                    tokens.append(Token(kind: .blockRef, start: i, end: e + 2, name: inner.lowercased())); i = e + 2; continue
                }
            }
            if ch == "#", i == 0 || c[i - 1].isWhitespace {
                if hasPrefix("#[[", at: i), let e = find("]]", from: i + 3) {
                    let inner = String(c[i + 3..<e]).trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty {
                        tokens.append(Token(kind: .tagBracket, start: i, end: e + 2, name: inner)); i = e + 2; continue
                    }
                }
                var j = i + 1
                while j < n, !c[j].isWhitespace, !tagStopChars.contains(c[j]), c[j] != "[" { j += 1 }
                if j > i + 1 {
                    tokens.append(Token(kind: .tagBare, start: i, end: j, name: String(c[i + 1..<j]))); i = j; continue
                }
            }
            i += 1
        }
        return (tokens, props)
    }
}

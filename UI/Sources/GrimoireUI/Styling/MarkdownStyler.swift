import Foundation

public enum TaskState: String, Equatable, Sendable { case todo, doing, done }

public enum Style: Equatable, Sendable {
    case bold, italic, boldItalic, strike
    case code
    case codeBlock
    case heading(Int)
    case link
    case tag
    case blockRef
    case url
    case markdownLink
    case linkTarget
    case image
    case propertyKey
    case propertyValue
    case taskMarker(TaskState)
    case quote
    case marker
}

public struct StyleSpan: Equatable, Sendable {
    /// UTF-16 offsets into the input text.
    public var range: NSRange
    public var style: Style
    public init(range: NSRange, style: Style) {
        self.range = range
        self.style = style
    }
}

/// Turns one block's text into style spans for live syntax styling.
///
/// Layout of tokens (spans may overlap; output is sorted by location, longer first):
/// - `[[x]]`: `.marker` on `[[` and on `]]`; `.link` on the title `x` only.
/// - `#[[a b]]`: `.tag` on the whole token including `#`; `.marker` on `#[[` and on `]]`.
/// - `#tag`: `.tag` on the whole token including `#` (no marker).
/// - `((id))`: `.blockRef` on the whole token; `.marker` on `((` and `))`.
/// - `**x**`, `__x__`, `*x*`, `_x_`, `***x***`, `~~x~~`: `.marker` on each delimiter;
///   the style (`.bold`, `.italic`, `.boldItalic`, `.strike`) covers the inner text only.
/// - `` `x` ``: `.marker` on each backtick run, `.code` on the inner text; nothing else is styled inside.
/// - Fenced blocks: every line (fences included) is `.codeBlock`; `.marker` on the opening/closing backtick run.
/// - `# Heading`: `.marker` on the `#`s, `.heading(n)` on the text after them.
/// - `> quote`: `.quote` on the whole line, `.marker` on `>`.
/// - `key:: value`: `.propertyKey` on `key::`, `.propertyValue` on the value (leading spaces excluded).
/// - `TODO `/`DOING `/`DONE ` at the very start of the block: `.taskMarker` on the word only.
/// - `[label](url)`: `.markdownLink` on label, `.linkTarget` on `(url)`; `![alt](path)`: `.image` on the
///   whole token, `.linkTarget` on `(path)`.
/// Line breaks are "\n" and U+2028. Unclosed delimiters style nothing.
public enum MarkdownStyler {
    public static func spans(for text: String) -> [StyleSpan] {
        var scanner = Scanner(Array(text.utf16))
        scanner.run()
        return scanner.finish()
    }
}

private struct Scanner {
    let u: [UInt16]
    var out: [StyleSpan] = []

    init(_ units: [UInt16]) { u = units }

    // MARK: character helpers
    static let tagStops = Set(",.;:!?)(]}\"'`#".utf16)
    static func c(_ s: Character) -> UInt16 { s.utf16.first! }
    static let bt = c("`"), star = c("*"), under = c("_"), tilde = c("~"), hash = c("#"), lbr = c("["), rbr = c("]")
    static let lpar = c("("), rpar = c(")"), space = c(" "), bang = c("!"), colon = c(":"), gt = c(">")

    static func isBreak(_ x: UInt16) -> Bool { x == 0x0A || x == 0x2028 }
    static func isWS(_ x: UInt16) -> Bool {
        if x < 0x80 { return x == 0x20 || (x >= 0x09 && x <= 0x0D) }
        if x >= 0xD800 && x <= 0xDFFF { return false }
        return Unicode.Scalar(x)?.properties.isWhitespace ?? false
    }
    static func isAlnum(_ x: UInt16) -> Bool {
        if x < 0x80 { return (x >= 0x30 && x <= 0x39) || (x >= 0x41 && x <= 0x5A) || (x >= 0x61 && x <= 0x7A) }
        if x >= 0xD800 && x <= 0xDFFF { return false }
        guard let s = Unicode.Scalar(x) else { return false }
        return s.properties.isAlphabetic || s.properties.numericType != nil
    }
    static func isKeyChar(_ x: UInt16) -> Bool { isAlnum(x) && x < 0x80 || x == 0x5F || x == 0x2D || x == 0x2E }

    mutating func add(_ from: Int, _ to: Int, _ style: Style) {
        guard to > from else { return }
        out.append(StyleSpan(range: NSRange(location: from, length: to - from), style: style))
    }

    func has(_ s: String, at i: Int, before e: Int) -> Bool {
        let w = Array(s.utf16)
        guard i + w.count <= e else { return false }
        for k in 0..<w.count where u[i + k] != w[k] { return false }
        return true
    }

    func find(_ ch: UInt16, from: Int, to e: Int) -> Int? {
        var k = from
        while k < e { if u[k] == ch { return k }; k += 1 }
        return nil
    }

    func findPair(_ a: UInt16, _ b: UInt16, from: Int, to e: Int) -> Int? {
        var k = from
        while k + 1 < e { if u[k] == a && u[k + 1] == b { return k }; k += 1 }
        return nil
    }

    func run(of ch: UInt16, at i: Int, to e: Int) -> Int {
        var k = i
        while k < e && u[k] == ch { k += 1 }
        return k - i
    }

    // MARK: lines
    mutating func run() {
        var inFence = false
        var ls = 0
        let n = u.count
        while ls <= n {
            var le = ls
            while le < n && !Scanner.isBreak(u[le]) { le += 1 }
            line(ls, le, &inFence)
            ls = le + 1
        }
    }

    mutating func line(_ ls: Int, _ le: Int, _ inFence: inout Bool) {
        if le == ls { return }
        var fs = ls
        while fs < le && (u[fs] == Scanner.space || u[fs] == 0x09) { fs += 1 }
        let isFence = has("```", at: fs, before: le)
        if inFence || isFence {
            add(ls, le, .codeBlock)
            if isFence {
                add(fs, fs + run(of: Scanner.bt, at: fs, to: le), .marker)
                inFence.toggle()
            }
            return
        }
        // property line
        var k = ls
        while k < le && Scanner.isKeyChar(u[k]) { k += 1 }
        if k > ls, k + 1 < le + 0, u[k] == Scanner.colon, u[k + 1] == Scanner.colon {
            add(ls, k + 2, .propertyKey)
            var vs = k + 2
            while vs < le && (u[vs] == Scanner.space || u[vs] == 0x09) { vs += 1 }
            add(vs, le, .propertyValue)
            inline(vs, le)
            return
        }
        var start = ls
        if ls == 0, let (word, state) = taskWord(le) {
            add(0, word, .taskMarker(state))
            start = word + 1
        } else {
            let h = run(of: Scanner.hash, at: ls, to: le)
            if (1...6).contains(h), ls + h < le, u[ls + h] == Scanner.space {
                add(ls, ls + h, .marker)
                var ts = ls + h
                while ts < le && u[ts] == Scanner.space { ts += 1 }
                add(ts, le, .heading(h))
                inline(ts, le)
                return
            }
            if u[ls] == Scanner.gt, ls + 1 < le, u[ls + 1] == Scanner.space {
                add(ls, le, .quote)
                add(ls, ls + 1, .marker)
                start = ls + 2
            }
        }
        inline(start, le)
    }

    func taskWord(_ le: Int) -> (Int, TaskState)? {
        for (w, s) in [("TODO", TaskState.todo), ("DOING", .doing), ("DONE", .done)] {
            let len = w.utf16.count
            if has(w, at: 0, before: le), len < le, u[len] == Scanner.space { return (len, s) }
        }
        return nil
    }

    // MARK: inline
    /// If a code span opens at `i`, returns (opening run length, start of closing run).
    func codeSpan(at i: Int, to e: Int) -> (Int, Int)? {
        let n = run(of: Scanner.bt, at: i, to: e)
        var k = i + n
        while k < e {
            if u[k] == Scanner.bt {
                let m = run(of: Scanner.bt, at: k, to: e)
                if m == n { return k > i + n ? (n, k) : nil }
                k += m
            } else { k += 1 }
        }
        return nil
    }

    /// Finds the closing delimiter for an emphasis opened at `i` with `len` delimiter characters.
    func closer(_ ch: UInt16, _ len: Int, opener i: Int, to e: Int) -> Int? {
        let isUnderscore = ch == Scanner.under
        var k = i + len
        guard k < e, !Scanner.isWS(u[k]) else { return nil }
        k += 1
        while k < e {
            let x = u[k]
            if x == Scanner.bt {
                if let (n, close) = codeSpan(at: k, to: e) { k = close + n; continue }
                k += run(of: Scanner.bt, at: k, to: e); continue
            }
            if x == ch {
                let m = run(of: ch, at: k, to: e)
                let ok = (len == 1) ? m == 1 : m >= len
                let cs = k + m - len
                if ok, cs > i + len, !Scanner.isWS(u[cs - 1]),
                   !(isUnderscore && cs + len < e && Scanner.isAlnum(u[cs + len])) {
                    return cs
                }
                k += m; continue
            }
            k += 1
        }
        return nil
    }

    mutating func emphasis(_ ch: UInt16, _ len: Int, _ style: Style, at i: Int, to e: Int) -> Int? {
        guard let cs = closer(ch, len, opener: i, to: e) else { return nil }
        add(i, i + len, .marker)
        add(cs, cs + len, .marker)
        add(i + len, cs, style)
        inline(i + len, cs)
        return cs + len
    }

    mutating func inline(_ s: Int, _ e: Int) {
        var i = s
        while i < e {
            let c = u[i]
            switch c {
            case Scanner.bt:
                if let (n, close) = codeSpan(at: i, to: e) {
                    add(i, i + n, .marker); add(i + n, close, .code); add(close, close + n, .marker)
                    i = close + n
                } else { i += run(of: Scanner.bt, at: i, to: e) }
            case Scanner.bang:
                if i + 1 < e, u[i + 1] == Scanner.lbr, let (_, _, pe) = mdLink(at: i + 1, to: e) {
                    add(i, pe, .image)
                    add(find(Scanner.lpar, from: i + 2, to: pe)!, pe, .linkTarget)
                    i = pe
                } else { i += 1 }
            case Scanner.lbr:
                if i + 1 < e, u[i + 1] == Scanner.lbr, let close = findPair(Scanner.rbr, Scanner.rbr, from: i + 3, to: e),
                   find(Scanner.lbr, from: i + 2, to: close) == nil {
                    add(i, i + 2, .marker); add(i + 2, close, .link); add(close, close + 2, .marker)
                    i = close + 2
                } else if let (ls, le, pe) = mdLink(at: i, to: e) {
                    add(ls, le, .markdownLink)
                    add(le + 1, pe, .linkTarget)
                    i = pe
                } else { i += 1 }
            case Scanner.hash:
                i = hashToken(at: i, to: e)
            case Scanner.lpar:
                if i + 1 < e, u[i + 1] == Scanner.lpar, let close = findPair(Scanner.rpar, Scanner.rpar, from: i + 3, to: e),
                   !(i + 2..<close).contains(where: { Scanner.isWS(u[$0]) || u[$0] == Scanner.lpar || u[$0] == Scanner.rpar }) {
                    add(i, close + 2, .blockRef); add(i, i + 2, .marker); add(close, close + 2, .marker)
                    i = close + 2
                } else { i += 1 }
            case 0x68: // h
                if (has("http://", at: i, before: e) || has("https://", at: i, before: e)),
                   i == s || !Scanner.isAlnum(u[i - 1]) {
                    var j = i
                    while j < e && !Scanner.isWS(u[j]) { j += 1 }
                    while j > i, "., ;:!?'\"".utf16.contains(u[j - 1]) { j -= 1 }
                    add(i, j, .url)
                    i = j
                } else { i += 1 }
            case Scanner.star, Scanner.under:
                if c == Scanner.under, i > 0, Scanner.isAlnum(u[i - 1]) { i += run(of: c, at: i, to: e); continue }
                let n = min(run(of: c, at: i, to: e), 3)
                let style: Style = n == 3 ? .boldItalic : (n == 2 ? .bold : .italic)
                if let next = emphasis(c, n, style, at: i, to: e) { i = next } else { i += run(of: c, at: i, to: e) }
            case Scanner.tilde:
                if run(of: c, at: i, to: e) >= 2, let next = emphasis(c, 2, .strike, at: i, to: e) { i = next }
                else { i += run(of: c, at: i, to: e) }
            default:
                i += 1
            }
        }
    }

    /// `[label](target)` starting at the `[`; returns (label start, label end, end of `(target)`).
    func mdLink(at i: Int, to e: Int) -> (Int, Int, Int)? {
        guard let close = find(Scanner.rbr, from: i + 1, to: e), close + 1 < e, u[close + 1] == Scanner.lpar,
              let pe = find(Scanner.rpar, from: close + 2, to: e) else { return nil }
        return (i + 1, close, pe + 1)
    }

    /// Handles `#` at `i`; returns the index to continue from.
    mutating func hashToken(at i: Int, to e: Int) -> Int {
        guard i == 0 || Scanner.isWS(u[i - 1]), i + 1 < e else { return i + 1 }
        if u[i + 1] == Scanner.lbr, i + 2 < e, u[i + 2] == Scanner.lbr,
           let close = findPair(Scanner.rbr, Scanner.rbr, from: i + 4, to: e) {
            add(i, close + 2, .tag); add(i, i + 3, .marker); add(close, close + 2, .marker)
            return close + 2
        }
        var j = i + 1
        while j < e, !Scanner.isWS(u[j]), !Scanner.tagStops.contains(u[j]), u[j] != Scanner.lbr { j += 1 }
        guard j > i + 1 else { return i + 1 }
        add(i, j, .tag)
        return j
    }

    func finish() -> [StyleSpan] {
        out.enumerated().sorted { a, b in
            let (x, y) = (a.element.range, b.element.range)
            if x.location != y.location { return x.location < y.location }
            if x.length != y.length { return x.length > y.length }
            return a.offset < b.offset
        }.map(\.element)
    }
}

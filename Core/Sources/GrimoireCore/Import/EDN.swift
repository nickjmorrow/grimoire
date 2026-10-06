import Foundation

public indirect enum EDNValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case keyword(String)        // keeps the leading colon, e.g. ":block/title"
    case symbol(String)
    case uuid(String)
    case vector([EDNValue])
    case list([EDNValue])
    case set([EDNValue])
    case map([(EDNValue, EDNValue)])
    case tagged(String, EDNValue)

    public static func == (a: EDNValue, b: EDNValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.double(x), .double(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.keyword(x), .keyword(y)): return x == y
        case let (.symbol(x), .symbol(y)): return x == y
        case let (.uuid(x), .uuid(y)): return x == y
        case let (.vector(x), .vector(y)): return x == y
        case let (.list(x), .list(y)): return x == y
        case let (.set(x), .set(y)): return x == y
        case let (.map(x), .map(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.tagged(t, x), .tagged(u, y)): return t == u && x == y
        default: return false
        }
    }
}

public struct EDNError: Error, Equatable {
    public let offset: Int
    public let message: String
}

/// A small EDN reader (enough for Logseq's datom exports), working on UTF-8 bytes for speed.
public enum EDN {
    public static func parse(_ text: String) throws -> EDNValue {
        var p = Parser(bytes: Array(text.utf8))
        let value = try p.value()
        try p.skip()
        guard p.i == p.b.count else { throw EDNError(offset: p.i, message: "unexpected trailing input") }
        return value
    }

    private struct Parser {
        let b: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { b = bytes }

        func fail(_ m: String) -> EDNError { EDNError(offset: i, message: m) }

        /// Skips whitespace, commas, comments and `#_` discarded forms.
        mutating func skip() throws {
            while i < b.count {
                let c = b[i]
                if c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D || c == 0x2C { i += 1 }
                else if c == 0x3B { while i < b.count && b[i] != 0x0A { i += 1 } }
                else if c == 0x23, i + 1 < b.count, b[i + 1] == 0x5F { i += 2; _ = try value() }
                else { return }
            }
        }

        mutating func value() throws -> EDNValue {
            try skip()
            guard i < b.count else { throw fail("unexpected end of input") }
            switch b[i] {
            case 0x5B: i += 1; return .vector(try items(close: 0x5D))
            case 0x28: i += 1; return .list(try items(close: 0x29))
            case 0x7B: i += 1; return try map()
            case 0x22: return .string(try string())
            case 0x23: return try dispatch()
            case 0x5D, 0x29, 0x7D: throw fail("unexpected closing delimiter")
            default: return try token()
            }
        }

        mutating func items(close: UInt8) throws -> [EDNValue] {
            var out: [EDNValue] = []
            while true {
                try skip()
                guard i < b.count else { throw fail("unterminated collection") }
                if b[i] == close { i += 1; return out }
                out.append(try value())
            }
        }

        mutating func map() throws -> EDNValue {
            var out: [(EDNValue, EDNValue)] = []
            while true {
                try skip()
                guard i < b.count else { throw fail("unterminated map") }
                if b[i] == 0x7D { i += 1; return .map(out) }
                let k = try value()
                try skip()
                guard i < b.count, b[i] != 0x7D else { throw fail("map key without a value") }
                out.append((k, try value()))
            }
        }

        mutating func dispatch() throws -> EDNValue {
            guard i + 1 < b.count else { throw fail("dangling #") }
            if b[i + 1] == 0x7B { i += 2; return .set(try items(close: 0x7D)) }
            i += 1
            let tag = String(decoding: tokenBytes(), as: UTF8.self)
            let v = try value()
            if tag == "uuid", case let .string(s) = v { return .uuid(s) }
            return .tagged(tag, v)
        }

        mutating func tokenBytes() -> ArraySlice<UInt8> {
            let start = i
            while i < b.count, !Self.isDelimiter(b[i]) { i += 1 }
            return b[start..<i]
        }

        static func isDelimiter(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D || c == 0x2C || c == 0x3B
                || c == 0x28 || c == 0x29 || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x22
        }

        mutating func token() throws -> EDNValue {
            let bytes = tokenBytes()
            guard !bytes.isEmpty else { throw fail("unexpected character") }
            let t = String(decoding: bytes, as: UTF8.self)
            switch t {
            case "nil": return .null
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: break
            }
            if bytes.first == 0x3A { return .keyword(t) }
            let first = bytes.first!
            if (first >= 0x30 && first <= 0x39) || ((first == 0x2D || first == 0x2B) && bytes.count > 1 && bytes[bytes.startIndex + 1] >= 0x30 && bytes[bytes.startIndex + 1] <= 0x39) {
                if let n = Int64(t) { return .int(n) }
                if let d = Double(t) { return .double(d) }
            }
            return .symbol(t)
        }

        mutating func string() throws -> String {
            i += 1
            var buf: [UInt8] = []
            while true {
                guard i < b.count else { throw fail("unterminated string") }
                let c = b[i]
                if c == 0x22 { i += 1; return String(decoding: buf, as: UTF8.self) }
                if c != 0x5C { buf.append(c); i += 1; continue }
                i += 1
                guard i < b.count else { throw fail("unterminated escape") }
                switch b[i] {
                case 0x6E: buf.append(0x0A)
                case 0x74: buf.append(0x09)
                case 0x72: buf.append(0x0D)
                case 0x5C: buf.append(0x5C)
                case 0x22: buf.append(0x22)
                case 0x75:
                    guard i + 4 < b.count, let code = UInt32(String(decoding: b[i + 1...i + 4], as: UTF8.self), radix: 16),
                          let scalar = Unicode.Scalar(code) else { throw fail("bad \\u escape") }
                    buf.append(contentsOf: Array(String(Character(scalar)).utf8))
                    i += 4
                default: throw fail("unknown escape")
                }
                i += 1
            }
        }
    }
}

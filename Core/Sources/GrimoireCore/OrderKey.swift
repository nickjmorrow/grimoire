import Foundation

/// Fractional index keys for sibling order. Keys compare in plain byte order,
/// use the digits 0-9A-Za-z, and never end in the zero digit.
public enum OrderKey {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let base = 62
    private static let appendWidth = 3

    private static func index(_ c: Character) -> Int { digits.firstIndex(of: c) ?? 0 }

    /// A key strictly between `a` and `b`. `nil` means the open end on that side.
    public static func between(_ a: String?, _ b: String?) -> String {
        if let a, b == nil, !a.isEmpty { return append(after: a) }
        return midpoint(Array(a ?? ""), b.map { Array($0) })
    }

    private static func midpoint(_ a: [Character], _ b: [Character]?) -> String {
        if let b {
            var n = 0
            while n < b.count && (n < a.count ? a[n] : "0") == b[n] { n += 1 }
            if n > 0 {
                return String(b[0..<n]) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let da = a.first.map(index) ?? 0
        let db = b?.first.map(index) ?? base
        if db - da > 1 { return String(digits[(da + db) / 2]) }
        if let b, b.count > 1 { return String(b[0]) }
        return String(digits[da]) + midpoint(Array(a.dropFirst()), nil)
    }

    /// Appending uses a fixed-width counter so repeated appends stay short.
    private static func append(after a: String) -> String {
        var d = a.map(index)
        while d.count < appendWidth { d.append(base / 2) }
        repeat {
            var i = d.count - 1
            while true {
                d[i] += 1
                if d[i] < base { break }
                d[i] = 0
                i -= 1
                if i < 0 { return a + String(digits[base / 2]) }
            }
        } while d.last == 0
        return String(d.map { digits[$0] })
    }
}

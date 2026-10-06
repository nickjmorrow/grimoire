import Testing
@testable import GrimoireCore

@Suite struct OrderKeyTests {
    @Test func firstKeyIsMiddle() {
        #expect(OrderKey.between(nil, nil) == "V")
    }

    @Test func afterAndBefore() {
        #expect(OrderKey.between("V", nil) > "V")
        #expect(OrderKey.between(nil, "V") < "V")
    }

    @Test func betweenIsStrictlyBetween() {
        var seed: UInt64 = 42
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        var keys: [String] = []
        for _ in 0..<1000 {
            let i = keys.isEmpty ? 0 : next() % (keys.count + 1)
            let a = i > 0 ? keys[i - 1] : nil
            let b = i < keys.count ? keys[i] : nil
            let k = OrderKey.between(a, b)
            if let a { #expect(a < k) }
            if let b { #expect(k < b) }
            keys.insert(k, at: i)
        }
        #expect(keys == keys.sorted())
    }

    @Test func neverEndsWithZeroDigit() {
        var keys: [String] = []
        var seed: UInt64 = 7
        for _ in 0..<500 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let i = keys.isEmpty ? 0 : Int(seed >> 33) % (keys.count + 1)
            let k = OrderKey.between(i > 0 ? keys[i - 1] : nil, i < keys.count ? keys[i] : nil)
            #expect(!k.hasSuffix("0"))
            keys.insert(k, at: i)
        }
    }

    @Test func appendManyStaysShort() {
        var last: String? = nil
        for _ in 0..<1000 {
            let k = OrderKey.between(last, nil)
            if let last { #expect(last < k) }
            #expect(k.count <= 4)
            last = k
        }
    }
}

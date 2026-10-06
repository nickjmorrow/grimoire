import Foundation
import Testing
@testable import GrimoireCore

@Suite struct EDNTests {
    @Test func parsesScalars() throws {
        let v = try EDN.parse(#"[nil true false 42 -7 3.5 "a\"b\né café 🌙" :k/v sym]"#)
        #expect(v == .vector([.null, .bool(true), .bool(false), .int(42), .int(-7), .double(3.5),
                              .string("a\"b\né café 🌙"), .keyword(":k/v"), .symbol("sym")]))
    }

    @Test func parsesLargeIntegersAsInt64() throws {
        #expect(try EDN.parse("1790035125466") == .int(1_790_035_125_466))
    }

    @Test func parsesCollections() throws {
        let v = try EDN.parse("[1 [2] #{3} (4) {:a 1, :b [2]}]")
        #expect(v == .vector([.int(1), .vector([.int(2)]), .set([.int(3)]), .list([.int(4)]),
                              .map([(.keyword(":a"), .int(1)), (.keyword(":b"), .vector([.int(2)]))])]))
    }

    @Test func parsesUuidAndTagged() throws {
        #expect(try EDN.parse(#"#uuid "6ab1c4b7-a911-4026-9bf7-41aba29cee0c""#) == .uuid("6ab1c4b7-a911-4026-9bf7-41aba29cee0c"))
        #expect(try EDN.parse(#"#inst "2026-10-05""#) == .tagged("inst", .string("2026-10-05")))
    }

    @Test func skipsCommentsAndDiscard() throws {
        #expect(try EDN.parse("; a comment\n[1 #_2 3]") == .vector([.int(1), .int(3)]))
    }

    @Test func reportsErrorOffset() {
        #expect(throws: EDNError.self) { try EDN.parse("[1 2") }
        do { _ = try EDN.parse("[1 }") } catch let e as EDNError { #expect(e.offset == 3) } catch {}
    }

    @Test func rejectsTrailingGarbage() {
        #expect(throws: EDNError.self) { try EDN.parse("[1] 2") }
    }

#if !DEBUG
    @Test func parsesLargeInputFast() throws {
        let body = (0..<250_000).map { "[\($0) :block/title \"text \($0)\"]" }.joined(separator: " ")
        let text = "{:datoms [\(body)]}"
        let t = try ContinuousClock().measure { _ = try EDN.parse(text) }
        #expect(t < .seconds(2), "\(t)")
    }
#endif
}

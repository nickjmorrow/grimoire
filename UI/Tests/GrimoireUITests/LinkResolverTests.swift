import Foundation
import Testing
@testable import GrimoireUI

@Suite struct LinkResolverTests {
    @Test func pageLinksIncludingTheirBrackets() {
        let t = "met [[Rob Gersch]] today"
        #expect(LinkResolver.target(at: 8, in: t) == .page("Rob Gersch"))
        #expect(LinkResolver.target(at: 4, in: t) == .page("Rob Gersch"))        // on the opening brackets
        #expect(LinkResolver.target(at: 1, in: t) == nil)
        #expect(LinkResolver.target(at: 22, in: t) == nil)
    }

    @Test func tagsPlainAndBracketed() {
        #expect(LinkResolver.target(at: 3, in: "a #recipe b") == .tag("recipe"))
        #expect(LinkResolver.target(at: 8, in: "a #[[two words]] b") == .tag("two words"))
    }

    @Test func urlsAndMarkdownLinks() {
        #expect(LinkResolver.target(at: 8, in: "see https://example.com/x ok") == .url(URL(string: "https://example.com/x")!))
        #expect(LinkResolver.target(at: 2, in: "[docs](https://a.dev/b)") == .url(URL(string: "https://a.dev/b")!))
    }

    @Test func blockReferences() {
        #expect(LinkResolver.target(at: 6, in: "see ((6721b0c4-1111-4222-8333-944455556666))") == .block("6721b0c4-1111-4222-8333-944455556666"))
    }

    @Test func nothingInsideCode() {
        #expect(LinkResolver.target(at: 4, in: "`[[x]]`") == nil)
    }

    @Test func emojiBeforeALinkKeepsOffsetsRight() {
        #expect(LinkResolver.target(at: 6, in: "🌙 a [[Moon]]") == .page("Moon"))
    }
}

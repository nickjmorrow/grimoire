import Foundation
import Testing
@testable import GrimoireCore

@Suite struct SuggestionTests {
    @Test func pageSuggestionsRankExactThenPrefixThenContains() throws {
        let g = try graphWithHome()
        for (i, t) in ["Cooking notes", "Focaccia", "Cook", "Slow cooker", "Unrelated"].enumerated() { try page(g, "p\(i)", t) }
        let r = try g.pages(matching: "cook", limit: 10).map(\.title)
        #expect(r == ["Cook", "Cooking notes", "Slow cooker"])
    }

    @Test func emptyQueryGivesRecentPagesAndPercentSignsAreLiteral() throws {
        let g = try graphWithHome()
        try page(g, "a", "100% done"); try page(g, "b", "Other")
        #expect(try g.pages(matching: "", limit: 5).count >= 2)
        #expect(try g.pages(matching: "%", limit: 5).map(\.title) == ["100% done"])
    }

    @Test func tagSuggestionsComeFromTheTagsTable() throws {
        let g = try graphWithHome()
        try g.add("b1", "a #recipe and #reading", key: "a")
        #expect(try g.tagNames(matching: "re", limit: 10).sorted() == ["reading", "recipe"])
        #expect(try g.tagNames(matching: "rec", limit: 10) == ["recipe"])
    }
}

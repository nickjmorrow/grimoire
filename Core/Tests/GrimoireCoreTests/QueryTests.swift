import Foundation
import GRDB
import Testing
@testable import GrimoireCore

func page(_ g: Graph, _ id: String, _ title: String) throws {
    try g.perform([.createPage(id: id, title: title, kind: .page, journalDate: nil)], author: .me)
}

@Suite struct QueryTests {
    @Test func treeIsOrderedAndNested() throws {
        let g = try graphWithHome()
        try g.add("b", "second", key: "b")
        try g.add("a", "first", key: "a")
        try g.add("a2", "child", parent: "a", key: "a")
        let tree = try g.tree(pageID: "home")
        #expect(tree.map(\.block.id) == ["a", "b"])
        #expect(tree[0].children.map(\.block.id) == ["a2"])
    }

    @Test func backlinksGroupedBySourcePage() throws {
        let g = try graphWithHome()
        try page(g, "foc", "Focaccia")
        try g.add("h1", "met [[Rob]]", key: "a")
        try g.add("h2", "again [[Rob]] and #Rob", key: "b")
        try g.add("f1", "[[Rob]] liked it", page: "foc")
        try g.add("self", "[[Rob]] on his own page", page: try g.page(titled: "Rob")!.id)
        let rob = try g.page(titled: "rob")!
        let refs = try g.backlinks(pageID: rob.id)
        #expect(refs.count == 2)
        #expect(Set(refs.map(\.page.id)) == ["home", "foc"])
        #expect(refs.first { $0.page.id == "home" }?.blocks.map(\.id) == ["h1", "h2"])
    }

    @Test func unlinkedReferencesExcludeLinked() throws {
        let g = try graphWithHome()
        try g.add("h1", "met [[Rob]]", key: "a")
        try g.add("h2", "met Rob today", key: "b")
        let rob = try g.page(titled: "Rob")!
        let refs = try g.unlinkedReferences(pageID: rob.id)
        #expect(refs.flatMap(\.blocks).map(\.id) == ["h2"])
    }

    @Test func searchPrefixAndTitleFirst() throws {
        let g = try graphWithHome()
        try page(g, "foc", "Focaccia")
        try g.add("h1", "my focaccia notes", key: "a")
        try g.add("h2", "unrelated", key: "b")
        let hits = try g.search("foca")
        #expect(hits.first?.pageID == "foc" && hits.first?.blockID == nil)
        #expect(hits.contains { $0.blockID == "h1" })
        #expect(!hits.contains { $0.blockID == "h2" })
        #expect(try g.search("my foca").map(\.blockID) == ["h1"])
        #expect(try g.search("\"quote( weird").isEmpty)   // FTS syntax characters never throw
    }

    @Test func recentAndFavoritesOrdered() throws {
        let g = try graphWithHome()
        try page(g, "p2", "Second")
        try g.add("h1", "x")
        try g.add("s1", "y", page: "p2")
        #expect(try g.recentPages().map(\.id) == ["p2", "home"])
        try g.perform([.setFavorite(pageID: "home", favorite: true, order: nil),
                       .setFavorite(pageID: "p2", favorite: true, order: nil)], author: .me)
        #expect(try g.favorites().map(\.id) == ["home", "p2"])
    }

    @Test func journalsPaginateByDate() throws {
        let g = try makeGraph()
        for d in ["2026-10-01", "2026-10-03", "2026-10-05"] {
            let id = try g.ensureJournal(JournalDate(iso: d)!, author: .me)
            try g.perform([.insertBlock(id: "b-\(d)", pageID: id, parentID: nil, orderKey: "V", text: "x")], author: .me)
        }
        #expect(try g.journals(before: nil, limit: 2).compactMap(\.journalDate) == ["2026-10-05", "2026-10-03"])
        #expect(try g.journals(before: JournalDate(iso: "2026-10-03"), limit: 5).compactMap(\.journalDate) == ["2026-10-01"])
    }

    @Test func taggedAndPropertyLookups() throws {
        let g = try graphWithHome()
        try g.add("r1", "Focaccia #recipe\nserves:: 8", key: "a")
        try g.add("r2", "Soup #recipe\nserves:: 4\nmood:: [[calm]]", key: "b")
        try g.add("r3", "no tags", key: "c")
        #expect(Set(try g.blocks(taggedWith: "Recipe").map(\.id)) == ["r1", "r2"])
        #expect(try g.blocks(withProperty: "serves", value: "8").map(\.id) == ["r1"])
        #expect(Set(try g.blocks(withProperty: "SERVES", value: nil).map(\.id)) == ["r1", "r2"])
        #expect(try g.blocks(withProperty: "mood", value: "calm").map(\.id) == ["r2"])
    }

    @Test func readOnlyQueryRejectsWrites() throws {
        let g = try graphWithHome()
        let rows = try g.readOnlyQuery("SELECT title, kind FROM pages")
        #expect(rows.count == 1 && rows[0]["title"] == "Home")
        #expect(throws: GraphError.readOnlyViolation) { try g.readOnlyQuery("DELETE FROM pages") }
        #expect(try g.count("SELECT COUNT(*) FROM pages") == 1)
    }

    @Test func pageTitledResolvesJournalAliases() throws {
        let g = try makeGraph()
        let today = JournalDate.today()
        let id = try g.ensureJournal(today, author: .me)
        #expect(try g.page(titled: "today")?.id == id)
        #expect(try g.page(titled: today.iso)?.id == id)
        #expect(try g.page(titled: "nope") == nil)
    }
}

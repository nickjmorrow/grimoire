import Foundation
import GRDB
import Testing
@testable import GrimoireCore

/// Creates page "Home" (id "home") and returns the graph.
func graphWithHome() throws -> Graph {
    let g = try makeGraph()
    try g.perform([.createPage(id: "home", title: "Home", kind: .page, journalDate: nil)], author: .me)
    return g
}

extension Graph {
    @discardableResult
    func add(_ id: String, _ text: String, page: String = "home", parent: String? = nil, key: String = "V") throws -> [Int64] {
        try perform([.insertBlock(id: id, pageID: page, parentID: parent, orderKey: key, text: text)], author: .me)
    }
    func count(_ sql: String, _ args: StatementArguments = []) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: sql, arguments: args) ?? 0 }
    }
    func text(_ id: String) throws -> String? { try db.read { try Block.fetchOne($0, key: id)?.text } }
}

@Suite struct BlockOpsTests {
    @Test func insertIndexesLinksTagsSearch() throws {
        let g = try graphWithHome()
        try g.add("b1", "Met [[Rob]] #person")
        #expect(try g.count("SELECT COUNT(*) FROM pages WHERE title_lower IN ('rob','person')") == 2)
        #expect(try g.count("SELECT COUNT(*) FROM tags WHERE name_lower = 'person'") == 1)
        #expect(try g.count("SELECT COUNT(*) FROM block_tags WHERE block_id = 'b1'") == 1)
        #expect(try g.count("SELECT COUNT(*) FROM links WHERE from_block = 'b1'") == 2)
        #expect(try g.count("SELECT COUNT(*) FROM search WHERE search MATCH 'met' AND owner_id = 'b1'") == 1)
    }

    @Test func editReplacesIndexRows() throws {
        let g = try graphWithHome()
        try g.add("b1", "Met [[Rob]] #person")
        try g.perform([.editText(blockID: "b1", text: "Met [[Ann]]")], author: .me)
        let ann = try g.db.read { try String.fetchOne($0, sql: "SELECT id FROM pages WHERE title_lower = 'ann'") }
        #expect(try g.count("SELECT COUNT(*) FROM links WHERE from_block = 'b1'") == 1)
        #expect(try g.count("SELECT COUNT(*) FROM links WHERE from_block = 'b1' AND to_page = ?", [ann]) == 1)
        #expect(try g.count("SELECT COUNT(*) FROM block_tags") == 0)
        #expect(try g.count("SELECT COUNT(*) FROM search WHERE search MATCH 'rob' AND owner_kind = 'block'") == 0)
    }

    @Test func linksResolveCaseInsensitivelyAcrossUnicode() throws {
        let g = try graphWithHome()
        try g.add("b1", "[[Café]]", key: "a")
        try g.add("b2", "[[café]]", key: "b")
        try g.add("b3", "[[CAFÉ]]", key: "c")
        try g.add("b4", "[[Cafe\u{301}]]", key: "d")   // decomposed é
        try g.add("b5", "#[[🌙 night]]", key: "e")
        #expect(try g.count("SELECT COUNT(*) FROM pages WHERE title_lower = ?", ["café".precomposedStringWithCanonicalMapping]) == 1)
        #expect(try g.count("SELECT COUNT(DISTINCT to_page) FROM links WHERE from_block IN ('b1','b2','b3','b4')") == 1)
        #expect(try g.count("SELECT COUNT(*) FROM tags WHERE name = '🌙 night'") == 1)
    }

    @Test func propertyTypesInferred() throws {
        let g = try graphWithHome()
        try g.add("b1", "Dish\nserves:: 8\nlink:: https://x.y\nmood:: [[calm]], [[tired]]\ndone:: true\nwhen:: 2026-10-05")
        func type(_ k: String) throws -> String? { try g.db.read { try String.fetchOne($0, sql: "SELECT type FROM properties WHERE key = ?", arguments: [k]) } }
        #expect(try type("serves") == "number")
        #expect(try type("link") == "url")
        #expect(try type("done") == "checkbox")
        #expect(try type("when") == "date")
        #expect(try type("mood") == "page")
        #expect(try g.db.read { try String.fetchOne($0, sql: "SELECT cardinality FROM properties WHERE key = 'mood'") } == "many")
        #expect(try g.count("SELECT COUNT(*) FROM block_props bp JOIN properties p ON p.id = bp.property_id WHERE p.key = 'mood' AND bp.owner_id = 'b1'") == 2)
        try g.add("b2", "serves:: lots", key: "W")
        #expect(try g.count("SELECT COUNT(*) FROM block_props WHERE owner_id = 'b2'") == 0)
        #expect(try g.text("b2") == "serves:: lots")
    }

    @Test func firstBlockPropertiesBecomePageProperties() throws {
        let g = try graphWithHome()
        try g.add("b1", "type:: recipe\nserves:: 4")
        #expect(try g.count("SELECT COUNT(*) FROM block_props WHERE owner_id = 'home' AND owner_kind = 'page'") == 2)
    }

    @Test func moveDetectsCycles() throws {
        let g = try graphWithHome()
        try g.add("a", "a")
        try g.add("b", "b", parent: "a")
        #expect(throws: GraphError.cycle) {
            try g.perform([.moveBlock(blockID: "a", pageID: "home", parentID: "b", orderKey: "V")], author: .me)
        }
        #expect(throws: GraphError.cycle) {
            try g.perform([.moveBlock(blockID: "a", pageID: "home", parentID: "a", orderKey: "V")], author: .me)
        }
    }

    @Test func moveAcrossPagesMovesSubtree() throws {
        let g = try graphWithHome()
        try g.perform([.createPage(id: "other", title: "Other", kind: .page, journalDate: nil)], author: .me)
        try g.add("a", "a"); try g.add("b", "b", parent: "a")
        try g.perform([.moveBlock(blockID: "a", pageID: "other", parentID: nil, orderKey: "V")], author: .me)
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE page_id = 'other'") == 2)
    }

    @Test func insertIntoMissingPageOrParentThrows() throws {
        let g = try graphWithHome()
        #expect(throws: GraphError.pageNotFound("nope")) { try g.add("x", "x", page: "nope") }
        #expect(throws: GraphError.blockNotFound("ghost")) { try g.add("x", "x", parent: "ghost") }
    }

    @Test func deleteRemovesSubtreeAndItsIndexRows() throws {
        let g = try graphWithHome()
        try g.add("p", "parent [[X]]", key: "a")
        try g.add("c1", "child one #t", parent: "p", key: "a")
        try g.add("c2", "child two", parent: "p", key: "b")
        try g.add("ref", "see ((c1))", key: "z")
        try g.perform([.deleteBlock(blockID: "p")], author: .me)
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE id IN ('p','c1','c2')") == 0)
        #expect(try g.count("SELECT COUNT(*) FROM links WHERE from_block IN ('p','c1','c2')") == 0)
        #expect(try g.count("SELECT COUNT(*) FROM block_tags WHERE block_id IN ('p','c1','c2')") == 0)
        #expect(try g.count("SELECT COUNT(*) FROM search WHERE owner_id IN ('p','c1','c2')") == 0)
        #expect(try g.text("ref") == "see ((c1))")
    }

    @Test func deleteInverseRestoresSubtreeWithIndexes() throws {
        let g = try graphWithHome()
        try g.add("p", "parent [[X]]", key: "a")
        try g.add("c1", "child #t", parent: "p", key: "a")
        let ids = try g.perform([.deleteBlock(blockID: "p")], author: .me)
        let inv = try g.db.read { try String.fetchOne($0, sql: "SELECT inverse FROM ops WHERE local_id = ?", arguments: [ids[0]])! }
        try g.perform([try JSONDecoder().decode(Op.self, from: Data(inv.utf8))], author: .me)
        #expect(try g.count("SELECT COUNT(*) FROM blocks") == 2)
        #expect(try g.count("SELECT COUNT(*) FROM links WHERE from_block IN ('p','c1')") == 2)
        #expect(try g.count("SELECT COUNT(*) FROM block_tags WHERE block_id = 'c1'") == 1)
    }

    @Test func journalLinkCreatesJournalPage() throws {
        let g = try graphWithHome()
        try g.add("b1", "due [[2026-10-05]]")
        let p = try g.db.read { try Page.fetchOne($0, key: "bd08754d-0f15-540c-9e70-8879385ec362") }
        #expect(p?.kind == .journal && p?.journalDate == "2026-10-05")
    }

    @Test func renameRewritesAllReferenceForms() throws {
        let g = try graphWithHome()
        try g.perform([.createPage(id: "old", title: "Old", kind: .page, journalDate: nil)], author: .me)
        try g.add("b1", "[[Old]] x", key: "a")
        try g.add("b2", "see #Old", key: "b")
        try g.add("b3", "see #[[old]]", key: "c")
        let ids = try g.perform([.renamePage(id: "old", title: "New Name")], author: .me)
        #expect(try g.text("b1") == "[[New Name]] x")
        #expect(try g.text("b2") == "see #[[New Name]]")
        #expect(try g.text("b3") == "see #[[New Name]]")
        #expect(try g.count("SELECT COUNT(*) FROM links WHERE to_page = 'old'") == 3)
        // The stored inverse restores the exact original texts.
        let inv = try g.db.read { try String.fetchOne($0, sql: "SELECT inverse FROM ops WHERE local_id = ?", arguments: [ids[0]])! }
        try g.perform([try JSONDecoder().decode(Op.self, from: Data(inv.utf8))], author: .me)
        #expect(try g.text("b1") == "[[Old]] x" && g.text("b2") == "see #Old" && g.text("b3") == "see #[[old]]")
    }

    @Test func reindexRebuildsIdentically() throws {
        let g = try graphWithHome()
        try g.add("b1", "Met [[Rob]] #person\nmood:: [[calm]]", key: "a")
        try g.add("b2", "child ((b1)) serves:: 3\nserves:: 3", parent: "b1", key: "a")
        try g.perform([.editText(blockID: "b2", text: "child [[Ann]]")], author: .me)
        func snapshot() throws -> [String] {
            try g.db.read { db in
                var rows: [String] = []
                for sql in ["SELECT from_block||'|'||IFNULL(to_page,'')||'|'||IFNULL(to_block,'')||'|'||kind FROM links",
                            "SELECT block_id||'|'||tag_id FROM block_tags",
                            "SELECT owner_id||'|'||owner_kind||'|'||property_id||'|'||value||'|'||position FROM block_props",
                            "SELECT owner_id||'|'||owner_kind||'|'||text FROM search"] {
                    rows += try String.fetchAll(db, sql: sql).sorted()
                    rows.append("--")
                }
                return rows
            }
        }
        let before = try snapshot()
        try g.reindex()
        #expect(try snapshot() == before)
    }
}

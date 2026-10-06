import Foundation
import GRDB
import Testing
@testable import GrimoireCore

@Suite struct HistoryTests {
    @Test func undoEditRestoresText() throws {
        let g = try graphWithHome()
        try g.add("b1", "zero")
        try g.perform([.editText(blockID: "b1", text: "one")], author: .me)
        #expect(try g.undo() == 1)
        #expect(try g.text("b1") == "zero")
    }

    @Test func undoDeleteRestoresSubtreeAndIndexes() throws {
        let g = try graphWithHome()
        try g.add("p", "parent [[X]]", key: "a")
        try g.add("c", "child #t", parent: "p", key: "a")
        try g.perform([.deleteBlock(blockID: "p")], author: .claude)
        #expect(try g.count("SELECT COUNT(*) FROM blocks") == 0)
        #expect(try g.undo(author: .claude) == 1)
        #expect(try g.count("SELECT COUNT(*) FROM blocks") == 2)
        #expect(try g.count("SELECT COUNT(*) FROM links WHERE from_block IN ('p','c')") == 2)
        #expect(try g.count("SELECT COUNT(*) FROM block_tags WHERE block_id = 'c'") == 1)
    }

    @Test func undoByAuthorSkipsOtherAuthors() throws {
        let g = try graphWithHome()
        try g.add("a", "A0", key: "a")
        try g.add("b", "B0", key: "b")
        try g.perform([.editText(blockID: "b", text: "B-claude")], author: .claude)
        try g.perform([.editText(blockID: "a", text: "A-me")], author: .me)
        #expect(try g.undo(author: .claude) == 1)
        #expect(try g.text("b") == "B0")
        #expect(try g.text("a") == "A-me")
    }

    @Test func undoTwiceUndoesTwoDistinctOps() throws {
        let g = try graphWithHome()
        try g.add("b1", "zero")
        try g.perform([.editText(blockID: "b1", text: "one")], author: .me)
        try g.perform([.editText(blockID: "b1", text: "two")], author: .me)
        try g.undo(); #expect(try g.text("b1") == "one")
        try g.undo(); #expect(try g.text("b1") == "zero")
        try g.undo(); #expect(try g.text("b1") == nil)   // undoing the insert deletes the block
    }

    @Test func undoNothingReturnsZero() throws {
        let g = try makeGraph()
        #expect(try g.undo() == 0)
    }

    @Test func changesSinceFiltersByAuthorAndTime() throws {
        let g = try graphWithHome()
        try g.add("a", "A")
        try g.perform([.editText(blockID: "a", text: "A2")], author: .claude)
        let all = try g.changes(since: 0)
        #expect(all.count == 3)
        let claude = try g.changes(since: 0, author: .claude)
        #expect(claude.count == 1)
        if case .editText(let id, let text) = claude[0].op { #expect(id == "a" && text == "A2") } else { Issue.record("wrong op") }
        let future = Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        #expect(try g.changes(since: future).isEmpty)
    }
}

import Foundation
import GRDB
import Testing
@testable import GrimoireCore

@Suite struct ReviewFixTests {
    // Critical: undo must never destroy later work or wedge the stack.
    @Test func undoRefusesWhenLaterWorkHangsOffTheBlock() throws {
        let g = try graphWithHome()
        try g.perform([.insertBlock(id: "a", pageID: "home", parentID: nil, orderKey: "V", text: "claude wrote this")], author: .claude)
        try g.perform([.insertBlock(id: "reply", pageID: "home", parentID: "a", orderKey: "V", text: "my reply")], author: .me)
        let r = try g.undoDetailed(author: .claude)
        #expect(r.undone == 0 && r.skipped.count == 1)
        #expect(try g.text("a") == "claude wrote this" && g.text("reply") == "my reply")
    }

    @Test func undoRefusesWhenBlockWasEditedSince() throws {
        let g = try graphWithHome()
        try g.perform([.insertBlock(id: "a", pageID: "home", parentID: nil, orderKey: "V", text: "draft")], author: .claude)
        try g.perform([.editText(blockID: "a", text: "my version")], author: .me)
        #expect(try g.undoDetailed(author: .claude).undone == 0)
        #expect(try g.text("a") == "my version")
    }

    @Test func undoRefusesToDeleteAPageThatNowHasContent() throws {
        let g = try makeGraph()
        try g.perform([.createPage(id: "draft", title: "Draft", kind: .page, journalDate: nil)], author: .claude)
        try g.perform([.insertBlock(id: "b", pageID: "draft", parentID: nil, orderKey: "V", text: "my notes")], author: .me)
        let r = try g.undoDetailed(author: .claude)
        #expect(r.undone == 0 && r.skipped.count == 1)
        #expect(try g.text("b") == "my notes")
    }

    @Test func undoDoesNotWedgeWhenATargetVanished() throws {
        let g = try graphWithHome()
        try g.add("b1", "mine", key: "a")
        try g.perform([.insertBlock(id: "b2", pageID: "home", parentID: nil, orderKey: "b", text: "claude's")], author: .claude)
        try g.perform([.editText(blockID: "b1", text: "claude edit")], author: .claude)
        try g.perform([.deleteBlock(blockID: "b1")], author: .me)
        let first = try g.undoDetailed(author: .claude, count: 2)
        #expect(first.undone == 1 && first.skipped.count == 1)       // the edit of the vanished block is skipped, b2's insert is undone
        #expect(try g.text("b2") == nil)
        #expect(try g.undoDetailed(author: .claude).undone == 0)      // and nothing is stuck
    }

    // Important: one command = one undo.
    @Test func batchedOpsUndoTogether() throws {
        let g = try makeGraph()
        try g.perform([.batch([
            .createPage(id: "plan", title: "Plan", kind: .page, journalDate: nil),
            .insertBlock(id: "a", pageID: "plan", parentID: nil, orderKey: "V", text: "a"),
            .insertBlock(id: "b", pageID: "plan", parentID: nil, orderKey: "W", text: "b"),
        ])], author: .claude)
        #expect(try g.undo(author: .claude) == 1)
        #expect(try g.count("SELECT COUNT(*) FROM pages") == 0 && g.count("SELECT COUNT(*) FROM blocks") == 0)
    }

    // Important: deletePage → undo with a grandchild stored before its parent.
    @Test func deletePageUndoWithGrandchildrenInAnyStorageOrder() throws {
        let g = try graphWithHome()
        try g.add("r", "root", key: "a")
        try g.add("m", "middle", parent: "r", key: "a")
        try g.add("g", "grandchild", parent: "m", key: "a")
        try g.perform([.deletePage(id: "home")], author: .me)
        #expect(try g.count("SELECT COUNT(*) FROM blocks") == 0)
        #expect(try g.undo(author: .me) == 1)
        #expect(try g.count("SELECT COUNT(*) FROM blocks") == 3)
    }

    // Important: deleting a page other blocks link to would silently un-tag them.
    @Test func deletePageRefusedWhileOtherBlocksLinkToIt() throws {
        let g = try graphWithHome()
        try g.add("b1", "met #rob")
        let rob = try g.page(titled: "rob")!
        #expect(throws: GraphError.pageInUse("rob")) { try g.perform([.deletePage(id: rob.id)], author: .me) }
        #expect(try g.count("SELECT COUNT(*) FROM block_tags") == 1)
    }

    @Test func deletePageOpsEmptyALinkedPageAndDeleteAnUnlinkedOne() throws {
        let g = try graphWithHome()
        try g.add("b1", "met #rob")
        let rob = try g.page(titled: "rob")!
        try g.add("r1", "about rob", page: rob.id)
        try g.add("r2", "child", page: rob.id, parent: "r1")
        try g.perform([.setFavorite(pageID: rob.id, favorite: true, order: nil)], author: .me)
        try g.perform([try g.deletePageOp(pageID: rob.id)], author: .me)
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE page_id = ?", [rob.id]) == 0)
        #expect(try g.page(titled: "rob")?.favorite == false)
        #expect(try g.count("SELECT COUNT(*) FROM block_tags") == 1)               // the tag on Home still works
        #expect(try g.undo(author: .me) == 1)                                         // one change, undone in one step
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE page_id = ?", [rob.id]) == 2)
        #expect(try g.page(titled: "rob")?.favorite == true)

        #expect(try g.deletePageOp(pageID: "home") == .deletePage(id: "home"))
        #expect(throws: GraphError.pageNotFound("nope")) { try g.deletePageOp(pageID: "nope") }
    }

    // Important: rewritten blocks' pages must show up as changed (mirror files, recents).
    @Test func renameTouchesPagesWhoseBlocksWereRewritten() throws {
        let g = try graphWithHome()
        try g.perform([.createPage(id: "old", title: "Old", kind: .page, journalDate: nil)], author: .me)
        try g.add("b1", "see [[Old]]")
        let before = try g.db.read { try Int64.fetchOne($0, sql: "SELECT updated_at FROM pages WHERE id = 'home'")! }
        Thread.sleep(forTimeInterval: 0.01)
        try g.perform([.renamePage(id: "old", title: "New")], author: .me)
        let after = try g.db.read { try Int64.fetchOne($0, sql: "SELECT updated_at FROM pages WHERE id = 'home'")! }
        #expect(after > before)
    }

    // Important: explicit and implicit pages share one deterministic id.
    @Test func implicitAndExplicitPageIDsAgree() throws {
        let g = try graphWithHome()
        try g.add("b1", "met [[Rob]]")
        #expect(try g.page(titled: "rob")?.id == Graph.pageID(forTitle: "Rob"))
        #expect(Graph.pageID(forTitle: "ROB") == Graph.pageID(forTitle: "rob"))
    }
}

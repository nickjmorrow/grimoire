import Foundation
import GrimoireCore
import Testing
@testable import GrimoireUI

private func row(_ id: String?, _ depth: Int, _ text: String, collapsed: Bool = false) -> OutlineRow {
    OutlineRow(blockID: id, depth: depth, text: text, collapsed: collapsed)
}
private func ids() -> () -> String { var n = 0; return { n += 1; return "new\(n)" } }

@Suite struct OutlineDocTests {
    @Test func normalizationClampsDepthAndFixesIDs() {
        let doc = OutlineDoc(rows: [row("a", 2, "a"), row("b", 5, "b"), row("a", 1, "dup"), row(nil, 0, "fresh")])
        let n = doc.normalized(newID: ids())
        #expect(n.rows.map(\.depth) == [0, 1, 1, 0])
        #expect(n.rows.map(\.blockID) == ["a", "b", "new1", "new2"])
    }

    @Test func parentAndSubtreeRanges() {
        let doc = OutlineDoc(rows: [row("a", 0, ""), row("b", 1, ""), row("c", 2, ""), row("d", 1, ""), row("e", 0, "")])
        #expect(doc.parentIndex(of: 2) == 1 && doc.parentIndex(of: 3) == 0 && doc.parentIndex(of: 0) == nil)
        #expect(doc.subtreeRange(of: 0) == 0..<4 && doc.subtreeRange(of: 1) == 1..<3 && doc.subtreeRange(of: 4) == 4..<5)
    }

    @Test func flattensATree() throws {
        let g = try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("ui-\(UUID().uuidString)"), device: "t")
        try g.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil),
                       .insertBlock(id: "a", pageID: "p", parentID: nil, orderKey: "a", text: "A"),
                       .insertBlock(id: "b", pageID: "p", parentID: "a", orderKey: "a", text: "B"),
                       .insertBlock(id: "c", pageID: "p", parentID: nil, orderKey: "b", text: "C")], author: .me)
        let tree = try g.tree(pageID: "p")
        let doc = OutlineDoc(tree: tree)
        #expect(doc.rows.map(\.blockID) == ["a", "b", "c"] && doc.rows.map(\.depth) == [0, 1, 0])
        #expect(OutlineDoc.keys(tree: tree) == ["a": "a", "b": "a", "c": "b"])
    }
}

@Suite struct OutlineSyncTests {
    let keys = ["a": "a", "b": "b", "c": "c", "d": "d"]
    func sync(_ old: [OutlineRow], _ new: [OutlineRow], keys: [String: String]? = nil) -> [Op] {
        OutlineSync.ops(old: OutlineDoc(rows: old), new: OutlineDoc(rows: new).normalized(newID: ids()), pageID: "p",
                        orderKeys: keys ?? self.keys, newID: ids())
    }
    let flat = [row("a", 0, "A"), row("b", 0, "B"), row("c", 0, "C")]

    @Test func equalDocsProduceNothing() { #expect(sync(flat, flat).isEmpty) }

    @Test func textEditIsOneEditOp() {
        var new = flat; new[1].text = "B!"
        #expect(sync(flat, new) == [.editText(blockID: "b", text: "B!")])
    }

    @Test func collapseToggleIsOneOp() {
        var new = flat; new[1].collapsed = true
        #expect(sync(flat, new) == [.setCollapsed(blockID: "b", collapsed: true)])
    }

    @Test func enterAtEndInsertsBetweenWithAKeyBetweenNeighbours() {
        let new = [flat[0], flat[1], row(nil, 0, ""), flat[2]]
        let ops = sync(flat, new)
        guard ops.count == 1, case let .insertBlock(id, page, parent, key, text) = ops[0] else { Issue.record("\(ops)"); return }
        #expect(id == "new1" && page == "p" && parent == nil && text == "" && key > "b" && key < "c")
    }

    @Test func indentMovesUnderPreviousSibling() {
        var new = flat; new[1].depth = 1
        let ops = sync(flat, new)
        guard ops.count == 1, case let .moveBlock(id, _, parent, key) = ops[0] else { Issue.record("\(ops)"); return }
        #expect(id == "b" && parent == "a" && !key.isEmpty)
    }

    @Test func outdentMovesToTheParentsLevelAfterTheParent() {
        let old = [row("a", 0, "A"), row("b", 1, "B"), row("c", 0, "C")]
        var new = old; new[1].depth = 0
        let ops = sync(old, new)
        guard ops.count == 1, case let .moveBlock(id, _, parent, key) = ops[0] else { Issue.record("\(ops)"); return }
        #expect(id == "b" && parent == nil && key > "a" && key < "c")
    }

    @Test func reorderingKeepsAMaximumOfExistingKeys() {
        // c moved to the front: only c needs a new key
        let new = [flat[2], flat[0], flat[1]]
        let ops = sync(flat, new)
        #expect(ops.count == 1)
        guard case let .moveBlock(id, _, parent, key) = ops[0] else { Issue.record("\(ops)"); return }
        #expect(id == "c" && parent == nil && key < "a")
    }

    @Test func deletingAMiddleRowDeletesIt() {
        #expect(sync(flat, [flat[0], flat[2]]) == [.deleteBlock(blockID: "b")])
    }

    @Test func deletingAParentRowKeepsItsChildrenByMovingThemFirst() {
        let old = [row("a", 0, "A"), row("b", 1, "B"), row("c", 1, "C"), row("d", 0, "D")]
        let new = [row("a", 0, "A"), row("b", 1, "B"), row("c", 1, "C"), row("d", 0, "D")].filter { $0.blockID != "a" }
        // b and c are now first rows → depth normalised to 0 and 1
        let ops = sync(old, new, keys: ["a": "a", "b": "a", "c": "b", "d": "b"])
        let kinds = ops.map { op -> String in
            switch op { case .moveBlock(let id, _, _, _): return "move \(id)"; case .deleteBlock(let id): return "delete \(id)"; default: return "other" }
        }
        #expect(kinds.last == "delete a")
        #expect(kinds.contains("move b"))                       // b is promoted out of the doomed subtree first
        #expect(kinds.firstIndex(of: "move b")! < kinds.firstIndex(of: "delete a")!)
    }

    @Test func deletingAWholeSubtreeSelectionIssuesOnlyTheRootDelete() {
        let old = [row("a", 0, "A"), row("b", 1, "B"), row("c", 0, "C")]
        #expect(sync(old, [old[2]], keys: ["a": "a", "b": "a", "c": "b"]) == [.deleteBlock(blockID: "a")])
    }

    @Test func duplicateIDFromEnterGetsAFreshIDForTheSecondParagraph() {
        let new = [row("a", 0, "A"), row("a", 0, "second half"), row("b", 0, "B"), row("c", 0, "C")]
        let ops = sync(flat, new)
        #expect(ops.contains { if case .insertBlock(let id, _, _, _, let t) = $0 { return id == "new1" && t == "second half" }; return false })
    }

    @Test func manyAppendsKeepKeysSortedAndShort() {
        var new = flat
        for i in 0..<50 { new.append(row(nil, 0, "n\(i)")) }
        let ops = sync(flat, new)
        let inserted = ops.compactMap { op -> String? in if case let .insertBlock(_, _, _, key, _) = op { return key }; return nil }
        #expect(inserted.count == 50 && inserted == inserted.sorted() && inserted.allSatisfy { $0.count <= 4 } && inserted.first! > "c")
    }

    @Test func pasteOfMultipleRowsInTheMiddleInsertsInOrder() {
        let new = [flat[0], row(nil, 0, "x"), row(nil, 1, "y"), row(nil, 0, "z"), flat[1], flat[2]]
        let ops = sync(flat, new)
        let inserted = ops.compactMap { op -> (String, String?, String)? in
            if case let .insertBlock(id, _, parent, key, text) = op { return (text, parent, key) }; return nil
        }
        #expect(inserted.map(\.0) == ["x", "y", "z"])
        #expect(inserted[1].1 == "new1")                       // y is a child of x (x got the first fresh id)
        #expect(inserted[0].2 < inserted[2].2 && inserted[2].2 < "b")
    }
}

import Foundation
import Testing
@testable import GrimoireUI

private func r(_ id: String?, _ depth: Int, _ text: String = "", collapsed: Bool = false) -> OutlineRow {
    OutlineRow(blockID: id, depth: depth, text: text.isEmpty ? (id ?? "") : text, collapsed: collapsed)
}
private func doc(_ rows: OutlineRow...) -> OutlineDoc { OutlineDoc(rows: rows) }
private func caret(_ row: Int, _ off: Int = 0) -> OutlineSelection { OutlineSelection(caret: OutlinePos(row: row, offset: off)) }
private func shape(_ d: OutlineDoc) -> String { d.rows.map { String(repeating: ".", count: $0.depth) + ($0.blockID ?? "?") }.joined(separator: " ") }

@Suite struct OutlineCommandsTests {
    let flat = doc(r("a", 0), r("b", 0), r("c", 0))
    let nested = doc(r("a", 0), r("a1", 1), r("a2", 1), r("b", 0), r("b1", 1))

    @Test func indentMakesTheBlockAChildOfThePreviousSibling() {
        #expect(shape(OutlineCommands.indent(flat, caret(1))!.doc) == "a .b c")
        #expect(OutlineCommands.indent(flat, caret(0)) == nil)                       // nothing above to nest under
        #expect(shape(OutlineCommands.indent(nested, caret(3))!.doc) == "a .a1 .a2 .b ..b1")   // subtree comes along
        #expect(OutlineCommands.indent(nested, caret(1)) == nil)                     // a1 is already the first child
    }

    @Test func indentingASelectionMovesAllSelectedBlocks() {
        let sel = OutlineSelection(anchor: OutlinePos(row: 1, offset: 0), head: OutlinePos(row: 2, offset: 1))
        #expect(shape(OutlineCommands.indent(flat, sel)!.doc) == "a .b .c")
    }

    @Test func outdentMovesTheBlockAfterItsParentsSubtree() {
        let e = OutlineCommands.outdent(nested, caret(1))!
        #expect(shape(e.doc) == "a .a2 a1 b .b1")
        #expect(e.selection.head.row == 2)                                          // the caret follows a1
        #expect(OutlineCommands.outdent(nested, caret(0)) == nil)
        let last = OutlineCommands.outdent(nested, caret(2))!
        #expect(shape(last.doc) == "a .a1 a2 b .b1")                                // last child: stays in place, one level up
    }

    @Test func moveUpAndDownSwapWholeSubtrees() {
        #expect(shape(OutlineCommands.moveUp(nested, caret(3))!.doc) == "b .b1 a .a1 .a2")
        #expect(OutlineCommands.moveUp(nested, caret(0)) == nil)
        #expect(OutlineCommands.moveUp(nested, caret(1)) == nil)                    // first child can't move above its parent
        let down = OutlineCommands.moveDown(nested, caret(0))!
        #expect(shape(down.doc) == "b .b1 a .a1 .a2")
        #expect(down.selection.head.row == 2)
        #expect(OutlineCommands.moveDown(nested, caret(3)) == nil)
    }

    @Test func splitInTheMiddleKeepsBothHalves() {
        let d = doc(r("a", 0, "hello world"), r("b", 0))
        let e = OutlineCommands.split(d, at: OutlinePos(row: 0, offset: 5))!
        #expect(e.doc.rows.map(\.text) == ["hello", " world", "b"] && e.doc.rows[0].blockID == "a" && e.doc.rows[1].blockID == nil)
        #expect(e.selection == caret(1, 0))
    }

    @Test func splitAtTheStartAddsAnEmptyBlockAboveAndKeepsTheCaretInTheOriginal() {
        let d = doc(r("a", 0, "text"))
        let e = OutlineCommands.split(d, at: OutlinePos(row: 0, offset: 0))!
        #expect(e.doc.rows.map(\.text) == ["", "text"] && e.doc.rows[1].blockID == "a" && e.selection == caret(1, 0))
    }

    @Test func splitAtTheEndOfAnExpandedParentCreatesTheFirstChild() {
        let e = OutlineCommands.split(nested, at: OutlinePos(row: 0, offset: 1))!
        #expect(shape(e.doc) == "a .? .a1 .a2 b .b1")
    }

    @Test func splitOfACollapsedBlockInsertsAfterItsHiddenSubtree() {
        let d = doc(r("a", 0, "a", collapsed: true), r("a1", 1), r("b", 0))
        let e = OutlineCommands.split(d, at: OutlinePos(row: 0, offset: 1))!
        #expect(shape(e.doc) == "a .a1 ? b" && e.selection == caret(2, 0))
    }

    @Test func enterOnAnEmptyNestedBlockOutdents() {
        let d = doc(r("a", 0), r("x", 1, ""))
        var rows = d.rows; rows[1].text = ""
        let e = OutlineCommands.split(OutlineDoc(rows: rows), at: OutlinePos(row: 1, offset: 0))!
        #expect(e.doc.rows.map(\.depth) == [0, 0])
    }

    @Test func aTaskContinuesAsATask() {
        let d = doc(r("a", 0, "TODO write"))
        let e = OutlineCommands.split(d, at: OutlinePos(row: 0, offset: 10))!
        #expect(e.doc.rows.map(\.text) == ["TODO write", "TODO "] && e.selection == caret(1, 5))
    }

    @Test func splittingWithEmojiUsesUTF16Offsets() {
        let d = doc(r("a", 0, "🌙 night"))
        let e = OutlineCommands.split(d, at: OutlinePos(row: 0, offset: 2))!      // after the emoji (2 UTF-16 units)
        #expect(e.doc.rows.map(\.text) == ["🌙", " night"])
    }

    @Test func mergeBackwardJoinsTextAndReparentsChildren() {
        let d = doc(r("a", 0, "ab"), r("b", 0, "cd"), r("b1", 1, "child"))
        let e = OutlineCommands.mergeBackward(d, at: 1)!
        #expect(e.doc.rows.map(\.text) == ["abcd", "child"] && e.doc.rows.map(\.depth) == [0, 1])
        #expect(e.selection == caret(0, 2))
        #expect(OutlineCommands.mergeBackward(d, at: 0) == nil)
    }

    @Test func mergeSkipsHiddenRowsAndJoinsTheVisiblePrevious() {
        let d = doc(r("a", 0, "A", collapsed: true), r("a1", 1, "hidden"), r("b", 0, "B"))
        let e = OutlineCommands.mergeBackward(d, at: 2)!
        #expect(e.doc.rows.map(\.text) == ["AB", "hidden"] && e.selection == caret(0, 1))
    }

    @Test func toggleCollapseNeedsChildren() {
        #expect(OutlineCommands.toggleCollapse(nested, row: 0)!.rows[0].collapsed)
        #expect(OutlineCommands.toggleCollapse(flat, row: 0) == nil)
        #expect(nested.hiddenFlags() == [false, false, false, false, false])
        #expect(OutlineCommands.toggleCollapse(nested, row: 0)!.hiddenFlags() == [false, true, true, false, false])
    }

    @Test func toggleTaskCyclesAndAdjustsTheCaret() {
        var d = doc(r("a", 0, "write"))
        var sel = caret(0, 5)
        var seen: [String] = []
        for _ in 0..<4 {
            let e = OutlineCommands.toggleTask(d, sel)!; d = e.doc; sel = e.selection; seen.append(d.rows[0].text)
        }
        #expect(seen == ["TODO write", "DOING write", "DONE write", "write"] && sel == caret(0, 5))
    }

    @Test func headingPrefixIsReplaced() {
        let d = doc(r("a", 0, "## old"))
        #expect(OutlineCommands.setHeading(d, caret(0, 3), level: 1)!.doc.rows[0].text == "# old")
        #expect(OutlineCommands.setHeading(d, caret(0, 3), level: 0)!.doc.rows[0].text == "old")
    }
}

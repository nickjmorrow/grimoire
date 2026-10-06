import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
@testable import GrimoireUI

private func r(_ id: String?, _ depth: Int, _ text: String, collapsed: Bool = false) -> OutlineRow {
    OutlineRow(blockID: id, depth: depth, text: text, collapsed: collapsed)
}

@Suite struct OutlineStorageTests {
    let rows = [r("a", 0, "first 🌙"), r("b", 1, "two\nlines"), r("c", 0, ""), r("d", 0, "café", collapsed: true), r("e", 1, "hidden child")]

    func render(_ rows: [OutlineRow]) -> NSAttributedString {
        OutlineStorage.attributed(doc: OutlineDoc(rows: rows), base: [:], indent: 22, gutter: 18)
    }

    @Test func roundTripKeepsEverything() {
        let s = render(rows)
        #expect(OutlineStorage.doc(from: s).rows == rows)
        #expect(s.string.hasSuffix("hidden child\n") && s.string.contains("two\u{2028}lines"))
    }

    @Test func emptyDocRendersNothingAndReadsBackEmpty() {
        #expect(render([]).length == 0 && OutlineStorage.doc(from: NSAttributedString(string: "")).rows.isEmpty)
    }

    @Test func identityAndIndentAreAttributes() {
        let s = render(rows)
        let ranges = OutlineStorage.rowRanges(in: s)
        #expect(ranges.count == 5)
        #expect(s.attribute(OutlineAttr.blockID, at: ranges[1].location, effectiveRange: nil) as? String == "b")
        #expect(s.attribute(OutlineAttr.depth, at: ranges[1].location, effectiveRange: nil) as? Int == 1)
        let style = s.attribute(.paragraphStyle, at: ranges[1].location, effectiveRange: nil) as! NSParagraphStyle
        #expect(style.firstLineHeadIndent == 22 + 18 && style.headIndent == 22 + 18)
        #expect(s.attribute(OutlineAttr.hidden, at: ranges[4].location, effectiveRange: nil) as? Bool == true)
        #expect(s.attribute(OutlineAttr.hidden, at: ranges[3].location, effectiveRange: nil) == nil)
    }

    @Test func textTypedInTheTailParagraphBecomesARow() {
        let m = NSMutableAttributedString(attributedString: render([r("a", 0, "x")]))
        m.append(NSAttributedString(string: "new", attributes: [OutlineAttr.blockID: "a", OutlineAttr.depth: 0]))
        let doc = OutlineStorage.doc(from: m)
        #expect(doc.rows.map(\.text) == ["x", "new"])
        #expect(doc.rows.map(\.blockID) == ["a", "a"])                                      // duplicate id, fixed later by normalization
    }

    @Test func theTailRowIsARealRowForEverything() {
        let m = NSMutableAttributedString(attributedString: render([r("a", 0, "x"), r("b", 0, "")]))
        m.append(NSAttributedString(string: "tail", attributes: [OutlineAttr.blockID: "b", OutlineAttr.depth: 0]))
        #expect(OutlineStorage.rowRanges(in: m).count == 3)
        var new = OutlineStorage.doc(from: m).rows
        new[2].text = "tail!"
        OutlineStorage.replaceRows(in: m, old: OutlineStorage.doc(from: m), new: OutlineDoc(rows: new), base: [:], indent: 22, gutter: 18)
        #expect(OutlineStorage.doc(from: m).rows.map(\.text) == ["x", "", "tail!"])
        #expect(OutlineStorage.pos(m.length, in: m) == OutlinePos(row: 2, offset: 5))
    }

    @Test func rowsAppendedAfterAnUnterminatedTailDoNotMergeIntoIt() {
        let m = NSMutableAttributedString(attributedString: render([r("a", 0, "x")]))
        m.append(NSAttributedString(string: "tail", attributes: [OutlineAttr.blockID: "t", OutlineAttr.depth: 0]))
        let old = OutlineStorage.doc(from: m)
        var rows = old.rows
        rows.append(OutlineRow(blockID: "n", depth: 0, text: "from outside"))
        OutlineStorage.replaceRows(in: m, old: old, new: OutlineDoc(rows: rows), base: [:], indent: 22, gutter: 18)
        #expect(OutlineStorage.doc(from: m).rows.map(\.text) == ["x", "tail", "from outside"])
    }

    @Test func structuralCommandsOnAnEmptyDocumentDoNothing() {
        let empty = OutlineDoc(rows: [])
        let sel = OutlineSelection(caret: OutlinePos(row: 0, offset: 0))
        #expect(OutlineCommands.outdent(empty, sel) == nil)
        #expect(OutlineCommands.moveUp(empty, sel) == nil)
        #expect(OutlineCommands.moveDown(empty, sel) == nil)
        #expect(OutlineCommands.toggleTask(empty, sel) == nil)
    }

    @Test func selectionMappingUsesUTF16Offsets() {
        let s = render(rows)
        // caret right after the emoji in row 0: "first 🌙" = 6 + 2 units
        #expect(OutlineStorage.selection(for: NSRange(location: 8, length: 0), in: s) == OutlineSelection(caret: OutlinePos(row: 0, offset: 8)))
        // start of row 1
        let start1 = OutlineStorage.rowRanges(in: s)[1].location
        #expect(OutlineStorage.selection(for: NSRange(location: start1 + 3, length: 0), in: s).head == OutlinePos(row: 1, offset: 3))
        let sel = OutlineSelection(anchor: OutlinePos(row: 0, offset: 2), head: OutlinePos(row: 1, offset: 3))
        #expect(OutlineStorage.range(for: sel, in: s) == NSRange(location: 2, length: start1 + 3 - 2))
        // the empty tail after the last newline maps to the end of the last row
        #expect(OutlineStorage.selection(for: NSRange(location: s.length, length: 0), in: s).head == OutlinePos(row: 4, offset: 12))
    }

    @Test func changedRowsFindsTheMinimalWindow() {
        var new = rows; new[2].text = "changed"; new.insert(r("z", 0, "inserted"), at: 3)
        let w = OutlineStorage.changedRows(old: rows, new: new)
        #expect(w.old == 2..<3 && w.new == 2..<4)
        #expect(OutlineStorage.changedRows(old: rows, new: rows).old.isEmpty)
    }

    @Test func replacingAWindowOfRowsPreservesTheRest() {
        let storage = NSMutableAttributedString(attributedString: render(rows))
        var new = rows; new[2].text = "changed"
        OutlineStorage.replaceRows(in: storage, old: OutlineDoc(rows: rows), new: OutlineDoc(rows: new), base: [:], indent: 22, gutter: 18)
        #expect(OutlineStorage.doc(from: storage).rows == new)
    }

    @Test func collapsingAParentRewritesTheHiddenFlagsOfItsChildren() {
        let storage = NSMutableAttributedString(attributedString: render(rows))
        var new = rows; new[3].collapsed = false                     // expand "d": its child becomes visible
        OutlineStorage.replaceRows(in: storage, old: OutlineDoc(rows: rows), new: OutlineDoc(rows: new), base: [:], indent: 22, gutter: 18)
        let ranges = OutlineStorage.rowRanges(in: storage)
        #expect(storage.attribute(OutlineAttr.hidden, at: ranges[4].location, effectiveRange: nil) == nil)
        #expect(storage.attribute(OutlineAttr.hasChildren, at: ranges[3].location, effectiveRange: nil) as? Bool == true)
    }
}

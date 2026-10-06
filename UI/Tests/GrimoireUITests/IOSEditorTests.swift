#if os(iOS)
import GrimoireCore
import Testing
import UIKit
@testable import GrimoireUI

@Suite @MainActor struct IOSEditorTests {
    func editor(_ rows: [(Int, String)]) -> OutlineTextView {
        let tv = OutlineTextView(theme: .midnightSun)
        tv.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        tv.load(OutlineDoc(rows: rows.enumerated().map { OutlineRow(blockID: "b\($0.offset)", depth: $0.element.0, text: $0.element.1) }))
        return tv
    }

    func caretAtEnd(_ tv: OutlineTextView, row: Int) {
        tv.selectedRange = OutlineStorage.range(for: OutlineSelection(caret: OutlinePos(row: row, offset: Int.max / 2)), in: tv.textStorage)
    }

    @Test func returnSplitsTheBlockAndBackspaceMergesItBack() {
        let tv = editor([(0, "hello world")])
        tv.selectedRange = NSRange(location: 5, length: 0)
        #expect(tv.textView(tv, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementText: "\n") == false)
        #expect(tv.currentDoc.rows.map(\.text) == ["hello", " world"])
        // caret is at the start of row 1; backspace deletes the terminator before it
        let nl = ("hello\n" as NSString).length - 1
        #expect(tv.textView(tv, shouldChangeTextIn: NSRange(location: nl, length: 1), replacementText: "") == false)
        #expect(tv.currentDoc.rows.map(\.text) == ["hello world"])
    }

    @Test func bracketsAutoPairAndTypeOver() {
        let tv = editor([(0, "")])
        #expect(tv.textView(tv, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "[") == false)
        #expect(tv.currentDoc.rows[0].text == "[]" && tv.selectedRange.location == 1)
        #expect(tv.textView(tv, shouldChangeTextIn: NSRange(location: 1, length: 0), replacementText: "]") == false)
        #expect(tv.selectedRange.location == 2 && tv.currentDoc.rows[0].text == "[]")
    }

    @Test func indentOutdentAndMoveWork() {
        let tv = editor([(0, "a"), (0, "b")])
        caretAtEnd(tv, row: 1)
        tv.indentSelection()
        #expect(tv.currentDoc.rows.map(\.depth) == [0, 1])
        tv.outdentSelection()
        #expect(tv.currentDoc.rows.map(\.depth) == [0, 0])
        tv.moveUp()
        #expect(tv.currentDoc.rows.map(\.text) == ["b", "a"])
    }

    @Test func undoRevertsAStructuralEdit() {
        let tv = editor([(0, "a"), (0, "b")])
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800)); window.addSubview(tv)
        caretAtEnd(tv, row: 1)
        tv.indentSelection()
        #expect(tv.currentDoc.rows.map(\.depth) == [0, 1])
        tv.undoManager?.undo()
        #expect(tv.currentDoc.rows.map(\.depth) == [0, 0])
        tv.undoManager?.redo()
        #expect(tv.currentDoc.rows.map(\.depth) == [0, 1])
    }

    @Test func theToolbarOffersPagesWhileTypingALink() {
        let tv = editor([(0, "see [[Foc")])
        tv.autocompleteSource = AutocompleteSource(pages: { _ in ["Focaccia"] })
        caretAtEnd(tv, row: 0)
        tv.textViewDidChangeSelection(tv)
        #expect(tv.autocompleteItems.map(\.title) == ["Focaccia", "Foc"])
        tv.acceptAutocomplete(tv.autocompleteItems[0])
        #expect(tv.currentDoc.rows[0].text == "see [[Focaccia]]")
        #expect(!tv.isAutocompleteOpen)
    }

    @Test func taskTogglesAndCollapseHidesChildren() {
        let tv = editor([(0, "parent"), (1, "child")])
        caretAtEnd(tv, row: 0)
        tv.cycleTask()
        #expect(tv.currentDoc.rows[0].text == "TODO parent")
        tv.toggleCollapse(expand: false)
        #expect(tv.currentDoc.rows[0].collapsed)
        tv.toggleCollapse(expand: true)
        #expect(!tv.currentDoc.rows[0].collapsed)
    }
}
#endif

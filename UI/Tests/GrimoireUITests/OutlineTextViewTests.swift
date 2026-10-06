#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import GrimoireUI

private func r(_ id: String?, _ depth: Int, _ text: String, collapsed: Bool = false) -> OutlineRow {
    OutlineRow(blockID: id, depth: depth, text: text, collapsed: collapsed)
}

@MainActor enum TestWindows { static var windows: [NSWindow] = []; static func keep(_ w: NSWindow) { windows.append(w) } }

@MainActor
func makeView(_ rows: [OutlineRow], theme: Theme = .midnightSun, width: CGFloat = 640) -> OutlineTextView {
    _ = NSApplication.shared
    let v = OutlineTextView(theme: theme)
    v.load(OutlineDoc(rows: rows))
    let h = v.contentHeight(forWidth: width)
    v.frame = NSRect(x: 0, y: 0, width: width, height: h)
    // An undo manager only exists once the view is in a window.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    window.contentView = v
    TestWindows.keep(window)
    return v
}

@MainActor
func snapshot(_ v: OutlineTextView, name: String) {
    let w = v.frame.width
    v.frame = NSRect(x: 0, y: 0, width: w, height: v.contentHeight(forWidth: w))
    v.textLayoutManager?.ensureLayout(for: v.textLayoutManager!.documentRange)
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".snapshots")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
}

@Suite @MainActor struct OutlineTextViewTests {
    let sample = [
        r("a", 0, "Plan for the week #planning"),
        r("b", 1, "TODO write the **Grimoire** spec with [[Rob Gersch]]"),
        r("c", 1, "DONE install xcodegen"),
        r("d", 1, "DOING dashboard polish"),
        r("e", 0, "# Reading notes"),
        r("f", 1, "type:: book\nauthor:: Martin Kleppmann"),
        r("g", 1, "Replication — a leader and followers; `fsync` matters. See ((6721b0c4-1111-4222-8333-944455556666)) and https://dataintensive.net for more."),
        r("h", 0, "Collapsed parent with hidden children", collapsed: true),
        r("i", 1, "hidden one"),
        r("j", 1, "hidden two"),
        r("k", 0, "```swift\nlet x = 1\n```"),
        r("l", 0, "> a quote that says something *wise* about ~~nothing~~ everything"),
    ]

    @Test func snapshots() {
        snapshot(makeView(sample), name: "page-dark")
        snapshot(makeView(sample, theme: .midnightSunLight), name: "page-light")
        #expect(true)
    }

    @Test func loadAndReadBackIsLossless() {
        let v = makeView(sample)
        #expect(v.currentDoc.rows == sample)
    }

    @Test func stylingAppliesToTheParagraph() {
        let v = makeView([r("a", 0, "plain **bold** text")])
        let storage = v.textStorage!
        let boldRange = ("plain **bold** text" as NSString).range(of: "bold")
        let font = storage.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let plain = storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        #expect(!NSFontManager.shared.traits(of: plain).contains(.boldFontMask))
    }

    @Test func typingIntoABlockChangesOnlyThatRow() {
        let v = makeView([r("a", 0, "hello"), r("b", 0, "world")])
        v.setSelectedRange(NSRange(location: 5, length: 0))
        v.insertText("!", replacementRange: v.selectedRange())
        #expect(v.currentDoc.rows.map(\.text) == ["hello!", "world"] && v.currentDoc.rows.map(\.blockID) == ["a", "b"])
    }

    @Test func enterSplitsAtTheCaretAndTheCaretMovesToTheNewBlock() {
        let v = makeView([r("a", 0, "hello world")])
        v.setSelectedRange(NSRange(location: 5, length: 0))
        v.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(v.currentDoc.rows.map(\.text) == ["hello", " world"])
        #expect(OutlineStorage.selection(for: v.selectedRange(), in: v.textStorage!).head == OutlinePos(row: 1, offset: 0))
        #expect(v.currentDoc.rows[0].blockID == "a")
    }

    @Test func tabIndentsAndShiftTabOutdents() {
        let v = makeView([r("a", 0, "a"), r("b", 0, "b")])
        v.setSelectedRange(NSRange(location: 3, length: 0))              // inside "b"
        v.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(v.currentDoc.rows.map(\.depth) == [0, 1])
        v.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(v.currentDoc.rows.map(\.depth) == [0, 0])
    }

    @Test func backspaceAtTheStartMergesIntoThePreviousBlock() {
        let v = makeView([r("a", 0, "ab"), r("b", 0, "cd")])
        v.setSelectedRange(NSRange(location: 3, length: 0))               // start of "cd"
        v.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(v.currentDoc.rows.map(\.text) == ["abcd"] && v.selectedRange().location == 2)
    }

    @Test func undoRestoresASplit() {
        let v = makeView([r("a", 0, "hello world")])
        v.setSelectedRange(NSRange(location: 5, length: 0))
        v.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(v.currentDoc.rows.count == 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))      // closes the per-event undo group
        v.undoManager?.undo()
        #expect(v.currentDoc.rows == [r("a", 0, "hello world")])
    }

    @Test func shiftEnterInsertsALineBreakInsideTheBlock() {
        let v = makeView([r("a", 0, "ab")])
        v.setSelectedRange(NSRange(location: 1, length: 0))
        v.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))
        #expect(v.currentDoc.rows.map(\.text) == ["a\nb"])
    }

    @Test func collapsingHidesTheChildrenAndTheCaretStaysPut() {
        let v = makeView([r("a", 0, "parent"), r("b", 1, "child")])
        v.setSelectedRange(NSRange(location: 2, length: 0))
        v.toggleCollapse(expand: false)
        let ranges = OutlineStorage.rowRanges(in: v.textStorage!)
        #expect(v.currentDoc.rows[0].collapsed)
        #expect(v.textStorage!.attribute(OutlineAttr.hidden, at: ranges[1].location, effectiveRange: nil) != nil)
    }

    @Test func pastingBulletsCreatesBlocks() {
        let v = makeView([r("a", 0, "first")])
        v.setSelectedRange(NSRange(location: 5, length: 0))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("- x\n  - y\n- z", forType: .string)
        v.paste(nil)
        #expect(v.currentDoc.rows.map(\.text) == ["first", "x", "y", "z"] && v.currentDoc.rows.map(\.depth) == [0, 0, 1, 0])
    }

    @Test func autoPairsBracketsAndTypesOverTheCloser() {
        let v = makeView([r("a", 0, "")])
        v.insertText("[", replacementRange: v.selectedRange())
        #expect(v.currentDoc.rows[0].text == "[]" && v.selectedRange().location == 1)
        v.insertText("]", replacementRange: v.selectedRange())
        #expect(v.currentDoc.rows[0].text == "[]" && v.selectedRange().location == 2)
    }

    @Test func externalDocKeepsTheCaretOnTheSameBlock() {
        let v = makeView([r("a", 0, "one"), r("b", 0, "two")])
        v.setSelectedRange(NSRange(location: 6, length: 0))                // inside "two"
        v.applyExternal(OutlineDoc(rows: [r("z", 0, "inserted above"), r("a", 0, "one"), r("b", 0, "two")]))
        #expect(OutlineStorage.selection(for: v.selectedRange(), in: v.textStorage!).head.row == 2)
    }

    @Test func idsAssignedBySavingAreWrittenBackOntoParagraphs() {
        let v = makeView([r("a", 0, "x"), r(nil, 0, "new")])
        v.patchIDs(OutlineDoc(rows: [r("a", 0, "x"), r("fresh", 0, "new")]))
        #expect(v.currentDoc.rows.map(\.blockID) == ["a", "fresh"])
    }
}
#endif

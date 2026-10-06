import Foundation
import Testing
@testable import GrimoireUI

@Suite struct OutlineMarkdownTests {
    @Test func parsesBulletsWithIndentAndContinuations() {
        let rows = OutlineMarkdown.parse("- a\n  - b\n    more of b\n- c")
        #expect(rows.map(\.text) == ["a", "b\nmore of b", "c"] && rows.map(\.depth) == [0, 1, 0] && rows.allSatisfy { $0.blockID == nil })
    }

    @Test func plainLinesBecomeBlocks() {
        #expect(OutlineMarkdown.parse("one\n\ntwo\nthree").map(\.text) == ["one", "two", "three"])
    }

    @Test func rendersRelativeToTheShallowestRow() {
        let rows = [OutlineRow(blockID: "a", depth: 1, text: "x"), OutlineRow(blockID: "b", depth: 2, text: "y\nz"), OutlineRow(blockID: "c", depth: 1, text: "w")]
        #expect(OutlineMarkdown.render(rows) == "- x\n  - y\n    z\n- w")
    }

    @Test func renderThenParseRoundTrips() {
        let rows = [OutlineRow(blockID: nil, depth: 0, text: "a"), OutlineRow(blockID: nil, depth: 1, text: "b\nc"), OutlineRow(blockID: nil, depth: 0, text: "d")]
        #expect(OutlineMarkdown.parse(OutlineMarkdown.render(rows)) == rows)
    }

    @Test func pasteReplacesAnEmptyBlockAndKeepsRelativeDepth() {
        let doc = OutlineDoc(rows: [OutlineRow(blockID: "a", depth: 0, text: "a"), OutlineRow(blockID: "b", depth: 1, text: "")])
        let e = OutlineCommands.paste(doc, at: OutlinePos(row: 1, offset: 0), rows: OutlineMarkdown.parse("- x\n  - y"))!
        #expect(e.doc.rows.map(\.text) == ["a", "x", "y"] && e.doc.rows.map(\.depth) == [0, 1, 2] && e.selection.head == OutlinePos(row: 2, offset: 1))
    }

    @Test func pasteAfterANonEmptyBlockGoesAfterItsSubtree() {
        let doc = OutlineDoc(rows: [OutlineRow(blockID: "a", depth: 0, text: "a"), OutlineRow(blockID: "a1", depth: 1, text: "a1"), OutlineRow(blockID: "b", depth: 0, text: "b")])
        let e = OutlineCommands.paste(doc, at: OutlinePos(row: 0, offset: 1), rows: OutlineMarkdown.parse("x\ny"))!
        #expect(e.doc.rows.map(\.text) == ["a", "a1", "x", "y", "b"])
    }
}

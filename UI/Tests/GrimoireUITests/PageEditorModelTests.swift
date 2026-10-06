import Foundation
import GrimoireCore
import Testing
@testable import GrimoireUI

private func tempGraph() throws -> Graph { try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("ui-\(UUID().uuidString)"), device: "t") }
private func row(_ id: String?, _ depth: Int, _ text: String) -> OutlineRow { OutlineRow(blockID: id, depth: depth, text: text) }

/// Lets main-queue work (saves, callbacks) run while the test waits.
private func pumpMain(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

@Suite @MainActor struct PageEditorModelTests {
    func setup() throws -> (Graph, PageEditorModel, Box) {
        let g = try tempGraph()
        try g.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil),
                       .insertBlock(id: "a", pageID: "p", parentID: nil, orderKey: "a", text: "one"),
                       .insertBlock(id: "b", pageID: "p", parentID: nil, orderKey: "b", text: "two")], author: .me)
        let m = PageEditorModel(graph: g, pageID: "p")
        m.debounceInterval = 0.05
        let box = Box(try m.load())
        m.currentDoc = { box.doc }
        return (g, m, box)
    }

    final class Box { var doc: OutlineDoc; init(_ d: OutlineDoc) { doc = d } }

    @Test func loadReturnsTheRows() async throws {
        let (_, m, box) = try setup()
        #expect(box.doc.rows.map(\.text) == ["one", "two"] && m.isDirty == false)
    }

    @Test func typingSavesAfterThePauseAndNotBefore() async throws {
        let (g, m, box) = try setup()
        box.doc.rows[0].text = "one!"
        m.noteEdited()
        #expect(try g.tree(pageID: "p")[0].block.text == "one")        // not yet
        await pumpMain(0.3); m.waitUntilIdle(); await pumpMain(0.05)
        let t = try g.tree(pageID: "p")[0].block.text
        #expect(t == "one!" && m.isDirty == false && m.saveCount == 1)
    }

    @Test func flushSavesImmediately() async throws {
        let (g, m, box) = try setup()
        box.doc.rows[1].text = "two!"
        m.noteEdited()
        var done = false
        m.flush { done = true }
        await pumpMain(0.2)
        let t = try g.tree(pageID: "p")[1].block.text
        #expect(done && t == "two!")
    }

    @Test func newRowsGetIDsAndTheViewIsToldAboutThem() async throws {
        let (g, m, box) = try setup()
        var patched: OutlineDoc?
        m.onNormalized = { patched = $0 }
        box.doc.rows.append(row(nil, 0, "three"))
        m.noteEdited(); m.flush(); await pumpMain(0.2)
        #expect(patched?.rows.last?.blockID != nil)
        #expect(try g.tree(pageID: "p").map(\.block.text) == ["one", "two", "three"])
    }

    @Test func anOutsideWriteReloadsAnIdleEditor() async throws {
        let (g, m, _) = try setup()
        var received: OutlineDoc?
        m.onExternalDoc = { received = $0 }
        try g.perform([.editText(blockID: "a", text: "changed by claude")], author: .claude)
        m.externalChangeDetected(); await pumpMain(0.2)
        #expect(received?.rows[0].text == "changed by claude")
    }

    @Test func anOutsideWriteDuringTypingWaitsForTheSaveThenReloads() async throws {
        let (g, m, box) = try setup()
        var received: [OutlineDoc] = []
        m.onExternalDoc = { received.append($0) }
        box.doc.rows[1].text = "typing…"
        m.noteEdited()
        try g.perform([.editText(blockID: "a", text: "outside")], author: .claude)
        m.externalChangeDetected()
        #expect(received.isEmpty)                                   // dirty: don't clobber
        await pumpMain(0.4); m.waitUntilIdle(); await pumpMain(0.2)
        #expect(try g.tree(pageID: "p").map(\.block.text) == ["outside", "typing…"])   // both survive in the database
        #expect(received.last?.rows.map(\.text) == ["outside", "typing…"])
    }

    @Test func savingOurOwnEditDoesNotEchoBackAsExternal() async throws {
        let (_, m, box) = try setup()
        var echoes = 0
        m.onExternalDoc = { _ in echoes += 1 }
        box.doc.rows[0].text = "mine"
        m.noteEdited(); m.flush(); await pumpMain(0.2)
        m.externalChangeDetected(); await pumpMain(0.2)
        #expect(echoes == 0)
    }
}

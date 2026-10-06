import Foundation
import GRDB
import Testing
@testable import GrimoireCore

/// A small graph in two versions, to import and then update.
private func export(_ version: Int) -> MiniExport {
    var m = MiniExport()
    m.page(1, "Notes", uuid: 1)
    m.block(10, "keeps as is", uuid: 10, page: 1, parent: 1, order: "a0")
    m.block(11, version == 1 ? "old text from logseq" : "newer text from logseq", uuid: 11, page: 1, parent: 1, order: "a1")
    m.block(12, version == 1 ? "edited in both places (logseq v1)" : "edited in both places (logseq v2)", uuid: 12, page: 1, parent: 1, order: "a2")
    if version == 1 { m.block(13, "deleted later in logseq", uuid: 13, page: 1, parent: 1, order: "a3") }
    if version == 2 {
        m.block(14, "brand new block", uuid: 14, page: 1, parent: 1, order: "a4")
        m.block(15, "its child", uuid: 15, page: 1, parent: 14, order: "a0")
        m.page(2, "New page", uuid: 2)
        m.block(16, "on the new page", uuid: 16, page: 2, parent: 2, order: "a0")
    }
    return m
}

@Suite struct LogseqUpdateTests {
    func id(_ n: Int) -> String { MiniExport.u(n) }

    @Test func newerLogseqContentLandsAndYourEditsSurvive() throws {
        let g = try makeGraph()
        _ = try LogseqImporter.importGraph(datoms: try Datoms(exportText: export(1).text), assetsFolder: nil, into: g)
        try g.perform([.editText(blockID: id(12), text: "my own edit in grimoire")], author: .me)

        let r = try LogseqUpdate.apply(datoms: try Datoms(exportText: export(2).text), assetsFolder: nil, to: g)
        #expect(r.pagesAdded == 1 && r.blocksAdded == 3)
        #expect(r.blocksUpdated == 1 && r.blocksRemoved == 1)
        #expect(r.keptYours == [id(12)])
        #expect(try g.text(id(11)) == "newer text from logseq")
        #expect(try g.text(id(12)) == "my own edit in grimoire")
        #expect(try g.text(id(13)) == nil)
        #expect(try g.text(id(14)) == "brand new block" && g.text(id(15)) == "its child")
        let child = try g.db.read { try Block.fetchOne($0, key: id(15)) }
        #expect(child?.parentId == id(14))
        #expect(try g.page(titled: "New page") != nil && g.text(id(16)) == "on the new page")
    }

    @Test func runningTheSameUpdateTwiceChangesNothing() throws {
        let g = try makeGraph()
        _ = try LogseqImporter.importGraph(datoms: try Datoms(exportText: export(1).text), assetsFolder: nil, into: g)
        _ = try LogseqUpdate.apply(datoms: try Datoms(exportText: export(2).text), assetsFolder: nil, to: g)
        let r = try LogseqUpdate.apply(datoms: try Datoms(exportText: export(2).text), assetsFolder: nil, to: g)
        #expect(r.pagesAdded == 0 && r.blocksAdded == 0 && r.blocksUpdated == 0 && r.blocksRemoved == 0)
    }

    @Test func blocksYouAddedInGrimoireAreNeverRemoved() throws {
        let g = try makeGraph()
        _ = try LogseqImporter.importGraph(datoms: try Datoms(exportText: export(1).text), assetsFolder: nil, into: g)
        let notes = Graph.pageID(forTitle: "Notes")
        try g.perform([.insertBlock(id: "mine", pageID: notes, parentID: nil, orderKey: "zz", text: "written in grimoire")], author: .me)
        _ = try LogseqUpdate.apply(datoms: try Datoms(exportText: export(2).text), assetsFolder: nil, to: g)
        #expect(try g.text("mine") == "written in grimoire")
    }

    @Test func updatesSyncLikeOtherChanges() async throws {
        let rig = try Rig()
        let g = try makeGraph()
        _ = try LogseqImporter.importGraph(datoms: try Datoms(exportText: export(1).text), assetsFolder: nil, into: g)
        let client = SyncClient(graph: g, deviceID: "mac")
        try await client.sync(using: rig.transport)
        _ = try LogseqUpdate.apply(datoms: try Datoms(exportText: export(2).text), assetsFolder: nil, to: g)
        try await client.sync(using: rig.transport)
        #expect(try rig.hub.graph.text(id(14)) == "brand new block")
        #expect(try rig.hub.graph.text(id(13)) == nil)
        #expect(try syncState(g) == syncState(rig.hub.graph))
    }
}

import Foundation
import GRDB
import Testing
@testable import GrimoireCore

@Suite struct BackupTests {
    func graph() throws -> Graph {
        let g = try Graph(folder: tempFolder(), device: "t")
        try g.perform([.createPage(id: "p1", title: "Soup", kind: .page, journalDate: nil),
                       .insertBlock(id: "b1", pageID: "p1", parentID: nil, orderKey: "a0", text: "stock first")], author: .me)
        return g
    }

    @Test func aBackupOpensAsAGraphWithTheSameContent() throws {
        let g = try graph(), dest = tempFolder()
        try Data("x".utf8).write(to: g.folder.appendingPathComponent("assets/abc.png"))
        let r = try g.backup(to: dest)
        #expect(r.assetsCopied == 1 && FileManager.default.fileExists(atPath: dest.appendingPathComponent("assets/abc.png").path))
        let copy = try DatabaseQueue(path: r.database.path)
        #expect(try copy.read { try String.fetchOne($0, sql: "SELECT text FROM blocks WHERE id = 'b1'") } == "stock first")
        #expect(try g.backup(to: dest, now: Date().addingTimeInterval(60)).assetsCopied == 0)        // assets are copied once
        #expect(!FileManager.default.fileExists(atPath: r.database.path + ".partial"))
    }

    @Test func oldBackupsAreThinnedToDailyThenWeekly() throws {
        let g = try graph(), dest = tempFolder()
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        for d in 0..<60 { try g.backup(to: dest, now: start.addingTimeInterval(Double(d) * 86_400)) }
        let kept = Graph.backups(in: dest)
        #expect(kept.count >= 14 && kept.count <= 14 + 8)
        let newest = (0..<14).map { Graph.stamp(start.addingTimeInterval(Double(59 - $0) * 86_400)) }
        for s in newest { #expect(kept.contains { $0.lastPathComponent.contains(s) }) }             // the last 14 days are all there
        #expect(kept.count < 60)
    }

    @Test func twoBackupsOnOneDayKeepOnlyTheNewest() throws {
        let g = try graph(), dest = tempFolder(), t = Date(timeIntervalSince1970: 1_760_000_000)
        for d in 0..<20 { try g.backup(to: dest, now: t.addingTimeInterval(Double(d) * 86_400)) }    // fill past the weekly window
        let before = Graph.backups(in: dest).count
        try g.backup(to: dest, now: t.addingTimeInterval(19 * 86_400 + 3600))
        #expect(Graph.backups(in: dest).count == before)
    }
}

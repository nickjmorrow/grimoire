import Foundation
import GRDB
import Testing
@testable import GrimoireCore

func makeGraph() throws -> Graph { try Graph(folder: tempFolder(), device: "test") }

@Suite struct PageOpsTests {
    @Test func createPageWritesRowAndOpLog() throws {
        let g = try makeGraph()
        try g.perform([.createPage(id: "p1", title: "Recipe", kind: .page, journalDate: nil)], author: .me)
        try g.db.read { db in
            let page = try Page.fetchOne(db, key: "p1")
            #expect(page?.title == "Recipe" && page?.titleLower == "recipe" && page?.kind == .page)
            let row = try Row.fetchOne(db, sql: "SELECT kind, author, seq, device FROM ops")
            #expect(row?["kind"] as String? == "createPage")
            #expect(row?["author"] as String? == "me")
            #expect(row?["device"] as String? == "test")
            #expect((row?["seq"] as Int64?) == nil)
        }
    }

    @Test func createPageWithTakenTitleThrows() throws {
        let g = try makeGraph()
        try g.perform([.createPage(id: "p1", title: "Recipe", kind: .page, journalDate: nil)], author: .me)
        #expect(throws: GraphError.titleTaken("recipe")) {
            try g.perform([.createPage(id: "p2", title: "recipe", kind: .page, journalDate: nil)], author: .me)
        }
        let n = try g.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ops") }
        #expect(n == 1)
    }

    @Test func ensureJournalIsIdempotentAndDeterministic() throws {
        let g = try makeGraph()
        let d = JournalDate(iso: "2026-10-05")!
        let a = try g.ensureJournal(d, author: .me)
        let b = try g.ensureJournal(d, author: .me)
        #expect(a == "bd08754d-0f15-540c-9e70-8879385ec362" && a == b)
        let page = try g.db.read { try Page.fetchOne($0, key: a) }
        #expect(page?.kind == .journal && page?.journalDate == "2026-10-05" && page?.title == "2026-10-05 Monday")
        #expect(try g.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pages") } == 1)
    }

    @Test func renamePageUpdatesTitleAndLogsInverse() throws {
        let g = try makeGraph()
        try g.perform([.createPage(id: "p1", title: "Old", kind: .page, journalDate: nil)], author: .me)
        try g.perform([.renamePage(id: "p1", title: "New Name")], author: .me)
        try g.db.read { db in
            let page = try Page.fetchOne(db, key: "p1")
            #expect(page?.title == "New Name" && page?.titleLower == "new name")
            let inv = try String.fetchOne(db, sql: "SELECT inverse FROM ops WHERE kind='renamePage'")!
            #expect(try JSONDecoder().decode(Op.self, from: Data(inv.utf8)) == .renamePage(id: "p1", title: "Old"))
        }
    }

    @Test func renameOntoExistingTitleThrows() throws {
        let g = try makeGraph()
        try g.perform([.createPage(id: "p1", title: "A", kind: .page, journalDate: nil),
                       .createPage(id: "p2", title: "B", kind: .page, journalDate: nil)], author: .me)
        #expect(throws: GraphError.titleTaken("b")) {
            try g.perform([.renamePage(id: "p1", title: "b")], author: .me)
        }
        #expect(try g.db.read { try Page.fetchOne($0, key: "p1")?.title } == "A")
        #expect(try g.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ops") } == 2)  // the two createPage ops only
    }

    @Test func setFavoriteOrdersFavorites() throws {
        let g = try makeGraph()
        try g.perform([.createPage(id: "a", title: "A", kind: .page, journalDate: nil),
                       .createPage(id: "b", title: "B", kind: .page, journalDate: nil),
                       .createPage(id: "c", title: "C", kind: .page, journalDate: nil)], author: .me)
        try g.perform([.setFavorite(pageID: "a", favorite: true, order: nil),
                       .setFavorite(pageID: "b", favorite: true, order: nil),
                       .setFavorite(pageID: "c", favorite: true, order: nil)], author: .me)
        func orders() throws -> [String: Int?] {
            try g.db.read { db in
                var out: [String: Int?] = [:]
                for p in try Page.fetchAll(db) { out[p.id] = p.favoriteOrder }
                return out
            }
        }
        #expect(try orders() == ["a": 0, "b": 1, "c": 2])
        try g.perform([.setFavorite(pageID: "b", favorite: false, order: nil)], author: .me)
        let b = try g.db.read { try Page.fetchOne($0, key: "b") }
        #expect(b?.favorite == false && b?.favoriteOrder == nil)
    }

    @Test func importAssetDedupesByHash() throws {
        let g = try makeGraph()
        let src = tempFolder().appendingPathExtension("txt")
        try Data("hello".utf8).write(to: src)
        let a1 = try g.importAsset(from: src, author: .me)
        let a2 = try g.importAsset(from: src, author: .me)
        #expect(a1.hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" && a1 == a2)
        #expect(try g.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assets") } == 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: g.folder.appendingPathComponent("assets").path)
        #expect(files == ["\(a1.hash).txt"])
    }
}

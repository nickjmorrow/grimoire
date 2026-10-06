import Foundation
import GRDB
import Testing
@testable import GrimoireCore

/// Builds a small Logseq datom export covering every mapping rule.
struct MiniExport {
    var lines: [String] = []
    static func q(_ s: String) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! enc.encode(s), as: UTF8.self)
    }
    static func u(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
    mutating func add(_ e: Int, _ attrs: [(String, String)]) { for (a, v) in attrs { lines.append("[\(e) \(a) \(v)]") } }
    var text: String { "{:logseq.db.sqlite.export/graph-format :datoms :datoms [\(lines.joined(separator: " "))]}" }

    /// A page entity.
    mutating func page(_ e: Int, _ title: String, uuid: Int, tags: [Int] = [], journalDay: Int? = nil, extra: [(String, String)] = []) {
        var a: [(String, String)] = [(":block/name", Self.q(title.lowercased())), (":block/title", Self.q(title)),
                                     (":block/uuid", "#uuid \(Self.q(Self.u(uuid)))"),
                                     (":block/created-at", "1790000000\(e)"), (":block/updated-at", "1790000001\(e)")]
        a += tags.map { (":block/tags", "\($0)") }
        if let journalDay { a.append((":block/journal-day", "\(journalDay)")) }
        add(e, a + extra)
    }

    /// A block entity under `parent` (a page or block entity), on `pageEnt`.
    mutating func block(_ e: Int, _ title: String, uuid: Int, page: Int, parent: Int, order: String = "a0",
                        tags: [Int] = [], extra: [(String, String)] = []) {
        var a: [(String, String)] = [(":block/title", Self.q(title)), (":block/uuid", "#uuid \(Self.q(Self.u(uuid)))"),
                                     (":block/page", "\(page)"), (":block/parent", "\(parent)"), (":block/order", Self.q(order)),
                                     (":block/created-at", "1790000000\(e)"), (":block/updated-at", "1790000001\(e)")]
        a += tags.map { (":block/tags", "\($0)") }
        add(e, a + extra)
    }

    // Entity ids used by `standard()`.
    static let rob = 1, journal = 2, person = 20, journalClass = 21, codeClass = 22, cardClass = 23, tagClass = 24, quoteClass = 25
    static let todo = 30, favorites = 70

    static func standard(assetsFolder: URL? = nil) -> MiniExport {
        var m = MiniExport()
        // Built-in and user classes
        m.add(person, [(":db/ident", ":user.class/person"), (":block/name", q("person")), (":block/title", q("person")),
                       (":block/uuid", "#uuid \(q(u(20)))"), (":block/tags", "\(tagClass)")])
        for (e, ident, title) in [(journalClass, ":logseq.class/Journal", "Journal"), (codeClass, ":logseq.class/Code", "Code"),
                                  (cardClass, ":logseq.class/Card", "Card"), (tagClass, ":logseq.class/Tag", "Tag"),
                                  (quoteClass, ":logseq.class/Quote", "Quote")] {
            m.add(e, [(":db/ident", ident), (":block/name", q(title.lowercased())), (":block/title", q(title)),
                      (":logseq.property/built-in?", "true"), (":block/uuid", "#uuid \(q(u(e)))")])
        }
        m.add(todo, [(":db/ident", ":logseq.property/status.todo"), (":block/title", q("Todo")), (":logseq.property/built-in?", "true")])
        // Property definitions
        for (e, ident, title, type, card) in [(50, ":user.property/serves-x", "serves", ":default", ":db.cardinality/one"),
                                              (51, ":user.property/author-x", "author", ":default", ":db.cardinality/one"),
                                              (52, ":user.property/year-x", "year", ":number", ":db.cardinality/one"),
                                              (53, ":user.property/mood-x", "mood", ":node", ":db.cardinality/many")] {
            m.add(e, [(":db/ident", ident), (":block/name", q(title)), (":block/title", q(title)),
                      (":logseq.property/type", type), (":db/cardinality", card), (":block/uuid", "#uuid \(q(u(e)))")])
        }
        // Pages
        m.page(rob, "Rob", uuid: 1, tags: [person], extra: [(":user.property/serves-x", "43"), (":block/alias", "80")])
        m.page(journal, "2026-10-05 Monday", uuid: 2, tags: [journalClass], journalDay: 20261005)
        m.page(60, "Rob", uuid: 60, tags: [person], extra: [(":user.property/serves-x", "46"), (":user.property/author-x", "41")])   // duplicate title, with its own metadata
        m.add(46, [(":block/title", q("9")), (":logseq.property/created-from-property", "50")])
        m.page(80, "Calm", uuid: 81); m.page(82, "Tired", uuid: 82)
        // Value blocks
        m.add(43, [(":block/title", q("8")), (":logseq.property/created-from-property", "50"), (":block/uuid", "#uuid \(q(u(43)))")])
        m.add(40, [(":block/title", q("4")), (":logseq.property/created-from-property", "50")])
        m.add(41, [(":block/title", q("Wight")), (":logseq.property/created-from-property", "51")])
        m.add(42, [(":logseq.property/value", "2001"), (":logseq.property/created-from-property", "52")])
        m.add(44, [(":logseq.property/value", "80"), (":logseq.property/created-from-property", "53")])
        m.add(45, [(":logseq.property/value", "82"), (":logseq.property/created-from-property", "53")])
        m.add(29, [(":block/title", q("number")), (":logseq.property/built-in?", "true")])   // the value the order-list-type refers to
        // Blocks on the journal
        m.block(3, "met [[\(u(1))]] about [[\(u(4))]]", uuid: 3, page: journal, parent: journal, order: "a0")
        m.block(4, "child text", uuid: 4, page: journal, parent: 3, order: "a0", tags: [person],
                extra: [(":logseq.property/status", "\(todo)"), (":block/collapsed?", "true")])
        m.block(5, "see [[deadbeef-dead-beef-dead-beefdeadbeef]]", uuid: 5, page: journal, parent: journal, order: "a1")
        m.block(6, "recycled", uuid: 6, page: journal, parent: journal, order: "a2", extra: [(":logseq.property/deleted-at", "1790999999999")])
        m.block(7, "gone child", uuid: 7, page: journal, parent: 6, order: "a0")
        m.block(8, "Dish\nserves:: 4", uuid: 8, page: journal, parent: journal, order: "a3",
                extra: [(":user.property/serves-x", "40"), (":user.property/author-x", "41")])
        m.block(9, "", uuid: 9, page: journal, parent: journal, order: "a4",
                extra: [(":user.property/year-x", "42"), (":user.property/mood-x", "44"), (":user.property/mood-x", "45")])
        m.block(10, "let x = 1", uuid: 10, page: journal, parent: journal, order: "a5", tags: [person],
                extra: [(":logseq.property.code/lang", q("swift")), (":logseq.property.node/display-type", ":code")])
        m.block(11, "Section", uuid: 11, page: journal, parent: journal, order: "a6", extra: [(":logseq.property/heading", "2")])
        m.block(12, "quoted", uuid: 12, page: journal, parent: journal, order: "a7", tags: [quoteClass])
        m.block(19, "second", uuid: 19, page: journal, parent: journal, order: "a75", extra: [(":logseq.property.node/display-type", ":quote")])
        m.block(120, "", uuid: 20, page: journal, parent: journal, order: "b3",
                extra: [(":block/link", "3"), (":logseq.property/status", "\(todo)")])        // a checklist item that is just a block reference
        for (e, n, key) in [(21, "one", "b4"), (22, "two", "b5"), (23, "three", "b6"), (24, "plain", "b7"), (25, "again", "b8")] {
            m.block(100 + e, n, uuid: e, page: journal, parent: journal, order: key,
                    extra: e == 24 ? [] : [(":logseq.property/order-list-type", "29")])
        }
        m.block(13, "front?", uuid: 13, page: journal, parent: journal, order: "a8", tags: [cardClass],
                extra: [(":logseq.property.fsrs/due", "1790870579556"),
                        (":logseq.property.fsrs/state", "{:lapses 2 :stability 0.6 :difficulty 5.87 :last-repeat 1790870279556 :reps 3 :state :learning :logseq/last-rating :again :elapsed-days 4 :scheduled-days 0}")])
        m.block(14, "![alt](../assets/\(u(90)).png) and ![gone](../assets/\(u(91)).png)", uuid: 14, page: journal, parent: journal, order: "a9")
        m.block(80 + 10, "pic", uuid: 90, page: journal, parent: journal, order: "b0",
                extra: [(":logseq.property.asset/checksum", q("abc")), (":logseq.property.asset/type", q("png"))])
        // A property definition page that also holds the user's own notes
        m.add(54, [(":db/ident", ":user.property/emotions-x"), (":block/name", q("emotions")), (":block/title", q("emotions")),
                   (":logseq.property/type", ":default"), (":block/uuid", "#uuid \(q(u(54)))")])
        m.block(17, "be mindful", uuid: 17, page: 54, parent: 54, order: "a0")
        // A page in the recycle bin that a live block still links to
        m.add(95, [(":block/name", q("old idea")), (":block/title", q("Old idea")), (":block/uuid", "#uuid \(q(u(95)))"),
                   (":logseq.property/deleted-at", "1790999999999")])
        m.block(16, "was [[\(u(95))]]", uuid: 16, page: journal, parent: journal, order: "b1")
        m.block(18, "[[\(u(90))]]", uuid: 18, page: journal, parent: journal, order: "b2")   // an embedded image
        // Blocks on Rob, and on the duplicate "Rob" page
        m.block(15, "first on rob", uuid: 15, page: rob, parent: rob, order: "a5")
        m.block(61, "from dup", uuid: 61, page: 60, parent: 60, order: "a7")
        // Favorites
        m.add(favorites, [(":block/name", q("$$$favorites")), (":block/title", q("$$$favorites"))])
        m.block(71, "", uuid: 71, page: favorites, parent: favorites, order: "a1", extra: [(":block/link", "\(journal)")])
        m.block(72, "", uuid: 72, page: favorites, parent: favorites, order: "a0", extra: [(":block/link", "\(rob)")])
        return m
    }
}

func importMini(_ m: MiniExport, assets: URL? = nil) throws -> (Graph, ImportReport) {
    let g = try makeGraph()
    let report = try LogseqImporter.importGraph(datoms: try Datoms(exportText: m.text), assetsFolder: assets, into: g)
    return (g, report)
}

func assetsFolder(withFileFor uuid: String, ext: String, bytes: String) throws -> URL {
    let dir = tempFolder(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(bytes.utf8).write(to: dir.appendingPathComponent("\(uuid).\(ext)"))
    return dir
}

@Suite struct LogseqImportTests {
    @Test func cardSchedulesAreImported() throws {
        let (g, r) = try importMini(.standard())
        #expect(r.cards == 1)
        let c = try g.card(blockID: MiniExport.u(13))!
        #expect(c.front == "front?")
        let s = c.state!
        #expect(s.due == 1790870579556 && s.lapses == 2 && s.reps == 3 && s.phase == .learning && s.lastReview == 1790870279556)
        #expect(abs(s.stability - 0.6) < 1e-9 && abs(s.difficulty - 5.87) < 1e-9)
        #expect(try g.reviewCount(blockID: MiniExport.u(13)) == 1)
        #expect(!r.warnings.contains { $0.contains("card review") })
    }

    @Test func mapsPagesJournalsAndBlocks() throws {
        let (g, r) = try importMini(.standard())
        #expect(r.journals == 1)
        let journal = try g.db.read { try Page.fetchOne($0, key: JournalDate(iso: "2026-10-05")!.pageID) }
        #expect(journal?.title == "2026-10-05 Monday" && journal?.kind == .journal && journal?.journalDate == "2026-10-05")
        let rob = try g.page(titled: "rob")!
        #expect(rob.id == Graph.pageID(forTitle: "Rob"))
        let b4 = try g.db.read { try Block.fetchOne($0, key: MiniExport.u(4)) }
        #expect(b4?.parentId == MiniExport.u(3) && b4?.pageId == journal?.id && b4?.orderKey == "a0" && b4?.author == .import)
        #expect(try g.db.read { try Block.fetchOne($0, key: MiniExport.u(3))?.parentId } == nil)
    }

    @Test func resolvesPageAndBlockReferences() throws {
        let (g, _) = try importMini(.standard())
        #expect(try g.text(MiniExport.u(3)) == "met [[Rob]] about ((\(MiniExport.u(4))))")
        #expect(try g.count("SELECT COUNT(*) FROM links WHERE from_block = ? AND to_block = ?", [MiniExport.u(3), MiniExport.u(4)]) == 1)
    }

    @Test func unresolvedReferencesAreReportedNotFatal() throws {
        let (g, r) = try importMini(.standard())
        #expect(r.unresolvedReferences == ["deadbeef-dead-beef-dead-beefdeadbeef"])
        #expect(try g.text(MiniExport.u(5)) == "see deadbeef-dead-beef-dead-beefdeadbeef")
        #expect(try g.page(titled: "deadbeef-dead-beef-dead-beefdeadbeef") == nil)   // no junk page from a dead link
    }

    @Test func referencesToRecycledPagesUseTheirTitleAndWarn() throws {
        let (g, r) = try importMini(.standard())
        #expect(try g.text(MiniExport.u(16)) == "was [[Old idea]]")
        #expect(r.warnings.contains("a block links to the deleted page 'Old idea'"))
        #expect(!r.unresolvedReferences.contains(MiniExport.u(95)))
    }

    @Test func propertyPagesWithContentAreImportedEmptyOnesAreNot() throws {
        let (g, _) = try importMini(.standard())
        let emotions = try g.page(titled: "emotions")
        let texts = try emotions.map { try g.tree(pageID: $0.id).map(\.block.text) }
        #expect(texts == ["be mindful"])
        #expect(try g.page(titled: "serves") == nil)
    }

    @Test func statusBecomesTaskMarkerAndCollapsedIsKept() throws {
        let (g, r) = try importMini(.standard())
        #expect(try g.text(MiniExport.u(4)) == "TODO child text #person")
        #expect(try g.db.read { try Block.fetchOne($0, key: MiniExport.u(4))?.collapsed } == true)
        #expect(r.tasks == 2)
    }

    @Test func userClassTagsBecomeHashtagsAndPageTags() throws {
        let (g, _) = try importMini(.standard())
        #expect(try g.count("SELECT COUNT(*) FROM block_tags bt JOIN tags t ON t.id = bt.tag_id WHERE bt.block_id = ? AND t.name_lower = 'person'", [MiniExport.u(4)]) == 1)
        let rob = try g.page(titled: "Rob")!
        let first = try g.tree(pageID: rob.id)[0].block
        #expect(first.text == "serves:: 8\nauthor:: Wight\ntags:: [[person]]")   // the duplicate page's extra property and tags are merged in
        #expect(try g.blocks(taggedWith: "person").map(\.id).contains(first.id))
        #expect(try g.tree(pageID: rob.id).map(\.block.text).contains("first on rob"))
    }

    @Test func valuePropertiesAreMappedByType() throws {
        let (g, _) = try importMini(.standard())
        #expect(try g.text(MiniExport.u(9)) == "mood:: [[Calm]], [[Tired]]\nyear:: 2001")
        #expect(try g.count("SELECT COUNT(*) FROM properties WHERE key = 'mood' AND type = 'page' AND cardinality = 'many'") == 1)
        #expect(try g.count("SELECT COUNT(*) FROM properties WHERE key = 'year' AND type = 'number'") == 1)
    }

    @Test func existingPropertyLinesAreNotDuplicated() throws {
        let (g, _) = try importMini(.standard())
        #expect(try g.text(MiniExport.u(8)) == "Dish\nserves:: 4\nauthor:: Wight")
    }

    @Test func recycledBlocksAndDescendantsAreSkipped() throws {
        let (g, r) = try importMini(.standard())
        #expect(try g.text(MiniExport.u(6)) == nil && g.text(MiniExport.u(7)) == nil)
        #expect(r.skippedRecycled == 2)
    }

    @Test func favoritesKeepOrder() throws {
        let (g, r) = try importMini(.standard())
        #expect(try g.favorites().map(\.title) == ["Rob", "2026-10-05 Monday"])
        #expect(r.favorites == 2)
    }

    @Test func assetsAreHashedAndReferencesRewritten() throws {
        let dir = try assetsFolder(withFileFor: MiniExport.u(90), ext: "png", bytes: "hello")
        let (g, r) = try importMini(.standard(), assets: dir)
        let hash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        #expect(try g.text(MiniExport.u(90)) == "![pic](assets/\(hash).png)")
        #expect(try g.text(MiniExport.u(18)) == "![pic](assets/\(hash).png)")      // a block that embeds the asset
        #expect(try g.text(MiniExport.u(14)) == "![alt](assets/\(hash).png) and ![gone](../assets/\(MiniExport.u(91)).png)")
        #expect(FileManager.default.fileExists(atPath: g.folder.appendingPathComponent("assets/\(hash).png").path))
        #expect(r.assets == 1 && r.missingAssetFiles == ["\(MiniExport.u(91)).png"])
    }

    @Test func embeddedAssetWithoutFileIsReportedMissing() throws {
        let (g, r) = try importMini(.standard())
        #expect(try g.text(MiniExport.u(18)) == "![pic](assets/\(MiniExport.u(90)).png)")
        #expect(r.missingAssetFiles.contains("\(MiniExport.u(90)).png"))
    }

    @Test func linkOnlyBlocksKeepTheirTarget() throws {
        let (g, _) = try importMini(.standard())
        #expect(try g.text(MiniExport.u(20)) == "TODO ((\(MiniExport.u(3))))")
    }

    @Test func numberedListsAreNumberedPerRun() throws {
        let (g, _) = try importMini(.standard())
        #expect(try ["21", "22", "23", "24", "25"].map { try g.text(MiniExport.u(Int($0)!)) } == ["1. one", "2. two", "3. three", "plain", "1. again"])
    }

    @Test func unsupportedFeaturesAreCountedNotSilentlyDropped() throws {
        let (_, r) = try importMini(.standard())
        #expect(r.warnings.contains("aliases are not imported (1 page)"))
    }

    @Test func unsafeAssetNamesAreIgnored() throws {
        let outer = tempFolder(); let assets = outer.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outer.appendingPathComponent("evil.txt"))
        var m = MiniExport()
        m.page(1, "Home", uuid: 1)
        m.add(5, [(":block/title", MiniExport.q("x")), (":block/uuid", "#uuid \"../evil\""), (":block/page", "1"), (":block/parent", "1"),
                  (":logseq.property.asset/checksum", "\"abc\""), (":logseq.property.asset/type", "\"txt\"")])
        let (g, r) = try importMini(m, assets: assets)
        #expect(r.assets == 0 && !r.warnings.filter { $0.contains("unsafe asset") }.isEmpty)
        #expect(try g.count("SELECT COUNT(*) FROM assets") == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: g.folder.appendingPathComponent("assets").path).isEmpty)
    }

    @Test func duplicateTitlesMergeAndAreReported() throws {
        let (g, r) = try importMini(.standard())
        #expect(r.mergedDuplicatePages == 1)
        #expect(r.warnings.contains("merged 2 pages titled 'Rob'"))
        #expect(try g.count("SELECT COUNT(*) FROM pages WHERE title_lower = 'rob'") == 1)
        let rob = try g.page(titled: "Rob")!
        #expect(try g.tree(pageID: rob.id).map(\.block.text).contains("from dup"))
    }

    @Test func headingCodeQuoteAndCardMapping() throws {
        let (g, _) = try importMini(.standard())
        #expect(try g.text(MiniExport.u(11)) == "## Section")
        #expect(try g.text(MiniExport.u(10)) == "```swift\nlet x = 1\n```\n#person")
        #expect(try g.text(MiniExport.u(12)) == "> quoted")
        #expect(try g.text(MiniExport.u(19)) == "> second")
        #expect(try g.text(MiniExport.u(13)) == "front? #card")
    }

    @Test func importKeepsTimestampsUuidsAndOrderKeys() throws {
        let (g, _) = try importMini(.standard())
        let b = try g.db.read { try Block.fetchOne($0, key: MiniExport.u(3)) }
        #expect(b?.createdAt == 17900000003 && b?.updatedAt == 17900000013 && b?.orderKey == "a0")
        let ops = try g.db.read { try Row.fetchAll($0, sql: "SELECT kind, author, inverse FROM ops") }
        #expect(ops.count == 1 && ops[0]["kind"] as String == "import" && ops[0]["author"] as String == "import")
    }

    @Test func importedGraphReindexesIdentically() throws {
        let (g, _) = try importMini(.standard())
        func snapshot() throws -> [String] {
            try g.db.read { db in
                var rows: [String] = []
                for sql in ["SELECT from_block||'|'||IFNULL(to_page,'')||'|'||IFNULL(to_block,'')||'|'||kind FROM links",
                            "SELECT block_id||'|'||tag_id FROM block_tags",
                            "SELECT owner_id||'|'||owner_kind||'|'||property_id||'|'||value||'|'||position FROM block_props",
                            "SELECT owner_id||'|'||owner_kind||'|'||text FROM search"] {
                    rows += try String.fetchAll(db, sql: sql).sorted(); rows.append("--")
                }
                return rows
            }
        }
        let before = try snapshot()
        try g.reindex()
        #expect(try snapshot() == before)
    }

    @Test func importRefusesNonEmptyGraph() throws {
        let g = try graphWithHome()
        #expect(throws: ImportError.graphNotEmpty) {
            try LogseqImporter.importGraph(datoms: try Datoms(exportText: MiniExport.standard().text), assetsFolder: nil, into: g)
        }
    }

    @Test func dryRunLeavesNoGraphBehind() throws {
        let report = try LogseqImporter.dryRun(datoms: try Datoms(exportText: MiniExport.standard().text), assetsFolder: nil)
        #expect(report.journals == 1 && report.blocks > 5)
    }
}

import Foundation
import GRDB
import Testing
@testable import GrimoireCore

// Runs against a real export when it exists (release builds only: parsing 11 MB in debug is slow).
//   swift test -c release -Xswiftc -enable-testing --package-path Core --filter RealGraphImportTests
#if !DEBUG
private let realExport = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Grimoire/import/logseq-export.edn")
private let realAssets = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("logseq/graphs/personal/assets")

@Suite(.serialized, .enabled(if: FileManager.default.fileExists(atPath: realExport.path))) struct RealGraphImportTests {
    static let result: (Graph, ImportReport) = {
        let datoms = try! Datoms(exportText: try! String(contentsOf: realExport, encoding: .utf8))
        let g = try! makeGraph()
        let r = try! LogseqImporter.importGraph(datoms: datoms, assetsFolder: realAssets, into: g)
        return (g, r)
    }()

    @Test func nothingUnresolvedAndEveryAssetIsEmbedded() throws {
        let (g, r) = Self.result
        #expect(r.unresolvedReferences.isEmpty && r.missingAssetFiles.isEmpty, "\(r)")
        #expect(r.assets == 54)
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE text LIKE '%](assets/%'") >= r.assets)
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE text GLOB '*\\[\\[[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*'") == 0)
        #expect(try g.count("SELECT COUNT(*) FROM links l WHERE l.kind = 'block' AND NOT EXISTS (SELECT 1 FROM blocks b WHERE b.id = l.to_block)") == 0)
    }

    @Test func formattingAndLinkOnlyBlocksSurvive() throws {
        let (g, r) = Self.result
        // 22 checklist items were bare TODO/DONE before link-only blocks kept their target; 4 genuinely empty tasks remain in the source.
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE text IN ('TODO','DOING','DONE')") <= 6, "checklist items that only link elsewhere must keep their target")
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE text LIKE '```%'") >= 20)
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE text LIKE '> %'") >= 3)
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE text GLOB '[0-9]. *' OR text GLOB '[0-9][0-9]. *'") >= 50)
        #expect(!r.warnings.isEmpty)
    }

    @Test func contentSurvives() throws {
        let (g, r) = Self.result
        #expect(r.journals > 1000 && r.blocks > 25_000 && r.favorites == 7)
        #expect(try g.count("SELECT COUNT(*) FROM block_tags bt JOIN tags t ON t.id = bt.tag_id WHERE t.name_lower = 'card'") >= 250)
        #expect(try g.page(titled: "designing data-intensive applications") != nil)
        #expect(try g.favorites().count == 7)
        #expect(try g.count("SELECT COUNT(*) FROM blocks WHERE text LIKE 'TODO %'") > 800)
    }

    @Test func budgetsHoldOnTheRealGraph() throws {
        let g = Self.result.0
        let ids = try g.db.read { try String.fetchAll($0, sql: "SELECT id FROM pages WHERE EXISTS (SELECT 1 FROM blocks WHERE page_id = pages.id)") }
        var rng = SeededGenerator(seed: 11)
        let open = try medianMillis(50) { _ in _ = try g.tree(pageID: ids.randomElement(using: &rng)!) }
        let search = try medianMillis(50) { i in _ = try g.search(["flour dough", "replic", "interview ques", "miles", "sourdough"][i % 5]) }
        let blockIDs = try g.db.read { try String.fetchAll($0, sql: "SELECT id FROM blocks ORDER BY RANDOM() LIMIT 100") }
        let edit = try medianMillis(100) { i in try g.perform([.editText(blockID: blockIDs[i], text: "edited \(i) [[Rob Gersch]] #card")], author: .me) }
        let cold = try medianMillis(5) { _ in _ = try Graph(folder: g.folder, device: "cold") }
        #expect(open < 50 && search < 30 && edit < 16 && cold < 150, "open \(open) ms, search \(search) ms, edit \(edit) ms, cold open \(cold) ms")
    }
}
#endif

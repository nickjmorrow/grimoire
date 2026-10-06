import Foundation
import GRDB
import Testing
@testable import GrimoireCore

@Suite struct MirrorExportTests {
    func focaccia() throws -> Graph {
        let g = try makeGraph()
        try page(g, "foc", "Focaccia")
        try g.add("b1", "type:: recipe\nserves:: 8", page: "foc", key: "a")
        try g.add("b2", "Dough", page: "foc", key: "b")
        try g.perform([.setCollapsed(blockID: "b2", collapsed: true)], author: .me)
        try g.add("6721b0c4-1111-4222-8333-944455556666", "mix flour\nthen water", page: "foc", parent: "b2", key: "a")
        try g.add("b4", "rest", page: "foc", parent: "b2", key: "b")
        try g.add("b5", "Bake", page: "foc", key: "c")
        try page(g, "home", "Home")
        try g.add("other", "see ((6721b0c4-1111-4222-8333-944455556666))", page: "home", key: "x")
        return g
    }

    @Test func renderMatchesGolden() throws {
        let g = try focaccia()
        let p = try g.page(titled: "Focaccia")!
        let md = MarkdownMirror.render(page: p, tree: try g.tree(pageID: "foc"),
                                       referencedBlockIDs: ["6721b0c4-1111-4222-8333-944455556666"])
        #expect(md == """
        type:: recipe
        serves:: 8

        - Dough
          collapsed:: true
          - mix flour
            then water
            id:: 6721b0c4-1111-4222-8333-944455556666
          - rest
        - Bake

        """)
    }

    @Test func pathsFollowLogseqConvention() throws {
        func p(_ title: String, kind: PageKind = .page, date: String? = nil) -> Page {
            Page(id: "x", title: title, titleLower: title.lowercased(), kind: kind, journalDate: date, favorite: false,
                 favoriteOrder: nil, createdAt: 0, updatedAt: 0)
        }
        #expect(MarkdownMirror.relativePath(for: p("a/b: c")) == "pages/a___b%3A c.md")
        #expect(MarkdownMirror.relativePath(for: p("2026-10-05 Monday", kind: .journal, date: "2026-10-05")) == "journals/2026-10-05.md")
    }

    @Test func writeMirrorIsAtomicAndFollowsRenameAndDelete() throws {
        let g = try focaccia()
        func file(_ rel: String) -> String? { try? String(contentsOf: g.folder.appendingPathComponent("mirror/\(rel)"), encoding: .utf8) }
        try g.writeMirror(pageID: "foc")
        #expect(file("pages/Focaccia.md")?.contains("- Bake") == true)
        #expect(file("pages/Focaccia.md")?.contains("id:: 6721b0c4-1111-4222-8333-944455556666") == true)  // referenced from Home
        try g.perform([.editText(blockID: "b5", text: "Bake 25 min")], author: .me)
        try g.writeMirror(pageID: "foc")
        #expect(file("pages/Focaccia.md")?.contains("- Bake 25 min") == true)
        try g.perform([.renamePage(id: "foc", title: "Schiacciata")], author: .me)
        try g.writeMirror(pageID: "foc")
        #expect(file("pages/Focaccia.md") == nil && file("pages/Schiacciata.md") != nil)
        try g.perform([.deletePage(id: "foc")], author: .me)
        try g.writeMirror(pageID: "foc")
        #expect(file("pages/Schiacciata.md") == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: g.folder.appendingPathComponent("mirror/pages").path)
        #expect(leftovers.filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func writeMirrorAllSkipsEmptyPagesAndCleansUp() throws {
        let g = try focaccia()
        try g.writeMirrorAll()
        let names = try FileManager.default.contentsOfDirectory(atPath: g.folder.appendingPathComponent("mirror/pages").path).sorted()
        #expect(names == ["Focaccia.md", "Home.md"])
    }

    @Test func exportJSONRoundTripsCounts() throws {
        let g = try focaccia()
        let url = tempFolder().appendingPathExtension("json")
        try g.exportJSON(to: url)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(obj["version"] as? Int == 1)
        for (key, table) in [("pages", "pages"), ("blocks", "blocks"), ("tags", "tags"), ("properties", "properties"),
                             ("blockProps", "block_props"), ("assets", "assets")] {
            #expect((obj[key] as? [Any])?.count == (try g.count("SELECT COUNT(*) FROM \(table)")), "\(key)")
        }
    }
}

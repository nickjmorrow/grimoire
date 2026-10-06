import Foundation
import Testing

let miniExport = #"""
{:logseq.db.sqlite.export/graph-format :datoms
 :datoms [[1 :block/name "rob"] [1 :block/title "Rob"] [1 :block/uuid #uuid "00000000-0000-4000-8000-000000000001"]
          [2 :block/name "2026-10-05"] [2 :block/title "Oct 5th, 2026"] [2 :block/journal-day 20261005]
          [2 :block/uuid #uuid "00000000-0000-4000-8000-000000000002"]
          [3 :block/title "met [[00000000-0000-4000-8000-000000000001]]"] [3 :block/page 2] [3 :block/parent 2]
          [3 :block/order "a0"] [3 :block/uuid #uuid "00000000-0000-4000-8000-000000000003"]]}
"""#

func writeMini() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mini-\(UUID().uuidString).edn")
    try Data(miniExport.utf8).write(to: url)
    return url
}

@Suite struct ImportTests {
    @Test func dryRunLeavesGraphUntouched() throws {
        let g = tempGraph(), file = try writeMini()
        let r = try grim(["import-logseq", file.path, "--dry-run", "--json"], graph: g)
        #expect(r.code == 0, "\(r.err)")
        let report = try json(r) as! [String: Any]
        #expect(report["journals"] as? Int == 1 && report["blocks"] as? Int == 1)
        #expect(!FileManager.default.fileExists(atPath: g.path))
    }

    @Test func importFillsGraphAndMirrorsIt() throws {
        let g = tempGraph(), file = try writeMini()
        #expect(try grim(["import-logseq", file.path], graph: g).code == 0)
        let page = try json(try grim(["today", "--json"], graph: g))
        _ = page
        let hits = try json(try grim(["search", "met", "--json"], graph: g)) as! [[String: Any]]
        #expect(hits.contains { ($0["snippet"] as? String)?.contains("[[Rob]]") == true || ($0["snippet"] as? String)?.contains("Rob") == true })
        let mirror = try FileManager.default.contentsOfDirectory(atPath: g.appendingPathComponent("mirror/journals").path)
        #expect(mirror == ["2026-10-05.md"])
    }

    @Test func importRefusesNonEmptyGraph() throws {
        let g = tempGraph(), file = try writeMini()
        #expect(try grim(["import-logseq", file.path], graph: g).code == 0)
        #expect(try grim(["import-logseq", file.path], graph: g).code == 3)
    }

    @Test func missingOrWrongFileExitCodes() throws {
        let g = tempGraph()
        #expect(try grim(["import-logseq", "/nonexistent.edn", "--dry-run"], graph: g).code == 2)
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).edn")
        try Data("{:foo 1}".utf8).write(to: bad)
        #expect(try grim(["import-logseq", bad.path, "--dry-run"], graph: g).code == 1)
    }
}

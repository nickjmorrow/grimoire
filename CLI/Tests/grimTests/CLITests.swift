import Foundation
import Testing

struct Result { var code: Int32; var out: String; var err: String }

let grimBinary: URL = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for rel in [".build/debug/grim", ".build/arm64-apple-macosx/debug/grim"] {
        let u = root.appendingPathComponent(rel)
        if FileManager.default.isExecutableFile(atPath: u.path) { return u }
    }
    return root.appendingPathComponent(".build/debug/grim")
}()

func grim(_ args: [String], graph: URL) throws -> Result {
    let p = Process()
    p.executableURL = grimBinary
    p.arguments = args + ["--graph", graph.path]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Result(code: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
}

func json(_ r: Result) throws -> Any { try JSONSerialization.jsonObject(with: Data(r.out.utf8)) }
func tempGraph() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("grim-cli-\(UUID().uuidString)") }

@Suite struct CLITests {
    @Test func todayBeforeAnythingIsWrittenIsNullNotAnError() throws {
        let g = tempGraph()
        let r = try grim(["today", "--json"], graph: g)
        #expect(r.code == 0)
        #expect((try json(r) as! [String: Any])["page"] is NSNull)
    }

    @Test func appendTodayCreatesJournalAndNestedBlocks() throws {
        let g = tempGraph()
        let a = try grim(["append", "today", "- a\n  - b", "--json"], graph: g)
        #expect(a.code == 0, "\(a.err)")
        let t = try json(try grim(["today", "--json"], graph: g)) as! [String: Any]
        let blocks = t["blocks"] as! [[String: Any]]
        #expect(blocks.count == 1 && blocks[0]["text"] as? String == "a")
        let kids = blocks[0]["children"] as! [[String: Any]]
        #expect(kids.count == 1 && kids[0]["text"] as? String == "b")
        let q = try json(try grim(["query", "SELECT DISTINCT author FROM blocks", "--json"], graph: g)) as! [[String: Any]]
        #expect(q.map { $0["author"] as? String } == ["claude"])
    }

    @Test func searchJSONShape() throws {
        let g = tempGraph()
        _ = try grim(["append", "Focaccia", "- dough rests overnight"], graph: g)
        let hits = try json(try grim(["search", "overn", "--json"], graph: g)) as! [[String: Any]]
        #expect(hits.contains { ($0["pageId"] as? String) != nil && ($0["blockId"] as? String) != nil && ($0["snippet"] as? String)?.contains("overnight") == true })
    }

    @Test func renameExitCode3OnConflict() throws {
        let g = tempGraph()
        _ = try grim(["create-page", "A"], graph: g)
        _ = try grim(["create-page", "B"], graph: g)
        #expect(try grim(["rename-page", "A", "b"], graph: g).code == 3)
        #expect(try grim(["rename-page", "Nope", "C"], graph: g).code == 2)
        #expect(try grim(["rename-page", "A", "C"], graph: g).code == 0)
    }

    @Test func queryRejectsWrite() throws {
        let g = tempGraph()
        _ = try grim(["create-page", "A"], graph: g)
        #expect(try grim(["query", "DELETE FROM pages"], graph: g).code == 4)
        let n = try json(try grim(["query", "SELECT COUNT(*) AS n FROM pages", "--json"], graph: g)) as! [[String: Any]]
        #expect(n[0]["n"] as? String == "1")
    }

    @Test func undoClaudeRevertsLastAppend() throws {
        let g = tempGraph()
        _ = try grim(["append", "Home", "- first"], graph: g)
        _ = try grim(["append", "Home", "- second"], graph: g)
        let u = try json(try grim(["undo", "--json"], graph: g)) as! [String: Any]
        #expect(u["undone"] as? Int == 1)
        let page = try json(try grim(["page", "Home", "--json"], graph: g)) as! [String: Any]
        #expect((page["blocks"] as! [[String: Any]]).map { $0["text"] as? String } == ["first"])
    }

    @Test func mirrorFileWrittenOnWrite() throws {
        let g = tempGraph()
        _ = try grim(["append", "today", "- a\n  - b"], graph: g)
        let mirror = try FileManager.default.contentsOfDirectory(atPath: g.appendingPathComponent("mirror/journals").path)
        #expect(mirror.count == 1)
        let text = try String(contentsOf: g.appendingPathComponent("mirror/journals/\(mirror[0])"), encoding: .utf8)
        #expect(text.contains("- a\n  - b"))
    }

    @Test func insertAfterAndMoveAndDelete() throws {
        let g = tempGraph()
        let a = try json(try grim(["append", "Home", "- one\n- three", "--json"], graph: g)) as! [String: Any]
        let ids = a["blockIds"] as! [String]
        let ins = try grim(["insert", "--after", ids[0], "two", "--json"], graph: g)
        #expect(ins.code == 0, "\(ins.err)")
        func texts() throws -> [String] {
            let page = try json(try grim(["page", "Home", "--json"], graph: g)) as! [String: Any]
            return (page["blocks"] as! [[String: Any]]).map { $0["text"] as! String }
        }
        #expect(try texts() == ["one", "two", "three"])
        #expect(try grim(["delete", ids[1]], graph: g).code == 0)
        #expect(try texts() == ["one", "two"])
        #expect(try grim(["edit", ids[0], "uno"], graph: g).code == 0)
        #expect(try texts() == ["uno", "two"])
    }

    @Test func multiBlockAppendUndoesAsOneChange() throws {
        let g = tempGraph()
        _ = try grim(["append", "Plan", "- a\n- b\n- c"], graph: g)
        let u = try json(try grim(["undo", "--json"], graph: g)) as! [String: Any]
        #expect(u["undone"] as? Int == 1)
        let n = try json(try grim(["query", "SELECT COUNT(*) AS n FROM blocks", "--json"], graph: g)) as! [[String: Any]]
        #expect(n[0]["n"] as? String == "0")
    }

    @Test func changesShowsEveryoneUnlessAuthorGiven() throws {
        let g = tempGraph()
        let a = try json(try grim(["append", "Home", "- one", "--json"], graph: g)) as! [String: Any]
        let id = (a["blockIds"] as! [String])[0]
        _ = try grim(["edit", id, "uno", "--author", "me"], graph: g)
        let all = try json(try grim(["changes", "--since", "1h", "--json"], graph: g)) as! [[String: Any]]
        #expect(Set(all.compactMap { $0["author"] as? String }) == ["claude", "me"])
        let mine = try json(try grim(["changes", "--since", "1h", "--author", "me", "--json"], graph: g)) as! [[String: Any]]
        #expect(Set(mine.compactMap { $0["author"] as? String }) == ["me"])
    }

    @Test func createPageAndLinkedPageShareOneID() throws {
        let linked = tempGraph(), created = tempGraph()
        _ = try grim(["append", "Home", "- met [[Rob]]"], graph: linked)
        _ = try grim(["create-page", "Rob"], graph: created)
        func robID(_ g: URL) throws -> String? {
            let q = try json(try grim(["query", "SELECT id FROM pages WHERE title_lower = 'rob'", "--json"], graph: g)) as! [[String: Any]]
            return q.first?["id"] as? String
        }
        #expect(try robID(linked) != nil && robID(linked) == robID(created))
    }

    @Test func renameUpdatesMirrorOfPagesThatLinkToIt() throws {
        let g = tempGraph()
        _ = try grim(["append", "Other", "- see [[Old]]"], graph: g)
        #expect(try grim(["rename-page", "Old", "New"], graph: g).code == 0)
        let text = try String(contentsOf: g.appendingPathComponent("mirror/pages/Other.md"), encoding: .utf8)
        #expect(text.contains("[[New]]") && !text.contains("[[Old]]"))
    }
}

@Suite struct BackupCLITests {
    @Test func backupWritesACopyThatOpensAsAGraph() throws {
        let g = tempGraph(), dest = tempGraph()
        _ = try grim(["append", "today", "- remember the stock", "--json"], graph: g)
        let r = try grim(["backup", dest.path, "--json"], graph: g)
        #expect(r.code == 0)
        let path = (try json(r) as! [String: Any])["path"] as! String
        #expect(path.hasPrefix(dest.path) && path.hasSuffix(".sqlite"))
        // the copy is a whole graph: put it where grim looks and read it back
        let restored = tempGraph()
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: restored.appendingPathComponent("graph.sqlite"))
        let s = try grim(["search", "stock", "--json"], graph: restored)
        #expect(s.code == 0 && s.out.contains("remember the [stock]"))
    }
}

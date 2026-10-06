import Foundation
import Testing

@Suite(.serialized) struct SyncCLITests {
    @Test func twoGraphsSyncThroughARealServer() throws {
        let root = grimBinary.deletingLastPathComponent()
        let server = root.appendingPathComponent("grim-sync")
        guard FileManager.default.isExecutableFile(atPath: server.path) else { Issue.record("build grim-sync first"); return }
        let tokens = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString).json")
        try Data(#"{"ta":"alpha","tb":"beta"}"#.utf8).write(to: tokens)
        let port = Int.random(in: 8800..<8990)
        let p = Process()
        p.executableURL = server
        p.arguments = ["--graph", tempGraph().path, "--tokens", tokens.path, "--port", String(port)]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 1.0)

        let a = tempGraph(), b = tempGraph()
        for (g, tok, dev) in [(a, "ta", "alpha"), (b, "tb", "beta")] {
            #expect(try grim(["sync-setup", "--url", "http://127.0.0.1:\(port)", "--token", tok, "--name", dev], graph: g).code == 0)
        }
        #expect(try grim(["append", "Shared", "- written on alpha"], graph: a).code == 0)
        let s1 = try grim(["sync", "--json"], graph: a)
        #expect(s1.code == 0, "\(s1.err)")
        let s2 = try grim(["sync", "--json"], graph: b)
        #expect(s2.code == 0, "\(s2.err)")
        let page = try grim(["page", "Shared"], graph: b)
        #expect(page.out.contains("written on alpha"))
        let status = try json(try grim(["sync-status", "--json"], graph: b)) as! [String: Any]
        #expect(status["pending"] as? Int == 0 && (status["lastSeq"] as? Int ?? 0) > 0)
        #expect(try grim(["sync"], graph: tempGraph()).code == 2)           // not set up
    }
}

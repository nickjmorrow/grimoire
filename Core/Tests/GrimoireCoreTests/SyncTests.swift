import CryptoKit
import Foundation
import GRDB
import Testing
@testable import GrimoireCore

/// Pages, blocks and favorites without timestamps: what two converged devices must agree on.
func syncState(_ g: Graph) throws -> [String] {
    try g.db.read { db in
        let pages = try Row.fetchAll(db, sql: "SELECT id, title, kind, favorite FROM pages ORDER BY id").map { "P \($0["id"] as String)|\($0["title"] as String)|\($0["kind"] as String)|\($0["favorite"] as Int)" }
        let blocks = try Row.fetchAll(db, sql: "SELECT id, page_id, parent_id, order_key, text, collapsed FROM blocks ORDER BY id").map {
            "B \($0["id"] as String)|\($0["page_id"] as String)|\($0["parent_id"] as String? ?? "-")|\($0["order_key"] as String)|\($0["text"] as String)|\($0["collapsed"] as Int)"
        }
        return pages + blocks
    }
}

struct Rig {
    let hub: SyncHub
    let transport: LocalTransport
    init() throws { hub = SyncHub(graph: try Graph(folder: tempFolder(), device: "hub")); transport = LocalTransport(hub: hub) }
    func device(_ name: String) throws -> (Graph, SyncClient) { let g = try Graph(folder: tempFolder(), device: name); return (g, SyncClient(graph: g)) }
}

@Suite struct SyncTests {
    @Test func aDeviceWritesAndAnotherReadsIt() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A"), (b, cb) = try rig.device("B")
        try a.perform([.createPage(id: "p", title: "Recipes", kind: .page, journalDate: nil),
                       .insertBlock(id: "b1", pageID: "p", parentID: nil, orderKey: "a", text: "focaccia")], author: .me)
        let r = try await ca.sync(using: rig.transport)
        #expect(r.pushed == 2); #expect(try ca.pendingCount() == 0)
        try await cb.sync(using: rig.transport)
        #expect(try syncState(b) == syncState(a))
        #expect(try syncState(rig.hub.graph) == syncState(a))
        #expect(try cb.lastSeq() == 2)
    }

    @Test func editsToDifferentBlocksBothSurvive() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A"), (b, cb) = try rig.device("B")
        try a.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil),
                       .insertBlock(id: "x", pageID: "p", parentID: nil, orderKey: "a", text: "x0"),
                       .insertBlock(id: "y", pageID: "p", parentID: nil, orderKey: "b", text: "y0")], author: .me)
        try await ca.sync(using: rig.transport); try await cb.sync(using: rig.transport)
        try a.perform([.editText(blockID: "x", text: "x-from-A")], author: .me)
        try b.perform([.editText(blockID: "y", text: "y-from-B")], author: .me)
        try await ca.sync(using: rig.transport); try await cb.sync(using: rig.transport); try await ca.sync(using: rig.transport)
        for g in [a, b, rig.hub.graph] { #expect(try g.text("x") == "x-from-A"); #expect(try g.text("y") == "y-from-B") }
        #expect(try syncState(a) == syncState(b))
    }

    @Test func concurrentEditsOfOneBlockKeepTheLoserAsAConflictSibling() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A"), (b, cb) = try rig.device("B")
        try a.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil), .insertBlock(id: "x", pageID: "p", parentID: nil, orderKey: "a", text: "base")], author: .me)
        try await ca.sync(using: rig.transport); try await cb.sync(using: rig.transport)
        try a.perform([.editText(blockID: "x", text: "A's version")], author: .me)
        try b.perform([.editText(blockID: "x", text: "B's version")], author: .me)
        try await ca.sync(using: rig.transport)                       // A is first
        let r = try await cb.sync(using: rig.transport)               // B rebases on top: B wins, A's text is kept beside it
        #expect(r.conflicts == 1)
        try await ca.sync(using: rig.transport)
        #expect(try a.text("x") == "B's version")
        let texts = try await a.db.read { try String.fetchAll($0, sql: "SELECT text FROM blocks WHERE page_id = 'p' ORDER BY order_key, id") }
        #expect(texts.count == 2 && texts[1].hasPrefix("A's version") && texts[1].contains("conflict::"))
        #expect(try syncState(a) == syncState(b)); #expect(try syncState(b) == syncState(rig.hub.graph))
    }

    @Test func aRemoteDeleteBeatsALocalEditWhichIsReportedNotLost() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A"), (b, cb) = try rig.device("B")
        try a.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil), .insertBlock(id: "x", pageID: "p", parentID: nil, orderKey: "a", text: "base")], author: .me)
        try await ca.sync(using: rig.transport); try await cb.sync(using: rig.transport)
        try a.perform([.deleteBlock(blockID: "x")], author: .me)
        try b.perform([.editText(blockID: "x", text: "edited")], author: .me)
        try await ca.sync(using: rig.transport); try await cb.sync(using: rig.transport)
        #expect(try b.text("x") == nil)
        #expect(try cb.issues().count == 1)
        #expect(try syncState(a) == syncState(b))
    }

    @Test func aMoveThatWouldMakeACycleIsRejectedAndBothConverge() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A"), (b, cb) = try rig.device("B")
        try a.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil),
                       .insertBlock(id: "P1", pageID: "p", parentID: nil, orderKey: "a", text: "one"),
                       .insertBlock(id: "Q1", pageID: "p", parentID: nil, orderKey: "b", text: "two")], author: .me)
        try await ca.sync(using: rig.transport); try await cb.sync(using: rig.transport)
        try a.perform([.moveBlock(blockID: "P1", pageID: "p", parentID: "Q1", orderKey: "a")], author: .me)
        try b.perform([.moveBlock(blockID: "Q1", pageID: "p", parentID: "P1", orderKey: "a")], author: .me)
        try await ca.sync(using: rig.transport); try await cb.sync(using: rig.transport); try await ca.sync(using: rig.transport)
        #expect(try syncState(a) == syncState(b)); #expect(try syncState(b) == syncState(rig.hub.graph))
        #expect(try cb.issues().count >= 1)
    }

    @Test func undoOnlyUndoesThisDevicesOwnOps() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A"), (b, cb) = try rig.device("B")
        try a.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil), .insertBlock(id: "x", pageID: "p", parentID: nil, orderKey: "a", text: "from A")], author: .me)
        try await ca.sync(using: rig.transport); try await cb.sync(using: rig.transport)
        #expect(try b.undo(count: 1) == 0)
        #expect(try b.text("x") == "from A")
        try b.perform([.insertBlock(id: "y", pageID: "p", parentID: nil, orderKey: "b", text: "from B")], author: .me)
        #expect(try b.undo(count: 5) == 1)
        #expect(try b.text("x") == "from A"); #expect(try b.text("y") == nil)
    }

    @Test func aRetriedPushDoesNotDuplicate() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A")
        try a.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil), .insertBlock(id: "x", pageID: "p", parentID: nil, orderKey: "a", text: "once")], author: .me)
        // the push reaches the hub but the answer is lost
        let ops = try await a.db.read { try Row.fetchAll($0, sql: "SELECT local_id, author, payload, created_at FROM ops ORDER BY local_id").map {
            OutgoingOp(localID: $0["local_id"], author: $0["author"], payload: $0["payload"], createdAt: $0["created_at"]) } }
        _ = try rig.hub.push(device: "A", base: 0, ops: ops)
        try await ca.sync(using: rig.transport)
        #expect(try rig.hub.head() == 2)
        #expect(try ca.pendingCount() == 0)
        #expect(try syncState(a) == syncState(rig.hub.graph))
        #expect(try a.count("SELECT COUNT(*) FROM blocks") == 1)
    }

    @Test func assetsTravelByHash() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A"), (b, cb) = try rig.device("B")
        let file = tempFolder().appendingPathExtension("txt")
        try Data("hello asset".utf8).write(to: file)
        let asset = try a.importAsset(from: file, author: .me)
        let r = try await ca.sync(using: rig.transport)
        #expect(r.assetsUp == 1)
        let rb = try await cb.sync(using: rig.transport)
        #expect(rb.assetsDown == 1)
        let copy = try FileManager.default.contentsOfDirectory(atPath: b.folder.appendingPathComponent("assets").path)
        #expect(copy.contains { $0.hasPrefix(asset.hash) })
    }

    @Test func opsMadeDirectlyOnTheHubAreSequencedAndReachDevices() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A")
        let onHub = try Graph(folder: rig.hub.graph.folder, device: "grim-on-hub")           // Claude's CLI on the hub machine
        try onHub.perform([.createPage(id: "p", title: "From hub", kind: .page, journalDate: nil), .insertBlock(id: "x", pageID: "p", parentID: nil, orderKey: "a", text: "hi")], author: .claude)
        try await ca.sync(using: rig.transport)
        #expect(try a.text("x") == "hi")
        try a.perform([.editText(blockID: "x", text: "hi back")], author: .me)
        try await ca.sync(using: rig.transport)
        #expect(try onHub.text("x") == "hi back")
    }

    @Test func differentProcessesOnOneGraphShareOneSyncIdentity() async throws {
        let rig = try Rig()
        let folder = tempFolder()
        let app = try Graph(folder: folder, device: "mac-app"), cli = try Graph(folder: folder, device: "cli-mac")
        try app.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil)], author: .me)
        try cli.perform([.insertBlock(id: "x", pageID: "p", parentID: nil, orderKey: "a", text: "by claude")], author: .claude)
        try await SyncClient(graph: app, deviceID: "mac").sync(using: rig.transport)
        #expect(try rig.hub.graph.text("x") == "by claude")
        #expect(try SyncClient(graph: cli, deviceID: "mac").pendingCount() == 0)
        let (b, cb) = try rig.device("B")
        try await cb.sync(using: rig.transport)
        #expect(try b.text("x") == "by claude")
    }

    @Test func aNewDeviceCatchesUpFromScratch() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A")
        try a.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil)], author: .me)
        for i in 0..<20 { try a.perform([.insertBlock(id: "b\(i)", pageID: "p", parentID: nil, orderKey: String(format: "a%02d", i), text: "t\(i)")], author: .me) }
        try await ca.sync(using: rig.transport)
        let (c, cc) = try rig.device("C")
        try await cc.sync(using: rig.transport)
        #expect(try syncState(c) == syncState(a))
    }
}

struct SplitMix: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
}

@Suite struct SyncConvergenceTests {
    func randomOp(_ g: Graph, _ rng: inout SplitMix, _ n: Int, _ dev: String) throws -> Op? {
        let pages = try g.db.read { try String.fetchAll($0, sql: "SELECT id FROM pages ORDER BY id") }
        let blocks = try g.db.read { try Row.fetchAll($0, sql: "SELECT id, page_id FROM blocks ORDER BY id").map { ($0["id"] as String, $0["page_id"] as String) } }
        if pages.isEmpty {
            return .createPage(id: "pg\(Int.random(in: 0..<5, using: &rng))", title: "Page \(Int.random(in: 0..<5, using: &rng))", kind: .page, journalDate: nil)
        }
        let roll = Int.random(in: 0..<10, using: &rng)
        switch roll {
        case 0:
            return .createPage(id: "pg\(Int.random(in: 0..<5, using: &rng))", title: "Page \(Int.random(in: 0..<5, using: &rng))", kind: .page, journalDate: nil)
        case 1, 2, 3:
            let page = pages.randomElement(using: &rng)!
            let parent = blocks.filter { $0.1 == page }.randomElement(using: &rng)?.0
            return .insertBlock(id: "\(dev)\(n)", pageID: page, parentID: Bool.random(using: &rng) ? parent : nil, orderKey: OrderKey.between(nil, nil) + String(Int.random(in: 0..<9, using: &rng)), text: "\(dev) says \(n)")
        case 4 where !blocks.isEmpty, 5 where !blocks.isEmpty:
            return .editText(blockID: blocks.randomElement(using: &rng)!.0, text: "\(dev) edit \(n)")
        case 6 where !blocks.isEmpty && Int.random(in: 0..<3, using: &rng) == 0:
            return .deleteBlock(blockID: blocks.randomElement(using: &rng)!.0)
        case 7 where blocks.count > 1:
            let b = blocks.randomElement(using: &rng)!, t = blocks.randomElement(using: &rng)!
            return .moveBlock(blockID: b.0, pageID: t.1, parentID: Bool.random(using: &rng) ? t.0 : nil, orderKey: "m\(Int.random(in: 0..<9, using: &rng))")
        case 8 where !blocks.isEmpty:
            return .setCollapsed(blockID: blocks.randomElement(using: &rng)!.0, collapsed: Bool.random(using: &rng))
        case 9:
            return .setFavorite(pageID: pages.randomElement(using: &rng)!, favorite: Bool.random(using: &rng), order: nil)
        default: return nil
        }
    }

    @Test(arguments: Array(1...60)) func threeDevicesAlwaysConverge(seed: Int) async throws {
        let rig = try Rig()
        var rng = SplitMix(s: UInt64(seed))
        let devices = try ["A", "B", "C"].map { try rig.device($0) }
        var step = 0
        for _ in 0..<140 {
            step += 1
            let i = Int.random(in: 0..<3, using: &rng)
            let name = ["A", "B", "C"][i]
            if Int.random(in: 0..<9, using: &rng) == 0 {
                try await devices[i].1.sync(using: rig.transport)
            } else if let op = try randomOp(devices[i].0, &rng, step, name) {
                _ = try? devices[i].0.perform([op], author: .me)           // an op that is invalid right now is simply not made
            }
        }
        for _ in 0..<3 { for d in devices { try await d.1.sync(using: rig.transport) } }
        let hubState = try syncState(rig.hub.graph)
        for (n, d) in devices.enumerated() {
            #expect(try d.1.pendingCount() == 0, "device \(n) still has pending ops (seed \(seed))")
            #expect(try syncState(d.0) == hubState, "device \(n) differs from the hub (seed \(seed))")
        }
    }
}

@Suite struct SyncReviewFixTests {
    /// A graph whose content did not come from replayable ops (an import).
    func importedGraph() throws -> Graph {
        let (g, _) = try importMini(.standard())
        return g
    }

    @Test func aGraphWithImportedHistoryBootstrapsAndKeepsLaterEdits() async throws {
        let rig = try Rig()
        let g = try importedGraph()
        let blocksBefore = try g.count("SELECT COUNT(*) FROM blocks")
        let pageBefore = try g.count("SELECT COUNT(*) FROM pages")
        let someBlock = try await g.db.read { try String.fetchOne($0, sql: "SELECT id FROM blocks WHERE text = 'first on rob'")! }
        try g.perform([.editText(blockID: someBlock, text: "edited after import")], author: .me)
        let c = SyncClient(graph: g, deviceID: "mac")
        let r = try await c.sync(using: rig.transport)
        #expect(r.rejected == 0)
        #expect(try rig.hub.graph.count("SELECT COUNT(*) FROM blocks") == blocksBefore)
        #expect(try rig.hub.graph.count("SELECT COUNT(*) FROM pages") == pageBefore)
        #expect(try rig.hub.graph.text(someBlock) == "edited after import")
        #expect(try g.text(someBlock) == "edited after import")
        #expect(try syncState(g) == syncState(rig.hub.graph))
        // a second device receives the same graph, including the favorites and the card schedule
        let (b, cb) = try rig.device("phone")
        try await cb.sync(using: rig.transport)
        #expect(try syncState(b) == syncState(g))
        #expect(try b.card(blockID: MiniExport.u(13))?.state?.lapses == 2)
    }

    @Test func importedHistoryCannotMergeIntoAHubThatAlreadyHasData() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A")
        try a.perform([.createPage(id: "p", title: "Existing", kind: .page, journalDate: nil)], author: .me)
        try await ca.sync(using: rig.transport)
        let g = try importedGraph()
        await #expect(throws: SyncError.needsReset) { try await SyncClient(graph: g, deviceID: "mac").sync(using: rig.transport) }
    }

    @Test func aRejectedOpIsDroppedOnceAndLaterGoodOpsStillGo() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A"), (b, cb) = try rig.device("B")
        try a.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil), .insertBlock(id: "x", pageID: "p", parentID: nil, orderKey: "a", text: "base")], author: .me)
        try await ca.sync(using: rig.transport); try await cb.sync(using: rig.transport)
        try a.perform([.deleteBlock(blockID: "x")], author: .me)
        try await ca.sync(using: rig.transport)
        // B edits the deleted block (hub will reject), then makes an unrelated good edit and adds a block
        try b.perform([.editText(blockID: "x", text: "doomed")], author: .me)
        try b.perform([.insertBlock(id: "y", pageID: "p", parentID: nil, orderKey: "b", text: "good")], author: .me)
        try await cb.sync(using: rig.transport)
        try await ca.sync(using: rig.transport)
        #expect(try syncState(a) == syncState(b)); #expect(try syncState(b) == syncState(rig.hub.graph))
        #expect(try b.text("y") == "good" && rig.hub.graph.text("y") == "good")
        // later activity on that block neither wedges sync nor resurrects stale state
        try b.perform([.editText(blockID: "y", text: "good, again")], author: .me)
        try await cb.sync(using: rig.transport); try await cb.sync(using: rig.transport)
        #expect(try rig.hub.graph.text("y") == "good, again" && b.text("y") == "good, again")
        #expect(try cb.pendingCount() == 0)
    }

    @Test func aReinstalledDeviceWithTheSameNameDoesNotLoseItsFirstOps() async throws {
        let rig = try Rig()
        let (a1, c1) = try rig.device("phone")
        try a1.perform([.createPage(id: "p", title: "First install", kind: .page, journalDate: nil)], author: .me)
        try await c1.sync(using: rig.transport)
        let (a2, c2) = try rig.device("phone")                      // fresh graph, same device name, local ids start over
        try await c2.sync(using: rig.transport)
        try a2.perform([.createPage(id: "q", title: "Second install", kind: .page, journalDate: nil)], author: .me)
        try await c2.sync(using: rig.transport)
        #expect(try rig.hub.graph.page(titled: "Second install") != nil)
        #expect(try syncState(a2) == syncState(rig.hub.graph))
    }

    @Test func aBigFirstPushGoesUpInChunks() async throws {
        let rig = try Rig()
        let (a, ca) = try rig.device("A")
        try a.perform([.createPage(id: "p", title: "Big", kind: .page, journalDate: nil)], author: .me)
        for i in 0..<(SyncClient.chunkSize * 2 + 30) { try a.perform([.insertBlock(id: "b\(i)", pageID: "p", parentID: nil, orderKey: String(format: "a%05d", i), text: "t\(i)")], author: .me) }
        let r = try await ca.sync(using: rig.transport)
        #expect(r.pushed == SyncClient.chunkSize * 2 + 31)
        #expect(try rig.hub.graph.count("SELECT COUNT(*) FROM blocks") == SyncClient.chunkSize * 2 + 30)
        #expect(try syncState(a) == syncState(rig.hub.graph))
    }

    @Test func assetsWithTheWrongHashAreRefused() throws {
        let rig = try Rig()
        #expect(throws: SyncError.self) { try rig.hub.putAsset(hash: String(repeating: "ab", count: 32), filename: nil, data: Data("not that hash".utf8)) }
        let good = Data("exact".utf8)
        let h = SHA256Hex.of(good)
        try rig.hub.putAsset(hash: h, filename: nil, data: good)
        #expect(rig.hub.assetURL(hash: h) != nil)
    }
}

enum SHA256Hex { static func of(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() } }

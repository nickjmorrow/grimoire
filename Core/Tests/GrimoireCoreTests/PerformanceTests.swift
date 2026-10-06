import Foundation
import GRDB
import Testing
@testable import GrimoireCore

// Budgets from the spec (§8), measured on a synthetic graph about twice the size of the real one.
// These only mean something in release mode:
//   swift test -c release -Xswiftc -enable-testing --package-path Core --filter PerformanceTests
#if !DEBUG
enum Shared {
    static let folder = tempFolder()
    static let graph: Graph = try! SyntheticGraph.build(in: folder, pages: 2000, blocksPerPage: 30, seed: 1)
    static let pageIDs: [String] = try! graph.db.read { try String.fetchAll($0, sql: "SELECT id FROM pages WHERE EXISTS (SELECT 1 FROM blocks WHERE page_id = pages.id)") }
}

func medianMillis(_ n: Int, _ body: (Int) throws -> Void) rethrows -> Double {
    var times: [Double] = []
    let clock = ContinuousClock()
    for i in 0..<n {
        let d = try clock.measure { try body(i) }
        times.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }
    return times.sorted()[n / 2]
}

@Suite(.serialized) struct PerformanceTests {
    @Test func openPageUnder50ms() throws {
        let g = Shared.graph
        var rng = SeededGenerator(seed: 2)
        let m = try medianMillis(50) { _ in _ = try g.tree(pageID: Shared.pageIDs.randomElement(using: &rng)!) }
        #expect(m < 50, "median \(m) ms")
    }

    @Test func searchUnder30ms() throws {
        let g = Shared.graph
        var rng = SeededGenerator(seed: 3)
        let v = SyntheticGraph.vocabulary
        let m = try medianMillis(50) { _ in
            _ = try g.search("\(v.randomElement(using: &rng)!) \(v.randomElement(using: &rng)!.prefix(4))")
        }
        #expect(m < 30, "median \(m) ms")
    }

    @Test func backlinksUnder50ms() throws {
        let g = Shared.graph
        var rng = SeededGenerator(seed: 4)
        let m = try medianMillis(50) { _ in _ = try g.backlinks(pageID: "p\(Int.random(in: 0..<1270, using: &rng))") }
        #expect(m < 50, "median \(m) ms")
    }

    @Test func editUnder16ms() throws {
        let g = Shared.graph
        var rng = SeededGenerator(seed: 5)
        let m = try medianMillis(100) { i in
            let id = "b\(Int.random(in: 0..<1000, using: &rng))-\(Int.random(in: 0..<30, using: &rng))"
            try g.perform([.editText(blockID: id, text: "edited \(i) [[Page 7 \(SyntheticGraph.vocabulary[7])]] #tag3")], author: .me)
        }
        #expect(m < 16, "median \(m) ms")
    }

    @Test func coldOpenUnder150ms() throws {
        _ = Shared.graph
        let m = try medianMillis(5) { _ in _ = try Graph(folder: Shared.folder, device: "cold") }
        #expect(m < 150, "median \(m) ms")
    }

    @Test func insertCostDoesNotGrowWithGraphSize() throws {
        // 200 inserts in one transaction, into an empty graph versus a graph of ~20k blocks.
        func millisPer200(_ g: Graph) throws -> Double {
            try g.perform([.createPage(id: "probe", title: "Probe", kind: .page, journalDate: nil)], author: .me)
            var key: String? = nil
            var ops: [Op] = []
            for i in 0..<200 {
                key = OrderKey.between(key, nil)
                ops.append(.insertBlock(id: "probe-\(i)", pageID: "probe", parentID: nil, orderKey: key!, text: "flour \(i) [[Probe]]"))
            }
            let d = try ContinuousClock().measure { try g.perform(ops, author: .me) }
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        let small = try millisPer200(try Graph(folder: tempFolder(), device: "small"))
        let big = try millisPer200(try SyntheticGraph.build(in: tempFolder(), pages: 400, blocksPerPage: 50, seed: 9))
        #expect(big < small * 3 + 100, "200 inserts took \(small) ms on an empty graph but \(big) ms on a 20k-block graph")
    }
}
#endif

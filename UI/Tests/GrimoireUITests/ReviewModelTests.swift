import Foundation
import GrimoireCore
import Testing
@testable import GrimoireUI

@Suite @MainActor struct ReviewModelTests {
    private func deck() throws -> (Graph, () -> Int64, (Int64) -> Void) {
        let g = try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("rev-\(UUID().uuidString)"), device: "t")
        let pid = Graph.pageID(forTitle: "Deck")
        var ops: [Op] = [.createPage(id: pid, title: "Deck", kind: .page, journalDate: nil)]
        for (i, q) in ["q1", "q2", "q3"].enumerated() {
            ops.append(.insertBlock(id: "c\(i)", pageID: pid, parentID: nil, orderKey: "a\(i)", text: "\(q) #card"))
            ops.append(.insertBlock(id: "a\(i)", pageID: pid, parentID: "c\(i)", orderKey: "a", text: "answer \(i)"))
        }
        try g.perform(ops, author: .me)
        var now: Int64 = 1_790_000_000_000
        return (g, { now }, { now += $0 })
    }

    @Test func rateRequiresRevealThenAdvances() throws {
        let (g, clock, _) = try deck()
        let m = ReviewModel(graph: g, scope: .all, clock: clock)
        #expect(m.current?.front == "q1" && m.queue.count == 3)
        m.rate(.good)
        #expect(m.answered == 0, "rating before reveal is ignored")
        m.reveal(); m.rate(.good)
        #expect(m.answered == 1 && m.current?.front == "q2" && !m.revealed)
    }

    @Test func againComesBackAtTheEndAndOthersLeave() throws {
        let (g, clock, _) = try deck()
        let m = ReviewModel(graph: g, scope: .all, clock: clock)
        m.reveal(); m.rate(.again)
        #expect(m.queue.map(\.front) == ["q2", "q3", "q1"])
        m.reveal(); m.rate(.easy); m.reveal(); m.rate(.good)
        #expect(m.current?.front == "q1")
        m.reveal(); m.rate(.good)
        #expect(m.isFinished && m.answered == 4)
    }

    @Test func undoRestoresTheCardAndTheSchedule() throws {
        let (g, clock, _) = try deck()
        let m = ReviewModel(graph: g, scope: .all, clock: clock)
        m.reveal(); m.rate(.good)
        #expect(try g.card(blockID: "c0")!.state != nil)
        m.undo()
        #expect(m.current?.front == "q1" && m.answered == 0)
        #expect(try g.card(blockID: "c0")!.state == nil)
        #expect(!m.canUndo)
    }

    @Test func intervalLabelsAreOrderedAndReadable() throws {
        let (g, clock, _) = try deck()
        let m = ReviewModel(graph: g, scope: .all, clock: clock)
        let l = m.intervalLabels
        #expect(l[.again] == "10m")
        #expect(l[.good] == "4d")
        #expect(ReviewModel.label(millis: 90 * 86_400_000) == "3mo")
        #expect(ReviewModel.label(millis: 3 * 3_600_000) == "3h")
    }
}

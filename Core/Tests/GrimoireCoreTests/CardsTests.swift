import Foundation
import Testing
@testable import GrimoireCore

@Suite struct CardsTests {
    let now: Int64 = 1_790_000_000_000
    let day: Int64 = 86_400_000

    func deck() throws -> Graph {
        let g = try graphWithHome()
        try g.add("h5", "ch 5 - replication", key: "a")
        try g.add("c1", "What is a leader? #card", parent: "h5", key: "a")
        try g.add("a1", "the node that takes writes", parent: "c1", key: "a")
        try g.add("a2", "followers copy it", parent: "a1", key: "a")
        try g.add("c2", "What is a follower? #card", parent: "h5", key: "b")
        try g.add("h6", "ch 6 - partitioning", key: "b")
        try g.add("c3", "What is a shard? #card", parent: "h6", key: "a")
        try g.add("plain", "not a card", key: "c")
        return g
    }

    @Test func taggedBlocksAreCardsWithTheirChildrenAsTheBack() throws {
        let g = try deck()
        #expect(try g.cardCounts(now: now) == CardCounts(due: 0, new: 3, total: 3))
        let c = try g.card(blockID: "c1")!
        #expect(c.front == "What is a leader?" && c.isNew)
        #expect(c.back == ["the node that takes writes", "  followers copy it"])
    }

    @Test func reviewingSchedulesLogsAndMovesTheCardOutOfNew() throws {
        let g = try deck()
        let s = try g.review(blockID: "c1", rating: .good, now: now)
        #expect(s.due == now + 4 * day)
        #expect(try g.reviewCount(blockID: "c1") == 1)
        #expect(try g.cardCounts(now: now) == CardCounts(due: 0, new: 2, total: 3))
        #expect(try g.cardCounts(now: now + 5 * day).due == 1)
        let next = try g.nextCards(now: now + 5 * day).map(\.blockID)
        #expect(next == ["c1", "c2", "c3"])                                         // due first, then new in page order
    }

    @Test func chapterAndPageScopes() throws {
        let g = try deck()
        #expect(try g.nextCards(scope: .chapter(pageID: nil, name: "ch 5")).map(\.blockID) == ["c1", "c2"])
        #expect(try g.nextCards(scope: .chapter(pageID: nil, name: "CH 6")).map(\.blockID) == ["c3"])
        #expect(try g.nextCards(scope: .page("home")).count == 3)
        #expect(try g.nextCards(scope: .chapter(pageID: nil, name: "ch 9")).isEmpty)
    }

    @Test func blockScopeAndPageGroups() throws {
        let g = try deck()
        #expect(try g.nextCards(scope: .block("h5")).map(\.blockID) == ["c1", "c2"])
        #expect(try g.nextCards(scope: .block("c1")).map(\.blockID) == ["c1"])
        #expect(try g.cardCounts(scope: .block("h6"), now: now) == CardCounts(due: 0, new: 1, total: 1))
        try g.review(blockID: "c1", rating: .good, now: now)
        let groups = try g.cardGroups(pageID: "home", now: now + 5 * day)
        #expect(groups.map(\.blockID) == ["h5", "h6"] && groups.allSatisfy { $0.depth == 0 })
        #expect(groups[0].counts == CardCounts(due: 1, new: 1, total: 2))
        #expect(groups[1].counts == CardCounts(due: 0, new: 1, total: 1))
    }

    @Test func nestedGroupsIndentAndSameCardsAsParentAreLeftOut() throws {
        let g = try graphWithHome()
        try g.add("book", "book", key: "a")
        try g.add("ch1", "ch 1", parent: "book", key: "a")
        try g.add("fl1", "flashcards", parent: "ch1", key: "a")
        try g.add("c1", "q1 #card", parent: "fl1", key: "a")
        try g.add("ch2", "ch 2", parent: "book", key: "b")
        try g.add("c2", "q2 #card", parent: "ch2", key: "a")
        let groups = try g.cardGroups(pageID: "home", now: now)
        #expect(groups.map(\.blockID) == ["book", "ch1", "ch2"])
        #expect(groups.map(\.depth) == [0, 1, 1])
    }

    @Test func newCardLimitAndAgainComesBackWithinTheSession() throws {
        let g = try deck()
        #expect(try g.nextCards(limit: 20, newLimit: 1).count == 1)
        try g.review(blockID: "c1", rating: .again, now: now)
        #expect(try g.nextCards(now: now + 11 * 60_000, newLimit: 0).map(\.blockID) == ["c1"])
        #expect(try g.nextCards(now: now + 5 * 60_000, newLimit: 0).isEmpty)
    }

    @Test func undoRestoresThePreviousStateAndRemovesTheReviewLog() throws {
        let g = try deck()
        try g.review(blockID: "c1", rating: .good, now: now)
        try g.review(blockID: "c1", rating: .easy, now: now + 4 * day)
        let before = try g.card(blockID: "c1")!.state
        #expect(try g.undo(count: 1) == 1)
        let after = try g.card(blockID: "c1")!.state!
        #expect(after.reps == 1 && after != before)
        #expect(try g.reviewCount(blockID: "c1") == 1)
        #expect(try g.undo(count: 1) == 1)
        #expect(try g.card(blockID: "c1")!.state == nil && (try g.reviewCount(blockID: "c1")) == 0)
    }

    @Test func deletingTheBlockRemovesItsCard() throws {
        let g = try deck()
        try g.review(blockID: "c2", rating: .good, now: now)
        try g.perform([.deleteBlock(blockID: "c2")], author: .me)
        #expect(try g.cardCounts(now: now + 10 * day).total == 2)
        #expect(try g.cardCounts(now: now + 10 * day).due == 0)
    }

    @Test func reviewingAMissingBlockThrows() throws {
        let g = try deck()
        #expect(throws: GraphError.self) { try g.review(blockID: "nope", rating: .good) }
    }
}

@Suite struct CardRestoreTests {
    @Test func undoingADeleteBringsTheScheduleBack() throws {
        let g = try graphWithHome()
        try g.add("c", "Question? #card", key: "a")
        try g.review(blockID: "c", rating: .good, now: 1_790_000_000_000)
        let before = try g.card(blockID: "c")!.state
        try g.perform([.deleteBlock(blockID: "c")], author: .me)
        #expect(try g.card(blockID: "c") == nil)
        try g.undo(count: 1)
        #expect(try g.card(blockID: "c")?.state == before)
    }

    @Test func undoOpRevertsOnlyThatAnswerEvenWhenOtherOpsCameAfter() throws {
        let g = try graphWithHome()
        try g.add("c", "Q #card", key: "a")
        let logged = try g.reviewLogged(blockID: "c", rating: .good, now: 1_790_000_000_000)
        try g.add("later", "an edit made after the answer", key: "b")
        #expect(try g.undoOp(logged.opID))
        #expect(try g.card(blockID: "c")?.state == nil)
        #expect(try g.text("later") == "an edit made after the answer")
    }
}

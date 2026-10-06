#if os(macOS)
import AppKit
import Foundation
import GrimoireCore
import Testing
@testable import GrimoireUI

/// Regenerates docs/screenshots/app.png from a made-up graph (never real notes):
///   GRIMOIRE_SCREENSHOT=1 swift test --package-path UI --filter ScreenshotTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_SCREENSHOT"] != nil)) @MainActor struct ScreenshotTests {
    @Test func appScreenshot() async throws {
        let g = try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString)"), device: "shot")
        let today = JournalDate.today()
        let todayID = try g.ensureJournal(today, author: .me)
        let yesterdayID = try g.ensureJournal(today.adding(days: -1), author: .me)
        let book = Graph.pageID(forTitle: "Designing Data-Intensive Applications")
        func block(_ id: String, _ page: String, _ parent: String?, _ key: String, _ text: String) -> Op {
            .insertBlock(id: id, pageID: page, parentID: parent, orderKey: key, text: text)
        }
        try g.perform([
            .createPage(id: book, title: "Designing Data-Intensive Applications", kind: .page, journalDate: nil),
            .createPage(id: Graph.pageID(forTitle: "Sourdough"), title: "Sourdough", kind: .page, journalDate: nil),
            .createPage(id: Graph.pageID(forTitle: "Trip planning"), title: "Trip planning", kind: .page, journalDate: nil),
            block("b1", book, nil, "a", "type:: book\nauthor:: Martin Kleppmann\nstatus:: reading"),
            block("b2", book, nil, "b", "# Replication"),
            block("b3", book, "b2", "a", "A leader takes writes and ships a log to followers. #databases"),
            block("b4", book, "b2", "b", "Followers lag; reads can see **stale** data unless you pin them to the leader."),
            block("b5", book, "b2", "c", "TODO write up the conflict rules for [[Trip planning]] notes sync"),
            block("b6", book, nil, "c", "# Partitioning"),
            block("b7", book, "b6", "a", "Hash partitioning spreads load; range partitioning keeps scans cheap."),
            block("b8", book, "b6", "b", "```sql\nSELECT * FROM events WHERE ts BETWEEN :a AND :b;\n```"),
            block("t1", todayID, nil, "a", "Morning: read two chapters of [[Designing Data-Intensive Applications]] #reading"),
            block("t2", todayID, nil, "b", "TODO feed the starter, [[Sourdough]] bake at 6pm"),
            block("t3", todayID, nil, "c", "DOING outline the weekend [[Trip planning]]"),
            block("t4", todayID, "t3", "a", "Book the train, pick two hikes"),
            block("t5", todayID, "t3", "b", "DONE check the forecast"),
            block("y1", yesterdayID, nil, "a", "Long walk, no phone. Thought about how replication logs resemble a journal."),
            block("y2", yesterdayID, nil, "b", "Shaped the loaf; overnight proof in the fridge #baking"),
            block("s1", Graph.pageID(forTitle: "Sourdough"), nil, "a", "Hydration 75%, 20% starter, bulk 5h at room temperature."),
            block("r1", Graph.pageID(forTitle: "Trip planning"), nil, "a", "Two nights, trains only. See [[Designing Data-Intensive Applications]] for the reading list."),
        ], author: .me)
        let app = HeadlessApp(graph: g, size: NSSize(width: 1500, height: 900))
        app.store.open(.page(book), newPane: true)
        await app.settle(1.2)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/screenshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        app.host.layoutSubtreeIfNeeded()
        let rep = try #require(app.host.bitmapImageRepForCachingDisplay(in: app.host.bounds))
        app.host.cacheDisplay(in: app.host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("app.png"))
    }
}
#endif

#if os(macOS)
import AppKit
import GrimoireCore
import Testing
@testable import GrimoireUI

/// The window is often left open overnight: the journals page must move on to the new day by itself.
@Suite @MainActor struct JournalRolloverTests {
    private func oneAmTomorrow() -> Date {
        let midnight = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)!
        return midnight.addingTimeInterval(3600)
    }

    @Test func todayStaysPutUntilMidnightThenMovesOn() throws {
        let g = try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("roll-\(UUID().uuidString)"), device: "t")
        let store = GraphStore(graph: g, defaults: UserDefaults(suiteName: "roll-\(UUID().uuidString)")!)
        let before = store.today, revision = store.revision
        store.refreshToday(now: Date())
        #expect(store.today == before && store.revision == revision, "same day: nothing changes")
        store.refreshToday(now: oneAmTomorrow())
        #expect(store.today == before.adding(days: 1))
        #expect(store.revision > revision, "views that list days reload")
    }
}

@Suite(.serialized, .enabled(if: hasGUISession)) @MainActor struct JournalRolloverEndToEndTests {
    @Test func anOpenJournalsPageStartsTheNextDayWhenMidnightPasses() async throws {
        let g = try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("roll-\(UUID().uuidString)"), device: "t")
        let app = HeadlessApp(graph: g)
        await app.settle(0.6)
        let today = app.store.today
        app.focus(app.textViews()[0])
        await app.typeKeys("written yesterday")
        await app.settle(0.9)
        #expect(try g.tree(pageID: today.pageID).map(\.block.text) == ["written yesterday"])

        let tomorrow = today.adding(days: 1)
        let oneAm = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)!.addingTimeInterval(3600)
        app.store.refreshToday(now: oneAm)
        await app.settle(until: { app.textViews().count > 0 && (try? g.tree(pageID: tomorrow.pageID)) != nil }, timeout: 2)
        await app.settle(0.5)
        let views = app.textViews()
        #expect(views.count >= 1)
        guard let first = views.first else { return }
        app.focus(first)
        await app.typeKeys("written today")
        await app.settle(0.9)
        #expect(try g.tree(pageID: tomorrow.pageID).map(\.block.text) == ["written today"], "typing at the top of the page lands on the new day")
        #expect(try g.tree(pageID: today.pageID).map(\.block.text) == ["written yesterday"], "the old day is untouched")
    }
}
#endif

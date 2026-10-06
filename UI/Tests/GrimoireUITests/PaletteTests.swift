import Foundation
import GrimoireCore
import Testing
@testable import GrimoireUI

@Suite @MainActor struct PaletteTests {
    private func store() throws -> GraphStore {
        let g = try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("pal-\(UUID().uuidString)"), device: "t")
        return GraphStore(graph: g, defaults: UserDefaults(suiteName: "pal-\(UUID().uuidString)")!)
    }
    private func page(_ s: GraphStore, _ title: String, text: String? = nil) throws {
        let id = Graph.pageID(forTitle: title)
        var ops: [Op] = [.createPage(id: id, title: title, kind: .page, journalDate: nil)]
        if let text { ops.append(.insertBlock(id: UUID().uuidString.lowercased(), pageID: id, parentID: nil, orderKey: "a", text: text)) }
        try s.graph.perform(ops, author: .me)
    }

    @Test func commandsAndPagesRankTogetherAndExactBeatsPrefix() throws {
        let s = try store()
        try page(s, "Today in history"); try page(s, "Tod")
        let titles = Palette.items(query: "today", store: s).map(\.title)
        #expect(titles.prefix(3).contains("Go to Today"))
        #expect(titles.firstIndex(of: "Today in history")! < titles.firstIndex(of: "Go to Today")!)
        #expect(titles.contains("Today in history"))
    }

    @Test func pageNamesMatchFuzzily() throws {
        let s = try store()
        try page(s, "Financial planning"); try page(s, "Focaccia"); try page(s, "Zebra")
        func pages(_ q: String) -> [String] { Palette.items(query: q, store: s).filter { $0.kind == .page }.map(\.title) }
        #expect(pages("fnplan").first == "Financial planning", "letters in order")
        #expect(pages("focacia").first == "Focaccia", "dropped letter")
        #expect(pages("focaccai").first == "Focaccia", "swapped letters")
        #expect(!pages("focacia").contains("Zebra"))
    }

    @Test func reviewUnderThisBulletPicksTheChapterAroundTheCaret() throws {
        let s = try store()
        let pid = Graph.pageID(forTitle: "Book")
        func ins(_ id: String, _ text: String, parent: String?, key: String) -> Op { .insertBlock(id: id, pageID: pid, parentID: parent, orderKey: key, text: text) }
        try s.graph.perform([.createPage(id: pid, title: "Book", kind: .page, journalDate: nil),
                             ins("ch1", "ch 1", parent: nil, key: "a"), ins("q1", "one #card", parent: "ch1", key: "a"), ins("q2", "two #card", parent: "ch1", key: "b"),
                             ins("ch2", "ch 2", parent: nil, key: "b"), ins("q3", "three #card", parent: "ch2", key: "a"), ins("note", "just a note", parent: nil, key: "c")], author: .me)
        s.open(.page(pid))
        s.caretBlock = .init(pageID: pid, blockID: "q2")
        #expect(s.caretReviewCandidate?.blockID == "ch1", "a card being edited reviews its chapter")
        s.caretBlock = .init(pageID: pid, blockID: "q3")
        #expect(s.caretReviewCandidate?.blockID == "q3", "a lone card falls back to itself")
        s.caretBlock = .init(pageID: pid, blockID: "note")
        #expect(s.caretReviewCandidate == nil)
        s.caretBlock = .init(pageID: pid, blockID: "ch1")
        s.reviewCardsAtCaret()
        #expect(s.focusedPane.location == .review(page: pid, block: "ch1"))
    }

    @Test func recentsAreThePagesYouOpenedNewestFirst() throws {
        let s = try store()
        try page(s, "Alpha", text: "a"); try page(s, "Beta", text: "b"); try page(s, "Gamma", text: "c")
        s.open(.page(Graph.pageID(forTitle: "Alpha"))); s.open(.page(Graph.pageID(forTitle: "Beta"))); s.open(.page(Graph.pageID(forTitle: "Alpha")))
        #expect(s.recents.prefix(3).map(\.title) == ["Alpha", "Beta", "Gamma"], "opened pages first, newest first; others (by edit) after")
        s.open(.page(Graph.pageID(forTitle: "Gamma")))
        #expect(s.recents.first?.title == "Gamma")
    }

    @Test func emptyQueryShowsRecentsThenEveryEnabledCommand() throws {
        let s = try store()
        try page(s, "Focaccia", text: "dough"); s.refreshLists()
        let items = Palette.items(query: "", store: s)
        #expect(items.first?.title == "Focaccia")
        #expect(items.contains { $0.title == "Command Palette" })
        #expect(!items.contains { $0.title == "Back" }, "disabled commands are hidden")
    }

    @Test func commandModeListsOnlyCommandsEvenWithoutTheGreaterThan() throws {
        let s = try store()
        try page(s, "Focaccia")
        let items = Palette.items(query: "", store: s, mode: .commands)
        #expect(!items.isEmpty && items.allSatisfy { $0.kind == .command || $0.kind == .theme })
        #expect(Palette.items(query: "foc", store: s, mode: .commands).allSatisfy { $0.kind != .page })
    }

    @Test func greaterThanLimitsToCommandsAndMatchesKeywords() throws {
        let s = try store()
        try page(s, "Reindex notes")
        let items = Palette.items(query: ">reindex", store: s)
        #expect(items.map(\.title) == ["Rebuild Search Index"])
    }

    @Test func blocksAreFoundByContentAndCreateRowOffered() throws {
        let s = try store()
        try page(s, "Recipes", text: "proof the focaccia overnight")
        let items = Palette.items(query: "focaccia", store: s)
        #expect(items.contains { $0.kind == .block && $0.subtitle == "Recipes" })
        #expect(items.contains { $0.kind == .create && $0.title == "Create page “focaccia”" })
        #expect(items.last?.kind == .search)
    }

    @Test func searchModePutsBlocksFirst() throws {
        let s = try store()
        try page(s, "Focus"); try page(s, "Recipes", text: "focus on the crumb")
        #expect(Palette.items(query: "focus", store: s, mode: .search).first?.kind == .block)
    }

    @Test func runningItemsNavigates() throws {
        let s = try store()
        try page(s, "Focaccia")
        let item = Palette.items(query: "focaccia", store: s).first { $0.kind == .page }!
        item.run(s, false)
        #expect(s.focusedPane.location == .page(Graph.pageID(forTitle: "Focaccia")))
        item.run(s, true)
        #expect(s.panes.count == 2)
    }

    @Test func themeCommandsSwitchTheTheme() throws {
        let s = try store()
        let light = Palette.items(query: "Theme: Midnight Sun Light", store: s).first { $0.kind == .theme }
        light?.run(s, false)
        #expect(s.theme.name == "Midnight Sun Light")
    }
}

@Suite @MainActor struct CommandRegistryTests {
    @Test func idsAreUniqueAndShortcutsDoNotCollide() {
        let ids = CommandRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let shortcuts = CommandRegistry.all.compactMap(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func theTwoPaletteShortcutsAreCmdPAndCmdShiftP() {
        #expect(CommandRegistry.command("palette")?.shortcut == Shortcut("p"))
        #expect(CommandRegistry.command("commands")?.shortcut == Shortcut("p", shift: true))
        #expect(CommandRegistry.command("palette")?.alternates == [Shortcut("k")])
        let all = CommandRegistry.all.flatMap { [$0.shortcut].compactMap { $0 } + $0.alternates }
        #expect(Set(all).count == all.count, "no key is used twice, alternates included")
    }

    @Test func shortcutsAvoidTheEditorsOwnKeys() {
        // ⌘B/⌘I are bold/italic, ⌘↑/↓ collapse, ⌘Z undo, ⌘A/C/V/X clipboard: no menu command may take them.
        let reserved = Set(["b", "i", "z", "a", "c", "v", "x"])
        for c in CommandRegistry.all { if let s = c.shortcut, s.command, !s.shift { #expect(!reserved.contains(s.key), "\(c.id)") } }
    }

    @Test func everyCommandRunsWithoutCrashingOnAFreshGraph() throws {
        let g = try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("cmd-\(UUID().uuidString)"), device: "t")
        let s = GraphStore(graph: g, defaults: UserDefaults(suiteName: "cmd-\(UUID().uuidString)")!)
        for c in CommandRegistry.all where c.id != "close-pane" && c.isEnabled(s) { c.run(s) }
        #expect(s.panes.count >= 1)
    }
}

@Suite @MainActor struct BlockRefDisplayTests {
    @Test func blockReferencesShowTheReferencedText() throws {
        let g = try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID().uuidString)"), device: "t")
        let pid = Graph.pageID(forTitle: "P")
        let target = "6ab1c4bd-da26-487d-a151-6ed840f543a8"
        try g.perform([.createPage(id: pid, title: "P", kind: .page, journalDate: nil),
                       .insertBlock(id: target, pageID: pid, parentID: nil, orderKey: "a", text: "situation: stayed in on friday night\nsecond line")], author: .me)
        let s = GraphStore(graph: g, defaults: UserDefaults(suiteName: "ref-\(UUID().uuidString)")!)
        #expect(s.expandBlockRefs("see ((\(target))) later") == "see “situation: stayed in on friday night” later")
        #expect(s.expandBlockRefs("gone ((11111111-1111-1111-1111-111111111111))") == "gone “(missing block)”")
        #expect(s.expandBlockRefs("no refs here") == "no refs here")
    }
}

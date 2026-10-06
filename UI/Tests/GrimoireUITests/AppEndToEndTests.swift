#if os(macOS)
import AppKit
import GrimoireCore
import Testing
@testable import GrimoireUI

private func freshGraph() throws -> Graph { try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString)"), device: "e2e") }

@Suite(.serialized) @MainActor struct AppEndToEndTests {
    @Test func journalsOpenWithTodaysEditorFocusedAndTypingReachesTheDatabase() async throws {
        let g = try freshGraph()
        let app = HeadlessApp(graph: g)
        await app.settle(0.6)
        let views = app.textViews()
        #expect(!views.isEmpty, "the journals page should host at least today's editor")
        guard let today = views.first else { return }
        app.focus(today)
        app.type("hello from the headless app")
        await app.settle(0.9)                                               // debounce + save
        let page = try g.tree(pageID: JournalDate.today().pageID)
        #expect(page.map(\.block.text) == ["hello from the headless app"])
        app.snapshot("e2e-journals")
    }

    @Test func enterAndTabBuildAnOutlineThatIsSavedAsATree() async throws {
        let g = try freshGraph()
        let app = HeadlessApp(graph: g)
        await app.settle(0.5)
        let tv = app.focus(app.textViews()[0])
        app.type("parent"); app.key("return"); app.type("child"); app.key("tab"); app.key("return"); app.type("second child")
        app.key("return"); app.key("tab", ["shift"]); app.type("sibling of parent")
        await app.settle(0.9)
        let tree = try g.tree(pageID: JournalDate.today().pageID)
        print("TREE", tree.map(\.block.text), tree.map { $0.children.map(\.block.text) }, tv.currentDoc.rows.map { "\($0.depth):\($0.text)" })
        #expect(tree.map(\.block.text) == ["parent", "sibling of parent"])
        #expect(tree[0].children.map(\.block.text) == ["child", "second child"])
        #expect(tv.currentDoc.rows.map(\.depth) == [0, 1, 1, 0])
    }

    @Test func anOutsideWriteAppearsInAnOpenEditor() async throws {
        let g = try freshGraph()
        let today = JournalDate.today()
        try g.ensureJournal(today, author: .me)
        try g.perform([.insertBlock(id: "b1", pageID: today.pageID, parentID: nil, orderKey: "a", text: "original")], author: .me)
        let app = HeadlessApp(graph: g)
        await app.settle(0.6)
        let cli = try Graph(folder: g.folder, device: "cli")
        try cli.perform([.editText(blockID: "b1", text: "changed by Claude"), .insertBlock(id: "b2", pageID: today.pageID, parentID: nil, orderKey: "b", text: "added by Claude")], author: .claude)
        await app.settle(1.0)                                              // poller notices the commit
        #expect(app.textViews()[0].currentDoc.rows.map(\.text).prefix(2) == ["changed by Claude", "added by Claude"])
    }
}
#endif

#if os(macOS)
@Suite(.serialized) @MainActor struct AutocompleteEndToEndTests {
    @Test func typingDoubleBracketOpensThePopupAndEnterInsertsTheLink() async throws {
        let g = try freshGraph()
        try g.perform([.createPage(id: "foc", title: "Focaccia", kind: .page, journalDate: nil)], author: .me)
        let app = HeadlessApp(graph: g)
        await app.settle(0.5)
        let tv = app.focus(app.textViews()[0])
        app.type("make [[Foc")
        #expect(tv.isAutocompleteOpen)
        #expect(tv.autocompleteItems.first?.title == "Focaccia")
        app.snapshot("e2e-autocomplete")
        app.key("return")
        #expect(!tv.isAutocompleteOpen)
        #expect(tv.currentDoc.rows[0].text == "make [[Focaccia]]")
        #expect(tv.selectedRange().location == ("make [[Focaccia]]" as NSString).length)
    }

    @Test func escapeClosesAndTagPopupInsertsATagWithASpace() async throws {
        let g = try freshGraph()
        try g.perform([.createPage(id: "r", title: "recipe", kind: .page, journalDate: nil)], author: .me)
        let app = HeadlessApp(graph: g)
        await app.settle(0.5)
        let tv = app.focus(app.textViews()[0])
        app.type("#rec")
        #expect(tv.isAutocompleteOpen)
        app.key("escape")
        #expect(!tv.isAutocompleteOpen)
        app.type("i")                                                       // typing again reopens it
        #expect(tv.isAutocompleteOpen)
        app.key("tab")
        #expect(tv.currentDoc.rows[0].text == "#recipe ")
    }

    @Test func slashCommandInsertsTodo() async throws {
        let g = try freshGraph()
        let app = HeadlessApp(graph: g)
        await app.settle(0.5)
        let tv = app.focus(app.textViews()[0])
        app.type("/todo"); app.key("return"); app.type("buy milk")
        #expect(tv.currentDoc.rows[0].text == "TODO buy milk")
    }
}
#endif

#if os(macOS)
@Suite(.serialized) @MainActor struct PaletteEndToEndTests {
    @Test func paletteOverlayTypesRanksAndOpensAPage() async throws {
        let g = try freshGraph()
        try g.perform([.createPage(id: Graph.pageID(forTitle: "Focaccia"), title: "Focaccia", kind: .page, journalDate: nil)], author: .me)
        let app = HeadlessApp(graph: g)
        await app.settle(0.4)
        app.store.showPalette(.all)
        await app.settle(0.4)
        // the palette's text field takes the keystrokes
        app.type("focac")
        await app.settle(0.4)
        app.snapshot("e2e-palette")
        app.key("return")
        await app.settle(until: { !app.store.paletteVisible })
        #expect(!app.store.paletteVisible)
        #expect(app.store.focusedPane.location == .page(Graph.pageID(forTitle: "Focaccia")))
    }
}
#endif

#if os(macOS)
@Suite(.serialized) @MainActor struct QuitAndRealGraphTests {
    @Test func quittingFlushesAnEditThatHasntBeenSavedYet() async throws {
        let g = try freshGraph()
        let app = HeadlessApp(graph: g)
        await app.settle(0.4)
        app.store.start()
        app.focus(app.textViews()[0]); app.type("unsaved words")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)     // before the 300 ms debounce
        #expect(try g.tree(pageID: JournalDate.today().pageID).map(\.block.text) == ["unsaved words"])
    }

    /// Opens a copy of the real imported graph (set GRIMOIRE_REAL_GRAPH to a folder) and times the first screen.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_REAL_GRAPH"] != nil)) func realGraphOpensFast() async throws {
        let src = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GRIMOIRE_REAL_GRAPH"]!)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for f in ["graph.sqlite", "graph.sqlite-wal", "graph.sqlite-shm"] where FileManager.default.fileExists(atPath: src.appendingPathComponent(f).path) {
            try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: copy.appendingPathComponent(f))
        }
        let g = try Graph(folder: copy, device: "e2e")
        let t0 = Date()
        let app = HeadlessApp(graph: g)
        await app.settle(0.3)
        let big = try g.recentPages(limit: 200).max { (try? g.tree(pageID: $0.id).count) ?? 0 < (try? g.tree(pageID: $1.id).count) ?? 0 }!
        let t1 = Date()
        app.store.open(.page(big.id))
        await app.settle(0.2)
        let openTime = Date().timeIntervalSince(t1)
        print("REAL first-screen", Date().timeIntervalSince(t0), "open largest page", big.title, (try g.tree(pageID: big.id)).count, "roots:", openTime)
        app.snapshot("real-largest-page")
        #expect(openTime < 1.0)
    }
}
#endif

#if os(macOS)
@Suite(.serialized) @MainActor struct DiagramEndToEndTests {
    @Test func aMermaidFenceGetsAPictureBelowItAndEditingChangesIt() async throws {
        let g = try freshGraph()
        let today = JournalDate.today()
        try g.ensureJournal(today, author: .me)
        try g.perform([.insertBlock(id: "d1", pageID: today.pageID, parentID: nil, orderKey: "a", text: "```mermaid\ngraph TD\n  A-->B\n```")], author: .me)
        let app = HeadlessApp(graph: g)
        await app.settle(0.3)
        let tv = app.textViews()[0]
        tv.diagramRenderer = MermaidRenderer(cacheFolder: nil)
        tv.refreshDiagrams()
        for _ in 0..<40 where tv.textStorage?.attribute(OutlineAttr.diagram, at: 0, effectiveRange: nil) == nil { await app.settle(0.25) }
        let first = tv.textStorage?.attribute(OutlineAttr.diagramKey, at: 0, effectiveRange: nil) as? String
        #expect(tv.textStorage?.attribute(OutlineAttr.diagram, at: 0, effectiveRange: nil) is NSImage)
        #expect(first != nil)
        // the text of the block is untouched by the picture
        #expect(tv.currentDoc.rows[0].text == "```mermaid\ngraph TD\n  A-->B\n```")
    }

    @Test func aBrokenDiagramShowsAnErrorNotAPicture() async throws {
        let g = try freshGraph()
        let today = JournalDate.today()
        try g.ensureJournal(today, author: .me)
        try g.perform([.insertBlock(id: "d1", pageID: today.pageID, parentID: nil, orderKey: "a", text: "```mermaid\nnot ->-> valid\n```")], author: .me)
        let app = HeadlessApp(graph: g)
        await app.settle(0.3)
        let tv = app.textViews()[0]
        tv.diagramRenderer = MermaidRenderer(cacheFolder: nil)
        tv.refreshDiagrams()
        for _ in 0..<40 where tv.textStorage?.attribute(OutlineAttr.diagramError, at: 0, effectiveRange: nil) == nil { await app.settle(0.25) }
        #expect(tv.textStorage?.attribute(OutlineAttr.diagramError, at: 0, effectiveRange: nil) is String)
        #expect(tv.textStorage?.attribute(OutlineAttr.diagram, at: 0, effectiveRange: nil) == nil)
    }
}
#endif

#if os(macOS)
@Suite(.serialized) @MainActor struct SyncStoreTests {
    @Test func theStoreSyncsWithAHubAndShowsStatus() async throws {
        let hub = SyncHub(graph: try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)"), device: "hub"))
        try hub.graph.perform([.createPage(id: "p", title: "From hub", kind: .page, journalDate: nil)], author: .claude)
        let g = try freshGraph()
        let store = GraphStore(graph: g, defaults: UserDefaults(suiteName: "sync-\(UUID().uuidString)")!)
        #expect(store.syncStatus == .off)
        store.start()
        store.startSync(transport: LocalTransport(hub: hub), deviceID: "mac", interval: 60)
        for _ in 0..<40 { if case .synced = store.syncStatus { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        guard case .synced = store.syncStatus else { Issue.record("status \(store.syncStatus)"); return }
        #expect(try g.page(titled: "From hub") != nil)
        #expect(store.allSynced && store.pendingChanges == 0 && store.lastSyncedAt != nil)
        // a change made here shows as waiting, then as synced once it has gone to the hub
        try g.perform([.createPage(id: "mine", title: "Written here", kind: .page, journalDate: nil)], author: .me)
        store.refreshPending()
        #expect(store.pendingChanges == 1 && !store.allSynced)
        store.syncNow()
        for _ in 0..<40 { if store.allSynced { break }; try await Task.sleep(nanoseconds: 100_000_000) }
        #expect(store.allSynced)
        #expect(try hub.graph.page(titled: "Written here") != nil)
        store.stop()
    }
}
#endif

#if os(macOS)
@Suite(.serialized) @MainActor struct ViewCostTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_REAL_GRAPH"] != nil)) func journalsOnTheRealGraphStayCheap() async throws {
        let src = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GRIMOIRE_REAL_GRAPH"]!)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for f in ["graph.sqlite", "graph.sqlite-wal", "graph.sqlite-shm"] where FileManager.default.fileExists(atPath: src.appendingPathComponent(f).path) {
            try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: copy.appendingPathComponent(f))
        }
        let app = HeadlessApp(graph: try Graph(folder: copy, device: "e2e"), size: NSSize(width: 1240, height: 820))
        await app.settle(2.0)
        func layers(_ l: CALayer?) -> Int { guard let l else { return 0 }; return 1 + (l.sublayers ?? []).reduce(0) { $0 + layers($1) } }
        func views(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + views($1) } }
        print("COST editors:", app.textViews().count, "views:", views(app.host), "layers:", layers(app.host.layer))
        #expect(app.textViews().count <= 12)
    }
}
#endif

#if os(macOS)
@Suite(.serialized) @MainActor struct JournalWeightTests {
    @Test func earlierDaysAreDrawnWithoutTheirOwnTextViews() async throws {
        let g = try freshGraph()
        let today = JournalDate.today()
        for back in 0..<10 {
            let d = today.adding(days: -back)
            try g.ensureJournal(d, author: .me)
            try g.perform([.insertBlock(id: "j\(back)", pageID: d.pageID, parentID: nil, orderKey: "a", text: "entry \(back)")], author: .me)
        }
        let app = HeadlessApp(graph: g, size: NSSize(width: 1240, height: 1600))
        await app.settle(1.0)
        #expect(app.textViews().count == 1, "only today's journal is a text view")
        #expect(app.textViews()[0].currentDoc.rows.map(\.text) == ["entry 0"])
    }
}
#endif

#if os(macOS)
@Suite(.serialized) @MainActor struct LayerCompareTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_REAL_GRAPH"] != nil)) func journalsVersusPageLayerFeatures() async throws {
        let src = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GRIMOIRE_REAL_GRAPH"]!)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for f in ["graph.sqlite", "graph.sqlite-wal", "graph.sqlite-shm"] where FileManager.default.fileExists(atPath: src.appendingPathComponent(f).path) {
            try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: copy.appendingPathComponent(f))
        }
        let app = HeadlessApp(graph: try Graph(folder: copy, device: "e2e"), size: NSSize(width: 1512, height: 940))
        await app.settle(1.5)
        func features(_ root: CALayer) -> [String: Int] {
            var out: [String: Int] = [:]
            func walk(_ l: CALayer) {
                var f: [String] = []
                if l.opacity < 1 { f.append("opacity") }
                if l.shouldRasterize { f.append("rasterize") }
                if l.mask != nil { f.append("mask") }
                if l.cornerRadius > 0 { f.append("corner") }
                if l.shadowOpacity > 0 { f.append("shadow") }
                if l.filters?.isEmpty == false { f.append("filters") }
                if l.backgroundFilters?.isEmpty == false { f.append("bgfilters") }
                if l.compositingFilter != nil { f.append("compositing") }
                if l.allowsGroupOpacity && l.opacity < 1 { f.append("groupOpacity") }
                if l.contents != nil { f.append("contents") }
                if l.isHidden { f.append("hidden") }
                for x in f { out[x, default: 0] += 1 }
                out["TOTAL", default: 0] += 1
                out["class:" + String(describing: type(of: l)), default: 0] += 1
                (l.sublayers ?? []).forEach(walk)
            }
            walk(root); return out
        }
        let j = features(app.host.layer!)
        let pageID = try await copy.path.isEmpty ? "" : (app.graph.db.read { try String.fetchOne($0, sql: "SELECT id FROM pages WHERE title_lower = 'interests'")! })
        app.store.open(.page(pageID))
        await app.settle(1.5)
        let p = features(app.host.layer!)
        let keys = Set(j.keys).union(p.keys).sorted()
        print("LAYERCMP key journals page")
        for k in keys where j[k, default: 0] != p[k, default: 0] { print("LAYERCMP \(k) \(j[k, default: 0]) \(p[k, default: 0])") }
    }
}
#endif

#if os(macOS)
@Suite(.serialized) @MainActor struct PageWidthTests {
    @Test func pageEditorsSpanTheirContainerWithEqualMargins() async throws {
        let g = try freshGraph()
        let id = Graph.pageID(forTitle: "Wide")
        try g.perform([.createPage(id: id, title: "Wide", kind: .page, journalDate: nil),
                       .insertBlock(id: "w1", pageID: id, parentID: nil, orderKey: "a", text: String(repeating: "word ", count: 120))], author: .me)
        let app = HeadlessApp(graph: g, size: NSSize(width: 1300, height: 800))
        app.store.open(.page(id))
        await app.settle(1.0)
        let tv = app.textViews()[0]
        let pane = app.host.bounds.width - 224                       // sidebar
        #expect(abs(tv.frame.width - pane) < 2, "the editor fills the pane")
        #expect(abs((tv.textContainer?.size.width ?? 0) - (tv.frame.width - tv.textContainerInset.width * 2)) < 1, "text wraps at the editor's full width")
        // margins are equal on both sides: the text column is centred in the pane
        #expect(tv.textContainerInset.width * 2 + (tv.textContainer?.size.width ?? 0) == tv.frame.width || abs(tv.textContainerInset.width * 2 + (tv.textContainer?.size.width ?? 0) - tv.frame.width) < 1)
        // and it keeps up when the window is resized
        app.window.setContentSize(NSSize(width: 1700, height: 800))
        app.host.frame = NSRect(x: 0, y: 0, width: 1700, height: 800)
        await app.settle(0.8)
        let tv2 = app.textViews()[0]
        #expect(abs((tv2.textContainer?.size.width ?? 0) - (tv2.frame.width - tv2.textContainerInset.width * 2)) < 1)
        #expect(tv2.frame.width > 1400)
    }
}
#endif

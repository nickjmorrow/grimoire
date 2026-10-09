#if os(macOS)
import AppKit
import GrimoireCore
import Testing
@testable import GrimoireUI

private func freshGraph() throws -> Graph { try Graph(folder: FileManager.default.temporaryDirectory.appendingPathComponent("indent-\(UUID().uuidString)"), device: "indent") }

/// A small deterministic generator so a failing fuzz run can be replayed from its seed.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

extension HeadlessApp {
    /// One key at a time with the run loop turning in between, as with a real keyboard (undo groups its changes per event).
    func press(_ name: String, _ mods: [String] = []) async { key(name, mods); await settle(0.02) }
    func typeKeys(_ text: String) async { for ch in text { key(String(ch)); await settle(0.01) } }
}

/// What the screen shows for each bullet, read back from the text view: the depth recorded on the paragraph, the indent its paragraph
/// style will lay it out at, and the depth the layout fragment (which draws the bullet) was given.
private struct DrawnRow: Equatable { var text: String; var depth: Int; var headIndent: CGFloat; var firstLineIndent: CGFloat; var fragmentDepth: Int }

@MainActor private func drawnRows(_ tv: OutlineTextView) -> [DrawnRow] {
    guard let storage = tv.textStorage, let layout = tv.textLayoutManager else { return [] }
    layout.ensureLayout(for: layout.documentRange)
    var fragmentDepths: [Int] = []
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { f in
        fragmentDepths.append((f as? OutlineLayoutFragment)?.depth ?? -1)
        return true
    }
    let ns = storage.string as NSString
    return OutlineStorage.rowRanges(in: storage).enumerated().map { i, r in
        let style = storage.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
        var text = ns.substring(with: r)
        if text.hasSuffix("\n") { text.removeLast() }
        return DrawnRow(text: text, depth: storage.attribute(OutlineAttr.depth, at: r.location, effectiveRange: nil) as? Int ?? -1,
                        headIndent: style?.headIndent ?? -1, firstLineIndent: style?.firstLineHeadIndent ?? -1,
                        fragmentDepth: fragmentDepths.indices.contains(i) ? fragmentDepths[i] : -2)
    }
}

/// Everything that must hold after any sequence of keystrokes. Returns the problems found (empty when the outline is sound).
@MainActor private func problems(_ tv: OutlineTextView) -> [String] {
    let indent = CGFloat(tv.theme.spacing.indent), gutter: CGFloat = 20
    let doc = tv.currentDoc
    var out: [String] = []
    var previous = -1
    for (i, row) in doc.rows.enumerated() {
        if row.depth < 0 || row.depth > previous + 1 { out.append("row \(i) \"\(row.text)\" has depth \(row.depth) under a row at depth \(previous)") }
        previous = row.depth
    }
    let drawn = drawnRows(tv)
    if drawn.count != doc.rows.count { out.append("\(drawn.count) paragraphs for \(doc.rows.count) rows") }
    for (i, d) in drawn.enumerated() where doc.rows.indices.contains(i) {
        let want = CGFloat(doc.rows[i].depth) * indent + gutter
        if d.headIndent != want || d.firstLineIndent != want {
            out.append("row \(i) \"\(d.text)\" is depth \(doc.rows[i].depth) but drawn indented \(d.firstLineIndent)/\(d.headIndent), expected \(want)")
        }
        if d.fragmentDepth != doc.rows[i].depth { out.append("row \(i) \"\(d.text)\" is depth \(doc.rows[i].depth) but its bullet is drawn at depth \(d.fragmentDepth)") }
    }
    return out
}

private func shape(_ rows: [OutlineRow]) -> [String] { rows.map { String(repeating: "  ", count: $0.depth) + "- " + $0.text } }

@Suite(.serialized, .enabled(if: hasGUISession)) @MainActor struct IndentationTests {
    private func open() async throws -> (HeadlessApp, OutlineTextView, Graph) {
        let g = try freshGraph()
        let app = HeadlessApp(graph: g)
        await app.settle(0.5)
        let tv = app.focus(app.textViews()[0])
        return (app, tv, g)
    }

    /// The tree as it was saved, flattened to the same shape the editor shows.
    private func saved(_ g: Graph) throws -> [String] {
        shape(OutlineDoc(tree: try g.tree(pageID: JournalDate.today().pageID)).rows)
    }

    @Test func typingBuildsAnIndentedOutlineThatIsDrawnAndSavedAtTheSameDepths() async throws {
        let (app, tv, g) = try await open()
        await app.typeKeys("one"); await app.press("return")
        await app.typeKeys("two"); await app.press("tab"); await app.press("return")
        await app.typeKeys("three"); await app.press("tab"); await app.press("return")
        await app.typeKeys("four"); await app.press("tab", ["shift"]); await app.press("return")
        await app.typeKeys("five"); await app.press("tab", ["shift"])
        await app.settle(0.9)
        let want = ["- one", "  - two", "    - three", "  - four", "- five"]
        #expect(shape(tv.currentDoc.rows) == want)
        #expect(problems(tv) == [])
        #expect(try saved(g) == want)
    }

    @Test func typingIntoAnIndentedBulletKeepsItsIndent() async throws {
        let (app, tv, _) = try await open()
        await app.typeKeys("parent"); await app.press("return"); await app.press("tab"); await app.typeKeys("child")
        for _ in 0..<5 { await app.press("left") }
        await app.typeKeys("XY")                                             // at the start of the word
        await app.press("return")                                                    // split an indented bullet in the middle
        await app.typeKeys("tail")
        #expect(shape(tv.currentDoc.rows) == ["- parent", "  - XY", "  - tailchild"])
        #expect(problems(tv) == [])
        for _ in 0..<4 { await app.press("delete") }                         // backspace over "tail"
        #expect(shape(tv.currentDoc.rows) == ["- parent", "  - XY", "  - child"])
        await app.press("delete")                                            // and once more: into the bullet above
        #expect(shape(tv.currentDoc.rows) == ["- parent", "  - XYchild"])
        #expect(problems(tv) == [])
    }

    @Test func enterOnAnEmptyIndentedBulletStepsOutOneLevelAtATime() async throws {
        let (app, tv, g) = try await open()
        await app.typeKeys("a"); await app.press("return"); await app.press("tab"); await app.typeKeys("b"); await app.press("return"); await app.press("tab"); await app.typeKeys("c")
        await app.press("return")                                                    // new empty bullet at depth 2
        await app.press("return")                                                    // empty: steps out to depth 1
        #expect(shape(tv.currentDoc.rows) == ["- a", "  - b", "    - c", "  - "])
        await app.press("return")                                                    // and again, to depth 0
        #expect(shape(tv.currentDoc.rows) == ["- a", "  - b", "    - c", "- "])
        #expect(problems(tv) == [])
        await app.typeKeys("d")
        await app.settle(0.9)
        #expect(try saved(g) == ["- a", "  - b", "    - c", "- d"])
    }

    @Test func backspaceAtTheStartOfAnIndentedBulletMergesWithoutLosingTheChildrensIndent() async throws {
        let (app, tv, g) = try await open()
        await app.typeKeys("a"); await app.press("return"); await app.press("tab"); await app.typeKeys("b"); await app.press("return"); await app.press("tab"); await app.typeKeys("c"); await app.press("return"); await app.press("tab", ["shift"])
        await app.typeKeys("d")
        #expect(shape(tv.currentDoc.rows) == ["- a", "  - b", "    - c", "  - d"])
        await app.press("left")                                              // caret at the start of "d"
        await app.press("delete")                                            // merge d into c
        #expect(shape(tv.currentDoc.rows) == ["- a", "  - b", "    - cd"])
        #expect(problems(tv) == [])
        await app.settle(0.9)
        #expect(try saved(g) == shape(tv.currentDoc.rows))
    }

    @Test func indentingAParentCarriesItsChildrenAndOutdentingBringsThemBack() async throws {
        let (app, tv, g) = try await open()
        await app.typeKeys("a"); await app.press("return"); await app.typeKeys("b"); await app.press("return"); await app.press("tab"); await app.typeKeys("b1"); await app.press("return"); await app.typeKeys("b2")
        await app.press("up"); await app.press("up")                                         // caret on "b"
        await app.press("tab")                                                       // b goes under a, b1 and b2 come with it
        #expect(shape(tv.currentDoc.rows) == ["- a", "  - b", "    - b1", "    - b2"])
        await app.press("tab", ["shift"])                                            // and out again as a whole
        #expect(shape(tv.currentDoc.rows) == ["- a", "- b", "  - b1", "  - b2"])
        #expect(problems(tv) == [])
        await app.settle(0.9)
        #expect(try saved(g) == shape(tv.currentDoc.rows))
    }

    @Test func undoAndRedoPutIndentationBackExactly() async throws {
        let (app, tv, g) = try await open()
        await app.typeKeys("a"); await app.press("return"); await app.typeKeys("b"); await app.press("return"); await app.typeKeys("c")
        await app.settle(0.1)
        // The headless window has no Edit menu, so ⌘Z is sent to the undo manager directly.
        func step(_ key: String, _ mods: [String] = []) async { await app.press(key, mods); await app.settle(0.05) }
        await step("tab"); await step("tab", ["shift"]); await step("tab")
        let indented = shape(tv.currentDoc.rows)
        print("UNDOSTACK before:", tv.undoManager?.undoActionName ?? "-", tv.undoManager === tv.window?.undoManager)
        var trail: [String] = []
        for _ in 0..<3 { tv.undoManager?.undo(); await app.settle(0.05); trail.append("\(tv.undoManager?.undoActionName ?? "-")|\(tv.undoManager?.redoActionName ?? "-") undo→\(shape(tv.currentDoc.rows)) drawn=\(drawnRows(tv).map { "\($0.depth)/\($0.headIndent)/\($0.fragmentDepth)" }) sel=\(tv.selectedRange()) canRedo=\(tv.undoManager?.canRedo ?? false) levels=\(tv.undoManager?.levelsOfUndo ?? -1)") }
        #expect(problems(tv) == [])
        #expect(tv.currentDoc.rows.map(\.depth).allSatisfy { $0 == 0 })
        for _ in 0..<3 { tv.undoManager?.redo(); await app.settle(0.05); trail.append("redo→\(shape(tv.currentDoc.rows)) canRedo=\(tv.undoManager?.canRedo ?? false)") }
        print("UNDOTRAIL", trail.joined(separator: "\n"))
        #expect(shape(tv.currentDoc.rows) == indented)
        #expect(problems(tv) == [])
        await app.settle(0.9)
        let inDatabase = try saved(g)
        #expect(inDatabase == indented, "screen \(shape(tv.currentDoc.rows)) database \(inDatabase)")
    }

    @Test func movingBlocksWithTheKeyboardKeepsEveryRowAtItsDepth() async throws {
        let (app, tv, g) = try await open()
        await app.typeKeys("a"); await app.press("return"); await app.press("tab"); await app.typeKeys("a1"); await app.press("return"); await app.press("tab", ["shift"]); await app.typeKeys("b"); await app.press("return"); await app.press("tab"); await app.typeKeys("b1")
        await app.press("up", ["opt", "shift"])                                      // b1 can't leave b
        await app.press("up"); await app.press("up")                                         // onto "a1"
        await app.press("down", ["opt", "shift"])
        #expect(problems(tv) == [])
        await app.settle(0.9)
        #expect(try saved(g) == shape(tv.currentDoc.rows))
    }

    @Test func journalReopenedFromTheDatabaseIsDrawnAtTheSameDepths() async throws {
        let (app, tv, g) = try await open()
        await app.typeKeys("root"); await app.press("return"); await app.press("tab"); await app.typeKeys("kid"); await app.press("return"); await app.press("tab"); await app.typeKeys("grandkid")
        await app.settle(0.9)
        let reopened = HeadlessApp(graph: g)
        await reopened.settle(0.6)
        let again = reopened.textViews()[0]
        #expect(shape(again.currentDoc.rows) == shape(tv.currentDoc.rows))
        #expect(problems(again) == [])
    }

    @Test func undoStillWorksAfterThePauseThatSavesTheEdit() async throws {
        let (app, tv, g) = try await open()
        await app.typeKeys("a"); await app.press("return"); await app.typeKeys("b"); await app.press("tab")
        await app.settle(1.0)                                                // long enough to save and for the poller to notice
        #expect(shape(tv.currentDoc.rows) == ["- a", "  - b"])
        tv.undoManager?.undo()
        await app.settle(0.1)
        #expect(shape(tv.currentDoc.rows) == ["- a", "- b"], "undo after a save should still undo the indent")
        #expect(problems(tv) == [])
        await app.settle(1.0)                                                // the undo must be saved too, not overwritten by the database
        #expect(shape(tv.currentDoc.rows) == ["- a", "- b"], "the undone indent came back from the database")
        #expect(try saved(g) == ["- a", "- b"])
    }

    /// Clicks the empty strip under the last bullet.
    private func clickBelowLastBullet(_ app: HeadlessApp, _ tv: OutlineTextView) async {
        await app.settle(0.5)                                                // SwiftUI re-measures the editor after the last edit
        let p = tv.convert(NSPoint(x: 200, y: tv.bounds.maxY - 12), to: nil)
        // A window that is never shown doesn't route mouse events, so find the view under the point the way the window would and click that.
        let frame = app.window.contentView!.superview!
        let target = frame.hitTest(frame.convert(p, from: nil))
        #expect(target === tv, "the strip under the last bullet belongs to the editor")
        if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: app.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { target?.mouseDown(with: e) }
        await app.settle(0.1)
    }

    @Test func clickingBelowTheLastBulletShowsAGhostBulletAndTypingAddsABulletAtThatDepth() async throws {
        let (app, tv, g) = try await open()
        await app.typeKeys("one"); await app.press("return"); await app.press("tab"); await app.typeKeys("two")
        #expect(!tv.ghostShown)
        await clickBelowLastBullet(app, tv)
        #expect(tv.ghostShown, "the caret is on the empty line under the last bullet")
        #expect(shape(tv.currentDoc.rows) == ["- one", "  - two"], "nothing is created until you type")
        app.snapshot("ghost-bullet")
        await app.typeKeys("three")
        #expect(!tv.ghostShown, "the ghost becomes a real bullet")
        #expect(shape(tv.currentDoc.rows) == ["- one", "  - two", "  - three"])
        #expect(problems(tv) == [])
        await app.settle(0.9)
        #expect(try saved(g) == ["- one", "  - two", "  - three"])
    }

    @Test func theGhostBulletGoesAwayWhenYouClickElsewhereAndLeavesNothingBehind() async throws {
        let (app, tv, g) = try await open()
        await app.typeKeys("one"); await app.press("return"); await app.typeKeys("two")
        await app.settle(0.9)
        await clickBelowLastBullet(app, tv)
        #expect(tv.ghostShown)
        await app.press("up")
        #expect(!tv.ghostShown)
        await app.settle(0.9)
        #expect(shape(tv.currentDoc.rows) == ["- one", "- two"])
        #expect(try saved(g) == ["- one", "- two"])
    }

    @Test func clickingBelowAnEmptyLastBulletJustFocusesIt() async throws {
        let (app, tv, _) = try await open()
        await app.typeKeys("one"); await app.press("return")
        await clickBelowLastBullet(app, tv)
        #expect(!tv.ghostShown, "the empty bullet is already the place to type")
        #expect(shape(tv.currentDoc.rows) == ["- one", "- "])
    }

    /// Random typing, Enter, Tab, Shift-Tab, Backspace, arrows, moves and undo against a real window; after every key the outline must be sound,
    /// and once saved the database must hold exactly what is on screen.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64]) func randomKeystrokesNeverLeaveTheIndentationWrong(seed: UInt64) async throws {
        let (app, tv, g) = try await open()
        var rng = SeededRandom(seed)
        var log: [String] = []
        let words = ["alpha", "beta", "gamma", "delta", "x", "yy"]
        for step in 0..<70 {
            let n = Int.random(in: 0..<14, using: &rng)
            switch n {
            case 0, 1, 2: let w = words.randomElement(using: &rng)!; await app.typeKeys(w); log.append("type \(w)")
            case 3, 4: await app.press("return"); log.append("return")
            case 5, 6: await app.press("tab"); log.append("tab")
            case 7: await app.press("tab", ["shift"]); log.append("shift-tab")
            case 8: await app.press("delete"); log.append("backspace")
            case 9: await app.press("up"); log.append("up")
            case 10: await app.press("down"); log.append("down")
            case 11: await app.press(Bool.random(using: &rng) ? "up" : "down", ["opt", "shift"]); log.append("move block")
            case 12: await app.press("left"); log.append("left")
            default: tv.undoManager?.undo(); await app.settle(0.02); log.append("undo")
            }
            let found = problems(tv)
            if !found.isEmpty {
                Issue.record("seed \(seed), after step \(step) (\(log.suffix(8).joined(separator: ", "))): \(found.joined(separator: "; "))\n\(shape(tv.currentDoc.rows).joined(separator: "\n"))")
                return
            }
        }
        await app.settle(1.2)
        let screen = shape(tv.currentDoc.rows)
        let inDatabase = try saved(g)
        #expect(inDatabase == screen || screen == ["- "], "seed \(seed): the database differs from the screen\nscreen:\n\(screen.joined(separator: "\n"))\ndatabase:\n\(inDatabase.joined(separator: "\n"))\nsteps: \(log.joined(separator: ", "))")
    }
}
#endif

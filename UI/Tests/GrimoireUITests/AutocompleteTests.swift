import Foundation
import Testing
import GrimoireCore
@testable import GrimoireUI

@Suite struct AutocompleteTests {
    private func trig(_ s: String, _ caret: Int? = nil) -> AutocompleteTrigger? { Autocomplete.detect(text: s, caret: caret ?? (s as NSString).length) }

    @Test func detectsLinkTagBlockRefAndSlash() {
        #expect(trig("see [[Foc") == AutocompleteTrigger(kind: .page, query: "Foc", range: NSRange(location: 4, length: 5)))
        #expect(trig("see #re")?.kind == .tag && trig("see #re")?.query == "re")
        #expect(trig("#")?.kind == .tag && trig("#")?.query == "")
        #expect(trig("a ((blo")?.kind == .blockRef)
        #expect(trig("/he")?.kind == .command && trig("do /he")?.query == "he")
    }

    @Test func nothingWhereATriggerHasEndedOrIsntAWordStart() {
        #expect(trig("[[done]] and more") == nil)
        #expect(trig("a#b") == nil)
        #expect(trig("a/b") == nil)
        #expect(trig("https://x.com/path") == nil)
        #expect(trig("#tag done") == nil)
        #expect(trig("[[a]] then [[b")?.query == "b")
    }

    @Test func caretInsideAutoPairedBracketsStillTriggers() {
        let t = trig("[[Foc]]", 5)
        #expect(t?.kind == .page && t?.query == "Foc")
    }

    @Test func rankingExactPrefixWordContainsFuzzy() {
        let titles = ["Slow cooker", "Cooking notes", "cook", "Xcode ok", "c-o-o-k"]
        let ranked = titles.compactMap { t in Autocomplete.score(query: "cook", title: t).map { (t, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
        #expect(ranked.first == "cook")
        #expect(Array(ranked.prefix(3)) == ["cook", "Cooking notes", "Slow cooker"])
        #expect(Autocomplete.score(query: "zzz", title: "cook") == nil)
        #expect(Autocomplete.score(query: "ckn", title: "Cooking notes") != nil)
    }

    @Test func pageItemsOfferCreateWhenThereIsNoExactMatch() {
        let src = AutocompleteSource(pages: { _ in ["Focaccia", "Focus"] })
        let items = Autocomplete.items(for: trig("[[Foc")!, source: src)
        #expect(items.map(\.title) == ["Focaccia", "Focus", "Foc"])
        #expect(items.last?.isCreate == true)
        let exact = Autocomplete.items(for: trig("[[focus")!, source: src)
        #expect(exact.last?.isCreate == false)
    }

    @Test func tagItemsMergeTagsAndPagesWithoutDuplicates() {
        let src = AutocompleteSource(pages: { _ in ["Recipe", "Reading list"] }, tags: { _ in ["recipe", "reading"] })
        let items = Autocomplete.items(for: trig("#re")!, source: src)
        #expect(items.map(\.title) == ["recipe", "reading", "Reading list", "re"])
        #expect(items.first { $0.title == "Reading list" }?.insertion == "#[[Reading list]]")
    }

    @Test func slashCommandsFilterByTitleAndKeyword() {
        let src = AutocompleteSource()
        #expect(Autocomplete.items(for: trig("/h2")!, source: src).first?.insertion == "## ")
        #expect(Autocomplete.items(for: trig("/mer")!, source: src).first?.title == "Mermaid diagram")
        #expect(Autocomplete.items(for: trig("/")!, source: src).count > 8)
        #expect(Autocomplete.items(for: trig("/today")!, source: src, today: JournalDate(year: 2026, month: 10, day: 5)!).first?.insertion.hasPrefix("[[") == true)
    }

    @Test func insertingALinkConsumesTheAutoPairedClosersAndParksTheCaretAfter() {
        let text = "see [[Foc]] ok"
        let t = trig(text, 9)!
        let e = Autocomplete.edit(for: AutocompleteItem(title: "Focaccia", detail: nil, insertion: "[[Focaccia]]"), trigger: t, in: text)
        #expect(e.range == NSRange(location: 4, length: 7))
        #expect(e.text == "[[Focaccia]]")
        #expect(e.caret == 4 + 12)
    }

    @Test func insertingATagAddsASpaceAndACodeFenceParksTheCaretInside() {
        let tag = Autocomplete.edit(for: AutocompleteItem(title: "recipe", detail: nil, insertion: "#recipe"), trigger: trig("x #re")!, in: "x #re")
        #expect(tag.text == "#recipe " && tag.caret == 2 + 8)
        let cmd = Autocomplete.items(for: trig("/code")!, source: AutocompleteSource())[0]
        let e = Autocomplete.edit(for: cmd, trigger: trig("/code")!, in: "/code")
        #expect(e.text == "```\u{2028}\u{2028}```" && e.caret == 4)
    }
}

import Foundation
import Testing
@testable import GrimoireUI

private func texts(_ text: String, _ style: Style) -> [String] {
    let ns = text as NSString
    return MarkdownStyler.spans(for: text).filter { $0.style == style }.map { ns.substring(with: $0.range) }
}

@Suite struct MarkdownStylerTests {
    @Test func emptyIsEmpty() { #expect(MarkdownStyler.spans(for: "").isEmpty) }
    @Test func plainTextHasNoSpans() { #expect(MarkdownStyler.spans(for: "just some words").isEmpty) }

    @Test func boldItalicStrike() {
        #expect(texts("a **b** c", .bold) == ["b"])
        #expect(texts("a __b__ c", .bold) == ["b"])
        #expect(texts("a *b* c", .italic) == ["b"])
        #expect(texts("a _b_ c", .italic) == ["b"])
        #expect(texts("a ***b*** c", .boldItalic) == ["b"])
        #expect(texts("a ~~b~~ c", .strike) == ["b"])
        #expect(texts("**b**", .marker) == ["**", "**"])
        #expect(texts("~~b~~", .marker) == ["~~", "~~"])
    }

    @Test func nesting() {
        let t = "**bold _x_**"
        #expect(texts(t, .bold) == ["bold _x_"])
        #expect(texts(t, .italic) == ["x"])
        #expect(texts(t, .marker) == ["**", "_", "_", "**"])
        #expect(texts("*a **b** c*", .italic) == ["a **b** c"])
        #expect(texts("*a **b** c*", .bold) == ["b"])
    }

    @Test func unclosedDelimitersStyleNothing() {
        for t in ["**a", "*a", "_a", "~~a", "a ** b **", "x * y", "`a", "[[a", "((a"] {
            #expect(MarkdownStyler.spans(for: t).isEmpty, "\(t)")
        }
    }

    @Test func snakeCaseIsNotItalic() {
        #expect(MarkdownStyler.spans(for: "use snake_case_name here").isEmpty)
        #expect(texts("a_b and _c_", .italic) == ["c"])
    }

    @Test func inlineCodeProtectsContents() {
        let t = "x `**not** [[a]] #t` y"
        #expect(texts(t, .code) == ["**not** [[a]] #t"])
        #expect(texts(t, .marker) == ["`", "`"])
        #expect(texts(t, .bold).isEmpty)
        #expect(texts(t, .link).isEmpty)
        #expect(texts(t, .tag).isEmpty)
        #expect(texts("**a `**` b**", .bold) == ["a `**` b"])
    }

    @Test func fencedBlockAcrossLineSeparators() {
        let t = "intro **b**\u{2028}```swift\u{2028}let a = **x** #t\u{2028}```\u{2028}after #tag"
        #expect(texts(t, .codeBlock) == ["```swift", "let a = **x** #t", "```"])
        #expect(texts(t, .bold) == ["b"])
        #expect(texts(t, .tag) == ["#tag"])
        #expect(texts(t, .marker) == ["**", "**", "```", "```"])
        let n = "```\nx **y**\n```"
        #expect(texts(n, .codeBlock) == ["```", "x **y**", "```"])
        #expect(texts("```\nx **y**", .bold).isEmpty) // unclosed fence runs to the end
    }

    @Test func wikiLinks() {
        let t = "see [[My Page]] now"
        #expect(texts(t, .link) == ["My Page"])
        #expect(texts(t, .marker) == ["[[", "]]"])
    }

    @Test func bracketTag() {
        let t = "a #[[two words]] b"
        #expect(texts(t, .tag) == ["#[[two words]]"])
        #expect(texts(t, .marker) == ["#[[", "]]"])
        #expect(texts(t, .link).isEmpty)
    }

    @Test func blockRef() {
        let t = "x ((6502f2c1-aaaa)) y"
        #expect(texts(t, .blockRef) == ["((6502f2c1-aaaa))"])
        #expect(texts(t, .marker) == ["((", "))"])
        #expect(texts("(a b) ((a b))", .blockRef).isEmpty)
    }

    @Test func urls() {
        #expect(texts("go https://a.com/x?y=1. ok", .url) == ["https://a.com/x?y=1"])
        #expect(texts("http://a.com", .url) == ["http://a.com"])
        #expect(texts("**https://a.com**", .url) == ["https://a.com"])
    }

    @Test func markdownLinksAndImages() {
        let t = "a [label](https://x.com) b"
        #expect(texts(t, .markdownLink) == ["label"])
        #expect(texts(t, .linkTarget) == ["(https://x.com)"])
        #expect(texts(t, .url).isEmpty)
        let i = "a ![alt](pic.png) b"
        #expect(texts(i, .image) == ["![alt](pic.png)"])
        #expect(texts(i, .linkTarget) == ["(pic.png)"])
        #expect(texts(i, .markdownLink).isEmpty)
    }

    @Test func headings() {
        for n in 1...6 {
            let t = String(repeating: "#", count: n) + " Title **b**"
            #expect(texts(t, .heading(n)) == ["Title **b**"])
            #expect(texts(t, .marker).first == String(repeating: "#", count: n))
            #expect(texts(t, .bold) == ["b"])
            #expect(texts(t, .tag).isEmpty)
        }
        #expect(texts("####### seven", .heading(6)).isEmpty)
        #expect(MarkdownStyler.spans(for: "####### seven").isEmpty)
        #expect(texts("a\u{2028}## Two", .heading(2)) == ["Two"])
    }

    @Test func tagsVersusHeadingsAndFragments() {
        #expect(texts("#tag", .tag) == ["#tag"])
        #expect(texts("x #tag, and #other.", .tag) == ["#tag", "#other"])
        #expect(texts("a\u{2028}#tag", .tag) == ["#tag"])
        #expect(texts("I like C# a lot", .tag).isEmpty)
        #expect(texts("C#sharp", .tag).isEmpty)
        #expect(texts("https://a.com/#frag", .tag).isEmpty)
        #expect(texts("see https://a.com/#frag #real", .tag) == ["#real"])
        #expect(texts("# Heading", .tag).isEmpty)
        #expect(texts("a # b", .tag).isEmpty)
    }

    @Test func taskMarkers() {
        #expect(texts("TODO write it", .taskMarker(.todo)) == ["TODO"])
        #expect(texts("DOING write it", .taskMarker(.doing)) == ["DOING"])
        #expect(texts("DONE write it", .taskMarker(.done)) == ["DONE"])
        #expect(texts("DONE **b**", .bold) == ["b"])
        #expect(MarkdownStyler.spans(for: "x TODO later").isEmpty)
        #expect(MarkdownStyler.spans(for: "a\u{2028}TODO later").isEmpty)
        #expect(MarkdownStyler.spans(for: "TODOS later").isEmpty)
        #expect(MarkdownStyler.spans(for: "TODO").isEmpty)
    }

    @Test func quotes() {
        let t = "> quoted **b**\u{2028}plain"
        #expect(texts(t, .quote) == ["> quoted **b**"])
        #expect(texts(t, .marker).first == ">")
        #expect(texts(t, .bold) == ["b"])
        #expect(texts(">no space", .quote).isEmpty)
    }

    @Test func propertyLines() {
        let t = "title:: Hello [[World]] #x\u{2028}other-key.1:: v"
        #expect(texts(t, .propertyKey) == ["title::", "other-key.1::"])
        #expect(texts(t, .propertyValue) == ["Hello [[World]] #x", "v"])
        #expect(texts(t, .link) == ["World"])
        #expect(texts(t, .tag) == ["#x"])
        #expect(texts("see a:: b", .propertyKey).isEmpty)
        #expect(texts("https://a.com", .propertyKey).isEmpty)
    }

    @Test func utf16OffsetsWithEmojiAndAccents() {
        let t = "🌙 **bold** café #tag"
        let ns = t as NSString
        let spans = MarkdownStyler.spans(for: t)
        let bold = spans.first { $0.style == .bold }!
        #expect(bold.range == NSRange(location: 5, length: 4))
        #expect(ns.substring(with: bold.range) == "bold")
        let tag = spans.first { $0.style == .tag }!
        #expect(ns.substring(with: tag.range) == "#tag")
        #expect(tag.range.location == ns.length - 4)
        #expect(texts("🌙_x_", .italic) == ["x"])
        #expect(texts("café_x_", .italic).isEmpty)
    }

    @Test func sortedByLocationThenLongerFirst() {
        let spans = MarkdownStyler.spans(for: "# T **b** [[a]] #[[c d]] `e`")
        for (a, b) in zip(spans, spans.dropFirst()) {
            #expect(a.range.location < b.range.location
                    || (a.range.location == b.range.location && a.range.length >= b.range.length))
        }
        let t = "#[[c d]]"
        #expect(MarkdownStyler.spans(for: t).first?.style == .tag)
    }

    @Test func tenThousandCharactersIsFast() {
        let unit = "Some **bold** and _it_ with [[Page]] #tag `code` https://a.com/x ((abc-1)) ~~s~~ snake_case_x "
        var text = ""
        while text.utf16.count < 10_000 { text += unit }
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure { count = MarkdownStyler.spans(for: text).count }
        #expect(count > 100)
        #expect(elapsed < .milliseconds(50), "took \(elapsed)")
    }
}

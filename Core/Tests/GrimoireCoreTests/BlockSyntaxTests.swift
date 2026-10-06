import Testing
@testable import GrimoireCore

@Suite struct BlockSyntaxTests {
    @Test func extractsLinksTagsRefs() {
        let p = BlockSyntax.parse("Met [[Rob Gersch]] about #job-search and #[[DDIA ch 5]] see ((6721b0c4-1111-4222-8333-944455556666))")
        #expect(p.pageLinks == ["Rob Gersch"])
        #expect(p.tags == ["job-search", "DDIA ch 5"])
        #expect(p.blockRefs == ["6721b0c4-1111-4222-8333-944455556666"])
    }

    @Test func extractsProperties() {
        let p = BlockSyntax.parse("Focaccia\ntotal-time:: 3h\nserves:: 8\nmood:: [[calm]], [[tired]]")
        #expect(p.properties == [
            PropertyLine(key: "total-time", value: "3h"),
            PropertyLine(key: "serves", value: "8"),
            PropertyLine(key: "mood", value: "[[calm]], [[tired]]"),
        ])
        #expect(p.pageLinks == ["calm", "tired"])
    }

    @Test func detectsTaskMarker() {
        #expect(BlockSyntax.parse("TODO call vet").task == .todo)
        #expect(BlockSyntax.parse("DOING x").task == .doing)
        #expect(BlockSyntax.parse("todo call").task == nil)
    }

    @Test func ignoresRefsInInlineCode() {
        let p = BlockSyntax.parse("`[[x]] #y` z")
        #expect(p.pageLinks.isEmpty && p.tags.isEmpty)
    }

    @Test func ignoresRefsInFencedCode() {
        let p = BlockSyntax.parse("```\n[[x]]\nk:: v\n```")
        #expect(p.pageLinks.isEmpty && p.properties.isEmpty)
    }

    @Test func hashInsideWordOrURLIsNotATag() {
        #expect(BlockSyntax.parse("C# and https://a.com/#frag").tags.isEmpty)
        #expect(BlockSyntax.parse("# Heading").tags.isEmpty)
    }

    @Test func replacingPageReferences() {
        let out = BlockSyntax.replacingPageReferences(in: "[[Old]] #Old #[[Old]] [[Older]]", from: "Old", to: "New")
        #expect(out == "[[New]] #New #[[New]] [[Older]]")
        let spaced = BlockSyntax.replacingPageReferences(in: "[[old]] #Old #[[Old]]", from: "Old", to: "New Name")
        #expect(spaced == "[[New Name]] #[[New Name]] #[[New Name]]")
        let code = BlockSyntax.replacingPageReferences(in: "`[[Old]]` [[Old]]", from: "Old", to: "New")
        #expect(code == "`[[Old]]` [[New]]")
    }
}

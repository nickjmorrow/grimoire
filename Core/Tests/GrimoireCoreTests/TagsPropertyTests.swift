import Testing
@testable import GrimoireCore

@Suite struct TagsPropertyTests {
    @Test func tagsPropertyCreatesRealTags() throws {
        let g = try graphWithHome()
        try g.add("b1", "Focaccia\ntags:: [[recipe]], [[dessert]]")
        #expect(try g.count("SELECT COUNT(*) FROM block_tags WHERE block_id = 'b1'") == 2)
        #expect(try g.blocks(taggedWith: "Recipe").map(\.id) == ["b1"])
        #expect(try g.count("SELECT COUNT(*) FROM tags WHERE name_lower IN ('recipe','dessert')") == 2)
    }

    @Test func tagsPropertySurvivesReindexAndEdit() throws {
        let g = try graphWithHome()
        try g.add("b1", "x\ntags:: [[recipe]]")
        try g.reindex()
        #expect(try g.count("SELECT COUNT(*) FROM block_tags WHERE block_id = 'b1'") == 1)
        try g.perform([.editText(blockID: "b1", text: "x")], author: .me)
        #expect(try g.count("SELECT COUNT(*) FROM block_tags WHERE block_id = 'b1'") == 0)
    }
}

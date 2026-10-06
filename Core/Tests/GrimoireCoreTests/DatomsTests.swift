import Testing
@testable import GrimoireCore

let miniDatoms = #"""
{:logseq.db.sqlite.export/schema-version {:major 65 :minor 33}
 :logseq.db.sqlite.export/graph-format :datoms
 :datoms [[1 :block/name "rob"] [1 :block/title "Rob"] [1 :block/uuid #uuid "6AB1C4B7-A911-4026-9BF7-41ABA29CEE0C"]
          [2 :block/page 1] [2 :block/title "met"] [2 :block/refs 1] [2 :block/refs 3] [2 :block/collapsed? true]
          [2 :block/created-at 1790035125466]
          [3 :db/ident :user.class/person]]}
"""#

@Suite struct DatomsTests {
    @Test func groupsByEntityAndAttribute() throws {
        let d = try Datoms(exportText: miniDatoms)
        #expect(d.entities == [1, 2, 3])
        #expect(d.values(2, ":block/refs") == [.int(1), .int(3)])
        #expect(d.attributes(of: 2).sorted() == [":block/collapsed?", ":block/created-at", ":block/page", ":block/refs", ":block/title"])
        #expect(d.entities(having: ":block/page") == [2])
    }

    @Test func typedAccessors() throws {
        let d = try Datoms(exportText: miniDatoms)
        #expect(d.string(1, ":block/title") == "Rob")
        #expect(d.int(2, ":block/created-at") == 1_790_035_125_466)
        #expect(d.bool(2, ":block/collapsed?") && !d.bool(1, ":block/collapsed?"))
        #expect(d.refs(2, ":block/refs") == [1, 3])
        #expect(d.string(2, ":nope") == nil)
    }

    @Test func findsByIdentAndLowercasedUuid() throws {
        let d = try Datoms(exportText: miniDatoms)
        #expect(d.entity(withIdent: ":user.class/person") == 3)
        #expect(d.entity(withUUID: "6ab1c4b7-a911-4026-9bf7-41aba29cee0c") == 1)
        #expect(d.entity(withUUID: "00000000-0000-0000-0000-000000000000") == nil)
    }

    @Test func rejectsOtherExportShapes() {
        #expect(throws: ImportError.notADatomExport) { try Datoms(exportText: "{:foo 1}") }
        #expect(throws: ImportError.notADatomExport) { try Datoms(exportText: "[1 2]") }
    }
}

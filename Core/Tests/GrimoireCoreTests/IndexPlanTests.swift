import Foundation
import GRDB
import Testing
@testable import GrimoireCore

/// Lookups that run on every delete, rename, tag listing and history query must be index searches, not table scans.
@Suite struct IndexPlanTests {
    private func plan(_ sql: String) throws -> String {
        let g = try Graph(folder: tempFolder(), device: "plan")
        return try g.db.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: ["x"]).map { $0["detail"] as String }.joined(separator: "\n")
        }
    }

    @Test func childBlocksByParentUseAnIndex() throws {
        let p = try plan("SELECT id FROM blocks WHERE parent_id = ?")
        #expect(p.contains("USING INDEX") || p.contains("USING COVERING INDEX"), "\(p)")
    }

    @Test func blocksByTagUseAnIndex() throws {
        let p = try plan("SELECT block_id FROM block_tags WHERE tag_id = ?")
        #expect(p.contains("block_tags_tag"), "\(p)")
    }

    @Test func tagsByPageUseAnIndex() throws {
        let p = try plan("SELECT id FROM tags WHERE page_id = ?")
        #expect(p.contains("tags_page"), "\(p)")
    }

    @Test func opsSinceATimeUseAnIndex() throws {
        let p = try plan("SELECT local_id FROM ops WHERE created_at >= ?")
        #expect(p.contains("ops_created"), "\(p)")
    }
}

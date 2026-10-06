import Foundation
import GRDB
import Testing
@testable import GrimoireCore

func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("grim-test-\(UUID().uuidString)")
    return url
}

@Suite struct GraphTests {
    @Test func openCreatesSchemaAndFolders() throws {
        let folder = tempFolder()
        let graph = try Graph(folder: folder, device: "test")
        let tables: [String] = try graph.db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table','view')")
        }
        for t in ["pages", "blocks", "tags", "block_tags", "properties", "block_props", "assets", "ops", "links", "search"] {
            #expect(tables.contains(t), "missing table \(t)")
        }
        for sub in ["assets", "mirror/journals", "mirror/pages", "themes"] {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(sub).path, isDirectory: &isDir) && isDir.boolValue)
        }
        let mode = try graph.db.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }

    @Test func reopenIsIdempotent() throws {
        let folder = tempFolder()
        _ = try Graph(folder: folder, device: "test")
        let again = try Graph(folder: folder, device: "test")
        let n = try again.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations") }
        #expect(n == Schema.migrator().migrations.count)
    }

    @Test func twoGraphsOnOneFolderWriteConcurrently() async throws {
        let folder = tempFolder()
        let a = try Graph(folder: folder, device: "a")
        let b = try Graph(folder: folder, device: "b")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (name, g) in [("a", a), ("b", b)] {
                group.addTask {
                    for i in 0..<200 {
                        try await g.db.write { db in
                            try db.execute(sql: "INSERT INTO properties (id, key, type, cardinality) VALUES (?, ?, 'text', 'one')",
                                           arguments: [UUID().uuidString.lowercased(), "\(name)-\(i)"])
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        let count = try await a.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM properties") }
        #expect(count == 400)
    }
}

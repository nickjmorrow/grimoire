import Foundation
import GRDB

/// Notices commits made by anyone (this process or another, such as the CLI) by watching SQLite's `data_version`.
public final class ChangeWatcher: @unchecked Sendable {
    private let queue: DatabaseQueue

    public init(graph: Graph) throws {
        var config = Configuration()
        config.readonly = true
        queue = try DatabaseQueue(path: graph.folder.appendingPathComponent("graph.sqlite").path, configuration: config)
    }

    /// Changes whenever any other connection commits to the database.
    public func version() -> Int64 {
        (try? queue.read { try Int64.fetchOne($0, sql: "PRAGMA data_version") }) ?? 0
    }
}

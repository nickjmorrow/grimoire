import Foundation
import GRDB

public final class Graph: Sendable {
    public let folder: URL
    public let device: String
    public let db: DatabasePool

    public init(folder: URL, device: String) throws {
        self.folder = folder
        self.device = device
        let fm = FileManager.default
        for sub in ["", "assets", "mirror/journals", "mirror/pages", "themes"] {
            try fm.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous=FULL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        db = try DatabasePool(path: folder.appendingPathComponent("graph.sqlite").path, configuration: config)
        try Schema.migrator().migrate(db)
    }
}

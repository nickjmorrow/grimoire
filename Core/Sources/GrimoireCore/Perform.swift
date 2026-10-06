import Foundation
import GRDB

extension Graph {
    public static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Applies ops in one transaction, logs each with its inverse, and returns their local ids.
    /// If any op throws, nothing is applied or logged.
    @discardableResult
    public func perform(_ ops: [Op], author: Author) throws -> [Int64] {
        try db.write { try Graph.perform(ops, in: $0, device: device, author: author) }
    }

    static func perform(_ ops: [Op], in db: Database, device: String, author: Author) throws -> [Int64] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var ids: [Int64] = []
        for op in ops {
            let now = nowMillis()
            let inverse = try Applier.apply(op, in: db, now: now, author: author)
            try db.execute(
                sql: "INSERT INTO ops (device, author, kind, payload, inverse, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [
                    device, author.rawValue, op.kind,
                    String(decoding: try encoder.encode(op), as: UTF8.self),
                    try inverse.map { String(decoding: try encoder.encode($0), as: UTF8.self) },
                    now,
                ])
            ids.append(db.lastInsertedRowID)
        }
        return ids
    }
}

enum Applier {
    /// Applies one op and returns the op that undoes it (nil when there is nothing to undo).
    static func apply(_ op: Op, in db: Database, now: Int64, author: Author) throws -> Op? {
        switch op {
        case let .createPage(id, title, kind, journalDate):
            return try createPage(id: id, title: title, kind: kind, journalDate: journalDate, in: db, now: now)
        case let .renamePage(id, title):
            return try renamePage(id: id, title: title, in: db, now: now)
        case let .setFavorite(pageID, favorite, order):
            return try setFavorite(pageID: pageID, favorite: favorite, order: order, in: db, now: now)
        case let .deletePage(id):
            return try deletePage(id: id, in: db)
        case let .discardPage(id):
            return try discardPage(id: id, in: db)
        case let .addAsset(hash, filename, mime, size):
            try Asset(hash: hash, filename: filename, mime: mime, size: size, createdAt: now).insert(db, onConflict: .ignore)
            return nil
        case .reviewCard, .setCard:
            return try CardApplier.apply(op, in: db)
        case let .batch(ops):
            var inverses: [Op] = []
            for o in ops { if let inv = try apply(o, in: db, now: now, author: author) { inverses.append(inv) } }
            return .batch(inverses.reversed())
        default:
            return try BlockApplier.apply(op, in: db, now: now, author: author)
        }
    }
}

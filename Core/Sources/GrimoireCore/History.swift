import Foundation
import GRDB

public struct Change: Sendable {
    public let localID: Int64
    public let author: Author
    public let op: Op
    public let createdAt: Int64
}

public struct UndoResult: Sendable, Equatable {
    public var undone: Int
    /// Ops whose inverse could not be applied safely (later work depends on them, or their target is gone).
    public var skipped: [String]
}

extension Graph {
    /// Logged ops at or after `since` (milliseconds since the epoch), oldest first, optionally by one author.
    public func changes(since: Int64, author: Author? = nil) throws -> [Change] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT local_id, author, payload, created_at FROM ops
                WHERE created_at >= ? AND (? IS NULL OR author = ?) ORDER BY local_id
                """, arguments: [since, author?.rawValue, author?.rawValue]).map { row in
                Change(localID: row["local_id"], author: Author(rawValue: row["author"])!,
                       op: try JSONDecoder().decode(Op.self, from: Data((row["payload"] as String).utf8)),
                       createdAt: row["created_at"])
            }
        }
    }

    /// Undoes the most recent `count` ops that haven't been undone (optionally only one author's), by performing their
    /// stored inverses as new ops. An inverse that would destroy later work, or whose target is gone, is skipped and
    /// marked void so it never blocks the ones behind it. Undo ops are never themselves undone.
    public func undoDetailed(author: Author? = nil, count: Int = 1, onlyOp: Int64? = nil) throws -> UndoResult {
        try db.write { db in
            var result = UndoResult(undone: 0, skipped: [])
            while result.undone < count {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT local_id, inverse FROM ops
                    WHERE inverse IS NOT NULL AND undone_by IS NULL AND undoes IS NULL AND local = 1 AND rejected = 0 AND (? IS NULL OR author = ?) AND (? IS NULL OR local_id = ?)
                    ORDER BY local_id DESC LIMIT 1
                    """, arguments: [author?.rawValue, author?.rawValue, onlyOp, onlyOp]) else { break }
                let originalID: Int64 = row["local_id"]
                let inverse = try JSONDecoder().decode(Op.self, from: Data((row["inverse"] as String).utf8))
                do {
                    try db.inSavepoint {
                        let newIDs = try Graph.perform([inverse], in: db, device: device, author: author ?? .me)
                        try db.execute(sql: "UPDATE ops SET undoes = ? WHERE local_id = ?", arguments: [originalID, newIDs[0]])
                        try db.execute(sql: "UPDATE ops SET undone_by = ? WHERE local_id = ?", arguments: [newIDs[0], originalID])
                        return .commit
                    }
                    result.undone += 1
                } catch let error as GraphError {
                    try db.execute(sql: "UPDATE ops SET undone_by = -1 WHERE local_id = ?", arguments: [originalID])
                    result.skipped.append("op \(originalID): \(error)")
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    try db.execute(sql: "UPDATE ops SET undone_by = -1 WHERE local_id = ?", arguments: [originalID])
                    result.skipped.append("op \(originalID): \(error.message ?? "constraint failed")")
                }
            }
            return result
        }
    }

    /// Undoes one specific op (by its local id) if it is still undoable. Returns whether it was.
    @discardableResult
    public func undoOp(_ localID: Int64) throws -> Bool { try undoDetailed(count: 1, onlyOp: localID).undone == 1 }

    /// Same as `undoDetailed`, returning only how many ops were undone.
    @discardableResult
    public func undo(author: Author? = nil, count: Int = 1) throws -> Int {
        try undoDetailed(author: author, count: count).undone
    }
}

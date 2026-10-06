import CryptoKit
import Foundation
import GRDB

/// The sequencer. The hub runs one of these over its hub graph: it applies each device's ops on top of the head and numbers them.
public final class SyncHub: Sendable {
    public let graph: Graph
    public init(graph: Graph) { self.graph = graph }

    public func head() throws -> Int64 { try graph.db.read { try Int64.fetchOne($0, sql: "SELECT COALESCE(MAX(seq), 0) FROM ops") ?? 0 } }

    /// Ops made directly on the hub's own graph (Claude's `grim` on the hub, say) are already applied there; give them their place in the order.
    private static func sequenceLocal(_ db: Database) throws {
        var head = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM ops") ?? 0
        for id in try Int64.fetchAll(db, sql: "SELECT local_id FROM ops WHERE seq IS NULL AND local = 1 AND rejected = 0 ORDER BY local_id") {
            head += 1
            try db.execute(sql: "UPDATE ops SET seq = ?, origin_local_id = local_id WHERE local_id = ?", arguments: [head, id])
        }
    }

    public func pull(since: Int64, limit: Int = 5000) throws -> [RemoteOp] {
        try graph.db.write { try Self.sequenceLocal($0) }
        return try graph.db.read { db in
            try Row.fetchAll(db, sql: "SELECT seq, device, COALESCE(origin_local_id, local_id) AS origin, author, payload, created_at FROM ops WHERE seq > ? ORDER BY seq LIMIT ?",
                             arguments: [since, limit]).map {
                RemoteOp(seq: $0["seq"], device: $0["device"], originLocalID: $0["origin"], author: $0["author"], payload: $0["payload"], createdAt: $0["created_at"])
            }
        }
    }

    /// Applies `ops` from `device` if `base` is the current head (the device has seen everything). Ops that cannot be applied are rejected one by one.
    public func push(device: String, base: Int64, ops: [OutgoingOp]) throws -> PushResult {
        try graph.db.write { db in
            try Self.sequenceLocal(db)
            var head = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM ops") ?? 0
            guard base == head else { return .behind(head: head) }
            var assigned: [SeqAssignment] = [], rejected: [Rejection] = []
            // Ops are taken in order and the first one that cannot be applied stops the batch: later ops may depend on it,
            // and the client re-bases the rest on top of what was taken and sends them again.
            for o in ops {
                if let seq = try Int64.fetchOne(db, sql: "SELECT seq FROM ops WHERE device = ? AND origin_local_id = ? AND payload = ? AND seq IS NOT NULL",
                                                arguments: [device, o.localID, o.payload]) {
                    assigned.append(SeqAssignment(localID: o.localID, seq: seq)); continue          // a retry of something already taken
                }
                guard let op = try? JSONDecoder().decode(Op.self, from: Data(o.payload.utf8)), let author = Author(rawValue: o.author) else {
                    rejected.append(Rejection(localID: o.localID, reason: "unreadable op")); break
                }
                switch SyncApply.apply(op, author: author, now: o.createdAt, in: db) {
                case .failure(let e):
                    rejected.append(Rejection(localID: o.localID, reason: "\(e)"))
                case .success(let inverse):
                    head += 1
                    try SyncApply.record(device: device, origin: o.localID, author: author, payload: o.payload, inverse: inverse, createdAt: o.createdAt, seq: head, in: db)
                    assigned.append(SeqAssignment(localID: o.localID, seq: head))
                    continue
                }
                break
            }
            return .accepted(assigned: assigned, rejected: rejected)
        }
    }

    // MARK: assets

    public func assetURL(hash: String) -> URL? {
        guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        let folder = graph.folder.appendingPathComponent("assets")
        return (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first { $0 == hash || $0.hasPrefix(hash + ".") }.map { folder.appendingPathComponent($0) }
    }

    public func putAsset(hash: String, filename: String?, data: Data) throws {
        guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, assetURL(hash: hash) == nil else { return }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else { throw SyncError.assetHashMismatch(hash) }
        let ext = filename.map { ($0 as NSString).pathExtension } ?? ""
        try data.write(to: graph.folder.appendingPathComponent("assets/\(ext.isEmpty ? hash : "\(hash).\(ext)")"), options: .atomic)
    }
}

/// Shared by the hub and clients: apply one op without logging, inside a savepoint that undoes a partial failure.
enum SyncApply {
    static func apply(_ op: Op, author: Author, now: Int64, in db: Database) -> Result<Op?, Error> {
        var result: Result<Op?, Error> = .success(nil)
        do {
            try db.inSavepoint {
                do { result = .success(try Applier.apply(op, in: db, now: now, author: author)); return .commit }
                catch { result = .failure(error); return .rollback }
            }
        } catch { return .failure(error) }
        return result
    }

    static func record(device: String, origin: Int64?, author: Author, payload: String, inverse: Op?, createdAt: Int64, seq: Int64?, in db: Database) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let kind = (try? JSONDecoder().decode(Op.self, from: Data(payload.utf8)))?.kind ?? "op"
        try db.execute(sql: "INSERT INTO ops (device, origin_local_id, author, kind, payload, inverse, created_at, seq, local) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)",
                       arguments: [device, origin, author.rawValue, kind, payload, try inverse.map { String(decoding: try enc.encode($0), as: UTF8.self) }, createdAt, seq])
    }
}

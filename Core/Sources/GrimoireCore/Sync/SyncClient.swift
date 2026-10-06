import CryptoKit
import Foundation
import GRDB

/// A device's side of sync. `sync` pulls what the hub has, rebases the device's own unsent ops on top of it, and pushes them.
public final class SyncClient: Sendable {
    public let graph: Graph
    /// The name the hub knows this install by (the same for the app, `grim` and the MCP server on one graph).
    public let deviceID: String
    public init(graph: Graph, deviceID: String? = nil) { self.graph = graph; self.deviceID = deviceID ?? graph.device }

    public func lastSeq() throws -> Int64 {
        try graph.db.read { try String.fetchOne($0, sql: "SELECT value FROM sync_state WHERE key = 'last_seq'").flatMap(Int64.init) ?? 0 }
    }

    public func pendingCount() throws -> Int {
        try graph.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ops WHERE seq IS NULL AND rejected = 0") ?? 0 }
    }

    public func issues() throws -> [(at: Int64, source: String, reason: String)] {
        try graph.db.read { try Row.fetchAll($0, sql: "SELECT at, source, reason FROM sync_issues ORDER BY id").map { (at: $0["at"], source: $0["source"], reason: $0["reason"]) } }
    }

    // MARK: the loop

    /// Ops per push request: a first sync of a big graph goes up in pieces, each acknowledged before the next.
    public static let chunkSize = 200

    @discardableResult
    public func sync(using t: SyncTransport) async throws -> SyncReport {
        var report = SyncReport()
        var behind = 0
        for _ in 0..<100_000 {
            let since = try lastSeq()
            let remote = try await t.pull(since: since)
            if since == 0, remote.isEmpty, try needsBootstrap() { try bootstrap() }
            else if since == 0, !remote.isEmpty, try needsBootstrap() { throw SyncError.needsReset }
            report.pulled += remote.count
            report.conflicts += try integrate(remote)
            report.assetsDown += try await fetchMissingAssets(t)
            let pending = try outgoing()
            if pending.isEmpty { return report }
            let chunk = Array(pending.prefix(Self.chunkSize))
            report.assetsUp += try await uploadAssets(for: chunk, t)
            switch try await t.push(base: try lastSeq(), device: deviceID, ops: chunk) {
            case .behind:
                behind += 1
                if behind > 8 { throw SyncError.couldNotCatchUp }
            case let .accepted(assigned, rejected):
                try acknowledge(assigned: assigned, rejected: rejected)
                report.pushed += assigned.count; report.rejected += rejected.count
            }
        }
        throw SyncError.couldNotCatchUp
    }

    // MARK: pending ops

    private func outgoing() throws -> [OutgoingOp] {
        try graph.db.read { db in
            try Row.fetchAll(db, sql: "SELECT local_id, author, payload, created_at FROM ops WHERE seq IS NULL AND rejected = 0 ORDER BY local_id")
                .map { OutgoingOp(localID: $0["local_id"], author: $0["author"], payload: $0["payload"], createdAt: $0["created_at"]) }
        }
    }

    private func acknowledge(assigned: [SeqAssignment], rejected: [Rejection]) throws {
        try graph.db.write { db in
            for a in assigned {
                try db.execute(sql: "UPDATE ops SET seq = ?, origin_local_id = local_id WHERE local_id = ?", arguments: [a.seq, a.localID])
            }
            for r in rejected {
                // flagged only: the next rebase rolls back from this op (and the ones after it), drops it, and re-applies the rest
                try db.execute(sql: "UPDATE ops SET rejected = 1 WHERE local_id = ?", arguments: [r.localID])
                try db.execute(sql: "INSERT INTO sync_issues (at, source, payload, reason) VALUES (?, 'push', ?, ?)",
                               arguments: [Graph.nowMillis(), try String.fetchOne(db, sql: "SELECT payload FROM ops WHERE local_id = ?", arguments: [r.localID]) ?? "", r.reason])
            }
            if let m = assigned.map(\.seq).max() { try Self.setLastSeq(m, db) }
        }
    }

    static func setLastSeq(_ seq: Int64, _ db: Database) throws {
        try db.execute(sql: "INSERT INTO sync_state (key, value) VALUES ('last_seq', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [String(seq)])
    }

    // MARK: first sync of a graph with unreplayable history

    /// A graph that came from an import has pages and blocks that no op in its log can recreate. Before its first sync the log is replaced by
    /// ops that do: pages, blocks (in chunks), favorites, collapsed state, assets and card schedules.
    func needsBootstrap() throws -> Bool {
        try graph.db.read { try Int.fetchOne($0, sql: "SELECT 1 FROM ops WHERE kind = 'import' LIMIT 1") != nil }
    }

    func bootstrap() throws {
        try graph.db.write { db in
            var ops: [(Op, Op?)] = []
            for p in try Page.order(Column("id")).fetchAll(db) {
                ops.append((.createPage(id: p.id, title: p.title, kind: p.kind, journalDate: p.journalDate), .discardPage(id: p.id)))
                if p.favorite { ops.append((.setFavorite(pageID: p.id, favorite: true, order: p.favoriteOrder), .setFavorite(pageID: p.id, favorite: false, order: nil))) }
            }
            let blocks = orderParentsFirst(try Block.fetchAll(db).map(BlockSnapshot.init))        // every parent comes before its children, across chunks too
            for snaps in stride(from: 0, to: blocks.count, by: 300).map({ Array(blocks[$0..<min($0 + 300, blocks.count)]) }) {
                ops.append((.restoreBlocks(snaps), .batch(snaps.reversed().map { .deleteBlock(blockID: $0.id) })))
            }
            for a in try Asset.fetchAll(db) { ops.append((.addAsset(hash: a.hash, filename: a.filename, mime: a.mime, size: a.size), nil)) }
            for id in try String.fetchAll(db, sql: "SELECT block_id FROM cards ORDER BY block_id") {
                if let st = try CardApplier.load(id, db) { ops.append((.setCard(blockID: id, state: st, undoReviewAt: nil), .setCard(blockID: id, state: nil, undoReviewAt: nil))) }
            }
            try db.execute(sql: "DELETE FROM ops WHERE seq IS NULL")
            let now = Graph.nowMillis()
            for (op, inv) in ops {
                let payload = String(decoding: try Self.encoder.encode(op), as: UTF8.self)
                try db.execute(sql: "INSERT INTO ops (device, author, kind, payload, inverse, created_at) VALUES (?, 'import', ?, ?, ?, ?)",
                               arguments: [graph.device, op.kind, payload, try Self.encode(inv), now])
            }
        }
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    // MARK: rebase

    private struct Own { var localID: Int64; var payload: String; var op: Op; var author: Author; var createdAt: Int64; var inverse: Op?; var rejected: Bool }

    /// Rolls the device's unsent ops back, applies the hub's ops, then re-applies the unsent ones on top. Returns how many conflicts it kept both sides of.
    func integrate(_ remote: [RemoteOp]) throws -> Int {
        try graph.db.write { db in
            let device = deviceID
            let decoder = JSONDecoder()
            let ownRows = try Row.fetchAll(db, sql: "SELECT local_id, author, payload, inverse, created_at, rejected FROM ops WHERE seq IS NULL ORDER BY local_id")
            var own: [Own] = ownRows.compactMap { r in
                guard let op = try? decoder.decode(Op.self, from: Data((r["payload"] as String).utf8)) else { return nil }
                return Own(localID: r["local_id"], payload: r["payload"], op: op, author: Author(rawValue: r["author"]) ?? .me, createdAt: r["created_at"],
                           inverse: (r["inverse"] as String?).flatMap { try? decoder.decode(Op.self, from: Data($0.utf8)) }, rejected: r["rejected"] == 1)
            }
            guard !remote.isEmpty || own.contains(where: { $0.rejected && $0.inverse != nil }) else { return 0 }

            // 1. roll back, newest first
            for o in own.reversed() {
                guard let inv = o.inverse else { continue }
                if case .failure(let e) = SyncApply.apply(inv, author: o.author, now: o.createdAt, in: db) {
                    throw SyncError.rollbackFailed("op \(o.localID): \(e)")
                }
            }

            for o in own where o.rejected { try db.execute(sql: "UPDATE ops SET inverse = NULL WHERE local_id = ?", arguments: [o.localID]) }

            // 2. the hub's ops, in order (our own already-sequenced ones are matched to their rows)
            for r in remote {
                let op = try? decoder.decode(Op.self, from: Data(r.payload.utf8))
                let author = Author(rawValue: r.author) ?? .me
                var inverse: Op?
                if let op {
                    switch SyncApply.apply(op, author: author, now: r.createdAt, in: db) {
                    case .success(let inv): inverse = inv
                    case .failure(let e): try Self.issue("pull", r.payload, "\(e)", db)
                    }
                } else { try Self.issue("pull", r.payload, "unreadable op", db) }
                if r.device == device, let i = own.firstIndex(where: { $0.localID == r.originLocalID && $0.payload == r.payload }) {
                    try db.execute(sql: "UPDATE ops SET seq = ?, origin_local_id = local_id, inverse = ? WHERE local_id = ?",
                                   arguments: [r.seq, try Self.encode(inverse), r.originLocalID])
                    own.remove(at: i)
                } else if try Int.fetchOne(db, sql: "SELECT 1 FROM ops WHERE seq = ?", arguments: [r.seq]) == nil {
                    try SyncApply.record(device: r.device, origin: r.originLocalID, author: author, payload: r.payload, inverse: inverse, createdAt: r.createdAt, seq: r.seq, in: db)
                }
            }
            if let m = remote.map(\.seq).max() { try Self.setLastSeq(m, db) }

            // 3. our unsent ops again, on top
            var conflicts = 0
            for o in own where !o.rejected {
                var extra: [Op] = []
                if case let .editText(id, new) = o.op, case let .editText(_, old)? = o.inverse,
                   let current = try Block.fetchOne(db, key: id), current.text != old, current.text != new {
                    extra = Self.conflictSibling(of: current, device: device, db: db)
                    conflicts += 1
                }
                switch SyncApply.apply(o.op, author: o.author, now: o.createdAt, in: db) {
                case .success(let inv):
                    try db.execute(sql: "UPDATE ops SET inverse = ? WHERE local_id = ?", arguments: [try Self.encode(inv), o.localID])
                case .failure(let e):
                    try db.execute(sql: "UPDATE ops SET rejected = 1, inverse = NULL WHERE local_id = ?", arguments: [o.localID])
                    try Self.issue("rebase", String(decoding: (try? JSONEncoder().encode(o.op)) ?? Data(), as: UTF8.self), "\(e)", db)
                    continue
                }
                if !extra.isEmpty { _ = try Graph.perform(extra, in: db, device: device, author: .sync) }
            }
            return conflicts
        }
    }

    /// The text that lost a concurrent edit, kept as the next sibling with a `conflict::` property.
    private static func conflictSibling(of block: Block, device: String, db: Database) -> [Op] {
        let next = try? String.fetchOne(db, sql: """
            SELECT order_key FROM blocks WHERE page_id = ? AND parent_id IS ? AND order_key > ? ORDER BY order_key LIMIT 1
            """, arguments: [block.pageId, block.parentId, block.orderKey])
        let stamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(block.updatedAt) / 1000))
        let id = UUIDv5.make(namespace: UUIDv5.property, name: "conflict:\(block.id):\(block.updatedAt):\(block.text.hashValue)")
        return [.insertBlock(id: id, pageID: block.pageId, parentID: block.parentId, orderKey: OrderKey.between(block.orderKey, next ?? nil),
                             text: block.text + "\nconflict:: other device \(stamp)")]
    }

    private static func encode(_ op: Op?) throws -> String? {
        guard let op else { return nil }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(op), as: UTF8.self)
    }

    private static func issue(_ source: String, _ payload: String, _ reason: String, _ db: Database) throws {
        try db.execute(sql: "INSERT INTO sync_issues (at, source, payload, reason) VALUES (?, ?, ?, ?)", arguments: [Graph.nowMillis(), source, payload, reason])
    }

    // MARK: assets

    private func assetFileExists(_ hash: String) -> Bool {
        let folder = graph.folder.appendingPathComponent("assets")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0 == hash || $0.hasPrefix(hash + ".") }
    }

    private func fetchMissingAssets(_ t: SyncTransport) async throws -> Int {
        let assets = try await graph.db.read { try Asset.fetchAll($0) }
        var n = 0
        for a in assets where !assetFileExists(a.hash) {
            guard let data = try await t.getAsset(hash: a.hash) else { continue }
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == a.hash else { throw SyncError.assetHashMismatch(a.hash) }
            let ext = (a.filename as NSString).pathExtension
            try data.write(to: graph.folder.appendingPathComponent("assets/\(ext.isEmpty ? a.hash : "\(a.hash).\(ext)")"), options: .atomic)
            n += 1
        }
        return n
    }

    private func uploadAssets(for ops: [OutgoingOp], _ t: SyncTransport) async throws -> Int {
        var n = 0
        for o in ops {
            guard case let .addAsset(hash, filename, _, _)? = try? JSONDecoder().decode(Op.self, from: Data(o.payload.utf8)) else { continue }
            let ext = (filename as NSString).pathExtension
            let url = graph.folder.appendingPathComponent("assets/\(ext.isEmpty ? hash : "\(hash).\(ext)")")
            if let data = try? Data(contentsOf: url) { try await t.putAsset(hash: hash, data: data); n += 1 }
        }
        return n
    }
}

/// A transport that talks to a hub in the same process (tests, and a hub app that is also a client).
public struct LocalTransport: SyncTransport {
    public let hub: SyncHub
    public init(hub: SyncHub) { self.hub = hub }
    public func pull(since: Int64) async throws -> [RemoteOp] { try hub.pull(since: since) }
    public func push(base: Int64, device: String, ops: [OutgoingOp]) async throws -> PushResult { try hub.push(device: device, base: base, ops: ops) }
    public func putAsset(hash: String, data: Data) async throws { try hub.putAsset(hash: hash, filename: nil, data: data) }
    public func getAsset(hash: String) async throws -> Data? { try hub.assetURL(hash: hash).flatMap { try? Data(contentsOf: $0) } }
}

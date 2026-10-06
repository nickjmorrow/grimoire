import CryptoKit
import Foundation
import GRDB
import UniformTypeIdentifiers

extension Applier {
    static func createPage(id: String, title: String, kind: PageKind, journalDate: String?, in db: Database, now: Int64) throws -> Op {
        let lower = Graph.titleKey(title)
        if try Page.filter(Column("title_lower") == lower).fetchOne(db) != nil { throw GraphError.titleTaken(lower) }
        let page = Page(id: id, title: title, titleLower: lower, kind: kind, journalDate: journalDate,
                        favorite: false, favoriteOrder: nil, createdAt: now, updatedAt: now)
        try page.insert(db)
        try Indexer.indexTitle(of: page, in: db)
        return .discardPage(id: id)
    }

    static func renamePage(id: String, title: String, in db: Database, now: Int64) throws -> Op {
        guard var page = try Page.fetchOne(db, key: id) else { throw GraphError.pageNotFound(id) }
        let lower = Graph.titleKey(title)
        if let other = try Page.filter(Column("title_lower") == lower).fetchOne(db), other.id != id {
            throw GraphError.titleTaken(lower)
        }
        let old = page.title
        page.title = title; page.titleLower = lower; page.updatedAt = now
        try page.update(db)
        try db.execute(sql: "UPDATE tags SET name = ?, name_lower = ? WHERE page_id = ?", arguments: [title, lower, id])
        try Indexer.indexTitle(of: page, in: db)
        // Rewrite every block that references the old title; remember the exact old texts for the inverse.
        let referencing = try String.fetchAll(db, sql: "SELECT DISTINCT from_block FROM links WHERE to_page = ? AND kind IN ('page','tag')", arguments: [id])
        var restores: [Op] = []
        for blockID in referencing {
            guard var block = try Block.fetchOne(db, key: blockID) else { continue }
            let rewritten = BlockSyntax.replacingPageReferences(in: block.text, from: old, to: title)
            if rewritten == block.text { continue }
            restores.append(.editText(blockID: blockID, text: block.text))
            block.text = rewritten; block.updatedAt = now
            try block.update(db)
            try Indexer.reindexBlock(blockID, in: db, now: now)
            try BlockApplier.touch(block.pageId, in: db, now: now)
        }
        let back = Op.renamePage(id: id, title: old)
        return restores.isEmpty ? back : .batch([back] + restores)
    }

    static func setFavorite(pageID: String, favorite: Bool, order: Int?, in db: Database, now: Int64) throws -> Op {
        guard var page = try Page.fetchOne(db, key: pageID) else { throw GraphError.pageNotFound(pageID) }
        let inverse = Op.setFavorite(pageID: pageID, favorite: page.favorite, order: page.favoriteOrder)
        if favorite {
            let next = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(favorite_order) + 1, 0) FROM pages WHERE favorite = 1") ?? 0
            page.favorite = true; page.favoriteOrder = order ?? next
        } else {
            page.favorite = false; page.favoriteOrder = nil
        }
        try page.update(db)
        return inverse
    }

    static func deletePage(id: String, in db: Database) throws -> Op {
        guard let page = try Page.fetchOne(db, key: id) else { throw GraphError.pageNotFound(id) }
        let incoming = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM links l JOIN blocks b ON b.id = l.from_block WHERE l.to_page = ? AND b.page_id != ?
            """, arguments: [id, id]) ?? 0
        if incoming > 0 { throw GraphError.pageInUse(page.title) }
        let snapshots = orderParentsFirst(try Block.filter(Column("page_id") == id).fetchAll(db).map(BlockSnapshot.init))
        for b in snapshots { try Indexer.removeBlockRows(b.id, in: db) }
        try Indexer.removeTitle(ofPage: id, in: db)
        _ = try Page.deleteOne(db, key: id)
        var restore: [Op] = [.createPage(id: id, title: page.title, kind: page.kind, journalDate: page.journalDate)]
        if !snapshots.isEmpty { restore.append(.restoreBlocks(snapshots)) }
        if page.favorite { restore.append(.setFavorite(pageID: id, favorite: true, order: page.favoriteOrder)) }
        return .batch(restore)
    }

    /// Undo of a page creation: only removes a page that is still empty and not linked from elsewhere.
    static func discardPage(id: String, in db: Database) throws -> Op? {
        guard let page = try Page.fetchOne(db, key: id) else { return nil }
        if try Block.filter(Column("page_id") == id).fetchCount(db) > 0 {
            throw GraphError.undoBlocked("page '\(page.title)' has content now")
        }
        let incoming = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM links WHERE to_page = ?", arguments: [id]) ?? 0
        if incoming > 0 { throw GraphError.undoBlocked("page '\(page.title)' is linked from other blocks now") }
        try Indexer.removeTitle(ofPage: id, in: db)
        _ = try Page.deleteOne(db, key: id)
        return .createPage(id: id, title: page.title, kind: page.kind, journalDate: page.journalDate)
    }
}

extension Graph {
    @discardableResult
    public func ensureJournal(_ date: JournalDate, author: Author) throws -> String {
        let id = date.pageID
        try db.write { db in
            if try Page.fetchOne(db, key: id) == nil {
                try Graph.perform([.createPage(id: id, title: date.title(), kind: .journal, journalDate: date.iso)],
                                  in: db, device: device, author: author)
            }
        }
        return id
    }

    /// Copies a file into `assets/` under its content hash and records it. Importing the same bytes twice is a no-op.
    public func importAsset(from url: URL, author: Author) throws -> Asset {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk); size += Int64(chunk.count)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension
        let target = folder.appendingPathComponent("assets/\(ext.isEmpty ? hash : "\(hash).\(ext)")")
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: url, to: target) }
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        try perform([.addAsset(hash: hash, filename: url.lastPathComponent, mime: mime, size: size)], author: author)
        return try db.read { try Asset.fetchOne($0, key: hash)! }
    }
}

import Foundation
import GRDB

enum BlockApplier {
    static func apply(_ op: Op, in db: Database, now: Int64, author: Author) throws -> Op? {
        switch op {
        case let .insertBlock(id, pageID, parentID, orderKey, text):
            guard try Page.fetchOne(db, key: pageID) != nil else { throw GraphError.pageNotFound(pageID) }
            if let parentID, try Block.fetchOne(db, key: parentID) == nil { throw GraphError.blockNotFound(parentID) }
            try Block(id: id, pageId: pageID, parentId: parentID, orderKey: orderKey, text: text, collapsed: false,
                      createdAt: now, updatedAt: now, author: author).insert(db)
            try touch(pageID, in: db, now: now)
            try Indexer.reindexBlock(id, in: db, now: now)
            return .discardBlock(blockID: id, text: text)

        case let .discardBlock(blockID, text):
            guard let block = try Block.fetchOne(db, key: blockID) else { return nil }
            if block.text != text { throw GraphError.undoBlocked("block \(blockID) was edited since") }
            if try Block.filter(Column("parent_id") == blockID).fetchCount(db) > 0 {
                throw GraphError.undoBlocked("block \(blockID) has child blocks now")
            }
            try Indexer.removeBlockRows(blockID, in: db)
            _ = try Block.deleteOne(db, key: blockID)
            try touch(block.pageId, in: db, now: now)
            try Indexer.reindexPageProperties(block.pageId, in: db, now: now)
            return .restoreBlocks([BlockSnapshot(block)])

        case let .editText(blockID, text):
            guard var block = try Block.fetchOne(db, key: blockID) else { throw GraphError.blockNotFound(blockID) }
            let old = block.text
            block.text = text; block.updatedAt = now; block.author = author
            try block.update(db)
            try touch(block.pageId, in: db, now: now)
            try Indexer.reindexBlock(blockID, in: db, now: now)
            return .editText(blockID: blockID, text: old)

        case let .moveBlock(blockID, pageID, parentID, orderKey):
            guard var block = try Block.fetchOne(db, key: blockID) else { throw GraphError.blockNotFound(blockID) }
            guard try Page.fetchOne(db, key: pageID) != nil else { throw GraphError.pageNotFound(pageID) }
            var cursor = parentID
            while let c = cursor {
                if c == blockID { throw GraphError.cycle }
                guard let parent = try Block.fetchOne(db, key: c) else { throw GraphError.blockNotFound(c) }
                cursor = parent.parentId
            }
            let inverse = Op.moveBlock(blockID: blockID, pageID: block.pageId, parentID: block.parentId, orderKey: block.orderKey)
            let oldPage = block.pageId
            block.pageId = pageID; block.parentId = parentID; block.orderKey = orderKey; block.updatedAt = now
            try block.update(db)
            if oldPage != pageID {
                for id in try subtreeIDs(of: blockID, in: db) where id != blockID {
                    try db.execute(sql: "UPDATE blocks SET page_id = ? WHERE id = ?", arguments: [pageID, id])
                }
                try touch(oldPage, in: db, now: now)
            }
            try touch(pageID, in: db, now: now)
            for page in Set([oldPage, pageID]) { try Indexer.reindexPageProperties(page, in: db, now: now) }
            return inverse

        case let .deleteBlock(blockID):
            guard let root = try Block.fetchOne(db, key: blockID) else { throw GraphError.blockNotFound(blockID) }
            let ids = try subtreeIDs(of: blockID, in: db)
            let snapshots = try ids.map { id -> BlockSnapshot in
                var snap = BlockSnapshot(try Block.fetchOne(db, key: id)!)
                snap.card = try CardApplier.load(id, db)
                return snap
            }
            for id in ids { try Indexer.removeBlockRows(id, in: db) }
            _ = try Block.deleteOne(db, key: blockID)
            try touch(root.pageId, in: db, now: now)
            try Indexer.reindexPageProperties(root.pageId, in: db, now: now)
            return .restoreBlocks(snapshots)

        case let .setCollapsed(blockID, collapsed):
            guard var block = try Block.fetchOne(db, key: blockID) else { throw GraphError.blockNotFound(blockID) }
            let old = block.collapsed
            block.collapsed = collapsed
            try block.update(db)
            return .setCollapsed(blockID: blockID, collapsed: old)

        case let .restoreBlocks(snapshots):
            let ids = Set(snapshots.map(\.id))
            for s in orderParentsFirst(snapshots) {
                guard try Page.fetchOne(db, key: s.pageId) != nil else { throw GraphError.pageNotFound(s.pageId) }
                try s.block.insert(db)
            }
            for s in snapshots { try Indexer.reindexBlock(s.id, in: db, now: now); if let c = s.card { try CardApplier.store(c, s.id, db) } }
            for page in Set(snapshots.map(\.pageId)) { try touch(page, in: db, now: now) }
            let roots = snapshots.filter { $0.parentId == nil || !ids.contains($0.parentId!) }.map { Op.deleteBlock(blockID: $0.id) }
            return roots.count == 1 ? roots[0] : .batch(roots)

        default:
            preconditionFailure("not a block operation: \(op.kind)")
        }
    }

    static func touch(_ pageID: String, in db: Database, now: Int64) throws {
        try db.execute(sql: "UPDATE pages SET updated_at = ? WHERE id = ?", arguments: [now, pageID])
    }

    /// The block and all its descendants, parents before children.
    static func subtreeIDs(of id: String, in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            WITH RECURSIVE sub(id) AS (
              SELECT id FROM blocks WHERE id = ?
              UNION ALL SELECT b.id FROM blocks b JOIN sub ON b.parent_id = sub.id)
            SELECT id FROM sub
            """, arguments: [id])
    }
}

import Foundation
import GRDB

/// Keeps the derived tables (links, tags, typed properties, search) consistent with block text.
/// Every function runs inside the caller's write transaction.
enum Indexer {
    // MARK: pages and tags

    static func ensurePage(named name: String, in db: Database, now: Int64) throws -> String {
        let key = Graph.titleKey(name)
        if let id = try String.fetchOne(db, sql: "SELECT id FROM pages WHERE title_lower = ?", arguments: [key]) { return id }
        let relative: Set<String> = ["today", "yesterday", "tomorrow"]
        if !relative.contains(key), let jd = JournalDate.parse(name, today: JournalDate(year: 2000, month: 1, day: 1)!) {
            if try Page.fetchOne(db, key: jd.pageID) != nil { return jd.pageID }
            let title = jd.title()
            let page = Page(id: jd.pageID, title: title, titleLower: Graph.titleKey(title), kind: .journal,
                            journalDate: jd.iso, favorite: false, favoriteOrder: nil, createdAt: now, updatedAt: now)
            try page.insert(db); try indexTitle(of: page, in: db)
            return page.id
        }
        let page = Page(id: Graph.pageID(forTitle: name), title: name, titleLower: key, kind: .page,
                        journalDate: nil, favorite: false, favoriteOrder: nil, createdAt: now, updatedAt: now)
        try page.insert(db); try indexTitle(of: page, in: db)
        return page.id
    }

    static func ensureTag(named name: String, pageID: String, in db: Database, now: Int64) throws -> String {
        let key = Graph.titleKey(name)
        if let id = try String.fetchOne(db, sql: "SELECT id FROM tags WHERE name_lower = ?", arguments: [key]) { return id }
        let tag = Tag(id: UUIDv5.make(namespace: UUIDv5.tag, name: key), name: name, nameLower: key, pageId: pageID, createdAt: now)
        try tag.insert(db)
        return tag.id
    }

    static func indexTitle(of page: Page, in db: Database) throws {
        try removeTitle(ofPage: page.id, in: db)
        try insertSearch(ownerID: page.id, kind: "page", text: page.title, in: db)
    }

    static func removeTitle(ofPage id: String, in db: Database) throws {
        try deleteSearch(ownerID: id, kind: "page", in: db)
    }

    // MARK: search rows

    static func insertSearch(ownerID: String, kind: String, text: String, in db: Database) throws {
        try db.execute(sql: "INSERT INTO search (owner_id, owner_kind, text) VALUES (?, ?, ?)", arguments: [ownerID, kind, text])
        try db.execute(sql: "INSERT OR REPLACE INTO search_ref (owner_id, owner_kind, fts_rowid) VALUES (?, ?, ?)",
                       arguments: [ownerID, kind, db.lastInsertedRowID])
    }

    static func deleteSearch(ownerID: String, kind: String, in db: Database) throws {
        guard let rowid = try Int64.fetchOne(db, sql: "SELECT fts_rowid FROM search_ref WHERE owner_id = ? AND owner_kind = ?",
                                             arguments: [ownerID, kind]) else { return }
        try db.execute(sql: "DELETE FROM search WHERE rowid = ?", arguments: [rowid])
        try db.execute(sql: "DELETE FROM search_ref WHERE owner_id = ? AND owner_kind = ?", arguments: [ownerID, kind])
    }

    // MARK: blocks

    static func removeBlockRows(_ id: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM links WHERE from_block = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM block_tags WHERE block_id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM block_props WHERE owner_id = ? AND owner_kind = 'block'", arguments: [id])
        try deleteSearch(ownerID: id, kind: "block", in: db)
    }

    static func reindexBlock(_ id: String, in db: Database, now: Int64) throws {
        try removeBlockRows(id, in: db)
        guard let block = try Block.fetchOne(db, key: id) else { return }
        let parsed = BlockSyntax.parse(block.text)
        for name in parsed.pageLinks {
            let pid = try ensurePage(named: name, in: db, now: now)
            try db.execute(sql: "INSERT INTO links (from_block, to_page, to_block, kind) VALUES (?, ?, NULL, 'page')", arguments: [id, pid])
        }
        for name in parsed.tags {
            let pid = try ensurePage(named: name, in: db, now: now)
            let tid = try ensureTag(named: name, pageID: pid, in: db, now: now)
            try db.execute(sql: "INSERT OR IGNORE INTO block_tags (block_id, tag_id) VALUES (?, ?)", arguments: [id, tid])
            try db.execute(sql: "INSERT INTO links (from_block, to_page, to_block, kind) VALUES (?, ?, NULL, 'tag')", arguments: [id, pid])
        }
        for ref in parsed.blockRefs {
            try db.execute(sql: "INSERT INTO links (from_block, to_page, to_block, kind) VALUES (?, NULL, ?, 'block')", arguments: [id, ref])
        }
        for line in parsed.properties { try indexProperty(line, owner: id, kind: "block", tagBlock: id, in: db, now: now) }
        try insertSearch(ownerID: id, kind: "block", text: block.text, in: db)
        if block.parentId == nil { try reindexPageProperties(block.pageId, in: db, now: now) }
    }

    /// A page's own properties are the `key:: value` lines of its first top-level block.
    static func reindexPageProperties(_ pageID: String, in db: Database, now: Int64) throws {
        try db.execute(sql: "DELETE FROM block_props WHERE owner_id = ? AND owner_kind = 'page'", arguments: [pageID])
        guard let first = try Block.fetchOne(db, sql: "SELECT * FROM blocks WHERE page_id = ? AND parent_id IS NULL ORDER BY order_key, id LIMIT 1", arguments: [pageID]) else { return }
        for line in BlockSyntax.parse(first.text).properties { try indexProperty(line, owner: pageID, kind: "page", in: db, now: now) }
    }

    static func reindexAll(in db: Database, now: Int64) throws {
        try db.execute(sql: "DELETE FROM links; DELETE FROM block_tags; DELETE FROM block_props; DELETE FROM search; DELETE FROM search_ref;")
        for page in try Page.fetchAll(db) { try indexTitle(of: page, in: db) }
        for id in try String.fetchAll(db, sql: "SELECT id FROM blocks ORDER BY created_at, id") { try reindexBlock(id, in: db, now: now) }
        for id in try String.fetchAll(db, sql: "SELECT id FROM pages") { try reindexPageProperties(id, in: db, now: now) }
    }

    // MARK: properties

    private static func inferType(_ value: String) -> PropertyType {
        if value.wholeMatch(of: /-?\d+(\.\d+)?/) != nil { return .number }
        if JournalDate(iso: value) != nil { return .date }
        if value.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}.*/) != nil, ISO8601DateFormatter().date(from: value) != nil { return .datetime }
        if (value.hasPrefix("http://") || value.hasPrefix("https://")), !value.contains(" ") { return .url }
        if value == "true" || value == "false" { return .checkbox }
        return .text
    }

    private static func valid(_ value: String, as type: PropertyType) -> Bool {
        switch type {
        case .text, .page: return true
        case .number: return value.wholeMatch(of: /-?\d+(\.\d+)?/) != nil
        case .date: return JournalDate(iso: value) != nil
        case .datetime: return ISO8601DateFormatter().date(from: value) != nil
        case .url: return (value.hasPrefix("http://") || value.hasPrefix("https://")) && !value.contains(" ")
        case .checkbox: return value == "true" || value == "false"
        }
    }

    private static func indexProperty(_ line: PropertyLine, owner: String, kind: String, tagBlock: String? = nil, in db: Database, now: Int64) throws {
        let key = line.key.lowercased()
        let refs = BlockSyntax.parse(line.value).pageLinks
        var property = try Property.filter(Column("key") == key).fetchOne(db)
        if property == nil {
            let type: PropertyType = refs.isEmpty ? inferType(line.value) : .page
            let created = Property(id: UUIDv5.make(namespace: UUIDv5.property, name: key), key: key, type: type,
                                   cardinality: refs.count > 1 ? .many : .one)
            try created.insert(db); property = created
        } else if property!.type == .page, refs.count > 1, property!.cardinality == .one {
            try db.execute(sql: "UPDATE properties SET cardinality = 'many' WHERE id = ?", arguments: [property!.id])
            property!.cardinality = .many
        }
        let p = property!
        // `tags:: [[a]], [[b]]` tags the block, exactly like #a #b would.
        if let tagBlock, key == "tags" || key == "tag", p.type == .page {
            for name in refs {
                let pid = try ensurePage(named: name, in: db, now: now)
                let tid = try ensureTag(named: name, pageID: pid, in: db, now: now)
                try db.execute(sql: "INSERT OR IGNORE INTO block_tags (block_id, tag_id) VALUES (?, ?)", arguments: [tagBlock, tid])
            }
        }
        var values: [String]
        if p.type == .page {
            if refs.isEmpty { return }
            values = try refs.map { try ensurePage(named: $0, in: db, now: now) }
        } else {
            guard valid(line.value, as: p.type) else { return }
            values = [line.value]
        }
        if p.cardinality == .one { values = Array(values.prefix(1)) }
        for (i, v) in values.enumerated() {
            try db.execute(sql: "INSERT INTO block_props (owner_id, owner_kind, property_id, value, position) VALUES (?, ?, ?, ?, ?)",
                           arguments: [owner, kind, p.id, v, i])
        }
    }
}

extension Graph {
    /// Rebuilds links, tag assignments, property values and search from block text. Does not log ops.
    public func reindex() throws {
        try db.write { try Indexer.reindexAll(in: $0, now: Graph.nowMillis()) }
    }
}

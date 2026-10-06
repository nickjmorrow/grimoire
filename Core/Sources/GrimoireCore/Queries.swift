import Foundation
import GRDB

public struct BlockNode: Sendable {
    public let block: Block
    public let children: [BlockNode]
}

public struct Reference: Sendable {
    public let page: Page
    public let blocks: [Block]
}

public struct SearchHit: Sendable, Equatable {
    public let pageID: String
    public let blockID: String?
    public let snippet: String
}

extension Graph {
    public func page(titled title: String) throws -> Page? {
        try db.read { db in
            if let p = try Page.filter(Column("title_lower") == Graph.titleKey(title)).fetchOne(db) { return p }
            if let jd = JournalDate.parse(title, today: .today()) { return try Page.fetchOne(db, key: jd.pageID) }
            return nil
        }
    }

    public func tree(pageID: String) throws -> [BlockNode] {
        let blocks = try db.read {
            try Block.filter(Column("page_id") == pageID).order(Column("order_key"), Column("id")).fetchAll($0)
        }
        let byParent = Dictionary(grouping: blocks, by: { $0.parentId })
        func build(_ parent: String?) -> [BlockNode] {
            (byParent[parent] ?? []).map { BlockNode(block: $0, children: build($0.id)) }
        }
        return build(nil)
    }

    public func backlinks(pageID: String) throws -> [Reference] {
        try db.read { db in
            let blocks = try Block.fetchAll(db, sql: """
                SELECT DISTINCT b.* FROM blocks b JOIN links l ON l.from_block = b.id
                WHERE l.to_page = ? AND b.page_id != ? ORDER BY b.order_key, b.id
                """, arguments: [pageID, pageID])
            return try Graph.group(blocks, in: db)
        }
    }

    public func unlinkedReferences(pageID: String) throws -> [Reference] {
        try db.read { db in
            guard let page = try Page.fetchOne(db, key: pageID) else { return [] }
            let phrase = "\"" + page.title.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let blocks = try Block.fetchAll(db, sql: """
                SELECT b.* FROM blocks b JOIN search s ON s.owner_id = b.id AND s.owner_kind = 'block'
                WHERE search MATCH ? AND b.page_id != ?
                  AND NOT EXISTS (SELECT 1 FROM links l WHERE l.from_block = b.id AND l.to_page = ?)
                ORDER BY b.order_key, b.id
                """, arguments: [phrase, pageID, pageID])
            return try Graph.group(blocks, in: db)
        }
    }

    private static func group(_ blocks: [Block], in db: Database) throws -> [Reference] {
        let byPage = Dictionary(grouping: blocks, by: \.pageId)
        let pages = try Page.fetchAll(db, keys: Array(byPage.keys)).sorted { $0.updatedAt > $1.updatedAt }
        return pages.map { Reference(page: $0, blocks: byPage[$0.id] ?? []) }
    }

    /// Full-text search. Page titles rank first; the last word matches as a prefix. FTS syntax in the input is neutralised.
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let words = query.split(whereSeparator: \.isWhitespace)
            .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let match = words.enumerated().map { i, w in "\"\(w)\"" + (i == words.count - 1 ? "*" : "") }.joined(separator: " ")
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.owner_id AS owner_id, s.owner_kind AS kind, b.page_id AS block_page,
                       snippet(search, 2, '[', ']', '…', 10) AS snip
                FROM search s LEFT JOIN blocks b ON b.id = s.owner_id AND s.owner_kind = 'block'
                WHERE search MATCH ?
                ORDER BY CASE s.owner_kind WHEN 'page' THEN 0 ELSE 1 END, rank
                LIMIT ?
                """, arguments: [match, limit]).map { row in
                let isPage = (row["kind"] as String) == "page"
                return SearchHit(pageID: isPage ? row["owner_id"] : row["block_page"],
                                 blockID: isPage ? nil : row["owner_id"], snippet: row["snip"])
            }
        }
    }

    /// Pages that have content, most recently changed first.
    public func recentPages(limit: Int = 30) throws -> [Page] {
        try db.read {
            try Page.fetchAll($0, sql: """
                SELECT * FROM pages WHERE EXISTS (SELECT 1 FROM blocks WHERE page_id = pages.id)
                ORDER BY updated_at DESC, id LIMIT ?
                """, arguments: [limit])
        }
    }

    public func favorites() throws -> [Page] {
        try db.read { try Page.filter(Column("favorite") == true).order(Column("favorite_order"), Column("id")).fetchAll($0) }
    }

    /// Journals that have content, newest first, optionally only those before a date.
    public func journals(before: JournalDate?, limit: Int) throws -> [Page] {
        try db.read {
            try Page.fetchAll($0, sql: """
                SELECT * FROM pages WHERE kind = 'journal' AND (? IS NULL OR journal_date < ?)
                  AND EXISTS (SELECT 1 FROM blocks WHERE page_id = pages.id)
                ORDER BY journal_date DESC LIMIT ?
                """, arguments: [before?.iso, before?.iso, limit])
        }
    }

    public func blocks(taggedWith tag: String) throws -> [Block] {
        try db.read {
            try Block.fetchAll($0, sql: """
                SELECT b.* FROM blocks b JOIN block_tags bt ON bt.block_id = b.id JOIN tags t ON t.id = bt.tag_id
                WHERE t.name_lower = ? ORDER BY b.updated_at DESC, b.id
                """, arguments: [Graph.titleKey(tag)])
        }
    }

    public func blocks(withProperty key: String, value: String?) throws -> [Block] {
        try db.read { db in
            guard let prop = try Property.filter(Column("key") == key.lowercased()).fetchOne(db) else { return [] }
            var wanted = value
            if let value, prop.type == .page {
                guard let id = try String.fetchOne(db, sql: "SELECT id FROM pages WHERE title_lower = ?", arguments: [Graph.titleKey(value)]) else { return [] }
                wanted = id
            }
            return try Block.fetchAll(db, sql: """
                SELECT DISTINCT b.* FROM blocks b JOIN block_props bp ON bp.owner_id = b.id AND bp.owner_kind = 'block'
                WHERE bp.property_id = ? AND (? IS NULL OR bp.value = ?) ORDER BY b.updated_at DESC, b.id
                """, arguments: [prop.id, wanted, wanted])
        }
    }

    /// Runs SQL on a read-only connection. Anything that would write fails with `.readOnlyViolation`.
    public func readOnlyQuery(_ sql: String) throws -> [[String: String?]] {
        do {
            return try db.read { db in
                try Row.fetchAll(db, sql: sql).map { row in
                    var out: [String: String?] = [:]
                    for col in row.columnNames {
                        let value: DatabaseValue = row[col]
                        switch value.storage {
                        case .null: out[col] = .some(nil)
                        case let .int64(i): out[col] = String(i)
                        case let .double(d): out[col] = String(d)
                        case let .string(s): out[col] = s
                        case let .blob(b): out[col] = "<blob \(b.count) bytes>"
                        }
                    }
                    return out
                }
            }
        } catch let e as DatabaseError where e.resultCode == .SQLITE_READONLY || e.extendedResultCode == .SQLITE_READONLY {
            throw GraphError.readOnlyViolation
        }
    }
}

// MARK: suggestions for autocomplete
extension Graph {
    /// Pages whose title contains `query`: exact match first, then prefix, then the rest, newest first. When fewer than `limit`
    /// pages contain it, fuzzy matches (letters in order, or a small typo) fill the rest, best first. An empty query gives recent pages.
    public func pages(matching query: String, limit: Int = 20) throws -> [Page] {
        let q = Graph.titleKey(query)
        if q.isEmpty { return try db.read { try Page.fetchAll($0, sql: "SELECT * FROM pages WHERE kind = 'page' ORDER BY updated_at DESC, id LIMIT ?", arguments: [limit]) } }
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try db.read { db in
            var out = try Page.fetchAll(db, sql: """
                SELECT * FROM pages WHERE title_lower LIKE ? ESCAPE '\\'
                ORDER BY title_lower = ? DESC, title_lower LIKE ? ESCAPE '\\' DESC, length(title_lower), updated_at DESC, id LIMIT ?
                """, arguments: ["%\(escaped)%", q, "\(escaped)%", limit])
            guard out.count < limit else { return out }
            let have = Set(out.map(\.id))
            let rows = try Row.fetchAll(db, sql: "SELECT id, title_lower FROM pages WHERE kind = 'page'")
            let ranked = rows.compactMap { r -> (String, Int)? in
                let id: String = r["id"]
                guard !have.contains(id), let s = Graph.fuzzyScore(query: q, title: r["title_lower"]) else { return nil }
                return (id, s)
            }.sorted { $0.1 > $1.1 }.prefix(limit - out.count)
            for (id, _) in ranked { if let p = try Page.fetchOne(db, key: id) { out.append(p) } }
            return out
        }
    }

    /// nil = no fuzzy match, else 20...200 (higher is better). Matches when the query's letters appear in order in the title (tighter
    /// is better), or when the query is within a typo or two of a word in the title (or the title's start).
    public static func fuzzyScore(query: String, title: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(title.lowercased())
        guard !q.isEmpty else { return 1 }
        var best: Int?
        var first = -1, last = -1, qi = 0
        for (i, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            if qi == 0 { first = i }
            last = i; qi += 1
        }
        if qi == q.count { best = max(20, 200 - (last - first + 1 - q.count) * 5 - min(t.count, 50)) }
        if q.count >= 4 {
            let allowed = q.count <= 5 ? 1 : 2
            var chunks = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(Array.init)
            chunks.append(Array(t.prefix(q.count)))
            for c in chunks {
                let d = editDistance(q, c)
                if d <= allowed { best = max(best ?? 0, 150 - d * 30 - min(t.count, 50) / 5) }
            }
        }
        return best
    }

    /// Optimal-string-alignment distance: insert, delete, substitute or swap two neighbours, each costing 1.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev2 = [Int](repeating: 0, count: b.count + 1), prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { cur[j] = min(cur[j], prev2[j - 2] + 1) }
            }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[b.count]
    }

    /// Tag names (as first written) that contain `query`, prefix matches first.
    public func tagNames(matching query: String, limit: Int = 20) throws -> [String] {
        let q = Graph.titleKey(query)
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try db.read {
            try String.fetchAll($0, sql: """
                SELECT name FROM tags WHERE name_lower LIKE ? ESCAPE '\\'
                ORDER BY name_lower LIKE ? ESCAPE '\\' DESC, length(name_lower), name_lower LIMIT ?
                """, arguments: ["%\(escaped)%", "\(escaped)%", limit])
        }
    }
}

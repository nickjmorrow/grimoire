import Foundation
import GRDB

enum CardApplier {
    static func load(_ blockID: String, _ db: Database) throws -> CardState? {
        try Row.fetchOne(db, sql: "SELECT * FROM cards WHERE block_id = ?", arguments: [blockID]).map {
            CardState(due: $0["due"], stability: $0["stability"], difficulty: $0["difficulty"], reps: $0["reps"], lapses: $0["lapses"],
                      phase: CardPhase(rawValue: $0["phase"]) ?? .review, lastReview: $0["last_review"])
        }
    }

    static func store(_ s: CardState, _ blockID: String, _ db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO cards (block_id, due, stability, difficulty, reps, lapses, phase, last_review) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [blockID, s.due, s.stability, s.difficulty, s.reps, s.lapses, s.phase.rawValue, s.lastReview])
    }

    static func apply(_ op: Op, in db: Database) throws -> Op? {
        switch op {
        case let .reviewCard(blockID, rating, at, state):
            guard try Block.fetchOne(db, key: blockID) != nil else { throw GraphError.blockNotFound(blockID) }
            let previous = try load(blockID, db)
            try store(state, blockID, db)
            try db.execute(sql: "INSERT INTO reviews (block_id, rating, reviewed_at, stability, difficulty, due) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [blockID, rating.rawValue, at, state.stability, state.difficulty, state.due])
            return .setCard(blockID: blockID, state: previous, undoReviewAt: at)
        case let .setCard(blockID, state, undoReviewAt):
            guard try Block.fetchOne(db, key: blockID) != nil else { throw GraphError.blockNotFound(blockID) }
            let previous = try load(blockID, db)
            if let state { try store(state, blockID, db) } else { try db.execute(sql: "DELETE FROM cards WHERE block_id = ?", arguments: [blockID]) }
            if let at = undoReviewAt {
                try db.execute(sql: "DELETE FROM reviews WHERE id = (SELECT id FROM reviews WHERE block_id = ? AND reviewed_at = ? ORDER BY id DESC LIMIT 1)", arguments: [blockID, at])
            }
            return .setCard(blockID: blockID, state: previous, undoReviewAt: nil)
        default: return nil
        }
    }
}

/// What a flashcard review shows.
public struct Card: Sendable, Equatable {
    public let blockID: String
    public let pageID: String
    public let pageTitle: String
    /// The block's text without the `#card` tag.
    public let front: String
    /// The children, as Markdown lines (indented by depth).
    public let back: [String]
    public let state: CardState?
    public var isNew: Bool { state == nil }
}

public struct CardCounts: Sendable, Equatable {
    public var due: Int, new: Int, total: Int
    public init(due: Int, new: Int, total: Int) { self.due = due; self.new = new; self.total = total }
}

/// Which cards a review covers.
public enum CardScope: Sendable, Equatable {
    case all
    case page(String)                                  // page id
    case chapter(pageID: String?, name: String)        // cards under a block whose text contains `name` ("ch 5")
    case block(String)                                 // cards inside one block's subtree (a chapter picked by id)
}

/// A block on a page that has cards somewhere beneath it (a chapter, a section), with how many.
public struct CardGroup: Sendable, Equatable, Identifiable {
    public var id: String { blockID }
    public let blockID: String
    public let title: String
    public let depth: Int
    public let counts: CardCounts
}

extension Graph {
    private func scopeSQL(_ scope: CardScope) -> (sql: String, args: [DatabaseValueConvertible]) {
        switch scope {
        case .all: return ("", [])
        case .page(let id): return (" AND b.page_id = ?", [id])
        case .block(let id):
            return ("""
                 AND EXISTS (
                   WITH RECURSIVE up(id, parent_id) AS (
                     SELECT id, parent_id FROM blocks WHERE id = b.id
                     UNION ALL SELECT p.id, p.parent_id FROM blocks p JOIN up ON p.id = up.parent_id)
                   SELECT 1 FROM up WHERE id = ?)
                """, [id])
        case .chapter(let pageID, let name):
            let like = "%" + name.lowercased().replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            var sql = """
                 AND EXISTS (
                   WITH RECURSIVE up(id, parent_id, text) AS (
                     SELECT id, parent_id, text FROM blocks WHERE id = b.parent_id
                     UNION ALL SELECT p.id, p.parent_id, p.text FROM blocks p JOIN up ON p.id = up.parent_id)
                   SELECT 1 FROM up WHERE lower(text) LIKE ? ESCAPE '\\')
                """
            var args: [DatabaseValueConvertible] = [like]
            if let pageID { sql += " AND b.page_id = ?"; args.append(pageID) }
            return (sql, args)
        }
    }

    private static let cardBlocks = """
        FROM blocks b JOIN block_tags bt ON bt.block_id = b.id JOIN tags t ON t.id = bt.tag_id AND t.name_lower = 'card'
        LEFT JOIN cards c ON c.block_id = b.id
        WHERE 1 = 1
        """

    public func cardCounts(scope: CardScope = .all, now: Int64 = Graph.nowMillis()) throws -> CardCounts {
        let (sql, args) = scopeSQL(scope)
        return try db.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total, SUM(c.block_id IS NULL) AS new, SUM(c.block_id IS NOT NULL AND c.due <= ?) AS due
                \(Graph.cardBlocks) \(sql)
                """, arguments: StatementArguments([now] + args))!
            return CardCounts(due: row["due"] ?? 0, new: row["new"] ?? 0, total: row["total"] ?? 0)
        }
    }

    /// Cards to study now: due ones (oldest first), then up to `newLimit` unseen ones in page order.
    public func nextCards(scope: CardScope = .all, now: Int64 = Graph.nowMillis(), limit: Int = 20, newLimit: Int = 10) throws -> [Card] {
        let (sql, args) = scopeSQL(scope)
        let ids: [String] = try db.read { db in
            let due = try String.fetchAll(db, sql: "SELECT b.id \(Graph.cardBlocks) AND c.block_id IS NOT NULL AND c.due <= ? \(sql) ORDER BY c.due, b.id LIMIT ?",
                                          arguments: StatementArguments([now] + args + [limit]))
            let room = max(0, min(newLimit, limit - due.count))
            // Unseen cards come in reading order: by page, then by position in the outline (path of order keys).
            let new = room == 0 ? [] : try String.fetchAll(db, sql: """
                WITH RECURSIVE tree(id, path) AS (
                  SELECT id, order_key FROM blocks WHERE parent_id IS NULL
                  UNION ALL SELECT k.id, tree.path || '/' || k.order_key FROM blocks k JOIN tree ON k.parent_id = tree.id)
                SELECT b.id \(Graph.cardBlocks) AND c.block_id IS NULL \(sql)
                ORDER BY (SELECT p.title_lower FROM pages p WHERE p.id = b.page_id), (SELECT path FROM tree WHERE tree.id = b.id), b.id LIMIT ?
                """, arguments: StatementArguments(args + [room]))
            return due + new
        }
        return try ids.compactMap { try card(blockID: $0) }
    }

    /// The blocks on a page that contain cards, in outline order and indented by how many listed blocks enclose them. A block holding
    /// exactly the same cards as its parent is left out (a "flashcards" bullet under "ch 1" shows as "ch 1").
    public func cardGroups(pageID: String, now: Int64 = Graph.nowMillis()) throws -> [CardGroup] {
        try db.read { db in
            let blocks = try Block.filter(Column("page_id") == pageID).order(Column("order_key"), Column("id")).fetchAll(db)
            let cardIDs = Set(try String.fetchAll(db, sql: """
                SELECT b.id FROM blocks b JOIN block_tags bt ON bt.block_id = b.id JOIN tags t ON t.id = bt.tag_id AND t.name_lower = 'card'
                WHERE b.page_id = ?
                """, arguments: [pageID]))
            guard !cardIDs.isEmpty else { return [] }
            let due = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT c.block_id, c.due FROM cards c JOIN blocks b ON b.id = c.block_id WHERE b.page_id = ?",
                                                                       arguments: [pageID]).map { (r: Row) -> (String, Int64) in (r["block_id"], r["due"]) })
            var kids: [String?: [Block]] = [:]
            for b in blocks { kids[b.parentId, default: []].append(b) }
            var out: [CardGroup] = []
            /// Returns (due, new) for the cards in this subtree.
            func walk(_ b: Block, depth: Int, parentTotal: Int?) -> (due: Int, new: Int) {
                let slot = out.count
                if !cardIDs.contains(b.id) { out.append(CardGroup(blockID: b.id, title: b.text, depth: depth, counts: CardCounts(due: 0, new: 0, total: 0))) }
                var due0 = 0, new0 = 0
                if cardIDs.contains(b.id) {
                    if let d = due[b.id] { if d <= now { due0 += 1 } } else { new0 += 1 }
                }
                // Counting first needs the subtree totals, so measure them, then place children under the right depth.
                let total = Graph.subtreeCardCount(b, kids: kids, cards: cardIDs)
                let shown = !cardIDs.contains(b.id) && total > 0 && total != parentTotal
                let childDepth = shown ? depth + 1 : depth
                if !cardIDs.contains(b.id) { out[slot] = CardGroup(blockID: b.id, title: b.text, depth: depth, counts: CardCounts(due: 0, new: 0, total: total)) }
                for k in kids[b.id] ?? [] {
                    let r = walk(k, depth: childDepth, parentTotal: cardIDs.contains(b.id) ? nil : total)
                    due0 += r.due; new0 += r.new
                }
                if !cardIDs.contains(b.id) {
                    if shown { out[slot] = CardGroup(blockID: b.id, title: b.text, depth: depth, counts: CardCounts(due: due0, new: new0, total: total)) }
                    else { out[slot] = CardGroup(blockID: "", title: "", depth: -1, counts: CardCounts(due: 0, new: 0, total: 0)) }
                }
                return (due0, new0)
            }
            for top in kids[nil] ?? [] { _ = walk(top, depth: 0, parentTotal: nil) }
            return out.filter { $0.depth >= 0 && $0.counts.total > 0 }
        }
    }

    private static func subtreeCardCount(_ b: Block, kids: [String?: [Block]], cards: Set<String>) -> Int {
        (cards.contains(b.id) ? 1 : 0) + (kids[b.id] ?? []).reduce(0) { $0 + subtreeCardCount($1, kids: kids, cards: cards) }
    }

    public func card(blockID: String) throws -> Card? {
        try db.read { db in
            guard let b = try Block.fetchOne(db, key: blockID), let page = try Page.fetchOne(db, key: b.pageId) else { return nil }
            var back: [String] = []
            func walk(_ parent: String, _ depth: Int) throws {
                for child in try Block.filter(Column("parent_id") == parent).order(Column("order_key"), Column("id")).fetchAll(db) {
                    back.append(String(repeating: "  ", count: depth) + child.text)
                    try walk(child.id, depth + 1)
                }
            }
            try walk(b.id, 0)
            let front = b.text.replacingOccurrences(of: #"(^|\s)#card\b"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            return Card(blockID: b.id, pageID: page.id, pageTitle: page.title, front: front, back: back, state: try CardApplier.load(b.id, db))
        }
    }

    /// Records an answer: schedules the card with FSRS and logs the review. Returns the new state.
    @discardableResult
    public func review(blockID: String, rating: Rating, now: Int64 = Graph.nowMillis(), author: Author = .me, fsrs: FSRS = FSRS()) throws -> CardState {
        try reviewLogged(blockID: blockID, rating: rating, now: now, author: author, fsrs: fsrs).state
    }

    /// Like `review`, also returning the op's local id so exactly that answer can be taken back with `undoOp`.
    public func reviewLogged(blockID: String, rating: Rating, now: Int64 = Graph.nowMillis(), author: Author = .me, fsrs: FSRS = FSRS()) throws -> (state: CardState, opID: Int64) {
        let current = try db.read { try CardApplier.load(blockID, $0) }
        let next = fsrs.next(current, rating, now: now)
        let ids = try perform([.reviewCard(blockID: blockID, rating: rating, at: now, state: next)], author: author)
        return (next, ids[0])
    }

    public func reviewCount(blockID: String) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM reviews WHERE block_id = ?", arguments: [blockID]) ?? 0 }
    }
}

import Foundation

/// Full row of a block, used to restore deleted subtrees.
public struct BlockSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var pageId: String
    public var parentId: String?
    public var orderKey: String
    public var text: String
    public var collapsed: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    public var author: Author
    /// The block's flashcard schedule, so deleting and restoring a card keeps it.
    public var card: CardState?

    public init(_ b: Block) {
        id = b.id; pageId = b.pageId; parentId = b.parentId; orderKey = b.orderKey; text = b.text
        collapsed = b.collapsed; createdAt = b.createdAt; updatedAt = b.updatedAt; author = b.author
    }

    var block: Block {
        Block(id: id, pageId: pageId, parentId: parentId, orderKey: orderKey, text: text,
              collapsed: collapsed, createdAt: createdAt, updatedAt: updatedAt, author: author)
    }
}

/// Every change to a graph is one of these. They are logged, replayed by sync and inverted by undo.
public indirect enum Op: Codable, Sendable, Equatable {
    case createPage(id: String, title: String, kind: PageKind, journalDate: String?)
    case renamePage(id: String, title: String)
    case setFavorite(pageID: String, favorite: Bool, order: Int?)
    case deletePage(id: String)
    case insertBlock(id: String, pageID: String, parentID: String?, orderKey: String, text: String)
    case editText(blockID: String, text: String)
    case moveBlock(blockID: String, pageID: String, parentID: String?, orderKey: String)
    case deleteBlock(blockID: String)
    case setCollapsed(blockID: String, collapsed: Bool)
    case restoreBlocks([BlockSnapshot])
    case addAsset(hash: String, filename: String, mime: String, size: Int64)
    /// A flashcard was answered: new memory state plus a review-log row.
    case reviewCard(blockID: String, rating: Rating, at: Int64, state: CardState)
    /// Sets (or with nil, clears) a card's memory state, and removes the review logged at `undoReviewAt` if given.
    case setCard(blockID: String, state: CardState?, undoReviewAt: Int64?)
    case batch([Op])
    /// Inverse of `insertBlock`: removes the block only if nothing has changed on it since.
    case discardBlock(blockID: String, text: String)
    /// Inverse of `createPage`: removes the page only if it is still empty and nothing links to it.
    case discardPage(id: String)

    var kind: String { Mirror(reflecting: self).children.first?.label ?? "\(self)" }
}

public enum GraphError: Error, Equatable {
    case titleTaken(String)
    case pageNotFound(String)
    case blockNotFound(String)
    case cycle
    case readOnlyViolation
    case undoBlocked(String)
    case pageInUse(String)
}

/// Orders snapshots so every block comes after its parent (roots first, then breadth-first).
func orderParentsFirst(_ snapshots: [BlockSnapshot]) -> [BlockSnapshot] {
    let ids = Set(snapshots.map(\.id))
    let children = Dictionary(grouping: snapshots.filter { $0.parentId.map(ids.contains) ?? false }, by: { $0.parentId! })
    var out: [BlockSnapshot] = snapshots.filter { $0.parentId == nil || !ids.contains($0.parentId!) }
    var i = 0
    while i < out.count { out += children[out[i].id] ?? []; i += 1 }
    return out
}

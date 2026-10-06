import Foundation
import GRDB

struct BlockPropRow: Codable {
    var ownerId: String, ownerKind: String, propertyId: String, value: String, position: Int
}

struct GraphExport: Codable {
    var version = 1
    var pages: [Page], blocks: [Block], tags: [Tag], properties: [Property], blockProps: [BlockPropRow], assets: [Asset]
    var cards: [CardRow] = []
    var reviews: [ReviewRow] = []
}

struct CardRow: Codable { var blockId: String; var state: CardState }
struct ReviewRow: Codable { var blockId: String; var rating: Int; var reviewedAt: Int64; var stability: Double; var difficulty: Double; var due: Int64 }

extension Graph {
    /// Writes every stored row as JSON (a lossless dump another tool can import).
    public func exportJSON(to url: URL) throws {
        let dump: GraphExport = try db.read { db in
            GraphExport(
                pages: try Page.order(Column("id")).fetchAll(db),
                blocks: try Block.order(Column("id")).fetchAll(db),
                tags: try Tag.order(Column("id")).fetchAll(db),
                properties: try Property.order(Column("id")).fetchAll(db),
                blockProps: try Row.fetchAll(db, sql: "SELECT * FROM block_props ORDER BY owner_id, property_id, position").map {
                    BlockPropRow(ownerId: $0["owner_id"], ownerKind: $0["owner_kind"], propertyId: $0["property_id"],
                                 value: $0["value"], position: $0["position"])
                },
                assets: try Asset.order(Column("hash")).fetchAll(db),
                cards: try String.fetchAll(db, sql: "SELECT block_id FROM cards ORDER BY block_id").compactMap { id in try CardApplier.load(id, db).map { CardRow(blockId: id, state: $0) } },
                reviews: try Row.fetchAll(db, sql: "SELECT * FROM reviews ORDER BY id").map {
                    ReviewRow(blockId: $0["block_id"], rating: $0["rating"], reviewedAt: $0["reviewed_at"], stability: $0["stability"], difficulty: $0["difficulty"], due: $0["due"])
                })
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        try enc.encode(dump).write(to: url, options: .atomic)
    }
}

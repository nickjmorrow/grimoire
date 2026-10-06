import Foundation
import GRDB

public enum Author: String, Codable, Sendable { case me, claude, `import`, sync }
public enum PageKind: String, Codable, Sendable { case page, journal }
public enum PropertyType: String, Codable, Sendable { case text, number, date, datetime, url, checkbox, page }
public enum Cardinality: String, Codable, Sendable { case one, many }

/// Records map camelCase properties to snake_case columns.
public protocol GrimRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}
public extension GrimRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
}

public struct Page: GrimRecord, Equatable {
    public static let databaseTableName = "pages"
    public var id: String
    public var title: String
    public var titleLower: String
    public var kind: PageKind
    public var journalDate: String?
    public var favorite: Bool
    public var favoriteOrder: Int?
    public var createdAt: Int64
    public var updatedAt: Int64
}

public struct Block: GrimRecord, Equatable {
    public static let databaseTableName = "blocks"
    public var id: String
    public var pageId: String
    public var parentId: String?
    public var orderKey: String
    public var text: String
    public var collapsed: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    public var author: Author
}

public struct Tag: GrimRecord, Equatable {
    public static let databaseTableName = "tags"
    public var id: String
    public var name: String
    public var nameLower: String
    public var pageId: String
    public var createdAt: Int64
}

public struct Property: GrimRecord, Equatable {
    public static let databaseTableName = "properties"
    public var id: String
    public var key: String
    public var type: PropertyType
    public var cardinality: Cardinality
}

public struct Asset: GrimRecord, Equatable {
    public static let databaseTableName = "assets"
    public var hash: String
    public var filename: String
    public var mime: String
    public var size: Int64
    public var createdAt: Int64
}

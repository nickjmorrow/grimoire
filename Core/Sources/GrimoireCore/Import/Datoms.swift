import Foundation

public enum ImportError: Error, Equatable {
    case notADatomExport
    case graphNotEmpty
}

/// Logseq's `graph export --type edn` output: `[entity attribute value]` triples grouped per entity.
public struct Datoms: Sendable {
    private var store: [Int64: [String: [EDNValue]]] = [:]
    private var uuidIndex: [String: Int64] = [:]
    private var identIndex: [String: Int64] = [:]

    public init(exportText: String) throws {
        guard case let .map(pairs) = try EDN.parse(exportText),
              let datoms = pairs.first(where: { $0.0 == .keyword(":datoms") })?.1,
              case let .vector(triples) = datoms else { throw ImportError.notADatomExport }
        store.reserveCapacity(triples.count / 6)
        for triple in triples {
            guard case let .vector(parts) = triple, parts.count == 3, case let .int(e) = parts[0], case let .keyword(a) = parts[1] else { continue }
            store[e, default: [:]][a, default: []].append(parts[2])
            if a == ":block/uuid", case let .uuid(u) = parts[2] { uuidIndex[u.lowercased()] = e }
            if a == ":db/ident", case let .keyword(k) = parts[2] { identIndex[k] = e }
        }
    }

    public var entities: [Int64] { store.keys.sorted() }
    public func entities(having attr: String) -> [Int64] { store.filter { $0.value[attr] != nil }.keys.sorted() }
    public func attributes(of e: Int64) -> [String] { Array(store[e]?.keys ?? [:].keys) }
    public func entity(withIdent ident: String) -> Int64? { identIndex[ident] }
    public func entity(withUUID uuid: String) -> Int64? { uuidIndex[uuid.lowercased()] }

    public func values(_ e: Int64, _ attr: String) -> [EDNValue] { store[e]?[attr] ?? [] }
    public func first(_ e: Int64, _ attr: String) -> EDNValue? { store[e]?[attr]?.first }
    public func string(_ e: Int64, _ attr: String) -> String? { if case let .string(s)? = first(e, attr) { return s }; return nil }
    public func int(_ e: Int64, _ attr: String) -> Int64? { if case let .int(n)? = first(e, attr) { return n }; return nil }
    public func bool(_ e: Int64, _ attr: String) -> Bool { if case .bool(true)? = first(e, attr) { return true }; return false }
    public func keyword(_ e: Int64, _ attr: String) -> String? { if case let .keyword(k)? = first(e, attr) { return k }; return nil }
    public func refs(_ e: Int64, _ attr: String) -> [Int64] { values(e, attr).compactMap { if case let .int(n) = $0 { return n }; return nil } }
    public func uuid(_ e: Int64) -> String? { if case let .uuid(u)? = first(e, ":block/uuid") { return u.lowercased() }; return nil }
}

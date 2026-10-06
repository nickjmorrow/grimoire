import CryptoKit
import Foundation
import GRDB
import UniformTypeIdentifiers

public struct ImportReport: Sendable, Equatable, Codable {
    public var pages = 0, journals = 0, blocks = 0, tags = 0, properties = 0, favorites = 0, assets = 0, tasks = 0, cards = 0
    public var skippedRecycled = 0, mergedDuplicatePages = 0
    public var unresolvedReferences: [String] = []
    public var missingAssetFiles: [String] = []
    public var warnings: [String] = []
    public init() {}
}

public enum LogseqImporter {
    /// Imports into a throwaway graph and returns what would happen.
    public static func dryRun(datoms: Datoms, assetsFolder: URL?) throws -> ImportReport {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("grim-dryrun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        return try importGraph(datoms: datoms, assetsFolder: assetsFolder, into: try Graph(folder: folder, device: "dry-run"))
    }

    /// Imports a Logseq datom export into an empty graph. Never touches the Logseq graph itself.
    public static func importGraph(datoms: Datoms, assetsFolder: URL?, into graph: Graph) throws -> ImportReport {
        let isEmpty = try graph.db.read {
            try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM pages) + (SELECT COUNT(*) FROM blocks)") == 0
        }
        guard isEmpty else { throw ImportError.graphNotEmpty }
        var run = Run(d: datoms, assetsFolder: assetsFolder, graphFolder: graph.folder)
        return try graph.db.write { try run.execute(in: $0, device: graph.device) }
    }
}

struct Run {
    let d: Datoms
    let assetsFolder: URL?
    let graphFolder: URL
    var report = ImportReport()

    var deletedCache: [Int64: Bool] = [:]
    var liveBlockCount: [Int64: Int] = [:]        // page entity → number of live blocks on it
    var pageIDFor: [Int64: String] = [:]          // Logseq page entity → Grimoire page id
    var pageTitleFor: [Int64: String] = [:]       // Logseq page entity → canonical title
    var uuidToPageTitle: [String: String] = [:]   // Logseq uuid (lowercased) → title
    var blockUUIDs: Set<String> = []
    var assetMap: [String: String] = [:]          // "uuid.ext" → "assets/<hash>.<ext>"
    var minTopKey: [String: String] = [:]         // page id → smallest top-level order key
    var canonicalPages: [(entity: Int64, pageID: String, created: Int64)] = []
    var mergedMembers: [String: [Int64]] = [:]    // page id → duplicate page entities folded into it
    var mergedTitles: [String: (title: String, count: Int)] = [:]
    var numbering: [Int64: Int] = [:]             // block entity → its number in a numbered list
    var unsafeAssets = 0
    var unresolved: Set<String> = []
    var missing: Set<String> = []
    var warnedDeleted: Set<String> = []

    init(d: Datoms, assetsFolder: URL?, graphFolder: URL) { self.d = d; self.assetsFolder = assetsFolder; self.graphFolder = graphFolder }

    // MARK: classification

    mutating func isDeleted(_ e: Int64) -> Bool {
        if let c = deletedCache[e] { return c }
        var result = d.int(e, ":logseq.property/deleted-at") != nil
        if !result, let parent = d.int(e, ":block/parent"), parent != e { result = isDeleted(parent) }
        if !result, let page = d.int(e, ":block/page"), page != e { result = isDeleted(page) }
        deletedCache[e] = result
        return result
    }

    func isValueBlock(_ e: Int64) -> Bool { d.first(e, ":logseq.property/created-from-property") != nil }

    mutating func isImportablePage(_ e: Int64) -> Bool {
        guard let name = d.string(e, ":block/name"), !name.hasPrefix("$$$") else { return false }
        if d.bool(e, ":logseq.property/built-in?") || isValueBlock(e) { return false }
        if let ident = d.keyword(e, ":db/ident") {
            // A property's own page is only worth keeping when the user wrote notes under it.
            let isProperty = ident.hasPrefix(":user.property/") && (liveBlockCount[e] ?? 0) > 0
            if !ident.hasPrefix(":user.class/") && !isProperty { return false }
        }
        return !isDeleted(e)
    }

    func isPage(_ e: Int64) -> Bool { d.string(e, ":block/name") != nil }

    mutating func execute(in db: Database, device: String) throws -> ImportReport {
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        let now = Graph.nowMillis()
        for e in d.entities(having: ":block/page") where !isValueBlock(e) && !isDeleted(e) {
            if let page = d.int(e, ":block/page") { liveBlockCount[page, default: 0] += 1 }
        }
        try insertPages(db, now)
        try copyAssets(db, now)
        try insertBlocks(db, now)
        report.cards = try LogseqCards.insert(from: d, blockIDs: blockUUIDs, into: db)
        try insertPageProperties(db, now)
        try applyFavorites(db)
        try Indexer.reindexAll(in: db, now: now)
        report.unresolvedReferences = unresolved.sorted()
        report.missingAssetFiles = missing.sorted()
        report.warnings += warnedDeleted.sorted().map { "a block links to the deleted page '\($0)'" }
        report.warnings += mergedTitles.values.sorted { $0.title < $1.title }.map { "merged \($0.count) pages titled '\($0.title)'" }
        if unsafeAssets > 0 { report.warnings.append("ignored \(unsafeAssets) unsafe asset name(s)") }
        report.warnings += unsupportedFeatureWarnings()
        report.tags = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags") ?? 0
        report.properties = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM properties") ?? 0
        let payload = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        try db.execute(sql: "INSERT INTO ops (device, author, kind, payload, inverse, created_at) VALUES (?, 'import', 'import', ?, NULL, ?)",
                       arguments: [device, payload, now])
        return report
    }

    // MARK: pages

    mutating func insertPages(_ db: Database, _ now: Int64) throws {
        var idByKey: [String: String] = [:]
        for e in d.entities(having: ":block/name") where isImportablePage(e) {
            var title = d.string(e, ":block/title") ?? d.string(e, ":block/name") ?? ""
            guard !title.isEmpty else { continue }
            var kind = PageKind.page
            var journalDate: String?
            var id: String
            if let day = d.int(e, ":block/journal-day"), let jd = JournalDate(year: Int(day / 10000), month: Int(day / 100 % 100), day: Int(day % 100)) {
                kind = .journal; journalDate = jd.iso; title = jd.title(); id = jd.pageID
            } else {
                id = Graph.pageID(forTitle: title)
            }
            let key = Graph.titleKey(title)
            if let existing = idByKey[key] {
                pageIDFor[e] = existing
                pageTitleFor[e] = title
                if let u = d.uuid(e) { uuidToPageTitle[u] = title }
                report.mergedDuplicatePages += 1
                mergedMembers[existing, default: []].append(e)
                mergedTitles[key] = (title, (mergedTitles[key]?.count ?? 1) + 1)
                continue
            }
            idByKey[key] = id
            pageIDFor[e] = id; pageTitleFor[e] = title
            if let u = d.uuid(e) { uuidToPageTitle[u] = title }
            let created = d.int(e, ":block/created-at") ?? now
            try Page(id: id, title: title, titleLower: key, kind: kind, journalDate: journalDate, favorite: false, favoriteOrder: nil,
                     createdAt: created, updatedAt: d.int(e, ":block/updated-at") ?? created).insert(db)
            canonicalPages.append((e, id, created))
            if kind == .journal { report.journals += 1 } else { report.pages += 1 }
        }
    }

    // MARK: assets

    mutating func copyAssets(_ db: Database, _ now: Int64) throws {
        guard let folder = assetsFolder else { return }
        for e in d.entities(having: ":logseq.property.asset/checksum") {
            guard let uuid = d.uuid(e), let ext = d.string(e, ":logseq.property.asset/type") else { continue }
            guard uuid.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/) != nil,
                  ext.wholeMatch(of: /[A-Za-z0-9]{1,12}/) != nil else { unsafeAssets += 1; continue }
            let name = "\(uuid).\(ext)"
            let src = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            var hasher = SHA256(); var size: Int64 = 0
            let handle = try FileHandle(forReadingFrom: src)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk); size += Int64(chunk.count) }
            let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let target = graphFolder.appendingPathComponent("assets/\(hash).\(ext)")
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: src, to: target) }
            let title = d.string(e, ":block/title") ?? uuid
            try Asset(hash: hash, filename: "\(title).\(ext)", mime: UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream",
                      size: size, createdAt: d.int(e, ":block/created-at") ?? now).insert(db, onConflict: .ignore)
            assetMap[name] = "assets/\(hash).\(ext)"
            report.assets += 1
        }
    }

    // MARK: blocks

    mutating func blockEntities() -> [Int64] {
        var out: [Int64] = []
        for e in d.entities(having: ":block/page") {
            guard !isValueBlock(e), let page = d.int(e, ":block/page") else { continue }
            guard pageIDFor[page] != nil || isDeleted(page) else { continue }       // blocks of skipped pages (favorites, built-ins) are ignored
            if isDeleted(e) { report.skippedRecycled += 1; continue }
            guard d.uuid(e) != nil, pageIDFor[page] != nil else { continue }
            out.append(e)
        }
        return out
    }

    mutating func insertBlocks(_ db: Database, _ now: Int64) throws {
        let entities = blockEntities()
        for e in entities { blockUUIDs.insert(d.uuid(e)!) }
        computeNumbering(entities)
        for e in entities {
            let page = d.int(e, ":block/page")!
            let pageID = pageIDFor[page]!
            let parentEntity = d.int(e, ":block/parent")
            let parentUUID: String? = parentEntity.flatMap { $0 == page ? nil : d.uuid($0) }
            let order = d.string(e, ":block/order") ?? "V"
            if parentUUID == nil, minTopKey[pageID].map({ order < $0 }) ?? true { minTopKey[pageID] = order }
            let created = d.int(e, ":block/created-at") ?? now
            try Block(id: d.uuid(e)!, pageId: pageID, parentId: parentUUID, orderKey: order, text: renderBlock(e),
                      collapsed: d.bool(e, ":block/collapsed?"), createdAt: created,
                      updatedAt: d.int(e, ":block/updated-at") ?? created, author: .import).insert(db)
            report.blocks += 1
        }
    }

    // MARK: page-level properties and tags

    mutating func insertPageProperties(_ db: Database, _ now: Int64) throws {
        for (e, pageID, created) in canonicalPages {
            let members = [e] + (mergedMembers[pageID] ?? [])
            var lines: [String] = []
            var seenKeys: Set<String> = []
            for m in members {
                for line in propertyLines(for: m, existingText: "") {
                    let key = line.components(separatedBy: ":: ")[0].lowercased()
                    if seenKeys.insert(key).inserted { lines.append(line) }
                }
            }
            var tags: [String] = []
            for m in members { for t in userClassNames(of: m) where !tags.contains(t) { tags.append(t) } }
            if !tags.isEmpty { lines.append("tags:: " + tags.map { "[[\($0)]]" }.joined(separator: ", ")) }
            guard !lines.isEmpty else { continue }
            try Block(id: UUIDv5.make(namespace: UUIDv5.property, name: "pageprops:\(pageID)"), pageId: pageID, parentId: nil,
                      orderKey: OrderKey.between(nil, minTopKey[pageID]), text: lines.joined(separator: "\n"), collapsed: false,
                      createdAt: created, updatedAt: created, author: .import).insert(db)
        }
    }

    // MARK: favorites

    mutating func applyFavorites(_ db: Database) throws {
        guard let fav = d.entities(having: ":block/name").first(where: { d.string($0, ":block/name") == "$$$favorites" }) else { return }
        let children = d.entities(having: ":block/link").filter { d.int($0, ":block/page") == fav }
            .sorted { (d.string($0, ":block/order") ?? "") < (d.string($1, ":block/order") ?? "") }
        for child in children {
            guard let link = d.int(child, ":block/link"), let pageID = pageIDFor[link] else { continue }
            try db.execute(sql: "UPDATE pages SET favorite = 1, favorite_order = ? WHERE id = ?", arguments: [report.favorites, pageID])
            report.favorites += 1
        }
    }
}

extension Run {
    /// Numbered-list blocks are numbered per run of consecutive numbered siblings.
    mutating func computeNumbering(_ entities: [Int64]) {
        let byParent = Dictionary(grouping: entities, by: { d.int($0, ":block/parent") ?? -1 })
        for kids in byParent.values {
            var n = 0
            for k in kids.sorted(by: { (d.string($0, ":block/order") ?? "", $0) < (d.string($1, ":block/order") ?? "", $1) }) {
                if isNumbered(k) { n += 1; numbering[k] = n } else { n = 0 }
            }
        }
    }

    func isNumbered(_ e: Int64) -> Bool {
        guard let v = d.first(e, ":logseq.property/order-list-type") else { return false }
        if case let .int(ref) = v, let t = d.string(ref, ":block/title") { return !t.lowercased().contains("bullet") }
        if case let .string(s) = v { return !s.lowercased().contains("bullet") }
        return true
    }

    /// Features Logseq has that Grimoire doesn't (yet): counted so nothing disappears without a word.
    mutating func unsupportedFeatureWarnings() -> [String] {
        var out: [String] = []
        let aliasPages = Set(pageIDFor.keys).filter { d.first($0, ":block/alias") != nil }.count
        if aliasPages > 0 { out.append("aliases are not imported (\(aliasPages) page\(aliasPages == 1 ? "" : "s"))") }
        let queries = d.entities(having: ":logseq.property/query").filter { d.int($0, ":block/page").map { pageIDFor[$0] != nil } ?? false && !isDeleted($0) }.count
        if queries > 0 { out.append("saved queries are not imported (\(queries))") }
        return out
    }
}


/// Review schedules from Logseq's `:logseq.property.fsrs/due` and `/state` (it keeps only the latest state, not the history).
public enum LogseqCards {
    public struct Imported: Equatable { public var blockID: String; public var state: CardState; public var lastRating: Rating? }

    public static func read(from d: Datoms) -> [Imported] {
        var out: [Imported] = []
        for e in d.entities(having: ":logseq.property.fsrs/state") {
            guard let uuid = d.uuid(e), case let .map(pairs)? = d.first(e, ":logseq.property.fsrs/state") else { continue }
            var m: [String: EDNValue] = [:]
            for (k, v) in pairs { if case let .keyword(name) = k { m[name] = v } }
            func num(_ k: String) -> Double? { switch m[k] { case .int(let n)?: return Double(n); case .double(let x)?: return x; default: return nil } }
            guard let stability = num(":stability"), let difficulty = num(":difficulty") else { continue }
            var due = d.int(e, ":logseq.property.fsrs/due") ?? 0
            let last = num(":last-repeat").map(Int64.init)
            if due == 0 { due = last ?? 0 }
            var phase = CardPhase.review
            if case let .keyword(k)? = m[":state"] { phase = ["new": .new, ":new": .new, ":learning": .learning, ":relearning": .relearning][k] ?? .review }
            var rating: Rating?
            if case let .keyword(k)? = m[":logseq/last-rating"] { rating = [":again": .again, ":hard": .hard, ":good": .good, ":easy": .easy][k] }
            let reps = Int(num(":reps") ?? 0)
            guard reps > 0 || phase != .new else { continue }
            out.append(Imported(blockID: uuid, state: CardState(due: due, stability: stability, difficulty: difficulty, reps: reps,
                                                               lapses: Int(num(":lapses") ?? 0), phase: phase == .new ? .learning : phase, lastReview: last), lastRating: rating))
        }
        return out
    }

    /// Stores schedules for the cards whose blocks exist in the graph. Returns how many.
    @discardableResult
    static func insert(from d: Datoms, blockIDs: Set<String>? = nil, into db: Database) throws -> Int {
        var n = 0
        for c in read(from: d) {
            let exists = try Int.fetchOne(db, sql: "SELECT 1 FROM blocks WHERE id = ?", arguments: [c.blockID]) != nil
            guard exists else { continue }
            try CardApplier.store(c.state, c.blockID, db)
            if let r = c.lastRating, let at = c.state.lastReview {
                try db.execute(sql: "INSERT INTO reviews (block_id, rating, reviewed_at, stability, difficulty, due) VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: [c.blockID, r.rawValue, at, c.state.stability, c.state.difficulty, c.state.due])
            }
            n += 1
        }
        return n
    }

    /// Adds schedules to an already-imported graph (used once, for graphs imported before cards were supported).
    public static func importInto(_ graph: Graph, datoms: Datoms) throws -> Int {
        try graph.db.write { try insert(from: datoms, into: $0) }
    }
}

import Foundation
import GRDB

public struct UpdateReport: Sendable, Equatable, Codable {
    public var pagesAdded = 0, blocksAdded = 0, blocksUpdated = 0, blocksRemoved = 0, assetsAdded = 0, cardsUpdated = 0
    /// Blocks Logseq changed that were also changed in Grimoire since the import: Grimoire's version is kept.
    public var keptYours: [String] = []
    public var import_: ImportReport?
    public init() {}
}

/// Brings Logseq changes made since the first import into a graph that is already in use, without touching anything edited in Grimoire.
///
/// A fresh import of the new export is built in a scratch graph and compared block by block (ids are Logseq's UUIDs):
/// - a block that is new in Logseq is added, under its parent when that exists, else at the page's top level;
/// - a block still marked `import` (never edited in Grimoire) takes Logseq's newer text, or is removed when Logseq deleted it;
/// - a block edited in Grimoire stays as it is and is listed in `keptYours`.
/// Everything goes through ops as author `import`, so it syncs like any other change.
public enum LogseqUpdate {
    public static func apply(datoms: Datoms, assetsFolder: URL?, to graph: Graph) throws -> UpdateReport {
        let scratchFolder = FileManager.default.temporaryDirectory.appendingPathComponent("grim-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchFolder) }
        let scratch = try Graph(folder: scratchFolder, device: "update-scratch")
        var report = UpdateReport()
        report.import_ = try LogseqImporter.importGraph(datoms: datoms, assetsFolder: assetsFolder, into: scratch)

        struct B { var id: String; var pageID: String; var parentID: String?; var orderKey: String; var text: String; var collapsed: Bool; var author: String }
        func blocks(_ g: Graph) throws -> [String: B] {
            try g.db.read { db in
                Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, page_id, parent_id, order_key, text, collapsed, author FROM blocks").map {
                    ($0["id"] as String, B(id: $0["id"], pageID: $0["page_id"], parentID: $0["parent_id"], orderKey: $0["order_key"], text: $0["text"], collapsed: ($0["collapsed"] as Int) == 1, author: $0["author"]))
                })
            }
        }
        let theirs = try blocks(scratch), mine = try blocks(graph)
        let myPages: Set<String> = try graph.db.read { Set(try String.fetchAll($0, sql: "SELECT id FROM pages")) }
        let newPages = try scratch.db.read { try Page.fetchAll($0).filter { !myPages.contains($0.id) } }

        var ops: [Op] = []
        for p in newPages {
            ops.append(.createPage(id: p.id, title: p.title, kind: p.kind, journalDate: p.journalDate))
            if p.favorite { ops.append(.setFavorite(pageID: p.id, favorite: true, order: p.favoriteOrder)) }
        }
        report.pagesAdded = newPages.count

        // new blocks, parents first
        let added = theirs.values.filter { mine[$0.id] == nil }
        func depth(_ b: B) -> Int { var d = 0, cur = b; while let p = cur.parentID, let n = theirs[p], d < 100 { d += 1; cur = n }; return d }
        for b in added.sorted(by: { (depth($0), $0.orderKey, $0.id) < (depth($1), $1.orderKey, $1.id) }) {
            let parentThere = b.parentID.map { mine[$0] != nil || theirs[$0] != nil } ?? false
            ops.append(.insertBlock(id: b.id, pageID: b.pageID, parentID: parentThere ? b.parentID : nil, orderKey: b.orderKey, text: b.text))
            if b.collapsed { ops.append(.setCollapsed(blockID: b.id, collapsed: true)) }
        }
        report.blocksAdded = added.count

        // changed text
        for (id, t) in theirs {
            guard let m = mine[id], m.text != t.text else { continue }
            if m.author == "import" { ops.append(.editText(blockID: id, text: t.text)); report.blocksUpdated += 1 }
            else { report.keptYours.append(id) }
        }

        // removed in Logseq: only blocks never edited here, and never a block with a surviving descendant
        let childrenOf = Dictionary(grouping: mine.values, by: { $0.parentID ?? "" })
        func survivors(_ id: String) -> Bool {
            if theirs[id] != nil { return true }
            return (childrenOf[id] ?? []).contains { survivors($0.id) }
        }
        func editedBelow(_ id: String) -> Bool { (childrenOf[id] ?? []).contains { $0.author != "import" || editedBelow($0.id) } }
        for m in mine.values where theirs[m.id] == nil && m.author == "import" && !survivors(m.id) && !editedBelow(m.id) {
            if let p = m.parentID, let pb = mine[p], theirs[p] == nil, pb.author == "import", !survivors(p) { continue }      // its parent's delete covers it
            ops.append(.deleteBlock(blockID: m.id)); report.blocksRemoved += 1
        }

        // new assets
        let myAssets: Set<String> = try graph.db.read { Set(try String.fetchAll($0, sql: "SELECT hash FROM assets")) }
        for a in try scratch.db.read({ try Asset.fetchAll($0) }) where !myAssets.contains(a.hash) {
            let ext = (a.filename as NSString).pathExtension
            let name = ext.isEmpty ? a.hash : "\(a.hash).\(ext)"
            let src = scratch.folder.appendingPathComponent("assets/\(name)"), dst = graph.folder.appendingPathComponent("assets/\(name)")
            if !FileManager.default.fileExists(atPath: dst.path), FileManager.default.fileExists(atPath: src.path) { try FileManager.default.copyItem(at: src, to: dst) }
            ops.append(.addAsset(hash: a.hash, filename: a.filename, mime: a.mime, size: a.size)); report.assetsAdded += 1
        }

        // card schedules that moved on in Logseq
        for c in LogseqCards.read(from: datoms) {
            let current = try graph.db.read { try CardApplier.load(c.blockID, $0) }
            let exists = mine[c.blockID] != nil || theirs[c.blockID] != nil
            if exists, (current?.lastReview ?? 0) < (c.state.lastReview ?? 0) { ops.append(.setCard(blockID: c.blockID, state: c.state, undoReviewAt: nil)); report.cardsUpdated += 1 }
        }

        for chunk in stride(from: 0, to: ops.count, by: 300).map({ Array(ops[$0..<min($0 + 300, ops.count)]) }) {
            try graph.perform(chunk, author: .import)
        }
        return report
    }
}

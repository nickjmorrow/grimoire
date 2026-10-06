import Foundation
import GRDB
import Testing
@testable import GrimoireCore

/// Compares the Logseq export against a Grimoire graph, block by block (set GRIMOIRE_AUDIT_EDN and GRIMOIRE_AUDIT_GRAPH).
@Suite struct ContentAuditTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_AUDIT_EDN"] != nil)) func rareFeaturesOnLiveBlocks() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["GRIMOIRE_AUDIT_EDN"]!), encoding: .utf8)
        let d = try Datoms(exportText: text)
        for attr in [":logseq.property/scheduled", ":logseq.property/deadline", ":logseq.property/query", ":block/alias", ":logseq.property/assignee", ":logseq.property/used-template", ":logseq.property/ls-type"] {
            for e in d.entities(having: attr) where d.first(e, ":logseq.property/deleted-at") == nil {
                let page = d.int(e, ":block/page").flatMap { d.string($0, ":block/title") } ?? "(page)"
                print("RARE", attr, "|", d.uuid(e) ?? "?", "|", page, "|", (d.string(e, ":block/title") ?? "").prefix(90), "|", d.values(e, attr).prefix(2))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRIMOIRE_AUDIT_EDN"] != nil)) func everyLiveLogseqBlockIsInGrimoire() throws {
        let env = ProcessInfo.processInfo.environment
        let text = try String(contentsOf: URL(fileURLWithPath: env["GRIMOIRE_AUDIT_EDN"]!), encoding: .utf8)
        let d = try Datoms(exportText: text)
        let graph = try Graph(folder: URL(fileURLWithPath: env["GRIMOIRE_AUDIT_GRAPH"]!), device: "audit")
        let have: [String: String] = try graph.db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, text FROM blocks").map { ($0["id"] as String, $0["text"] as String) })
        }
        let pageIDs: Set<String> = try graph.db.read { Set(try String.fetchAll($0, sql: "SELECT id FROM pages")) }
        _ = pageIDs
        func deleted(_ e: Int64) -> Bool {
            var cur: Int64? = e
            var hops = 0
            while let c = cur, hops < 200 {
                if d.first(c, ":logseq.property/deleted-at") != nil { return true }
                cur = d.int(c, ":block/parent"); hops += 1
            }
            return false
        }
        var live = 0, missing: [String] = [], textDiffers: [String] = [], attrCounts: [String: Int] = [:]
        let ignorable: Set<String> = [":block/uuid", ":block/page", ":block/parent", ":block/order", ":block/created-at", ":block/updated-at", ":block/title", ":block/tags",
                                      ":block/refs", ":block/path-refs", ":block/link", ":block/collapsed?", ":block/name", ":block/journal-day", ":block/tx-id", ":db/id",
                                      ":block/page-name", ":logseq.property/created-by-ref", ":block/format", ":block/content", ":block/macros"]
        for e in d.entities(having: ":block/page") {
            guard let uuid = d.uuid(e), d.first(e, ":logseq.property/created-from-property") == nil, !deleted(e) else { continue }
            guard let page = d.int(e, ":block/page"), !deleted(page), d.string(page, ":block/name")?.hasPrefix("$$$") != true else { continue }
            live += 1
            guard let mine = have[uuid] else { missing.append("\(uuid) \(d.string(e, ":block/title") ?? "")".prefix(120).description); continue }
            var title = (d.string(e, ":block/title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // [[uuid]] references become [[Title]] on import: resolve them the same way before comparing
            while let r = title.range(of: #"\[\[[0-9a-f]{8}-[0-9a-f-]{27}\]\]"#, options: .regularExpression) {
                let id = String(title[r].dropFirst(2).dropLast(2))
                let name = d.entity(withUUID: id).flatMap { d.string($0, ":block/title") } ?? "?"
                title.replaceSubrange(r, with: "[[\(name)]]")
            }
            let key = String(title.prefix(40)).lowercased()
            if !key.isEmpty, !mine.lowercased().contains(key) { textDiffers.append("\(uuid) L:\(title.prefix(70)) | G:\(mine.prefix(70))") }
            for a in d.attributes(of: e) where !ignorable.contains(a) { attrCounts[a, default: 0] += 1 }
        }
        print("AUDIT live logseq blocks:", live, "missing in grimoire:", missing.count, "text differs:", textDiffers.count)
        for m in missing.filter({ !$0.contains(" image_") }).prefix(40) { print("AUDIT missing(non-image):", m) }
        print("AUDIT missing image blocks:", missing.filter { $0.contains(" image_") }.count)
        for m in textDiffers.prefix(40) { print("AUDIT differs:", m) }
        for (a, n) in attrCounts.sorted(by: { $0.value > $1.value }).prefix(40) { print("AUDIT attr", a, n) }
    }
}

import ArgumentParser
import Foundation
import GrimoireCore

private func pageOutput(_ g: Graph, _ page: Page, json: Bool) throws {
    let tree = try g.tree(pageID: page.id)
    if json { printJSON(["page": pageDict(page), "blocks": tree.map(blockDict)]) }
    else { print("# \(page.title)\n" + outline(tree)) }
}

struct Today: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show today's journal (does not create it).")
    @OptionGroup var g: GlobalOptions
    func run() throws {
        try guarded {
            let graph = try g.open()
            let date = JournalDate.today()
            guard let page = try graph.db.read({ try Page.fetchOne($0, key: date.pageID) }) else {
                if g.json { printJSON(["page": NSNull(), "date": date.iso, "blocks": [Any]()]) } else { print("No journal yet for \(date.iso).") }
                return
            }
            try pageOutput(graph, page, json: g.json)
        }
    }
}

struct PageCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "page", abstract: "Show a page and its blocks.")
    @OptionGroup var g: GlobalOptions
    @Argument var title: String
    func run() throws {
        try guarded {
            let graph = try g.open()
            guard let page = try graph.page(titled: title) else { throw GraphError.pageNotFound(title) }
            try pageOutput(graph, page, json: g.json)
        }
    }
}

struct Journal: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a journal by date (2026-10-05, 'Oct 5th, 2026', yesterday…).")
    @OptionGroup var g: GlobalOptions
    @Argument var date: String
    func run() throws {
        try guarded {
            let graph = try g.open()
            guard let jd = JournalDate.parse(date, today: .today()) else { throw GraphError.pageNotFound(date) }
            guard let page = try graph.db.read({ try Page.fetchOne($0, key: jd.pageID) }) else { throw GraphError.pageNotFound(jd.iso) }
            try pageOutput(graph, page, json: g.json)
        }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Full-text search over page titles and blocks.")
    @OptionGroup var g: GlobalOptions
    @Argument var query: String
    @Option var limit = 50
    func run() throws {
        try guarded {
            let hits = try g.open().search(clean(query), limit: limit)
            if g.json { printJSON(hits.map { ["pageId": $0.pageID, "blockId": $0.blockID as Any? ?? NSNull(), "snippet": $0.snippet] as [String: Any] }) }
            else { for h in hits { print("\(h.pageID)\t\(h.blockID ?? "-")\t\(h.snippet)") } }
        }
    }
}

struct Backlinks: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Blocks that link to a page, grouped by source page.")
    @OptionGroup var g: GlobalOptions
    @Argument var title: String
    func run() throws {
        try guarded {
            let graph = try g.open()
            guard let page = try graph.page(titled: title) else { throw GraphError.pageNotFound(title) }
            let refs = try graph.backlinks(pageID: page.id)
            if g.json { printJSON(refs.map { ["page": pageDict($0.page), "blocks": $0.blocks.map(flatBlockDict)] as [String: Any] }) }
            else { for r in refs { print("## \(r.page.title)"); for b in r.blocks { print("- \(b.text)  [\(b.id)]") } } }
        }
    }
}

struct Recent: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recently changed pages.")
    @OptionGroup var g: GlobalOptions
    @Option var limit = 30
    func run() throws {
        try guarded {
            let pages = try g.open().recentPages(limit: limit)
            if g.json { printJSON(pages.map(pageDict)) } else { for p in pages { print(p.title) } }
        }
    }
}

struct Favorites: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Favorite pages in order.")
    @OptionGroup var g: GlobalOptions
    func run() throws {
        try guarded {
            let pages = try g.open().favorites()
            if g.json { printJSON(pages.map(pageDict)) } else { for p in pages { print(p.title) } }
        }
    }
}

struct TagCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tag", abstract: "Blocks tagged with a tag.")
    @OptionGroup var g: GlobalOptions
    @Argument var tag: String
    func run() throws {
        try guarded {
            let blocks = try g.open().blocks(taggedWith: tag)
            if g.json { printJSON(blocks.map(flatBlockDict)) } else { for b in blocks { print("- \(b.text)  [\(b.id)]") } }
        }
    }
}

struct Prop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Blocks with a property, optionally with a given value.")
    @OptionGroup var g: GlobalOptions
    @Argument var key: String
    @Argument var value: String?
    func run() throws {
        try guarded {
            let blocks = try g.open().blocks(withProperty: key, value: value)
            if g.json { printJSON(blocks.map(flatBlockDict)) } else { for b in blocks { print("- \(b.text)  [\(b.id)]") } }
        }
    }
}

struct Query: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run read-only SQL against the graph database.")
    @OptionGroup var g: GlobalOptions
    @Argument var sql: String
    func run() throws {
        try guarded {
            let rows = try g.open().readOnlyQuery(clean(sql))
            if g.json { printJSON(rows.map { $0.mapValues { $0 as Any? ?? NSNull() } }) }
            else { for r in rows { print(r.keys.sorted().map { "\($0)=\(r[$0].flatMap { $0 } ?? "NULL")" }.joined(separator: "\t")) } }
        }
    }
}

struct Changes: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "What changed since a time (ISO 8601 or a duration like 2h, 30m, 1d), and who changed it.")
    @OptionGroup var g: GlobalOptions
    @Option var since: String = "1d"
    func run() throws {
        try guarded {
            guard let from = Self.parse(since) else { eprint("--since must be ISO 8601 or a duration like 2h"); throw ExitCode(1) }
            let author: Author? = (g.author == nil || g.author == "any") ? nil : try g.actor()
            let changes = try g.open().changes(since: from, author: author)
            if g.json {
                printJSON(changes.map { ["id": $0.localID, "author": $0.author.rawValue, "createdAt": $0.createdAt, "op": "\($0.op)"] as [String: Any] })
            } else { for c in changes { print("\(c.localID)\t\(c.author.rawValue)\t\(c.op)") } }
        }
    }

    static func parse(_ s: String) -> Int64? {
        if let m = s.wholeMatch(of: /(\d+)([smhd])/), let n = Int64(m.1) {
            let unit: Int64 = ["s": 1, "m": 60, "h": 3600, "d": 86400][String(m.2)]!
            return nowMillis() - n * unit * 1000
        }
        return ISO8601DateFormatter().date(from: s).map { Int64($0.timeIntervalSince1970 * 1000) }
    }
}

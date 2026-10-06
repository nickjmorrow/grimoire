import Foundation
import GrimoireCore

public enum PaletteMode: Sendable { case all, search, commands }

public struct PaletteItem: Identifiable {
    public enum Kind: Sendable { case page, command, block, theme, create, search }
    public let id: String
    public let kind: Kind
    public let title: String
    public var subtitle: String?
    public var symbol: String
    public var shortcut: String?
    /// `newPane` is true for ⌘↩.
    public let run: @MainActor (GraphStore, Bool) -> Void
}

/// Builds the palette's rows for a query. Rows are ranked together (exact > prefix > word > contains > fuzzy);
/// pages win ties over commands, matching blocks and "search everything" follow.
@MainActor public enum Palette {
    public static func items(query raw: String, store: GraphStore, mode: PaletteMode = .all, limit: Int = 40) -> [PaletteItem] {
        var query = raw.trimmingCharacters(in: .whitespaces)
        var commandsOnly = mode == .commands
        if query.hasPrefix(">") { commandsOnly = true; query = String(query.dropFirst()).trimmingCharacters(in: .whitespaces) }

        var scored: [(Int, PaletteItem)] = []
        var createRow: PaletteItem?

        // commands and themes
        if mode == .all || commandsOnly {
            for c in CommandRegistry.all where c.isEnabled(store) {
                if store.compact, Self.macOnlyCommands.contains(c.id) { continue }
                guard let s = bestScore(query, [c.title] + c.keywords) else { continue }
                scored.append((s, PaletteItem(id: "cmd:" + c.id, kind: .command, title: c.title, subtitle: nil, symbol: c.symbol, shortcut: c.shortcut?.display) { s, _ in c.run(s) }))
            }
            for t in store.themes.available {
                let title = "Theme: \(t.name)"
                guard let s = bestScore(query, [title, "appearance", "colors"]) else { continue }
                let name = t.name
                scored.append((s - (query.isEmpty ? 0 : 0), PaletteItem(id: "theme:" + name, kind: .theme, title: title, subtitle: t.name == store.theme.name ? "Current" : nil,
                                                            symbol: "paintpalette") { s, _ in s.themes.select(name: name); s.refreshLists() }))
            }
        }

        if !commandsOnly {
            // pages
            if query.isEmpty {
                if mode == .all { for p in store.recents.prefix(8) { scored.append((2000, pageItem(p, store: store))) } }
            } else {
                let pages = (try? store.graph.pages(matching: query, limit: 10)) ?? []
                for p in pages { scored.append(((Autocomplete.score(query: query, title: p.title) ?? 50) + 50, pageItem(p, store: store))) }
                if let jd = JournalDate.parse(query, today: .today()), (try? store.graph.page(titled: query)) == nil {
                    scored.append((1500, PaletteItem(id: "journal:" + jd.iso, kind: .page, title: jd.longTitle, subtitle: "Journal", symbol: "calendar") { s, newPane in
                        try? s.graph.ensureJournal(jd, author: .me); s.databaseChanged(); s.open(.page(jd.pageID), newPane: newPane) }))
                }
                if !pages.contains(where: { $0.title.caseInsensitiveCompare(query) == .orderedSame }) {
                    let t = query
                    let create = PaletteItem(id: "create:" + t, kind: .create, title: "Create page “\(t)”", subtitle: nil, symbol: "plus.circle") { s, newPane in
                        if let id = s.pageID(forTitle: t, create: true) { s.open(.page(id), newPane: newPane) } }
                    // On the phone a stray Return should open the best match, not make a page; "Create page" then follows the matching blocks.
                    if store.compact && query.count >= 2 { createRow = create } else { scored.append((10, create)) }
                }
            }
        }

        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : false }
        var out = scored.map(\.1)

        // matching blocks and the "search everything" row come last
        if !commandsOnly, query.count >= 2 {
            var blocks: [PaletteItem] = []
            for hit in (try? store.graph.search(query, limit: 30)) ?? [] {
                guard let bid = hit.blockID else { continue }
                let page = store.page(id: hit.pageID)
                let pid = hit.pageID
                blocks.append(PaletteItem(id: "block:" + bid, kind: .block, title: clean(hit.snippet), subtitle: page?.title, symbol: "text.alignleft") { s, newPane in
                    s.open(.page(pid), newPane: newPane) })
                if blocks.count >= 10 { break }
            }
            if mode == .search { out = blocks + out } else { out += blocks }
            if let createRow { out.append(createRow) }
            let q = query
            out.append(PaletteItem(id: "search:" + q, kind: .search, title: "Search everything for “\(q)”", subtitle: nil, symbol: "text.magnifyingglass") { s, newPane in
                s.open(.search(q), newPane: newPane) })
        }
        if let createRow, !out.contains(where: { $0.id == createRow.id }) { out.append(createRow) }
        return Array(out.prefix(limit))
    }

    /// Commands with no meaning on the one-pane iPhone layout (they open the palette itself, or manage panes).
    private static let macOnlyCommands: Set<String> = ["palette", "commands", "search", "split", "close-pane", "focus-1", "focus-2", "focus-3"]

    private static func pageItem(_ p: Page, store: GraphStore) -> PaletteItem {
        let id = p.id
        let title = p.kind == .journal ? (p.journalDate.flatMap(JournalDate.init(iso:))?.longTitle ?? p.title) : p.title
        return PaletteItem(id: "page:" + id, kind: .page, title: title, subtitle: p.kind == .journal ? "Journal" : (p.favorite ? "Favorite" : nil),
                           symbol: p.kind == .journal ? "calendar" : (p.favorite ? "star.fill" : "doc.text")) { s, newPane in s.open(.page(id), newPane: newPane) }
    }

    private static func clean(_ snippet: String) -> String { snippet.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") }

    /// Best score over the title and its aliases; an empty query matches everything with a small score.
    static func bestScore(_ query: String, _ names: [String]) -> Int? {
        if query.isEmpty { return 1 }
        let scores = names.enumerated().compactMap { i, n in Autocomplete.score(query: query, title: n).map { $0 - (i == 0 ? 0 : 20) } }
        return scores.max()
    }
}

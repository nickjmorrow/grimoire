import GrimoireCore
import GRDB
import SwiftUI

struct AllPagesView: View {
    let store: GraphStore
    let paneID: UUID
    @State private var pages: [Page] = []
    @State private var filter = ""
    @State private var sortByTitle = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter pages", text: $filter).textFieldStyle(.plain)
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(store.color(\.surface)))
                Picker("", selection: $sortByTitle) { Text("Recent").tag(false); Text("A–Z").tag(true) }
                    .pickerStyle(.segmented).frame(width: 130).labelsHidden()
            }.padding(14)
            List {
                ForEach(shown, id: \.id) { p in
                    Button { store.open(.page(p.id), in: paneID) } label: {
                        HStack {
                            Text(p.title).foregroundStyle(store.color(\.text))
                            Spacer()
                            Text(Date(timeIntervalSince1970: TimeInterval(p.updatedAt) / 1000), style: .date)
                                .font(.system(size: 11)).foregroundStyle(store.color(\.textFaint))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).listRowBackground(Color.clear)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).calmScroll()
        }
        .task(id: store.revision) {
            pages = (try? store.graph.db.read { try Page.fetchAll($0, sql: "SELECT * FROM pages WHERE kind = 'page' AND EXISTS (SELECT 1 FROM blocks WHERE page_id = pages.id) ORDER BY updated_at DESC") }) ?? []
        }
    }

    private var shown: [Page] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var out = f.isEmpty ? pages : pages.filter { $0.titleLower.contains(f) }
        if sortByTitle { out.sort { $0.titleLower < $1.titleLower } }
        return Array(out.prefix(400))
    }
}

struct TagsView: View {
    let store: GraphStore
    let paneID: UUID
    @State private var tags: [(name: String, pageID: String, count: Int)] = []

    var body: some View {
        List {
            ForEach(tags, id: \.pageID) { t in
                Button { store.open(.page(t.pageID), in: paneID) } label: {
                    HStack {
                        Text("#" + t.name).foregroundStyle(store.color(\.tag))
                        Spacer()
                        Text("\(t.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(store.color(\.textFaint))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).calmScroll()
        .task(id: store.revision) {
            tags = (try? store.graph.db.read { db in
                try Row.fetchAll(db, sql: "SELECT t.name AS name, t.page_id AS page_id, COUNT(bt.block_id) AS n FROM tags t LEFT JOIN block_tags bt ON bt.tag_id = t.id GROUP BY t.id ORDER BY n DESC, t.name_lower")
                    .map { (name: $0["name"] as String, pageID: $0["page_id"] as String, count: $0["n"] as Int) }
            }) ?? []
        }
    }
}

struct SearchResultsView: View {
    let store: GraphStore
    let query: String
    let paneID: UUID
    @State private var hits: [SearchHit] = []

    var body: some View {
        List {
            if hits.isEmpty {
                Text(query.isEmpty ? "Type in the command palette (⌘K) to search." : "No results.").foregroundStyle(store.color(\.textDim))
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                Button { store.open(.page(h.pageID), in: paneID) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.page(id: h.pageID)?.title ?? "").font(.system(size: 12, weight: .semibold)).foregroundStyle(store.color(\.link))
                        Text(h.snippet.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""))
                            .font(.system(size: 13)).foregroundStyle(store.color(\.text)).lineLimit(3)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).calmScroll()
        .task(id: query) { hits = (try? store.graph.search(query, limit: 100)) ?? [] }
    }
}

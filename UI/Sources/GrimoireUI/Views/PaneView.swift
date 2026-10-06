import GrimoireCore
import SwiftUI

struct PaneView: View {
    let store: GraphStore
    let pane: Pane

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(store.color(\.border))
            content
        }
        .background(store.color(\.background))
        .overlay(alignment: .top) {
            if store.panes.count > 1 && store.focusedPaneID == pane.id {
                Rectangle().fill(store.color(\.accent)).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { store.focusedPaneID = pane.id })
    }

    private var title: String {
        switch pane.location {
        case .journals: return "Journals"
        case .allPages: return "All pages"
        case .tags: return "Tags"
        case .review: return "Review"
        case .search(let q): return q.isEmpty ? "Search" : "Search: \(q)"
        case .page(let id):
            guard let p = store.page(id: id) else { return "Missing page" }
            return p.kind == .journal ? (p.journalDate.flatMap(JournalDate.init(iso:))?.longTitle ?? p.title) : p.title
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "sidebar.left", store: store) { store.sidebarVisible.toggle() }
            IconButton(symbol: "chevron.left", store: store, enabled: pane.canGoBack) { store.back(in: pane.id) }
            IconButton(symbol: "chevron.right", store: store, enabled: pane.canGoForward) { store.forward(in: pane.id) }
            Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                .foregroundStyle(store.color(\.textDim)).padding(.leading, 6)
            Spacer()
            if case .page(let id) = pane.location, let p = store.page(id: id) {
                IconButton(symbol: p.favorite ? "star.fill" : "star", store: store) { store.toggleFavorite(pageID: id) }
            }
            SyncBadge(store: store)
            IconButton(symbol: "magnifyingglass", store: store) { store.showPalette(.all) }
            if !store.compact {
                IconButton(symbol: "rectangle.split.2x1", store: store, enabled: store.panes.count < GraphStore.maxPanes) {
                    store.open(pane.location, newPane: true)
                }
            }
            if store.panes.count > 1, !store.compact { IconButton(symbol: "xmark", store: store) { store.closePane(pane.id) } }
        }
        .padding(.horizontal, 8).frame(height: 38)
        .background(store.color(\.surface).opacity(0.55))
    }

    @ViewBuilder private var content: some View {
        switch pane.location {
        case .journals: JournalsView(store: store)
        case .page(let id): PageView(store: store, pageID: id).id(id)
        case .allPages: AllPagesView(store: store, paneID: pane.id)
        case .tags: TagsView(store: store, paneID: pane.id)
        case .review(let page, let block): ReviewView(store: store, page: page, block: block).id("\(page ?? "")|\(block ?? "")")
        case .search(let q): SearchResultsView(store: store, query: q, paneID: pane.id)
        }
    }
}

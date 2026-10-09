import GrimoireCore
import SwiftUI

/// Today first, then earlier days that have something in them, newest first.
struct JournalsView: View {
    let store: GraphStore
    @State private var earlier: [Page] = []
    /// Days loaded at first; `defaults write <bundle-id> perf.journalDays <n>` changes it (a diagnostic knob).
    @State private var limit = max(1, UserDefaults.standard.integer(forKey: "perf.journalDays") == 0 ? 14 : UserDefaults.standard.integer(forKey: "perf.journalDays"))
    @State private var canLoadMore = true
    /// Earlier days are drawn as plain text; only today and the day being edited get a real text view (a stack of them made the window heavy).
    @State private var editing: Set<String> = []
    /// Days currently on screen, and the height each one had when last drawn. A day that scrolls out of view is replaced by an empty
    /// box of that height, so the window only ever holds the few days you can see.
    @State private var onScreen: Set<String> = []
    @State private var heights: [String: CGFloat] = [:]

    var body: some View {
        let today = store.today
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                day(today, pageID: today.pageID, focus: true)
                ForEach(earlier.filter { $0.id != today.pageID }, id: \.id) { page in
                    if let d = page.journalDate.flatMap(JournalDate.init(iso:)) { day(d, pageID: page.id, focus: false) }
                }
                if canLoadMore {
                    Color.clear.frame(height: 40).onAppear { limit += 14 }
                }
            }
            .padding(.bottom, 80)
        }
        .calmScroll()
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .task(id: "\(store.revision)-\(limit)") { load() }
    }

    private func day(_ date: JournalDate, pageID: String, focus: Bool) -> some View {
        let live = focus || onScreen.contains(pageID) || editing.contains(pageID)
        return ZStack(alignment: .topLeading) {
            if live {
                dayContent(date, pageID: pageID, focus: focus)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[pageID] = $0 }
            } else {
                Color.clear.frame(height: heights[pageID] ?? 140)
            }
        }
        .onScrollVisibilityChange(threshold: 0.001) { visible in
            if visible { onScreen.insert(pageID) } else { onScreen.remove(pageID) }
        }
    }

    private func dayContent(_ date: JournalDate, pageID: String, focus: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { try? store.graph.ensureJournal(date, author: .me); store.databaseChanged(); store.open(.page(pageID)) } label: {
                Text(date.longTitle).font(Font(store.theme.titleFont())).foregroundStyle(focus ? store.color(\.text) : store.color(\.textDim))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, CGFloat(store.theme.spacing.pagePadding) + 4).padding(.top, 26).padding(.bottom, 6)
            if focus || editing.contains(pageID) {
                PageEditor(store: store, pageID: pageID, journal: date, autofocus: (focus && !UserDefaults.standard.bool(forKey: "perf.noAutofocus")) || editing.contains(pageID)).id(pageID)
            } else {
                JournalDayText(store: store, pageID: pageID) { editing.insert(pageID) }
            }
        }
    }

    private func load() {
        let pages = (try? store.graph.journals(before: nil, limit: limit)) ?? []
        earlier = pages
        canLoadMore = pages.count >= limit
    }
}


/// A day's blocks as read-only text with bullets and indentation. Tapping it turns the day into an editor.
struct JournalDayText: View {
    let store: GraphStore
    let pageID: String
    let edit: () -> Void
    @State private var rows: [(row: OutlineRow, hidden: Bool)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                if !item.hidden {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(store.color(\.bullet)).frame(width: 5, height: 5).offset(y: -2)
                        RenderedBlockText(text: item.row.text, store: store, selectable: false)
                    }
                    .padding(.leading, CGFloat(item.row.depth) * CGFloat(store.theme.spacing.indent))
                }
            }
        }
        .padding(.horizontal, CGFloat(store.theme.spacing.pagePadding) + 4).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .task(id: store.revision) {
            let doc = OutlineDoc(tree: (try? store.graph.tree(pageID: pageID)) ?? [])
            let hidden = doc.hiddenFlags()
            rows = doc.rows.enumerated().map { ($0.element, hidden.indices.contains($0.offset) ? hidden[$0.offset] : false) }
        }
    }
}

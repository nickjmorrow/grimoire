import GrimoireCore
import SwiftUI

struct PageView: View {
    let store: GraphStore
    let pageID: String
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        let page = store.page(id: pageID)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let page {
                    if page.kind == .journal {
                        Text(page.journalDate.flatMap(JournalDate.init(iso:))?.longTitle ?? page.title)
                            .font(Font(store.theme.titleFont())).foregroundStyle(store.color(\.text))
                            .padding(.horizontal, CGFloat(store.theme.spacing.pagePadding) + 4).padding(.top, 26).padding(.bottom, 6)
                    } else {
                        TextField("Untitled", text: $draftTitle, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.plain).focused($titleFocused)
                            .onChange(of: draftTitle) { _, v in
                                // A vertical-axis field takes Return as a newline; titles are one line, so Return commits instead.
                                guard v.contains("\n") else { return }
                                draftTitle = v.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                                commitTitle(page); titleFocused = false
                            }
                            .font(Font(store.theme.titleFont())).foregroundStyle(store.color(\.text))
                            .padding(.horizontal, CGFloat(store.theme.spacing.pagePadding) + 4).padding(.top, 26).padding(.bottom, 6)
                            .onSubmit { commitTitle(page) }
                            .onChange(of: titleFocused) { _, focused in if !focused { commitTitle(page) } }
                            .onAppear { draftTitle = page.title }
                    }
                    CardsBar(store: store, pageID: pageID)
                    PageEditor(store: store, pageID: pageID, journal: page.journalDate.flatMap(JournalDate.init(iso:)))
                    ReferencesView(store: store, pageID: pageID)
                } else {
                    Text("This page no longer exists.").foregroundStyle(store.color(\.textDim)).padding(40)
                }
            }
            .padding(.bottom, 80)
        }
        .calmScroll()
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private func commitTitle(_ page: Page) {
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != page.title else { draftTitle = page.title; return }
        if !store.rename(pageID: pageID, to: t) { draftTitle = page.title }
    }
}

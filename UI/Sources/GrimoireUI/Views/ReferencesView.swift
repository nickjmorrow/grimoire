import GrimoireCore
import SwiftUI

/// Linked and unlinked references under a page.
struct ReferencesView: View {
    let store: GraphStore
    let pageID: String
    @State private var linked: [Reference] = []
    @State private var unlinked: [Reference] = []
    @State private var showUnlinked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !linked.isEmpty {
                section("Linked references", count: linked.reduce(0) { $0 + $1.blocks.count }, groups: linked)
            }
            if !unlinked.isEmpty {
                Button { showUnlinked.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showUnlinked ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text("Unlinked references").font(.system(size: 11, weight: .semibold)).tracking(0.6)
                        Text("\(unlinked.reduce(0) { $0 + $1.blocks.count })").font(.system(size: 11)).foregroundStyle(store.color(\.textFaint))
                    }.foregroundStyle(store.color(\.textDim))
                }.buttonStyle(.plain)
                if showUnlinked { groupsView(unlinked) }
            }
        }
        .padding(.horizontal, CGFloat(store.theme.spacing.pagePadding) + 4).padding(.top, 36)
        .task(id: "\(pageID)-\(store.revision)") { load() }
    }

    private func section(_ title: String, count: Int, groups: [Reference]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.9)
                Text("\(count)").font(.system(size: 11)).foregroundStyle(store.color(\.textFaint))
            }.foregroundStyle(store.color(\.textDim))
            groupsView(groups)
        }
    }

    private func groupsView(_ groups: [Reference]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.page.id) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Button { store.open(.page(g.page.id)) } label: {
                        Text(title(of: g.page)).font(.system(size: 13, weight: .semibold)).foregroundStyle(store.color(\.link))
                    }.buttonStyle(.plain)
                    ForEach(g.blocks, id: \.id) { b in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(store.color(\.bullet)).frame(width: 5, height: 5).padding(.top, 8)
                            RenderedBlockText(text: b.text, store: store)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { store.open(.page(g.page.id), newPane: NSEventModifier.shiftHeld) }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: CGFloat(store.theme.radius)).fill(store.color(\.surface)))
            }
        }
    }

    private func title(of p: Page) -> String {
        p.kind == .journal ? (p.journalDate.flatMap(JournalDate.init(iso:))?.longTitle ?? p.title) : p.title
    }

    private func load() {
        linked = (try? store.graph.backlinks(pageID: pageID)) ?? []
        unlinked = (try? store.graph.unlinkedReferences(pageID: pageID)) ?? []
    }
}

enum NSEventModifier {
    static var shiftHeld: Bool {
        #if canImport(AppKit)
        return NSEvent.modifierFlags.contains(.shift)
        #else
        return false
        #endif
    }
}

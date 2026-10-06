import GrimoireCore
import SwiftUI

struct Sidebar: View {
    let store: GraphStore

    var body: some View {
        // A plain stack, not safeAreaInset: on macOS 26+ an inset over a scroll view adds a live-blur "scroll pocket" behind it.
        VStack(spacing: 0) {
            list
            footer
        }
        .background(store.color(\.surface))
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Grimoire")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(store.color(\.accent))
                    .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)
                row("Journals", "calendar", .journals)
                row("All pages", "doc.text", .allPages)
                row("Tags", "tag", .tags)
                row(store.dueCards > 0 ? "Review (\(store.dueCards))" : "Review", "rectangle.stack", .review(page: nil, block: nil))
                if !store.favorites.isEmpty {
                    header("Favorites")
                    ForEach(store.favorites, id: \.id) { pageRow($0, icon: "star.fill") }
                }
                header("Recent")
                ForEach(store.recents, id: \.id) { pageRow($0, icon: nil) }
            }
            .padding(.horizontal, 8).padding(.bottom, 16)
        }
        .calmScroll()
    }

    @ViewBuilder private var footer: some View {
        if store.syncStatus != .off {
            HStack(spacing: 6) {
                Circle().frame(width: 6, height: 6).foregroundStyle(syncColor)
                Text(store.syncStatus.label).font(.system(size: 11)).foregroundStyle(store.color(\.textFaint))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle()).onTapGesture { tapSync() }
        }
    }

    private func tapSync() {
        if case .failed = store.syncStatus, !store.syncIssues.isEmpty { store.showSyncIssues(); return }
        if let e = store.lastSyncError { store.show("Sync: \(e)") }
        store.syncNow()
    }

    private var syncColor: Color {
        switch store.syncStatus {
        case .synced: return store.color(\.success)
        case .syncing: return store.color(\.accent)
        case .offline: return store.color(\.warning)
        case .failed: return store.color(\.danger)
        case .off: return .clear
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold)).tracking(0.9)
            .foregroundStyle(store.color(\.textFaint))
            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
    }

    private func row(_ title: String, _ symbol: String, _ location: Location) -> some View {
        SidebarRow(store: store, title: title, symbol: symbol, active: store.focusedPane.location == location) { store.open(location) }
    }

    private func pageRow(_ page: Page, icon: String?) -> some View {
        SidebarRow(store: store, title: page.kind == .journal ? (page.journalDate.flatMap(JournalDate.init(iso:))?.longTitle ?? page.title) : page.title,
                   symbol: icon, active: store.focusedPane.location == .page(page.id)) { store.open(.page(page.id)) }
            .contextMenu { Button("Open in New Pane") { store.open(.page(page.id), newPane: true) } }
    }
}

struct SidebarRow: View {
    let store: GraphStore
    let title: String
    var symbol: String?
    var active: Bool
    let action: () -> Void
    @State private var hover = false
    /// On iPhone the sidebar is a touch list: bigger type and ~44 pt rows. The Mac keeps its compact rows.
    private static var touchScale: CGFloat {
        #if os(iOS)
        1.2
        #else
        1
        #endif
    }
    private static var verticalPadding: CGFloat {
        #if os(iOS)
        11
        #else
        5
        #endif
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: Self.touchScale * 11.5)).frame(width: Self.touchScale * 16)
                        .foregroundStyle(active ? store.color(\.accent) : store.color(\.textFaint))
                }
                Text(title).font(.system(size: Self.touchScale * 13)).lineLimit(1)
                    .foregroundStyle(active ? store.color(\.text) : store.color(\.textDim))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, Self.verticalPadding)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? store.color(\.surfaceRaised) : (hover ? store.color(\.surfaceRaised).opacity(0.5) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

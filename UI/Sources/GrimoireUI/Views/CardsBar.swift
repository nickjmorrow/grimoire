import GrimoireCore
import SwiftUI

/// Under a page's title: how many flashcards the page holds and a way to review them, all at once or one chapter (bullet) at a time.
struct CardsBar: View {
    let store: GraphStore
    let pageID: String
    @State private var showGroups = false
    @State private var groups: [CardGroup] = []

    var body: some View {
        let _ = store.revision
        let counts = (try? store.graph.cardCounts(scope: .page(pageID))) ?? CardCounts(due: 0, new: 0, total: 0)
        if counts.total > 0 {
            HStack(spacing: 10) {
                Button {
                    groups = (try? store.graph.cardGroups(pageID: pageID)) ?? []
                    if groups.isEmpty { review(nil) } else { showGroups.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack").font(.system(size: 11))
                        Text(Self.summary(counts)).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(store.color(\.surfaceRaised)))
                    .foregroundStyle(store.color(counts.due + counts.new > 0 ? \.link : \.textDim))
                }
                .buttonStyle(.plain)
                .help("Review this page's flashcards")
                .popover(isPresented: $showGroups, arrowEdge: .bottom) { picker(counts) }
                Spacer()
            }
            .padding(.horizontal, CGFloat(store.theme.spacing.pagePadding) + 4).padding(.bottom, 8)
        }
    }

    static func summary(_ c: CardCounts) -> String {
        let cards = "\(c.total) card\(c.total == 1 ? "" : "s")"
        if c.due + c.new == 0 { return cards + " · all caught up" }
        return cards + " · " + [c.due > 0 ? "\(c.due) due" : nil, c.new > 0 ? "\(c.new) new" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    private func picker(_ all: CardCounts) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                row("Whole page", all, depth: 0, bold: true) { review(nil) }
                Divider().padding(.vertical, 4)
                ForEach(groups) { g in row(Self.cleaned(g.title), g.counts, depth: g.depth, bold: false) { review(g.blockID) } }
            }
            .padding(8)
        }
        .frame(width: 360).frame(maxHeight: 420)
    }

    private func row(_ title: String, _ c: CardCounts, depth: Int, bold: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: bold ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(c.due + c.new > 0 ? "\(c.due + c.new) to do" : "\(c.total)").font(.system(size: 11))
                    .foregroundStyle(store.color(c.due + c.new > 0 ? \.link : \.textFaint))
            }
            .padding(.leading, CGFloat(depth) * 14 + 6).padding(.trailing, 6).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func review(_ block: String?) {
        showGroups = false
        store.open(.review(page: pageID, block: block))
    }

    /// A bullet's first line without link brackets, for a one-line label.
    static func cleaned(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return line.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "").trimmingCharacters(in: .whitespaces)
    }
}

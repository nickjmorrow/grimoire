import GrimoireCore
import SwiftUI

/// Flashcard review: the question, then the answer on reveal; space/return reveals, 1–4 rate, u undoes.
struct ReviewView: View {
    let store: GraphStore
    let page: String?
    let block: String?
    @State private var model: ReviewModel?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let model { content(model) } else { Color.clear }
        }
        .onAppear {
            let scope: CardScope = block.map(CardScope.block) ?? page.map(CardScope.page) ?? .all
            model = ReviewModel(graph: store.graph, scope: scope)
            focused = true
        }
    }

    /// What this review is limited to: a bullet's text, a page's title, or nothing for the whole graph.
    private var scopeTitle: String? {
        if let block, let b = store.block(id: block) { return CardsBar.cleaned(b.text) }
        if let page { return store.page(id: page)?.title }
        return nil
    }

    private func content(_ m: ReviewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(m.counts.due) due · \(m.counts.new) new").font(.system(size: 12)).foregroundStyle(store.color(\.textDim))
                if let scopeTitle { Text("· \(scopeTitle)").font(.system(size: 12)).foregroundStyle(store.color(\.textFaint)).lineLimit(1) }
                Spacer()
                Text("\(m.answered) done").font(.system(size: 12)).foregroundStyle(store.color(\.textFaint))
                if m.canUndo { Button("Undo") { m.undo() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(store.color(\.link)) }
            }
            .padding(.horizontal, 24).padding(.top, 14)
            if let card = m.current {
                // Top-anchored and scrollable: the question stays put when the answer appears, and a long answer can be read on a phone.
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(card.pageTitle).font(.system(size: 11, weight: .semibold)).tracking(0.8).textCase(.uppercase).foregroundStyle(store.color(\.textFaint))
                    RenderedBlockText(text: card.front, store: store).font(.system(size: 22, weight: .semibold))
                    if m.revealed {
                        Divider().overlay(store.color(\.border))
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(card.back.enumerated()), id: \.offset) { _, line in
                                let depth = line.prefix(while: { $0 == " " }).count / 2
                                RenderedBlockText(text: String(line.drop(while: { $0 == " " })), store: store).padding(.leading, CGFloat(depth) * 18)
                            }
                            if card.back.isEmpty { Text("(no answer written)").foregroundStyle(store.color(\.textFaint)) }
                        }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading).padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
                }
                .calmScroll()
            } else {
                Spacer(minLength: 12)
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(store.color(\.success))
                    Text(m.answered > 0 ? "Done for now — \(m.answered) reviewed" : "Nothing due").font(.system(size: 16, weight: .medium)).foregroundStyle(store.color(\.text))
                }
                Spacer(minLength: 12)
            }
            if m.current != nil {
                controls(m)
                #if os(macOS)
                Text("space show answer, then Good  ·  1 Again  2 Hard  3 Good  4 Easy  ·  u undo  ·  esc leave")
                    .font(.system(size: 11)).foregroundStyle(store.color(\.textFaint)).padding(.top, 10).padding(.bottom, 20)
                #else
                Color.clear.frame(height: 20)
                #endif
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: m.revealed)
        .sensoryFeedback(.selection, trigger: m.answered)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.space) { advance(m); return .handled }
        .onKeyPress(.return) { advance(m); return .handled }
        .onKeyPress(.escape) { leave(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in
            if let n = Int(press.characters), let r = Rating(rawValue: n) { m.rate(r); return .handled }
            return .ignored
        }
        .onKeyPress("u") { m.undo(); return .handled }
        .background(store.color(\.background))
    }

    /// Space or return: show the answer, then (once it's showing) rate the card Good.
    private func advance(_ m: ReviewModel) { if m.revealed { m.rate(.good) } else { m.reveal() } }

    /// Esc: back to where the review was started from.
    private func leave() { if store.focusedPane.canGoBack { store.back() } else { store.open(.journals) } }

    @ViewBuilder private func controls(_ m: ReviewModel) -> some View {
        if m.revealed {
            HStack(spacing: 10) {
                ForEach(Rating.allCases, id: \.self) { r in
                    Button { m.rate(r) } label: {
                        VStack(spacing: 2) {
                            Text(name(r)).font(.system(size: 13, weight: .semibold))
                            Text(m.intervalLabels[r] ?? "").font(.system(size: 11)).foregroundStyle(store.color(\.textFaint))
                        }.frame(maxWidth: 96, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 8).fill(store.color(\.surfaceRaised)))
                    .foregroundStyle(store.color(r == .again ? \.danger : r == .easy ? \.success : \.text))
                }
            }
            .padding(.horizontal, 16)
        } else {
            Button("Show answer") { m.reveal() }.buttonStyle(.plain)
                .padding(.horizontal, 22).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(store.color(\.accent)))
                .foregroundStyle(store.color(\.background))
        }
    }

    private func name(_ r: Rating) -> String { ["Again", "Hard", "Good", "Easy"][r.rawValue - 1] + " \(r.rawValue)" }
}

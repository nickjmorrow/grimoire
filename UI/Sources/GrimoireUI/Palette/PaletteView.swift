import GrimoireCore
import SwiftUI

/// The ⌘K overlay: one text field, one ranked list. ↑/↓ move, ↩ runs, ⌘↩ runs in a new pane, esc closes, `>` limits to commands.
struct PaletteView: View {
    let store: GraphStore
    @State private var query = ""
    @State private var selection = 0
    @State private var items: [PaletteItem] = []
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28).ignoresSafeArea()
                .onTapGesture { store.paletteVisible = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: store.paletteMode == .search ? "text.magnifyingglass" : store.paletteMode == .commands ? "command" : "magnifyingglass").foregroundStyle(store.color(\.textFaint))
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain).font(.system(size: 16)).foregroundStyle(store.color(\.text))
                        .focused($focused)
                        .onSubmit { run(newPane: false) }
                        .accessibilityIdentifier("palette-field")
                }
                .padding(.horizontal, 16).frame(height: 50)
                Divider().overlay(store.color(\.border))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == selection)
                                    .id(item.id)
                                    .onTapGesture { selection = i; run(newPane: NSEventModifierCheck.commandHeld) }
                            }
                            if items.isEmpty { Text("No matches").foregroundStyle(store.color(\.textDim)).padding(20) }
                        }.padding(6)
                    }
                    .frame(height: min(380, CGFloat(max(items.count, 1)) * 34 + 12))
                    .onChange(of: selection) { _, new in if items.indices.contains(new) { proxy.scrollTo(items[new].id) } }
                }
            }
            .frame(maxWidth: 580)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(store.color(\.surfaceRaised)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.color(\.border), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
            .padding(.top, 90)
        }
        .onAppear { query = ""; refresh(); focused = true }
        .onChange(of: query) { _, _ in selection = 0; refresh() }
        .onChange(of: store.paletteMode) { _, _ in refresh() }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { store.paletteVisible = false; return .handled }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) { run(newPane: true); return .handled }
            return .ignored
        }
    }

    private var placeholder: String {
        switch store.paletteMode {
        case .search: return "Search everything…"
        case .commands: return "Run a command…"
        case .all: return "Go to a page, search, or run a command…  (> for commands)"
        }
    }

    private func refresh() { items = Palette.items(query: query, store: store, mode: store.paletteMode) }
    private func move(_ d: Int) { guard !items.isEmpty else { return }; selection = (selection + d + items.count) % items.count }

    private func run(newPane: Bool) {
        guard items.indices.contains(selection) else { return }
        let item = items[selection]
        store.paletteVisible = false
        item.run(store, newPane)
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).frame(width: 18).foregroundStyle(selected ? store.color(\.accent) : store.color(\.textFaint))
            Text(item.title).lineLimit(1).font(.system(size: 14)).foregroundStyle(store.color(\.text))
            if let s = item.subtitle { Text(s).font(.system(size: 12)).foregroundStyle(store.color(\.textFaint)).lineLimit(1) }
            Spacer(minLength: 8)
            if let k = item.shortcut { Text(k).font(.system(size: 12, design: .rounded)).foregroundStyle(store.color(\.textDim)) }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? store.color(\.selection) : .clear))
        .contentShape(Rectangle())
    }
}

#if canImport(AppKit)
import AppKit
enum NSEventModifierCheck { static var commandHeld: Bool { NSEvent.modifierFlags.contains(.command) } }
#else
enum NSEventModifierCheck { static var commandHeld: Bool { false } }
#endif

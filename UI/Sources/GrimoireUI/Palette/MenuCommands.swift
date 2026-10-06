import SwiftUI

public struct GraphStoreKey: FocusedValueKey { public typealias Value = GraphStore }
extension FocusedValues {
    public var graphStore: GraphStore? {
        get { self[GraphStoreKey.self] }
        set { self[GraphStoreKey.self] = newValue }
    }
}

extension Shortcut {
    var keyboardShortcut: KeyboardShortcut {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(key.first!), modifiers: m)
    }
}

/// The menu bar, generated from `CommandRegistry`: every registry command with a `menu` appears there with its shortcut.
public struct GrimoireMenuCommands: Commands {
    @FocusedValue(\.graphStore) private var store

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) { items(in: "File") }
        CommandGroup(replacing: .printItem) { }          // ⌘P is the page switcher here
        CommandMenu("Go") { items(in: "Go") }
        CommandGroup(after: .sidebar) { items(in: "View") }
    }

    @ViewBuilder private func items(in menu: String) -> some View {
        ForEach(CommandRegistry.all.filter { $0.menu == menu }) { c in
            Button(c.title) { if let store { c.run(store) } }
                .keyboardShortcut(c.shortcut?.keyboardShortcut)
                .disabled(store == nil || !(store.map(c.isEnabled) ?? false))
        }
    }
}

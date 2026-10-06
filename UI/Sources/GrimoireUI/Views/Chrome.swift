import GrimoireCore
import SwiftUI

extension GraphStore {
    func color(_ keyPath: KeyPath<Theme.Colors, String>) -> Color { theme.colors.swiftUI(keyPath) }
    var uiFont: Font { Font(theme.bodyFont()) }
}

extension View {
    /// macOS 26+ draws a soft blurred "scroll edge effect" (live backdrop filters) at the edges of every scroll view. It costs the window server
    /// more the bigger the window gets, and the app's flat panes don't need it.
    @ViewBuilder func calmScroll() -> some View {
        if #available(macOS 26, iOS 26, *) { self.scrollEdgeEffectHidden(true, for: .all) } else { self }
    }
}

/// A small circular toolbar button.
struct IconButton: View {
    let symbol: String
    let store: GraphStore
    var enabled = true
    let action: () -> Void
    @State private var hover = false
    /// The tappable square: a fingertip needs more than the 24 pt glyph circle.
    private static var touch: CGFloat {
        #if os(iOS)
        40
        #else
        24
        #endif
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(enabled ? store.color(\.textDim) : store.color(\.textFaint).opacity(0.5))
                .background(Circle().fill(hover && enabled ? store.color(\.surfaceRaised) : .clear))
                .frame(width: Self.touch, height: Self.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

/// Block text rendered read-only with the same styling as the editor (used in reference lists and search results).
struct RenderedBlockText: View {
    let text: String
    let store: GraphStore
    /// Selectable text is a heavier view on macOS; screens that show many blocks turn it off.
    var selectable = true
    var body: some View {
        if selectable {
            Text(attributed).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        } else {
            Text(attributed).lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var attributed: AttributedString {
        let theme = store.theme
        let storage = NSMutableAttributedString(string: OutlineStorage.storageText(store.expandBlockRefs(text)) + "\n", attributes: ParagraphStyler.baseAttributes(theme: theme))
        ParagraphStyler.apply(to: storage, range: NSRange(location: 0, length: storage.length), theme: theme)
        storage.deleteCharacters(in: NSRange(location: storage.length - 1, length: 1))
        storage.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: storage.length))
        #if canImport(AppKit)
        return (try? AttributedString(storage, including: \.appKit)) ?? AttributedString(text)
        #else
        return (try? AttributedString(storage, including: \.uiKit)) ?? AttributedString(text)
        #endif
    }
}

extension JournalDate {
    /// "Monday, October 5, 2026"
    var longTitle: String { title(format: "EEEE, MMMM d, yyyy") }
}

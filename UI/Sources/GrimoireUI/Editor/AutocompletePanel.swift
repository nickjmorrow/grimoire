#if os(macOS)
import AppKit

/// The popup list under the caret. A plain subview of the text view (no extra window), so it moves and tests with the editor.
final class AutocompletePanel: NSView {
    private(set) var items: [AutocompleteItem] = []
    private(set) var selected = 0
    var theme: Theme
    var onPick: ((AutocompleteItem) -> Void)?
    static let rowHeight: CGFloat = 26
    static let width: CGFloat = 360

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.35; layer?.shadowRadius = 10; layer?.shadowOffset = CGSize(width: 0, height: -3)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func show(_ items: [AutocompleteItem], theme: Theme) {
        self.theme = theme
        let keep = self.items.isEmpty ? 0 : min(selected, items.count - 1)
        self.items = items
        selected = max(0, keep)
        layer?.backgroundColor = theme.colors.platformColor(\.surfaceRaised).cgColor
        layer?.borderColor = theme.colors.platformColor(\.border).cgColor
        setFrameSize(NSSize(width: Self.width, height: CGFloat(min(items.count, 9)) * Self.rowHeight + 8))
        needsDisplay = true
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
        needsDisplay = true
    }

    var current: AutocompleteItem? { items.indices.contains(selected) ? items[selected] : nil }

    private var visibleRange: Range<Int> {
        let n = min(items.count, 9)
        let start = min(max(0, selected - n + 1), max(0, items.count - n))
        return start..<(start + n)
    }

    override func draw(_ dirtyRect: NSRect) {
        let ui = NSFont.systemFont(ofSize: 13)
        let small = NSFont.systemFont(ofSize: 11)
        for (slot, i) in visibleRange.enumerated() {
            let item = items[i]
            let y = 4 + CGFloat(slot) * Self.rowHeight
            let row = NSRect(x: 4, y: y, width: bounds.width - 8, height: Self.rowHeight)
            if i == selected {
                theme.colors.platformColor(\.selection).setFill()
                NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
            }
            let title = NSAttributedString(string: item.title.replacingOccurrences(of: "\u{2028}", with: " "), attributes: [
                .font: ui, .foregroundColor: theme.colors.platformColor(item.isCreate ? \.accent : \.text)])
            let maxW = bounds.width - 24 - (item.detail == nil ? 0 : 96)
            title.draw(with: NSRect(x: 12, y: y + 5, width: maxW, height: 18), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            if let d = item.detail {
                NSAttributedString(string: d, attributes: [.font: small, .foregroundColor: theme.colors.platformColor(\.textFaint)])
                    .draw(with: NSRect(x: bounds.width - 104, y: y + 7, width: 92, height: 16), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let slot = Int((p.y - 4) / Self.rowHeight)
        let i = visibleRange.lowerBound + slot
        if items.indices.contains(i) { selected = i; onPick?(items[i]) }
    }
}
#endif

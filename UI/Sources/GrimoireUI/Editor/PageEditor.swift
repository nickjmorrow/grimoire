#if os(macOS)
import AppKit
import GrimoireCore
import SwiftUI

/// SwiftUI host for one page's text view. Pages stack inside an outer scroll view, so the view reports its full height.
public struct PageEditor: NSViewRepresentable {
    let store: GraphStore
    let pageID: String
    var journal: JournalDate? = nil
    var autofocus = false

    public init(store: GraphStore, pageID: String, journal: JournalDate? = nil, autofocus: Bool = false) {
        self.store = store; self.pageID = pageID; self.journal = journal; self.autofocus = autofocus
    }

    public func makeNSView(context: Context) -> OutlineTextView {
        let view = OutlineTextView(theme: store.theme)
        let model = PageEditorModel(graph: store.graph, pageID: pageID)
        if let journal { let graph = store.graph; model.prepare = { try graph.ensureJournal(journal, author: .me) } }
        view.model = model
        let failureStore = store
        model.onSaveFailed = { [weak failureStore] error in failureStore?.show("Couldn't save: \(error)") }
        var doc = (try? model.load()) ?? OutlineDoc(rows: [])
        if doc.rows.isEmpty { doc = OutlineDoc(rows: [OutlineRow(blockID: nil, depth: 0, text: "")]) }
        view.load(doc)
        view.autofocus = autofocus
        store.register(model)
        model.onSaved = { [weak store] in store?.refreshPending(); store?.kickSync() }
        let store = self.store
        view.autocompleteSource = store.autocompleteSource
        let pageID = self.pageID
        view.onCaretBlockChange = { [weak store] id in store?.caretBlock = id.map { GraphStore.CaretBlock(pageID: pageID, blockID: $0) } }
        view.onOpenLink = { target, newPane in store.openLink(target, newPane: newPane) }
        view.onContentSizeChange = { [weak view] in view?.invalidateIntrinsicContentSize() }
        return view
    }

    public func updateNSView(_ view: OutlineTextView, context: Context) {
        if view.theme != store.theme { view.applyTheme(store.theme) }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: OutlineTextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 600
        let width = (w.isFinite && w > 0) ? w : 600
        return CGSize(width: width, height: nsView.contentHeight(forWidth: width))
    }

    public static func dismantleNSView(_ view: OutlineTextView, coordinator: ()) { view.flushPendingSave() }
}
#endif

#if os(iOS)
import GrimoireCore
import SwiftUI
import UIKit

/// SwiftUI host for one page's text view on iOS. Pages stack inside an outer scroll view, so the view reports its full height.
public struct PageEditor: UIViewRepresentable {
    let store: GraphStore
    let pageID: String
    var journal: JournalDate? = nil
    var autofocus = false

    public init(store: GraphStore, pageID: String, journal: JournalDate? = nil, autofocus: Bool = false) {
        self.store = store; self.pageID = pageID; self.journal = journal; self.autofocus = autofocus
    }

    public func makeUIView(context: Context) -> OutlineTextView {
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
        view.autocompleteSource = store.autocompleteSource
        let store = self.store
        view.onOpenLink = { target, newPane in store.openLink(target, newPane: newPane) }
        view.onContentSizeChange = { [weak view] in view?.invalidateIntrinsicContentSize() }
        return view
    }

    public func updateUIView(_ view: OutlineTextView, context: Context) {
        if view.theme != store.theme { view.applyTheme(store.theme) }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: OutlineTextView, context: Context) -> CGSize? {
        let w = proposal.width ?? 390
        let width = (w.isFinite && w > 0) ? w : 390
        return CGSize(width: width, height: uiView.contentHeight(forWidth: width))
    }

    public static func dismantleUIView(_ view: OutlineTextView, coordinator: ()) { view.flushPendingSave() }
}
#endif

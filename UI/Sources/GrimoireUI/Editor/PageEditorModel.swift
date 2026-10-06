import Foundation
import GrimoireCore

/// Connects one open page to the database: loads it, saves edits after a short pause, and notices outside changes.
/// The view owns the text; the model only ever reads it through `currentDoc` and writes ops from it.
public final class PageEditorModel {
    public let graph: Graph
    public let pageID: String
    public var debounceInterval: TimeInterval = 0.3

    /// Set by the view: reads the text view's current outline (called on the main thread).
    public var currentDoc: (() -> OutlineDoc)?
    /// Called on the main thread when saving gave new rows their ids (the view patches its paragraphs).
    public var onNormalized: ((OutlineDoc) -> Void)?
    /// Called on the main thread when the database changed under an idle editor.
    public var onExternalDoc: ((OutlineDoc) -> Void)?
    /// Called on the main thread after each successful save.
    public var onSaved: (() -> Void)?
    /// Called on the main thread when the text changes (before it is saved).
    public var onEdited: (() -> Void)?
    /// Runs on the save queue before the first write (a journal page is created lazily, on the first keystroke).
    public var prepare: (() throws -> Void)?
    /// Called on the main thread when a save fails (the edit stays unsaved and is retried with the next one).
    public var onSaveFailed: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "grimoire.editor.save")
    private var saved = OutlineDoc(rows: [])             // queue-confined
    private var savedKeys: [String: String] = [:]        // queue-confined
    private var editGeneration = 0                        // main thread
    private var savedGeneration = 0                       // main thread
    private var debounce: DispatchWorkItem?
    private var reloadWhenIdle = false
    public private(set) var saveCount = 0

    public init(graph: Graph, pageID: String) { self.graph = graph; self.pageID = pageID }

    public var isDirty: Bool { editGeneration != savedGeneration }

    /// Reads the page and remembers it as the saved state.
    public func load() throws -> OutlineDoc {
        let tree = try graph.tree(pageID: pageID)
        let doc = OutlineDoc(tree: tree)
        queue.sync { saved = doc; savedKeys = OutlineDoc.keys(tree: tree) }
        return doc
    }

    /// The text changed: save after the pause.
    public func noteEdited() {
        onEdited?()
        editGeneration += 1
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// Saves right now (used when leaving the page, closing the window, quitting).
    public func flush(completion: (() -> Void)? = nil) {
        debounce?.cancel()
        guard let read = currentDoc else { completion?(); return }
        let generation = editGeneration
        var newIDCounter = 0
        let current = read()
        let normalized = current.normalized { newIDCounter += 1; return UUID().uuidString.lowercased() }
        if newIDCounter > 0 || normalized.rows.map(\.blockID) != current.rows.map(\.blockID) { onNormalized?(normalized) }
        let pageID = self.pageID, graph = self.graph
        queue.async { [self] in
            // A page the user hasn't typed into yet is shown with one empty placeholder row: that is not a change.
            if saved.rows.isEmpty, normalized.rows.count == 1, normalized.rows[0].text.isEmpty {
                DispatchQueue.main.async { self.savedGeneration = max(self.savedGeneration, generation); completion?() }
                return
            }
            let ops = OutlineSync.ops(old: saved, new: normalized, pageID: pageID, orderKeys: savedKeys, newID: { UUID().uuidString.lowercased() })
            if !ops.isEmpty {
                do { try self.prepare?(); try graph.perform(ops, author: .me) } catch { NSLog("grimoire: save failed: \(error)"); DispatchQueue.main.async { self.onSaveFailed?(error); completion?() }; return }
                if let tree = try? graph.tree(pageID: pageID) { saved = OutlineDoc(tree: tree); savedKeys = OutlineDoc.keys(tree: tree) }
            }
            DispatchQueue.main.async {
                self.savedGeneration = max(self.savedGeneration, generation)
                if !ops.isEmpty { self.saveCount += 1; self.onSaved?() }
                if self.reloadWhenIdle && !self.isDirty { self.reloadWhenIdle = false; self.externalChangeDetected() }
                completion?()
            }
        }
    }

    /// Something else wrote to the database. Reload if there is nothing unsaved; otherwise wait for the save.
    /// What matters is whether the database now differs from what the editor *shows*, not from what we last saved.
    public func externalChangeDetected() {
        if isDirty { reloadWhenIdle = true; return }
        let shown = currentDoc?()
        let generation = editGeneration
        let pageID = self.pageID, graph = self.graph
        queue.async { [self] in
            guard let tree = try? graph.tree(pageID: pageID) else { return }
            let doc = OutlineDoc(tree: tree)
            let keys = OutlineDoc.keys(tree: tree)
            DispatchQueue.main.async {
                // Only now, if the editor still shows what we compared against, may the database state become the saved state;
                // otherwise a later save would diff against it and undo the outside change.
                guard generation == self.editGeneration else { self.reloadWhenIdle = true; return }
                self.queue.async { self.saved = doc; self.savedKeys = keys }
                if doc != shown { self.onExternalDoc?(doc) }
            }
        }
    }

    /// Blocks until queued saves have finished (tests).
    public func waitUntilIdle() { queue.sync {} }
}

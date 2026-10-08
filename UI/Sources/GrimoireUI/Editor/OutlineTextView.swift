#if os(macOS)
import AppKit

/// The editing surface for one page: a TextKit 2 text view where every block is a paragraph.
public final class OutlineTextView: NSTextView, NSTextStorageDelegate {
    public let outlineDelegate = OutlineTextDelegate()
    public private(set) var theme: Theme
    public var model: PageEditorModel? { didSet { wireModel() } }
    /// Called when a link, tag, URL or block reference is activated (⌘-click). The Bool asks for a new pane.
    public var onOpenLink: ((LinkTarget, Bool) -> Void)?
    /// Called after each text change with the current paragraph text and caret offset inside it (autocomplete hook).
    /// Called with the block id of the bullet the caret is in (nil for a new, unsaved bullet).
    public var onCaretBlockChange: ((String?) -> Void)?
    public var onCaretContextChange: ((String, Int, NSRect) -> Void)?
    /// Autocomplete gets first refusal on navigation keys.
    public var keyInterceptor: ((NSEvent) -> Bool)?
    /// Candidates for `[[`, `#`, `((` and `/`; nil turns the popup off.
    public var autocompleteSource: AutocompleteSource?
    private var autocompletePanel: AutocompletePanel?
    private var activeTrigger: AutocompleteTrigger?
    var isAutocompleteOpen: Bool { autocompletePanel?.superview != nil }
    var autocompleteItems: [AutocompleteItem] { autocompletePanel?.items ?? [] }
    public var onContentSizeChange: (() -> Void)?
    public var autofocus = false
    public var intrinsicWidthHint: CGFloat = 600

    private var base: [NSAttributedString.Key: Any]
    private var lastRowCount = 0
    private var restyling = false
    /// Rows whose formatting syntax is showing (the bullets the selection is in, while the editor has focus).
    private var revealedRows: Set<Int> = []

    public init(theme: Theme) {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.textContainer = container
        content.addTextLayoutManager(layout)
        self.theme = theme
        self.base = ParagraphStyler.baseAttributes(theme: theme)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 100), textContainer: container)
        content.delegate = outlineDelegate
        layout.delegate = outlineDelegate
        textStorage?.delegate = self
        isRichText = true
        allowsUndo = true
        isEditable = true
        isSelectable = true
        drawsBackground = true
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = false
        applyTheme(theme)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: theme

    private var gutter: CGFloat { 20 }
    private var indent: CGFloat { CGFloat(theme.spacing.indent) }

    public func applyTheme(_ newTheme: Theme) {
        theme = newTheme
        base = ParagraphStyler.baseAttributes(theme: newTheme)
        backgroundColor = newTheme.colors.platformColor(\.background)
        insertionPointColor = newTheme.colors.platformColor(\.accent)
        selectedTextAttributes = [.backgroundColor: newTheme.colors.platformColor(\.selection)]
        textContainerInset = NSSize(width: CGFloat(newTheme.spacing.pagePadding), height: 6)
        outlineDelegate.metrics = OutlineMetrics(theme: newTheme)
        outlineDelegate.metrics.gutter = gutter
        typingAttributes = base
        // Re-render the paragraphs that are already there.
        if let storage = textStorage, storage.length > 0 {
            let doc = currentDoc
            storage.setAttributedString(OutlineStorage.attributed(doc: doc, base: base, indent: indent, gutter: gutter))
            revealedRows = []
            updateRevealedRows()
        }
        textLayoutManager?.invalidateLayout(for: textLayoutManager!.documentRange)
        scheduleDiagramRefresh(after: 0.05)
        needsDisplay = true
    }

    // MARK: content

    public var currentDoc: OutlineDoc { textStorage.map { OutlineStorage.doc(from: $0) } ?? OutlineDoc(rows: []) }

    /// Replaces everything with `doc` (opening a page).
    public func load(_ doc: OutlineDoc) {
        guard let storage = textStorage else { return }
        storage.setAttributedString(OutlineStorage.attributed(doc: doc, base: base, indent: indent, gutter: gutter))
        revealedRows = []
        lastRowCount = doc.rows.count
        undoManager?.removeAllActions()
        scheduleDiagramRefresh(after: 0.05)
        setSelectedRange(NSRange(location: 0, length: 0))
        invalidateIntrinsicContentSize()
    }

    /// Shows a database change made elsewhere, keeping the caret on the same block when it still exists.
    public func applyExternal(_ doc: OutlineDoc) {
        guard let storage = textStorage else { return }
        let old = currentDoc
        let sel = OutlineStorage.selection(for: selectedRange(), in: storage)
        let caretID = old.rows.indices.contains(sel.head.row) ? old.rows[sel.head.row].blockID : nil
        if let r = OutlineStorage.replacement(in: storage, old: old, new: doc, base: base, indent: indent, gutter: gutter) {
            storage.replaceCharacters(in: r.range, with: r.text)
        }
        undoManager?.removeAllActions()
        lastRowCount = doc.rows.count
        scheduleDiagramRefresh(after: 0.05)
        if let id = caretID, let row = doc.rows.firstIndex(where: { $0.blockID == id }) {
            let off = min(sel.head.offset, (doc.rows[row].text as NSString).length)
            setSelectedRange(OutlineStorage.range(for: OutlineSelection(caret: OutlinePos(row: row, offset: off)), in: storage))
        }
        updateRevealedRows(force: true)
        invalidateIntrinsicContentSize()
    }

    /// The model assigned ids to new paragraphs: write them onto the paragraphs (no text change, no undo entry).
    public func patchIDs(_ doc: OutlineDoc) {
        guard let storage = textStorage else { return }
        let ranges = OutlineStorage.rowRanges(in: storage)
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        storage.beginEditing()
        for (i, r) in ranges.enumerated() where i < doc.rows.count {
            if let id = doc.rows[i].blockID, storage.attribute(OutlineAttr.blockID, at: r.location, effectiveRange: nil) as? String != id {
                storage.addAttribute(OutlineAttr.blockID, value: id, range: r)
            }
            if storage.attribute(OutlineAttr.depth, at: r.location, effectiveRange: nil) as? Int != doc.rows[i].depth {
                storage.addAttribute(OutlineAttr.depth, value: doc.rows[i].depth, range: r)
            }
        }
        storage.endEditing()
    }

    private func wireModel() {
        guard let model else { return }
        model.currentDoc = { [weak self] in self?.currentDoc ?? OutlineDoc(rows: []) }
        model.onNormalized = { [weak self] doc in self?.patchIDs(doc) }
        model.onExternalDoc = { [weak self] doc in self?.applyExternal(doc) }
    }

    public func flushPendingSave() { model?.flush() }

    // MARK: restyling

    public func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !restyling else { return }
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        var start = min(editedRange.location, ns.length)
        while start > 0, ns.character(at: start - 1) != 0x0A { start -= 1 }
        var end = min(NSMaxRange(editedRange), ns.length)
        if !(end > 0 && ns.character(at: end - 1) == 0x0A && end > editedRange.location) {
            while end < ns.length { let c = ns.character(at: end); end += 1; if c == 0x0A { break } }
        }
        var p = start
        restyling = true
        while p < end {
            var q = p
            while q < ns.length { let c = ns.character(at: q); q += 1; if c == 0x0A { break } }
            ParagraphStyler.apply(to: storage, range: NSRange(location: p, length: q - p), theme: theme, concealSyntax: true)
            p = q
        }
        restyling = false
    }

    /// Reveals the formatting syntax of the bullets the selection is in and conceals it everywhere else.
    /// `force` restyles the revealed rows even if they were already revealed (an edit just concealed them).
    func updateRevealedRows(force: Bool = false, focused: Bool? = nil) {
        guard let storage = textStorage, storage.editedMask.isEmpty else { return }
        let isFocused = focused ?? (window?.firstResponder === self)
        let wanted: Set<Int> = isFocused ? Set(selection.rowRange) : []
        let conceal = revealedRows.subtracting(wanted)
        let reveal = force ? wanted : wanted.subtracting(revealedRows)
        revealedRows = wanted
        guard !conceal.isEmpty || !reveal.isEmpty else { return }
        restyling = true
        undoManager?.disableUndoRegistration()
        storage.beginEditing()
        ParagraphStyler.restyle(rows: conceal, in: storage, theme: theme, concealSyntax: true)
        ParagraphStyler.restyle(rows: reveal, in: storage, theme: theme, concealSyntax: false)
        storage.endEditing()
        undoManager?.enableUndoRegistration()
        restyling = false
    }

    public override func didChangeText() {
        super.didChangeText()
        updateRevealedRows(force: true)
        if let storage = textStorage {
            let count = OutlineStorage.rowRanges(in: storage).count
            if count != lastRowCount { lastRowCount = count; refreshDerivedAttributes() }
        }
        model?.noteEdited()
        scheduleDiagramRefresh()
        invalidateIntrinsicContentSize()
        onContentSizeChange?()
        reportCaretContext()
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if !stillSelectingFlag { reportCaretContext() }
        updateRevealedRows()
    }

    private func reportCaretContext() {
        guard let storage = textStorage, selectedRange().length == 0 else { onCaretContextChange?("", 0, .zero); return }
        let pos = OutlineStorage.pos(selectedRange().location, in: storage)
        let doc = currentDoc
        guard doc.rows.indices.contains(pos.row) else { return }
        onCaretBlockChange?(doc.rows[pos.row].blockID)
        onCaretContextChange?(doc.rows[pos.row].text, pos.offset, caretRect())
        updateAutocomplete(text: doc.rows[pos.row].text, caret: pos.offset)
    }

    // MARK: diagrams

    private var diagramTimer: Timer?
    /// The renderer (shared by default; tests inject their own).
    public var diagramRenderer: MermaidRenderer = .shared

    func scheduleDiagramRefresh(after delay: TimeInterval = 0.5) {
        diagramTimer?.invalidate()
        diagramTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDiagrams() }
        }
    }

    /// Draws the Mermaid fence of every block that has one, and clears the picture from blocks that no longer do.
    public func refreshDiagrams() {
        guard let storage = textStorage else { return }
        let doc = currentDoc
        let ranges = OutlineStorage.rowRanges(in: storage)
        for (i, row) in doc.rows.enumerated() where i < ranges.count {
            let r = ranges[i]
            let applied = storage.attribute(OutlineAttr.diagramKey, at: r.location, effectiveRange: nil) as? String
            guard let source = DiagramSource.mermaid(in: row.text) else {
                if applied != nil { setDiagram(nil, error: nil, key: nil, blockID: row.blockID, rowIndex: i) }
                continue
            }
            let key = DiagramSource.key(source: source, theme: theme.name)
            if applied == key { continue }
            let id = row.blockID, themeAtStart = theme
            Task { @MainActor [weak self] in
                let renderer = self?.diagramRenderer ?? .shared
                let result = await renderer.render(source: source, theme: themeAtStart)
                guard let self, self.theme.name == themeAtStart.name, let idx = self.rowIndex(ofBlock: id, fallback: i),
                      DiagramSource.mermaid(in: self.currentDoc.rows[idx].text) == source else { return }
                switch result {
                case .image(let img): self.setDiagram(img, error: nil, key: key, blockID: id, rowIndex: idx)
                case .failure(let msg): self.setDiagram(nil, error: msg, key: key, blockID: id, rowIndex: idx)
                }
            }
        }
    }

    private func rowIndex(ofBlock id: String?, fallback: Int) -> Int? {
        let doc = currentDoc
        if let id, let i = doc.rows.firstIndex(where: { $0.blockID == id }) { return i }
        return doc.rows.indices.contains(fallback) ? fallback : nil
    }

    private func setDiagram(_ image: NSImage?, error: String?, key: String?, blockID: String?, rowIndex: Int) {
        guard let storage = textStorage else { return }
        let ranges = OutlineStorage.rowRanges(in: storage)
        guard ranges.indices.contains(rowIndex) else { return }
        let r = ranges[rowIndex]
        restyling = true
        undoManager?.disableUndoRegistration()
        storage.beginEditing()
        for k in [OutlineAttr.diagram, OutlineAttr.diagramKey, OutlineAttr.diagramError] { storage.removeAttribute(k, range: r) }
        let style = ((base[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        if let image { storage.addAttribute(OutlineAttr.diagram, value: image, range: r); style.paragraphSpacing += OutlineLayoutFragment.diagramSize(image).height + 16 }
        else if let error { storage.addAttribute(OutlineAttr.diagramError, value: error, range: r); style.paragraphSpacing += 28 }
        if let key { storage.addAttribute(OutlineAttr.diagramKey, value: key, range: r) }
        storage.addAttribute(.paragraphStyle, value: style, range: r)
        storage.endEditing()
        undoManager?.enableUndoRegistration()
        restyling = false
        textLayoutManager?.invalidateLayout(for: textLayoutManager!.documentRange)
        invalidateIntrinsicContentSize()
        onContentSizeChange?()
        needsDisplay = true
    }

    // MARK: autocomplete

    private func updateAutocomplete(text: String, caret: Int) {
        guard let source = autocompleteSource, !applyingAutocomplete,
              let trigger = Autocomplete.detect(text: text, caret: caret) else { closeAutocomplete(); return }
        let items = Autocomplete.items(for: trigger, source: source)
        guard !items.isEmpty else { closeAutocomplete(); return }
        activeTrigger = trigger
        let panel = autocompletePanel ?? AutocompletePanel(theme: theme)
        autocompletePanel = panel
        panel.onPick = { [weak self] item in self?.acceptAutocomplete(item) }
        panel.show(items, theme: theme)
        let caretRect = self.caretRect()
        var origin = NSPoint(x: max(8, min(caretRect.minX - 4, bounds.width - panel.frame.width - 8)), y: caretRect.maxY + 4)
        if isFlipped == false { origin.y = caretRect.minY - panel.frame.height - 4 }
        panel.setFrameOrigin(origin)
        if panel.superview == nil { addSubview(panel) }
    }

    func closeAutocomplete() { autocompletePanel?.removeFromSuperview(); activeTrigger = nil }

    private var applyingAutocomplete = false

    func acceptAutocomplete(_ item: AutocompleteItem? = nil) {
        guard let panel = autocompletePanel, let trigger = activeTrigger, let item = item ?? panel.current, let storage = textStorage else { return }
        let sel = OutlineStorage.selection(for: selectedRange(), in: storage)
        let doc = currentDoc
        guard doc.rows.indices.contains(sel.head.row) else { return }
        let rowStart = OutlineStorage.rowRanges(in: storage)[sel.head.row].location
        let e = Autocomplete.edit(for: item, trigger: trigger, in: doc.rows[sel.head.row].text)
        applyingAutocomplete = true
        closeAutocomplete()
        insertText(e.text, replacementRange: NSRange(location: rowStart + e.range.location, length: e.range.length))
        setSelectedRange(NSRange(location: rowStart + e.caret, length: 0))
        applyingAutocomplete = false
    }

    /// Keys the open popup claims. Returns true when handled.
    private func autocompleteKey(_ event: NSEvent) -> Bool {
        guard isAutocompleteOpen, let panel = autocompletePanel else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 125: panel.move(1); return true
        case 126: panel.move(-1); return true
        case 36, 76, 48: acceptAutocomplete(); return true
        case 53: closeAutocomplete(); return true
        default: return false
        }
    }

    /// The caret's rectangle in this view's coordinates (for placing popups).
    public func caretRect() -> NSRect {
        let r = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        guard let window else { return r }
        return convert(window.convertFromScreen(r), from: nil)
    }

    /// Keeps the has-children / hidden attributes in step after edits that change the structure.
    func refreshDerivedAttributes() {
        guard let storage = textStorage else { return }
        let derived = OutlineStorage.derived(currentDoc)
        let ranges = OutlineStorage.rowRanges(in: storage)
        restyling = true
        undoManager?.disableUndoRegistration()
        storage.beginEditing()
        for (i, r) in ranges.enumerated() where i < derived.count {
            let d = derived[i]
            if (storage.attribute(OutlineAttr.hasChildren, at: r.location, effectiveRange: nil) != nil) != d.hasChildren {
                if d.hasChildren { storage.addAttribute(OutlineAttr.hasChildren, value: true, range: r) } else { storage.removeAttribute(OutlineAttr.hasChildren, range: r) }
            }
            if (storage.attribute(OutlineAttr.hidden, at: r.location, effectiveRange: nil) != nil) != d.hidden {
                if d.hidden { storage.addAttribute(OutlineAttr.hidden, value: true, range: r) } else { storage.removeAttribute(OutlineAttr.hidden, range: r) }
            }
        }
        storage.endEditing()
        undoManager?.enableUndoRegistration()
        restyling = false
    }

    // MARK: sizing

    /// The text always wraps at the view's own width (minus the side margins), whatever width it was first measured at.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let container = textContainer, newSize.width > 0 else { return }
        let w = max(100, newSize.width - textContainerInset.width * 2)
        if abs(container.size.width - w) > 0.5 {
            container.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
            textLayoutManager?.invalidateLayout(for: textLayoutManager!.documentRange)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    public func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let layout = textLayoutManager, let container = textContainer else { return 100 }
        container.size = NSSize(width: max(100, width - textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: layout.documentRange)
        return ceil(layout.usageBoundsForTextContainer.maxY) + textContainerInset.height * 2
    }

    // MARK: structural edits

    /// Applies an outline edit as one undoable text replacement and restores the selection.
    public func apply(_ edit: OutlineEdit, actionName: String) {
        guard let storage = textStorage else { return }
        let old = currentDoc
        if let r = OutlineStorage.replacement(in: storage, old: old, new: edit.doc, base: base, indent: indent, gutter: gutter) {
            if shouldChangeText(in: r.range, replacementString: r.text.string) {
                storage.replaceCharacters(in: r.range, with: r.text)
                didChangeText()
            }
        }
        setSelectedRange(OutlineStorage.range(for: edit.selection, in: storage))
        scrollRangeToVisible(selectedRange())
        undoManager?.setActionName(actionName)
    }

    private var selection: OutlineSelection { OutlineStorage.selection(for: selectedRange(), in: textStorage!) }

    public override func doCommand(by selector: Selector) {
        if keyInterceptor == nil || true {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): splitAtCaret(); return
            case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                insertText("\u{2028}", replacementRange: selectedRange()); return
            case #selector(NSResponder.insertTab(_:)):
                if let e = OutlineCommands.indent(currentDoc, selection) { apply(e, actionName: "Indent") }
                return
            case #selector(NSResponder.insertBacktab(_:)):
                if let e = OutlineCommands.outdent(currentDoc, selection) { apply(e, actionName: "Outdent") }
                return
            case #selector(NSResponder.deleteBackward(_:)):
                if selectedRange().length == 0, selection.head.offset == 0, let e = OutlineCommands.mergeBackward(currentDoc, at: selection.head.row) {
                    apply(e, actionName: "Merge Blocks"); return
                }
                if selectedRange().length == 0, selection.head.offset == 0 { return }
            case #selector(NSResponder.deleteForward(_:)):
                let doc = currentDoc, sel = selection.head
                if selectedRange().length == 0, doc.rows.indices.contains(sel.row), sel.offset == (doc.rows[sel.row].text as NSString).length {
                    let hidden = doc.hiddenFlags()
                    let next = doc.subtreeRange(of: sel.row).upperBound
                    let visibleNext = doc.rows[sel.row].collapsed ? next : sel.row + 1
                    if visibleNext < doc.rows.count, !hidden[visibleNext], let e = OutlineCommands.mergeBackward(doc, at: visibleNext) {
                        apply(e, actionName: "Merge Blocks")
                    }
                    return
                }
            default: break
            }
        }
        super.doCommand(by: selector)
    }

    private func splitAtCaret() {
        if selectedRange().length > 0 { insertText("", replacementRange: selectedRange()) }
        let doc = currentDoc
        let head = selection.head
        guard doc.rows.indices.contains(head.row) else { return }
        if let e = OutlineCommands.split(doc, at: head) { apply(e, actionName: "New Block") }
    }

    public override func keyDown(with event: NSEvent) {
        if keyInterceptor?(event) == true { return }
        if autocompleteKey(event) { return }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let doc = currentDoc
        switch (event.keyCode, flags) {
        case (126, [.option, .shift]):                                   // ⌥⇧↑ move block up
            if let e = OutlineCommands.moveUp(doc, selection) { apply(e, actionName: "Move Block Up") }; return
        case (125, [.option, .shift]):
            if let e = OutlineCommands.moveDown(doc, selection) { apply(e, actionName: "Move Block Down") }; return
        case (126, [.command]):                                          // ⌘↑ collapse
            toggleCollapse(expand: false); return
        case (125, [.command]):                                          // ⌘↓ expand
            toggleCollapse(expand: true); return
        case (36, [.command]), (76, [.command]):                         // ⌘↩ cycle task state
            if let e = OutlineCommands.toggleTask(doc, selection) { apply(e, actionName: "Toggle Task") }; return
        default: break
        }
        if flags == [.command], let ch = event.charactersIgnoringModifiers {
            if ch == "b" { wrapSelection("**"); return }
            if ch == "i" { wrapSelection("*"); return }
        }
        super.keyDown(with: event)
    }

    public func toggleCollapse(expand: Bool?) {
        let doc = currentDoc
        let row = selection.head.row
        guard doc.rows.indices.contains(row) else { return }
        if let want = expand, doc.rows[row].collapsed == !want { return }
        if let d = OutlineCommands.toggleCollapse(doc, row: row) {
            apply(OutlineEdit(doc: d, selection: OutlineSelection(caret: OutlinePos(row: row, offset: min(selection.head.offset, (doc.rows[row].text as NSString).length)))), actionName: "Toggle Collapse")
        }
    }

    public func wrapSelection(_ marker: String) {
        let r = selectedRange()
        let ns = string as NSString
        let inner = ns.substring(with: r)
        insertText(marker + inner + marker, replacementRange: r)
        if r.length == 0 { setSelectedRange(NSRange(location: r.location + marker.utf16.count, length: 0)) }
        else { setSelectedRange(NSRange(location: r.location + marker.utf16.count, length: r.length)) }
    }

    // MARK: typing helpers

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        if let s = string as? String, s.count == 1 {
            let sel = selectedRange()
            let ns = self.string as NSString
            if (s == "]" || s == ")"), sel.length == 0, sel.location < ns.length, ns.substring(with: NSRange(location: sel.location, length: 1)) == s {
                setSelectedRange(NSRange(location: sel.location + 1, length: 0)); return           // type over the closing bracket
            }
            if s == "[" || s == "(" {
                let close = s == "[" ? "]" : ")"
                let inner = sel.length > 0 ? ns.substring(with: sel) : ""
                super.insertText(s + inner + close, replacementRange: replacementRange.location == NSNotFound ? sel : replacementRange)
                setSelectedRange(NSRange(location: sel.location + 1, length: (inner as NSString).length))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: clipboard

    public override func copy(_ sender: Any?) { writeSelectionToPasteboard() }
    public override func cut(_ sender: Any?) { if writeSelectionToPasteboard() { insertText("", replacementRange: selectedRange()) } }

    @discardableResult private func writeSelectionToPasteboard() -> Bool {
        let r = selectedRange()
        guard r.length > 0, let storage = textStorage else { return false }
        let sel = OutlineStorage.selection(for: r, in: storage)
        let doc = currentDoc
        var text: String
        if sel.rowRange.count == 1 {
            text = OutlineStorage.rowText((storage.string as NSString).substring(with: r))
        } else {
            var rows = Array(doc.rows[sel.rowRange])
            if let last = rows.indices.last {
                let lastText = rows[last].text as NSString
                rows[last].text = lastText.substring(to: min(sel.rowRange.upperBound == sel.head.row ? sel.head.offset : sel.anchor.offset, lastText.length))
                let firstText = rows[0].text as NSString
                rows[0].text = firstText.substring(from: min(sel.rowRange.lowerBound == sel.anchor.row ? sel.anchor.offset : sel.head.offset, firstText.length))
            }
            text = OutlineMarkdown.render(rows)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    public override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .newlines)
        if !trimmed.contains("\n") {
            insertText(trimmed.replacingOccurrences(of: "\n", with: ""), replacementRange: selectedRange()); return
        }
        if selectedRange().length > 0 { insertText("", replacementRange: selectedRange()) }
        let rows = OutlineMarkdown.parse(trimmed)
        let doc = currentDoc
        let at = doc.rows.indices.contains(selection.head.row) ? selection.head : OutlinePos(row: 0, offset: 0)
        if let e = OutlineCommands.paste(doc, at: at, rows: rows) { apply(e, actionName: "Paste") }
    }

    public override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    public override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    // MARK: mouse

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        if let hit = fragmentHit(at: p), let storage = textStorage {
            let doc = currentDoc
            // 1. the bullet / checkbox gutter
            let bulletX = textContainerInset.width + CGFloat(hit.depth) * indent
            if p.x >= bulletX - 4, p.x <= bulletX + gutter, doc.rows.indices.contains(hit.row) {
                if let state = hit.task {
                    _ = state
                    if let e = OutlineCommands.toggleTask(doc, OutlineSelection(caret: OutlinePos(row: hit.row, offset: 0))) {
                        apply(e, actionName: "Toggle Task"); return
                    }
                } else if hit.hasChildren, let d = OutlineCommands.toggleCollapse(doc, row: hit.row) {
                    let keep = OutlineSelection(caret: OutlinePos(row: hit.row, offset: 0))
                    apply(OutlineEdit(doc: d, selection: keep), actionName: "Toggle Collapse"); return
                }
            }
            // 2. ⌘-click follows links
            if flags.contains(.command), doc.rows.indices.contains(hit.row) {
                let idx = charIndex(at: p)
                let offset = OutlineStorage.selection(for: NSRange(location: idx, length: 0), in: storage).head.offset
                if let target = LinkResolver.target(at: offset, in: doc.rows[hit.row].text) {
                    onOpenLink?(target, flags.contains(.shift)); return
                }
            }
        }
        super.mouseDown(with: event)
    }

    struct FragmentHit { var row: Int; var depth: Int; var hasChildren: Bool; var task: TaskState? }

    func fragmentHit(at p: NSPoint) -> FragmentHit? {
        guard let layout = textLayoutManager, let content = textContentStorage else { return nil }
        let local = CGPoint(x: p.x - textContainerInset.width, y: p.y - textContainerInset.height)
        guard let fragment = layout.textLayoutFragment(for: local) as? OutlineLayoutFragment else { return nil }
        let loc = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard let storage = textStorage else { return nil }
        let row = OutlineStorage.pos(loc, in: storage).row
        return FragmentHit(row: row, depth: fragment.depth, hasChildren: fragment.hasChildren, task: fragment.task)
    }

    func charIndex(at p: NSPoint) -> Int {
        guard let layout = textLayoutManager, let content = textContentStorage else { return 0 }
        let local = CGPoint(x: p.x - textContainerInset.width, y: p.y - textContainerInset.height)
        guard let fragment = layout.textLayoutFragment(for: local) else { return 0 }
        let fragOrigin = fragment.layoutFragmentFrame.origin
        let base = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        for line in fragment.textLineFragments {
            let pt = CGPoint(x: local.x - fragOrigin.x, y: local.y - fragOrigin.y)
            if line.typographicBounds.contains(pt) || line === fragment.textLineFragments.last {
                return base + line.characterIndex(for: CGPoint(x: pt.x - line.typographicBounds.origin.x, y: pt.y - line.typographicBounds.origin.y))
            }
        }
        return base
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if autofocus, let window, window.firstResponder === window || window.firstResponder == nil || window.firstResponder is NSWindow {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                if let storage = self.textStorage {
                    let n = OutlineStorage.rowRanges(in: storage).count
                    self.setSelectedRange(OutlineStorage.range(for: OutlineSelection(caret: OutlinePos(row: max(0, n - 1), offset: Int.max / 2)), in: storage))
                }
            }
        }
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight(forWidth: max(frame.width, 200)))
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { flushPendingSave() }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { updateRevealedRows(focused: true) }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        flushPendingSave()
        let resigned = super.resignFirstResponder()
        if resigned { updateRevealedRows(focused: false) }
        return resigned
    }
}
#endif

#if os(iOS)
import UIKit

/// The iPhone/iPad editing surface: the same one-paragraph-per-block TextKit 2 model as the Mac editor, driven by UITextView.
/// Return splits a block, Backspace at a block's start merges, a toolbar above the keyboard indents, moves and inserts.
public final class OutlineTextView: UITextView, UITextViewDelegate, NSTextStorageDelegate, UIGestureRecognizerDelegate {
    public let outlineDelegate = OutlineTextDelegate()
    public private(set) var theme: Theme
    public var model: PageEditorModel? { didSet { wireModel() } }
    public var onOpenLink: ((LinkTarget, Bool) -> Void)?
    public var autocompleteSource: AutocompleteSource?
    public var onContentSizeChange: (() -> Void)?
    public var autofocus = false

    private var base: [NSAttributedString.Key: Any]
    private var lastRowCount = 0
    private var restyling = false
    /// Rows whose formatting syntax is showing (the bullets the selection is in, while editing).
    private var revealedRows: Set<Int> = []
    private var activeTrigger: AutocompleteTrigger?
    private let accessory = EditorAccessory()
    var autocompleteItems: [AutocompleteItem] { accessory.items }
    var isAutocompleteOpen: Bool { !accessory.items.isEmpty }

    public init(theme: Theme) {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        content.addTextLayoutManager(layout)
        self.theme = theme
        self.base = ParagraphStyler.baseAttributes(theme: theme)
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 100), textContainer: container)
        content.delegate = outlineDelegate
        layout.delegate = outlineDelegate
        textStorage.delegate = self
        delegate = self
        isScrollEnabled = false
        isEditable = true
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        backgroundColor = .clear
        accessory.owner = self
        inputAccessoryView = accessory
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
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
        tintColor = newTheme.colors.platformColor(\.accent)
        textContainerInset = UIEdgeInsets(top: 6, left: CGFloat(newTheme.spacing.pagePadding), bottom: 6, right: CGFloat(newTheme.spacing.pagePadding))
        outlineDelegate.metrics = OutlineMetrics(theme: newTheme)
        outlineDelegate.metrics.gutter = gutter
        typingAttributes = base
        if textStorage.length > 0 {
            let doc = currentDoc
            textStorage.setAttributedString(OutlineStorage.attributed(doc: doc, base: base, indent: indent, gutter: gutter))
            revealedRows = []
            updateRevealedRows()
        }
        accessory.apply(theme: newTheme)
        textLayoutManager?.invalidateLayout(for: textLayoutManager!.documentRange)
        setNeedsDisplay()
    }

    // MARK: content

    public var currentDoc: OutlineDoc { OutlineStorage.doc(from: textStorage) }

    public func load(_ doc: OutlineDoc) {
        textStorage.setAttributedString(OutlineStorage.attributed(doc: doc, base: base, indent: indent, gutter: gutter))
        revealedRows = []
        lastRowCount = doc.rows.count
        undoManager?.removeAllActions()
        selectedRange = NSRange(location: 0, length: 0)
        invalidateIntrinsicContentSize()
    }

    public func applyExternal(_ doc: OutlineDoc) {
        let old = currentDoc
        let sel = OutlineStorage.selection(for: selectedRange, in: textStorage)
        let caretID = old.rows.indices.contains(sel.head.row) ? old.rows[sel.head.row].blockID : nil
        if let r = OutlineStorage.replacement(in: textStorage, old: old, new: doc, base: base, indent: indent, gutter: gutter) {
            textStorage.replaceCharacters(in: r.range, with: r.text)
        }
        undoManager?.removeAllActions()
        lastRowCount = doc.rows.count
        if let id = caretID, let row = doc.rows.firstIndex(where: { $0.blockID == id }) {
            let off = min(sel.head.offset, (doc.rows[row].text as NSString).length)
            selectedRange = OutlineStorage.range(for: OutlineSelection(caret: OutlinePos(row: row, offset: off)), in: textStorage)
        }
        updateRevealedRows(force: true)
        invalidateIntrinsicContentSize()
    }

    public func patchIDs(_ doc: OutlineDoc) {
        let ranges = OutlineStorage.rowRanges(in: textStorage)
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        restyling = true
        textStorage.beginEditing()
        for (i, r) in ranges.enumerated() where i < doc.rows.count {
            if let id = doc.rows[i].blockID, textStorage.attribute(OutlineAttr.blockID, at: r.location, effectiveRange: nil) as? String != id {
                textStorage.addAttribute(OutlineAttr.blockID, value: id, range: r)
            }
            if textStorage.attribute(OutlineAttr.depth, at: r.location, effectiveRange: nil) as? Int != doc.rows[i].depth {
                textStorage.addAttribute(OutlineAttr.depth, value: doc.rows[i].depth, range: r)
            }
        }
        textStorage.endEditing()
        restyling = false
    }

    private func wireModel() {
        guard let model else { return }
        model.currentDoc = { [weak self] in self?.currentDoc ?? OutlineDoc(rows: []) }
        model.onNormalized = { [weak self] doc in self?.patchIDs(doc) }
        model.onExternalDoc = { [weak self] doc in self?.applyExternal(doc) }
    }

    public func flushPendingSave() { model?.flush() }

    // MARK: restyling and change tracking

    public func textStorage(_ storage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
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

    public func textViewDidChange(_ textView: UITextView) { didEdit() }

    private func didEdit() {
        let count = OutlineStorage.rowRanges(in: textStorage).count
        if count != lastRowCount { lastRowCount = count; refreshDerivedAttributes() }
        model?.noteEdited()
        updateRevealedRows(force: true)
        invalidateIntrinsicContentSize()
        onContentSizeChange?()
        updateAutocomplete()
    }

    public func textViewDidChangeSelection(_ textView: UITextView) { updateAutocomplete(); updateRevealedRows() }
    public func textViewDidBeginEditing(_ textView: UITextView) { updateRevealedRows() }
    public func textViewDidEndEditing(_ textView: UITextView) { updateRevealedRows() }

    /// Reveals the formatting syntax of the bullets the selection is in and conceals it everywhere else.
    /// `force` restyles the revealed rows even if they were already revealed (an edit just concealed them).
    func updateRevealedRows(force: Bool = false) {
        guard textStorage.editedMask.isEmpty else { return }
        let wanted: Set<Int> = isFirstResponder ? Set(selection.rowRange) : []
        let conceal = revealedRows.subtracting(wanted)
        let reveal = force ? wanted : wanted.subtracting(revealedRows)
        revealedRows = wanted
        guard !conceal.isEmpty || !reveal.isEmpty else { return }
        restyling = true
        undoManager?.disableUndoRegistration()
        textStorage.beginEditing()
        ParagraphStyler.restyle(rows: conceal, in: textStorage, theme: theme, concealSyntax: true)
        ParagraphStyler.restyle(rows: reveal, in: textStorage, theme: theme, concealSyntax: false)
        textStorage.endEditing()
        undoManager?.enableUndoRegistration()
        restyling = false
    }

    func refreshDerivedAttributes() {
        let derived = OutlineStorage.derived(currentDoc)
        let ranges = OutlineStorage.rowRanges(in: textStorage)
        restyling = true
        undoManager?.disableUndoRegistration()
        textStorage.beginEditing()
        for (i, r) in ranges.enumerated() where i < derived.count {
            let d = derived[i]
            if (textStorage.attribute(OutlineAttr.hasChildren, at: r.location, effectiveRange: nil) != nil) != d.hasChildren {
                if d.hasChildren { textStorage.addAttribute(OutlineAttr.hasChildren, value: true, range: r) } else { textStorage.removeAttribute(OutlineAttr.hasChildren, range: r) }
            }
            if (textStorage.attribute(OutlineAttr.hidden, at: r.location, effectiveRange: nil) != nil) != d.hidden {
                if d.hidden { textStorage.addAttribute(OutlineAttr.hidden, value: true, range: r) } else { textStorage.removeAttribute(OutlineAttr.hidden, range: r) }
            }
        }
        textStorage.endEditing()
        undoManager?.enableUndoRegistration()
        restyling = false
    }

    // MARK: sizing

    public func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let layout = textLayoutManager else { return 100 }
        textContainer.size = CGSize(width: max(100, width - textContainerInset.left - textContainerInset.right), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: layout.documentRange)
        return ceil(layout.usageBoundsForTextContainer.maxY) + textContainerInset.top + textContainerInset.bottom
    }

    public override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: contentHeight(forWidth: max(bounds.width, 200))) }

    // MARK: structural edits

    private var selection: OutlineSelection { OutlineStorage.selection(for: selectedRange, in: textStorage) }

    /// Applies an outline edit as one undoable text replacement and restores the selection.
    public func apply(_ edit: OutlineEdit, actionName: String) {
        let old = currentDoc
        let before = selectedRange
        if let r = OutlineStorage.replacement(in: textStorage, old: old, new: edit.doc, base: base, indent: indent, gutter: gutter) {
            replaceUndoably(range: r.range, with: r.text, selectionBefore: before, actionName: actionName)
        }
        selectedRange = OutlineStorage.range(for: edit.selection, in: textStorage)
    }

    private func replaceUndoably(range: NSRange, with text: NSAttributedString, selectionBefore: NSRange, actionName: String) {
        let previous = textStorage.attributedSubstring(from: range)
        textStorage.replaceCharacters(in: range, with: text)
        didEdit()
        let newRange = NSRange(location: range.location, length: text.length)
        undoManager?.registerUndo(withTarget: self) { target in
            let after = target.selectedRange
            target.replaceUndoably(range: newRange, with: previous, selectionBefore: after, actionName: actionName)
            target.selectedRange = NSRange(location: min(selectionBefore.location, target.textStorage.length), length: 0)
        }
        undoManager?.setActionName(actionName)
    }

    func indentSelection() { if let e = OutlineCommands.indent(currentDoc, selection) { apply(e, actionName: "Indent") } }
    func outdentSelection() { if let e = OutlineCommands.outdent(currentDoc, selection) { apply(e, actionName: "Outdent") } }
    func moveUp() { if let e = OutlineCommands.moveUp(currentDoc, selection) { apply(e, actionName: "Move Block Up") } }
    func moveDown() { if let e = OutlineCommands.moveDown(currentDoc, selection) { apply(e, actionName: "Move Block Down") } }
    func cycleTask() { if let e = OutlineCommands.toggleTask(currentDoc, selection) { apply(e, actionName: "Toggle Task") } }

    func toggleCollapse(expand: Bool?) {
        let doc = currentDoc
        let row = selection.head.row
        guard doc.rows.indices.contains(row) else { return }
        if let want = expand, doc.rows[row].collapsed == !want { return }
        if let d = OutlineCommands.toggleCollapse(doc, row: row) {
            apply(OutlineEdit(doc: d, selection: OutlineSelection(caret: OutlinePos(row: row, offset: min(selection.head.offset, (doc.rows[row].text as NSString).length)))), actionName: "Toggle Collapse")
        }
    }

    func insertSnippet(_ s: String) { insertText(s) }

    private func splitAtCaret() {
        if selectedRange.length > 0 { replaceUndoably(range: selectedRange, with: NSAttributedString(), selectionBefore: selectedRange, actionName: "Delete") }
        let doc = currentDoc
        let head = selection.head
        guard doc.rows.indices.contains(head.row), let e = OutlineCommands.split(doc, at: head) else { return }
        apply(e, actionName: "New Block")
    }

    // MARK: typing

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let ns = textStorage.string as NSString
        if text == "\n" { splitAtCaret(); return false }
        if text.isEmpty, range.length == 1, range.location < ns.length, ns.character(at: range.location) == 0x0A {
            // Backspace at the start of a block merges it into the previous one.
            let sel = OutlineStorage.selection(for: NSRange(location: range.location + 1, length: 0), in: textStorage)
            if let e = OutlineCommands.mergeBackward(currentDoc, at: sel.head.row) { apply(e, actionName: "Merge Blocks"); return false }
            return false
        }
        if text.count == 1 {
            if (text == "]" || text == ")"), range.length == 0, range.location < ns.length, ns.substring(with: NSRange(location: range.location, length: 1)) == text {
                selectedRange = NSRange(location: range.location + 1, length: 0); return false                    // type over the closer
            }
            if text == "[" || text == "(" {
                let close = text == "[" ? "]" : ")"
                let inner = range.length > 0 ? ns.substring(with: range) : ""
                textStorage.replaceCharacters(in: range, with: NSAttributedString(string: text + inner + close, attributes: base))
                selectedRange = NSRange(location: range.location + 1, length: (inner as NSString).length)
                didEdit()
                return false
            }
        }
        return true
    }

    // MARK: hardware keyboard

    public override var keyCommands: [UIKeyCommand]? {
        func cmd(_ input: String, _ mods: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: mods, action: action)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return [
            cmd("\t", [], #selector(keyIndent)), cmd("\t", .shift, #selector(keyOutdent)),
            cmd(UIKeyCommand.inputUpArrow, [.alternate, .shift], #selector(keyMoveUp)), cmd(UIKeyCommand.inputDownArrow, [.alternate, .shift], #selector(keyMoveDown)),
            cmd("\r", .command, #selector(keyTask)),
            cmd(UIKeyCommand.inputUpArrow, .command, #selector(keyCollapse)), cmd(UIKeyCommand.inputDownArrow, .command, #selector(keyExpand)),
        ]
    }
    @objc private func keyIndent() { indentSelection() }
    @objc private func keyOutdent() { outdentSelection() }
    @objc private func keyMoveUp() { moveUp() }
    @objc private func keyMoveDown() { moveDown() }
    @objc private func keyTask() { cycleTask() }
    @objc private func keyCollapse() { toggleCollapse(expand: false) }
    @objc private func keyExpand() { toggleCollapse(expand: true) }

    // MARK: taps: bullets, checkboxes and links

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let tap = gestureRecognizer as? UITapGestureRecognizer, tap.view === self, tap.delegate === self else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        return classify(tap.location(in: self)) != nil
    }

    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private enum TapAction { case task(Int), collapse(Int), link(LinkTarget) }

    private func classify(_ p: CGPoint) -> TapAction? {
        guard let hit = fragmentHit(at: p) else { return nil }
        let doc = currentDoc
        guard doc.rows.indices.contains(hit.row) else { return nil }
        let bulletX = textContainerInset.left + CGFloat(hit.depth) * indent
        if p.x >= bulletX - 6, p.x <= bulletX + gutter + 4 {
            if hit.task != nil { return .task(hit.row) }
            if hit.hasChildren { return .collapse(hit.row) }
        }
        // a link is followed from any block except the one being edited
        if selection.head.row != hit.row || !isFirstResponder {
            let offset = OutlineStorage.selection(for: NSRange(location: charIndex(at: p), length: 0), in: textStorage).head.offset
            if let target = LinkResolver.target(at: offset, in: doc.rows[hit.row].text) { return .link(target) }
        }
        return nil
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let action = classify(tap.location(in: self)) else { return }
        let doc = currentDoc
        switch action {
        case .task(let row):
            if let e = OutlineCommands.toggleTask(doc, OutlineSelection(caret: OutlinePos(row: row, offset: 0))) { apply(e, actionName: "Toggle Task") }
        case .collapse(let row):
            if let d = OutlineCommands.toggleCollapse(doc, row: row) { apply(OutlineEdit(doc: d, selection: OutlineSelection(caret: OutlinePos(row: row, offset: 0))), actionName: "Toggle Collapse") }
        case .link(let target):
            onOpenLink?(target, false)
        }
    }

    struct FragmentHit { var row: Int; var depth: Int; var hasChildren: Bool; var task: TaskState? }

    func fragmentHit(at p: CGPoint) -> FragmentHit? {
        guard let layout = textLayoutManager, let content = layout.textContentManager as? NSTextContentStorage else { return nil }
        let local = CGPoint(x: p.x - textContainerInset.left, y: p.y - textContainerInset.top)
        guard let fragment = layout.textLayoutFragment(for: local) as? OutlineLayoutFragment else { return nil }
        let loc = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return FragmentHit(row: OutlineStorage.pos(loc, in: textStorage).row, depth: fragment.depth, hasChildren: fragment.hasChildren, task: fragment.task)
    }

    func charIndex(at p: CGPoint) -> Int {
        guard let layout = textLayoutManager, let content = layout.textContentManager as? NSTextContentStorage else { return 0 }
        let local = CGPoint(x: p.x - textContainerInset.left, y: p.y - textContainerInset.top)
        guard let fragment = layout.textLayoutFragment(for: local) else { return 0 }
        let origin = fragment.layoutFragmentFrame.origin
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        for line in fragment.textLineFragments {
            let pt = CGPoint(x: local.x - origin.x, y: local.y - origin.y)
            if line.typographicBounds.contains(pt) || line === fragment.textLineFragments.last {
                return start + line.characterIndex(for: CGPoint(x: pt.x - line.typographicBounds.origin.x, y: pt.y - line.typographicBounds.origin.y))
            }
        }
        return start
    }

    // MARK: autocomplete in the keyboard toolbar

    private func updateAutocomplete() {
        guard let source = autocompleteSource, selectedRange.length == 0 else { accessory.show(items: []); activeTrigger = nil; return }
        let pos = OutlineStorage.pos(selectedRange.location, in: textStorage)
        let doc = currentDoc
        guard doc.rows.indices.contains(pos.row), let trigger = Autocomplete.detect(text: doc.rows[pos.row].text, caret: pos.offset) else {
            accessory.show(items: []); activeTrigger = nil; return
        }
        activeTrigger = trigger
        accessory.show(items: Autocomplete.items(for: trigger, source: source))
    }

    func acceptAutocomplete(_ item: AutocompleteItem) {
        guard let trigger = activeTrigger else { return }
        let sel = selection
        let doc = currentDoc
        guard doc.rows.indices.contains(sel.head.row) else { return }
        let rowStart = OutlineStorage.rowRanges(in: textStorage)[sel.head.row].location
        let e = Autocomplete.edit(for: item, trigger: trigger, in: doc.rows[sel.head.row].text)
        activeTrigger = nil
        accessory.show(items: [])
        let range = NSRange(location: rowStart + e.range.location, length: e.range.length)
        textStorage.replaceCharacters(in: range, with: NSAttributedString(string: e.text, attributes: base))
        selectedRange = NSRange(location: rowStart + e.caret, length: 0)
        didEdit()
    }

    // MARK: focus

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if autofocus, window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.isFirstResponder else { return }
                _ = self.becomeFirstResponder()
                let n = OutlineStorage.rowRanges(in: self.textStorage).count
                self.selectedRange = OutlineStorage.range(for: OutlineSelection(caret: OutlinePos(row: max(0, n - 1), offset: Int.max / 2)), in: self.textStorage)
            }
        }
    }
}

/// The bar above the keyboard: structure buttons, or suggestions while a `[[`, `#`, `((` or `/` is being typed.
final class EditorAccessory: UIView {
    weak var owner: OutlineTextView?
    private let scroll = UIScrollView()
    private var dismiss = UIButton()
    private let stack = UIStackView()
    private(set) var items: [AutocompleteItem] = []
    private var theme: Theme?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        autoresizingMask = .flexibleWidth
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal; stack.spacing = 8; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll); scroll.addSubview(stack)
        // A fixed "hide keyboard" button on the right, outside the scrolling row, so it is always reachable.
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "keyboard.chevron.compact.down")
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        dismiss = UIButton(configuration: cfg, primaryAction: UIAction { [weak self] _ in _ = self?.owner?.resignFirstResponder() })
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dismiss)
        NSLayoutConstraint.activate([
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor), dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 48), dismiss.heightAnchor.constraint(equalToConstant: 40),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(theme: Theme) { self.theme = theme; backgroundColor = theme.colors.platformColor(\.surfaceRaised); dismiss.tintColor = theme.colors.platformColor(\.accent); rebuild() }

    func show(items: [AutocompleteItem]) { guard items != self.items else { return }; self.items = items; rebuild(); scroll.setContentOffset(.zero, animated: false) }

    private func button(_ title: String? = nil, symbol: String? = nil, accent: Bool = false, _ action: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.title = title
        if let symbol { cfg.image = UIImage(systemName: symbol) }
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        cfg.baseForegroundColor = theme.map { $0.colors.platformColor(accent ? \.accent : \.text) } ?? .label
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
        b.layer.cornerRadius = 8
        b.backgroundColor = theme.map { $0.colors.platformColor(\.surface) }
        return b
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if items.isEmpty {
            let o = { [weak self] (f: @escaping (OutlineTextView) -> Void) -> () -> Void in { if let v = self?.owner { f(v) } } }
            stack.addArrangedSubview(button(symbol: "decrease.indent", o { $0.outdentSelection() }))
            stack.addArrangedSubview(button(symbol: "increase.indent", o { $0.indentSelection() }))
            stack.addArrangedSubview(button(symbol: "arrow.up", o { $0.moveUp() }))
            stack.addArrangedSubview(button(symbol: "arrow.down", o { $0.moveDown() }))
            stack.addArrangedSubview(button(symbol: "checkmark.square", o { $0.cycleTask() }))
            stack.addArrangedSubview(button("[[ ]]", o { $0.insertSnippet("[[") }))
            stack.addArrangedSubview(button("#", o { $0.insertSnippet("#") }))
            stack.addArrangedSubview(button("/", o { $0.insertSnippet("/") }))
        } else {
            for item in items {
                stack.addArrangedSubview(button(item.title.replacingOccurrences(of: "\u{2028}", with: " "), accent: item.isCreate) { [weak self] in self?.owner?.acceptAutocomplete(item) })
            }
        }
    }
}
#endif

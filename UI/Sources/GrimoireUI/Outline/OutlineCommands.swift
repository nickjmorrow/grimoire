import Foundation

public struct OutlinePos: Equatable, Sendable {
    public var row: Int
    public var offset: Int          // UTF-16 offset into the row's text
    public init(row: Int, offset: Int) { self.row = row; self.offset = offset }
}

public struct OutlineSelection: Equatable, Sendable {
    public var anchor: OutlinePos
    public var head: OutlinePos
    public init(anchor: OutlinePos, head: OutlinePos) { self.anchor = anchor; self.head = head }
    public init(caret: OutlinePos) { anchor = caret; head = caret }
    public var rowRange: ClosedRange<Int> { min(anchor.row, head.row)...max(anchor.row, head.row) }
    public var isCaret: Bool { anchor == head }
}

public struct OutlineEdit: Equatable, Sendable {
    public var doc: OutlineDoc
    public var selection: OutlineSelection
}

/// Structural editing commands as pure functions on the outline. Each returns nil when it can't apply.
public enum OutlineCommands {
    // MARK: hierarchy

    public static func indent(_ doc: OutlineDoc, _ sel: OutlineSelection) -> OutlineEdit? {
        let first = sel.rowRange.lowerBound
        guard first > 0, doc.rows[first].depth <= doc.rows[first - 1].depth else { return nil }
        var rows = doc.rows
        let end = doc.subtreeRange(of: sel.rowRange.upperBound).upperBound
        for i in first..<end { rows[i].depth += 1 }
        return OutlineEdit(doc: OutlineDoc(rows: rows), selection: sel)
    }

    /// Logical outdent: the block (with its subtree) moves to just after its parent's subtree, so its later siblings stay put.
    public static func outdent(_ doc: OutlineDoc, _ sel: OutlineSelection) -> OutlineEdit? {
        let first = sel.rowRange.lowerBound
        guard doc.rows.indices.contains(first), doc.rows[first].depth > 0, let parent = doc.parentIndex(of: first) else { return nil }
        let end = doc.subtreeRange(of: sel.rowRange.upperBound).upperBound
        let parentEnd = doc.subtreeRange(of: parent).upperBound
        var rows = doc.rows
        var moved = Array(rows[first..<end])
        for i in moved.indices { moved[i].depth -= 1 }
        var shift = 0
        if parentEnd > end {
            rows.removeSubrange(first..<end)
            rows.insert(contentsOf: moved, at: parentEnd - moved.count)
            shift = parentEnd - end
        } else {
            rows.replaceSubrange(first..<end, with: moved)
        }
        return OutlineEdit(doc: OutlineDoc(rows: rows), selection: shifted(sel, by: shift))
    }

    public static func moveUp(_ doc: OutlineDoc, _ sel: OutlineSelection) -> OutlineEdit? {
        let first = sel.rowRange.lowerBound
        guard doc.rows.indices.contains(first) else { return nil }
        let end = doc.subtreeRange(of: sel.rowRange.upperBound).upperBound
        var j = first - 1
        while j >= 0, doc.rows[j].depth > doc.rows[first].depth { j -= 1 }
        guard j >= 0, doc.rows[j].depth == doc.rows[first].depth else { return nil }
        var rows = doc.rows
        let block = Array(rows[first..<end])
        rows.removeSubrange(first..<end)
        rows.insert(contentsOf: block, at: j)
        return OutlineEdit(doc: OutlineDoc(rows: rows), selection: shifted(sel, by: j - first))
    }

    public static func moveDown(_ doc: OutlineDoc, _ sel: OutlineSelection) -> OutlineEdit? {
        let first = sel.rowRange.lowerBound
        guard doc.rows.indices.contains(first) else { return nil }
        let end = doc.subtreeRange(of: sel.rowRange.upperBound).upperBound
        guard end < doc.rows.count, doc.rows[end].depth == doc.rows[first].depth else { return nil }
        let nextEnd = doc.subtreeRange(of: end).upperBound
        var rows = doc.rows
        let block = Array(rows[first..<end])
        rows.removeSubrange(first..<end)
        rows.insert(contentsOf: block, at: nextEnd - block.count)
        return OutlineEdit(doc: OutlineDoc(rows: rows), selection: shifted(sel, by: nextEnd - end))
    }

    // MARK: splitting and merging

    /// Enter. Empty nested block → outdent; caret at the start → empty block above; otherwise split at the caret.
    public static func split(_ doc: OutlineDoc, at pos: OutlinePos) -> OutlineEdit? {
        guard doc.rows.indices.contains(pos.row) else { return nil }
        var rows = doc.rows
        let row = rows[pos.row]
        let text = row.text as NSString
        let offset = min(max(pos.offset, 0), text.length)
        if row.text.isEmpty, row.depth > 0 { return outdent(doc, OutlineSelection(caret: pos)) }
        if offset == 0, !row.text.isEmpty {
            rows.insert(OutlineRow(blockID: nil, depth: row.depth, text: ""), at: pos.row)
            return OutlineEdit(doc: OutlineDoc(rows: rows), selection: OutlineSelection(caret: OutlinePos(row: pos.row + 1, offset: 0)))
        }
        let prefix = text.substring(to: offset), suffix = text.substring(from: offset)
        let hasOpenChildren = pos.row + 1 < rows.count && rows[pos.row + 1].depth > row.depth && !row.collapsed
        let depth = hasOpenChildren ? row.depth + 1 : row.depth
        let at = hasOpenChildren ? pos.row + 1 : doc.subtreeRange(of: pos.row).upperBound
        var newText = suffix
        var caret = 0
        if let marker = taskMarker(of: prefix), offset >= marker.utf16.count {
            newText = marker + suffix; caret = marker.utf16.count               // a task continues as a task
        }
        rows[pos.row].text = prefix
        rows.insert(OutlineRow(blockID: nil, depth: depth, text: newText), at: at)
        return OutlineEdit(doc: OutlineDoc(rows: rows), selection: OutlineSelection(caret: OutlinePos(row: at, offset: caret)))
    }

    /// Backspace at the start of a block: join it onto the previous visible block; its children become that block's children.
    public static func mergeBackward(_ doc: OutlineDoc, at row: Int) -> OutlineEdit? {
        guard row > 0, doc.rows.indices.contains(row) else { return nil }
        let hidden = doc.hiddenFlags()
        guard let p = (0..<row).last(where: { !hidden[$0] }) else { return nil }
        var rows = doc.rows
        let joinAt = (rows[p].text as NSString).length
        rows[p].text += rows[row].text
        let childRange = doc.subtreeRange(of: row)
        for k in (row + 1)..<childRange.upperBound {
            rows[k].depth = rows[k].depth - rows[row].depth - 1 + rows[p].depth + 1
        }
        rows.remove(at: row)
        return OutlineEdit(doc: OutlineDoc(rows: rows), selection: OutlineSelection(caret: OutlinePos(row: p, offset: joinAt)))
    }

    // MARK: state toggles

    public static func toggleCollapse(_ doc: OutlineDoc, row: Int) -> OutlineDoc? {
        guard doc.rows.indices.contains(row), doc.subtreeRange(of: row).count > 1 else { return nil }
        var rows = doc.rows
        rows[row].collapsed.toggle()
        return OutlineDoc(rows: rows)
    }

    /// Cycles the task marker of the selected blocks: none → TODO → DOING → DONE → none.
    public static func toggleTask(_ doc: OutlineDoc, _ sel: OutlineSelection) -> OutlineEdit? {
        guard !doc.rows.isEmpty, sel.rowRange.upperBound < doc.rows.count else { return nil }
        var rows = doc.rows
        var selection = sel
        for i in sel.rowRange {
            let old = taskMarker(of: rows[i].text) ?? ""
            let next = ["": "TODO ", "TODO ": "DOING ", "DOING ": "DONE ", "DONE ": ""][old] ?? ""
            rows[i].text = next + rows[i].text.dropFirst(old.count)
            let delta = next.count - old.count
            if selection.anchor.row == i { selection.anchor.offset = max(0, selection.anchor.offset + delta) }
            if selection.head.row == i { selection.head.offset = max(0, selection.head.offset + delta) }
        }
        return OutlineEdit(doc: OutlineDoc(rows: rows), selection: selection)
    }

    /// Makes the selected blocks headings of `level` (1–6); level 0 removes the heading.
    public static func setHeading(_ doc: OutlineDoc, _ sel: OutlineSelection, level: Int) -> OutlineEdit? {
        var rows = doc.rows
        var selection = sel
        for i in sel.rowRange {
            var text = rows[i].text
            var removed = 0
            if let r = text.range(of: "^#{1,6} ", options: .regularExpression) { removed = text.distance(from: r.lowerBound, to: r.upperBound); text.removeFirst(removed) }
            let prefix = level > 0 ? String(repeating: "#", count: level) + " " : ""
            rows[i].text = prefix + text
            let delta = prefix.count - removed
            if selection.anchor.row == i { selection.anchor.offset = max(0, selection.anchor.offset + delta) }
            if selection.head.row == i { selection.head.offset = max(0, selection.head.offset + delta) }
        }
        return OutlineEdit(doc: OutlineDoc(rows: rows), selection: selection)
    }

    // MARK: helpers

    /// "TODO ", "DOING " or "DONE " when the text starts with one.
    static func taskMarker(of text: String) -> String? {
        for m in ["TODO ", "DOING ", "DONE "] where text.hasPrefix(m) { return m }
        return nil
    }

    private static func shifted(_ sel: OutlineSelection, by rows: Int) -> OutlineSelection {
        OutlineSelection(anchor: OutlinePos(row: sel.anchor.row + rows, offset: sel.anchor.offset),
                         head: OutlinePos(row: sel.head.row + rows, offset: sel.head.offset))
    }
}

extension OutlineDoc {
    /// A row is hidden when any ancestor is collapsed.
    public func hiddenFlags() -> [Bool] {
        var out = [Bool](repeating: false, count: rows.count)
        var collapsedDepth: Int? = nil
        for (i, r) in rows.enumerated() {
            if let d = collapsedDepth {
                if r.depth > d { out[i] = true; continue }
                collapsedDepth = nil
            }
            if r.collapsed { collapsedDepth = r.depth }
        }
        return out
    }
}

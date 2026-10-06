import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Attributes that tie a paragraph of the text view to a block.
public enum OutlineAttr {
    public static let blockID = NSAttributedString.Key("grim.blockID")
    public static let depth = NSAttributedString.Key("grim.depth")
    public static let collapsed = NSAttributedString.Key("grim.collapsed")
    public static let hidden = NSAttributedString.Key("grim.hidden")
    /// A rendered diagram (NSImage) shown below the block, the key it was drawn for, or why drawing failed.
    public static let diagram = NSAttributedString.Key("grim.diagram")
    public static let diagramKey = NSAttributedString.Key("grim.diagramKey")
    public static let diagramError = NSAttributedString.Key("grim.diagramError")
}

/// The text-view representation of an outline: one paragraph per block, each ending in "\n".
/// A block's own line breaks are stored as U+2028 so that they stay inside the paragraph.
public enum OutlineStorage {
    static let lineSeparator = "\u{2028}"

    static func storageText(_ rowText: String) -> String { rowText.replacingOccurrences(of: "\n", with: lineSeparator) }
    static func rowText(_ storageText: String) -> String { storageText.replacingOccurrences(of: lineSeparator, with: "\n") }

    /// A row plus the facts about it that depend on its neighbours.
    public struct Derived: Equatable { public var row: OutlineRow; public var hidden: Bool; public var hasChildren: Bool }

    public static func derived(_ doc: OutlineDoc) -> [Derived] {
        let hidden = doc.hiddenFlags()
        return doc.rows.indices.map { Derived(row: doc.rows[$0], hidden: hidden[$0], hasChildren: $0 + 1 < doc.rows.count && doc.rows[$0 + 1].depth > doc.rows[$0].depth) }
    }

    public static func attributed(doc: OutlineDoc, base: [NSAttributedString.Key: Any], indent: CGFloat, gutter: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for d in derived(doc) { out.append(paragraph(d, base: base, indent: indent, gutter: gutter)) }
        return out
    }

    static func paragraph(_ d: Derived, base: [NSAttributedString.Key: Any], indent: CGFloat, gutter: CGFloat) -> NSAttributedString {
        let row = d.row, hidden = d.hidden
        var attrs = base
        let style = NSMutableParagraphStyle()
        if let basePS = base[.paragraphStyle] as? NSParagraphStyle { style.setParagraphStyle(basePS) }
        let x = CGFloat(row.depth) * indent + gutter
        style.firstLineHeadIndent = x
        style.headIndent = x
        attrs[.paragraphStyle] = style
        attrs[OutlineAttr.depth] = row.depth
        if let id = row.blockID { attrs[OutlineAttr.blockID] = id }
        if row.collapsed { attrs[OutlineAttr.collapsed] = true }
        if hidden { attrs[OutlineAttr.hidden] = true }
        if d.hasChildren { attrs[OutlineAttr.hasChildren] = true }
        return NSAttributedString(string: storageText(row.text) + "\n", attributes: attrs)
    }

    /// Ranges of every block paragraph, each including its terminating newline. Text after the final newline (the "tail",
    /// where the caret can land below the last block) counts as one more, unterminated, row.
    public static func rowRanges(in storage: NSAttributedString) -> [NSRange] {
        let s = storage.string as NSString
        var out: [NSRange] = []
        var start = 0
        var i = 0
        while i < s.length {
            if s.character(at: i) == 0x0A { out.append(NSRange(location: start, length: i + 1 - start)); start = i + 1 }
            i += 1
        }
        if start < s.length { out.append(NSRange(location: start, length: s.length - start)) }
        return out
    }

    static func isTerminated(_ r: NSRange, in s: NSString) -> Bool { r.length > 0 && s.character(at: NSMaxRange(r) - 1) == 0x0A }

    /// Reads the text view contents back into an outline.
    public static func doc(from storage: NSAttributedString) -> OutlineDoc {
        let s = storage.string as NSString
        let rows = rowRanges(in: storage).map { range -> OutlineRow in
            let textRange = NSRange(location: range.location, length: range.length - (isTerminated(range, in: s) ? 1 : 0))
            let attrs = storage.attributes(at: range.location, effectiveRange: nil)
            return OutlineRow(blockID: attrs[OutlineAttr.blockID] as? String, depth: attrs[OutlineAttr.depth] as? Int ?? 0,
                              text: rowText(s.substring(with: textRange)), collapsed: attrs[OutlineAttr.collapsed] as? Bool ?? false)
        }
        return OutlineDoc(rows: rows)
    }

    // MARK: selection mapping

    public static func selection(for range: NSRange, in storage: NSAttributedString) -> OutlineSelection {
        OutlineSelection(anchor: pos(range.location, in: storage), head: pos(range.location + range.length, in: storage))
    }

    static func pos(_ index: Int, in storage: NSAttributedString) -> OutlinePos {
        let ranges = rowRanges(in: storage)
        let s = storage.string as NSString
        guard !ranges.isEmpty else { return OutlinePos(row: 0, offset: 0) }
        func textLength(_ r: NSRange) -> Int { r.length - (isTerminated(r, in: s) ? 1 : 0) }
        for (i, r) in ranges.enumerated() where index < NSMaxRange(r) || (i == ranges.count - 1 && !isTerminated(r, in: s) && index <= NSMaxRange(r)) {
            return OutlinePos(row: i, offset: min(max(index - r.location, 0), textLength(r)))
        }
        let last = ranges.last!                      // after the final newline with no tail text: the end of the last row
        return OutlinePos(row: ranges.count - 1, offset: textLength(last))
    }

    public static func range(for sel: OutlineSelection, in storage: NSAttributedString) -> NSRange {
        let a = index(of: sel.anchor, in: storage), h = index(of: sel.head, in: storage)
        return NSRange(location: min(a, h), length: abs(h - a))
    }

    static func index(of p: OutlinePos, in storage: NSAttributedString) -> Int {
        let ranges = rowRanges(in: storage)
        let s = storage.string as NSString
        guard p.row < ranges.count else { return storage.length }
        let r = ranges[p.row]
        return r.location + min(p.offset, r.length - (isTerminated(r, in: s) ? 1 : 0))
    }

    // MARK: incremental updates

    /// The smallest windows of rows (in the old and new lists) that differ.
    public static func changedRows(old: [OutlineRow], new: [OutlineRow]) -> (old: Range<Int>, new: Range<Int>) {
        window(old, new)
    }

    static func window<T: Equatable>(_ old: [T], _ new: [T]) -> (old: Range<Int>, new: Range<Int>) {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        return (prefix..<(old.count - suffix), prefix..<(new.count - suffix))
    }

    /// The text replacement that turns `storage` (currently showing `old`) into `new`, limited to the paragraphs that differ
    /// (including ones whose hidden / has-children state changed). nil when nothing differs.
    public static func replacement(in storage: NSAttributedString, old: OutlineDoc, new: OutlineDoc,
                                   base: [NSAttributedString.Key: Any], indent: CGFloat, gutter: CGFloat) -> (range: NSRange, text: NSAttributedString)? {
        let o = derived(old), n = derived(new)
        let w = window(o, n)
        if w.old.isEmpty && w.new.isEmpty { return nil }
        let ranges = rowRanges(in: storage)
        let start = w.old.lowerBound < ranges.count ? ranges[w.old.lowerBound].location : storage.length
        let end = w.old.isEmpty ? start : NSMaxRange(ranges[w.old.upperBound - 1])
        let repl = NSMutableAttributedString()
        for i in w.new { repl.append(paragraph(n[i], base: base, indent: indent, gutter: gutter)) }
        // Rows added after an unterminated tail row must not run into it: end the tail first.
        if w.old.isEmpty, start == storage.length, storage.length > 0, !w.new.isEmpty,
           (storage.string as NSString).character(at: storage.length - 1) != 0x0A {
            let nl = NSMutableAttributedString(string: "\n", attributes: storage.attributes(at: storage.length - 1, effectiveRange: nil))
            nl.append(repl)
            return (NSRange(location: start, length: 0), nl)
        }
        return (NSRange(location: start, length: end - start), repl)
    }

    /// Applies `replacement` straight to a mutable storage (used by tests and by non-undoable refreshes).
    public static func replaceRows(in storage: NSMutableAttributedString, old: OutlineDoc, new: OutlineDoc,
                                   base: [NSAttributedString.Key: Any], indent: CGFloat, gutter: CGFloat) {
        if let r = replacement(in: storage, old: old, new: new, base: base, indent: indent, gutter: gutter) {
            storage.replaceCharacters(in: r.range, with: r.text)
        }
    }
}

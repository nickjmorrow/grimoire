import Foundation

/// Markdown outline text ⇄ outline rows (for copy, paste and export). Bullets are "- ", two spaces per level.
public enum OutlineMarkdown {
    /// Parses pasted text. Bulleted lines become blocks at their indent; otherwise each non-empty line is a block.
    /// Indented non-bullet lines continue the previous block.
    public static func parse(_ text: String) -> [OutlineRow] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let hasBullets = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
        var rows: [OutlineRow] = []
        var bulletIndent = 0
        for raw in lines {
            let line = raw.replacingOccurrences(of: "\t", with: "  ")
            let indent = line.prefix(while: { $0 == " " }).count
            let rest = String(line.dropFirst(indent))
            if rest.isEmpty { continue }
            if hasBullets {
                if rest.hasPrefix("- ") || rest == "-" {
                    rows.append(OutlineRow(blockID: nil, depth: indent / 2, text: String(rest.dropFirst(2))))
                    bulletIndent = indent
                } else if !rows.isEmpty {
                    rows[rows.count - 1].text += "\n" + String(line.dropFirst(min(indent, bulletIndent + 2)))
                } else {
                    rows.append(OutlineRow(blockID: nil, depth: 0, text: rest))
                }
            } else {
                rows.append(OutlineRow(blockID: nil, depth: 0, text: rest))
            }
        }
        var out = OutlineDoc(rows: rows).normalized { UUID().uuidString.lowercased() }.rows
        for i in out.indices { out[i].blockID = nil }
        return out
    }

    /// Renders rows as a Markdown outline relative to the shallowest row.
    public static func render(_ rows: [OutlineRow]) -> String {
        let base = rows.map(\.depth).min() ?? 0
        return rows.map { r in
            let pad = String(repeating: "  ", count: r.depth - base)
            let lines = r.text.components(separatedBy: "\n")
            return pad + "- " + lines[0] + lines.dropFirst().map { "\n" + pad + "  " + $0 }.joined()
        }.joined(separator: "\n")
    }
}

extension OutlineCommands {
    /// Inserts pasted rows after the current block's subtree (or replaces it when it is empty). Caret ends on the last pasted row.
    public static func paste(_ doc: OutlineDoc, at pos: OutlinePos, rows pasted: [OutlineRow]) -> OutlineEdit? {
        guard !pasted.isEmpty, doc.rows.indices.contains(pos.row) || doc.rows.isEmpty else { return nil }
        var rows = doc.rows
        if rows.isEmpty {
            rows = pasted
            return OutlineEdit(doc: OutlineDoc(rows: rows), selection: OutlineSelection(caret: OutlinePos(row: rows.count - 1, offset: (rows.last!.text as NSString).length)))
        }
        let current = rows[pos.row]
        let base = pasted.map(\.depth).min() ?? 0
        let shifted = pasted.map { OutlineRow(blockID: nil, depth: $0.depth - base + current.depth, text: $0.text) }
        let at: Int
        if current.text.isEmpty && doc.subtreeRange(of: pos.row).count == 1 {
            rows.remove(at: pos.row); at = pos.row
        } else {
            at = doc.subtreeRange(of: pos.row).upperBound
        }
        rows.insert(contentsOf: shifted, at: at)
        let last = at + shifted.count - 1
        return OutlineEdit(doc: OutlineDoc(rows: rows), selection: OutlineSelection(caret: OutlinePos(row: last, offset: (shifted.last!.text as NSString).length)))
    }
}

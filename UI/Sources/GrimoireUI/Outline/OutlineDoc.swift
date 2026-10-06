import GrimoireCore
import Foundation

/// One block as the editor sees it: a line of the page with a depth. Text uses "\n" for line breaks inside a block.
public struct OutlineRow: Equatable, Sendable {
    public var blockID: String?
    public var depth: Int
    public var text: String
    public var collapsed: Bool
    public init(blockID: String?, depth: Int, text: String, collapsed: Bool = false) {
        self.blockID = blockID; self.depth = depth; self.text = text; self.collapsed = collapsed
    }
}

/// A page as a flat list of rows. The parent of a row is the nearest earlier row that is shallower.
public struct OutlineDoc: Equatable, Sendable {
    public var rows: [OutlineRow]
    public init(rows: [OutlineRow]) { self.rows = rows }

    public init(tree: [BlockNode]) {
        var out: [OutlineRow] = []
        func walk(_ nodes: [BlockNode], depth: Int) {
            for n in nodes {
                out.append(OutlineRow(blockID: n.block.id, depth: depth, text: n.block.text, collapsed: n.block.collapsed))
                walk(n.children, depth: depth + 1)
            }
        }
        walk(tree, depth: 0)
        rows = out
    }

    /// Existing order keys of every block in a tree, by block id.
    public static func keys(tree: [BlockNode]) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ nodes: [BlockNode]) { for n in nodes { out[n.block.id] = n.block.orderKey; walk(n.children) } }
        walk(tree)
        return out
    }

    /// Depth can't jump by more than one level, the first row is top-level, and every row has a unique id.
    public func normalized(newID: () -> String) -> OutlineDoc {
        var out = rows
        var seen = Set<String>()
        for i in out.indices {
            let maxDepth = i == 0 ? 0 : out[i - 1].depth + 1
            out[i].depth = max(0, min(out[i].depth, maxDepth))
            if let id = out[i].blockID, !id.isEmpty, seen.insert(id).inserted { continue }
            let fresh = newID()
            out[i].blockID = fresh
            seen.insert(fresh)
        }
        return OutlineDoc(rows: out)
    }

    public func parentIndex(of i: Int) -> Int? {
        guard rows.indices.contains(i) else { return nil }
        var j = i - 1
        while j >= 0 { if rows[j].depth < rows[i].depth { return j }; j -= 1 }
        return nil
    }

    /// The row and all rows nested under it.
    public func subtreeRange(of i: Int) -> Range<Int> {
        var end = i + 1
        while end < rows.count && rows[end].depth > rows[i].depth { end += 1 }
        return i..<end
    }
}

import Foundation
import ArgumentParser
import GrimoireCore

/// Turns Markdown (nested `- ` bullets, 2 spaces per level, indented continuation lines) into block drafts.
enum MarkdownBlocks {
    struct Draft { var text: String; var depth: Int }

    static func parse(_ markdown: String) -> [Draft] {
        var drafts: [Draft] = []
        var bulletIndent = 0
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "  ")
            let indent = line.prefix(while: { $0 == " " }).count
            let rest = String(line.dropFirst(indent))
            if rest.hasPrefix("- ") || rest == "-" {
                drafts.append(Draft(text: String(rest.dropFirst(2)), depth: indent / 2))
                bulletIndent = indent
            } else if drafts.isEmpty {
                if !rest.isEmpty { drafts.append(Draft(text: rest, depth: 0)); bulletIndent = -2 }
            } else {
                drafts[drafts.count - 1].text += "\n" + String(line.dropFirst(min(indent, bulletIndent + 2)))
            }
        }
        return drafts.map { Draft(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), depth: $0.depth) }
            .filter { !$0.text.isEmpty }
    }
}

struct Placement {
    var pageID: String
    var parentID: String?
    var afterKey: String?
    var beforeKey: String?
}

func newID() -> String { UUID().uuidString.lowercased() }

func lastKey(_ g: Graph, pageID: String, parentID: String?) throws -> String? {
    try g.db.read {
        try String.fetchOne($0, sql: "SELECT order_key FROM blocks WHERE page_id = ? AND parent_id IS ? ORDER BY order_key DESC LIMIT 1",
                            arguments: [pageID, parentID])
    }
}

func nextKey(_ g: Graph, pageID: String, parentID: String?, after key: String) throws -> String? {
    try g.db.read {
        try String.fetchOne($0, sql: "SELECT order_key FROM blocks WHERE page_id = ? AND parent_id IS ? AND order_key > ? ORDER BY order_key LIMIT 1",
                            arguments: [pageID, parentID, key])
    }
}

/// Where new or moved blocks go: after a block, as the last child of a block, or at the end of a page.
func placement(_ g: Graph, page: String?, parent: String?, after: String?) throws -> Placement {
    func block(_ id: String) throws -> Block {
        guard let b = try g.db.read({ try Block.fetchOne($0, key: id) }) else { throw GraphError.blockNotFound(id) }
        return b
    }
    if let after {
        let b = try block(after)
        return Placement(pageID: b.pageId, parentID: b.parentId, afterKey: b.orderKey,
                         beforeKey: try nextKey(g, pageID: b.pageId, parentID: b.parentId, after: b.orderKey))
    }
    if let parent {
        let p = try block(parent)
        return Placement(pageID: p.pageId, parentID: p.id, afterKey: try lastKey(g, pageID: p.pageId, parentID: p.id), beforeKey: nil)
    }
    guard let page else { eprint("give --after, --parent or --page"); throw ExitCode(1) }
    guard let p = try g.page(titled: page) else { throw GraphError.pageNotFound(page) }
    return Placement(pageID: p.id, parentID: nil, afterKey: try lastKey(g, pageID: p.id, parentID: nil), beforeKey: nil)
}

func insertOps(_ drafts: [MarkdownBlocks.Draft], at place: Placement) -> (ops: [Op], ids: [String]) {
    var ops: [Op] = [], ids: [String] = []
    var ancestors: [String] = []
    var lastKeys: [String: String] = [:]
    for d in drafts {
        let depth = min(d.depth, ancestors.count)
        ancestors = Array(ancestors.prefix(depth))
        let parent = depth == 0 ? place.parentID : ancestors[depth - 1]
        let slot = parent ?? ""
        let key = OrderKey.between(lastKeys[slot] ?? (depth == 0 ? place.afterKey : nil), depth == 0 ? place.beforeKey : nil)
        lastKeys[slot] = key
        let id = newID()
        ops.append(.insertBlock(id: id, pageID: place.pageID, parentID: parent, orderKey: key, text: d.text))
        ids.append(id); ancestors.append(id)
    }
    return (ops, ids)
}

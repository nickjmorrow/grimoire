import Foundation
import GrimoireCore

func pageDict(_ p: Page) -> [String: Any] {
    ["id": p.id, "title": p.title, "kind": p.kind.rawValue, "journalDate": p.journalDate as Any? ?? NSNull(),
     "favorite": p.favorite, "updatedAt": p.updatedAt]
}

func blockDict(_ n: BlockNode) -> [String: Any] {
    var d: [String: Any] = ["id": n.block.id, "pageId": n.block.pageId, "parentId": n.block.parentId as Any? ?? NSNull(),
                            "text": n.block.text, "author": n.block.author.rawValue]
    if !n.children.isEmpty { d["children"] = n.children.map(blockDict) }
    return d
}

func flatBlockDict(_ b: Block) -> [String: Any] {
    ["id": b.id, "pageId": b.pageId, "parentId": b.parentId as Any? ?? NSNull(), "text": b.text, "author": b.author.rawValue]
}

func printJSON(_ value: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8)
    print(String(decoding: data, as: UTF8.self))
}

func outline(_ nodes: [BlockNode], depth: Int = 0) -> String {
    nodes.map { n in
        let pad = String(repeating: "  ", count: depth)
        let lines = n.block.text.components(separatedBy: "\n")
        var s = pad + "- " + lines[0] + "  [\(n.block.id)]\n"
        for l in lines.dropFirst() { s += pad + "  " + l + "\n" }
        return s + outline(n.children, depth: depth + 1)
    }.joined()
}

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

import Foundation
import GRDB

/// Renders pages as Logseq-style Markdown. The mirror is derived output; the database stays the source of truth.
public enum MarkdownMirror {
    public static func relativePath(for page: Page) -> String {
        if page.kind == .journal, let date = page.journalDate { return "journals/\(date).md" }
        let name = page.title.replacingOccurrences(of: "/", with: "___").replacingOccurrences(of: ":", with: "%3A")
        return "pages/\(name).md"
    }

    public static func render(page: Page, tree: [BlockNode], referencedBlockIDs: Set<String>) -> String {
        var out = ""
        var nodes = tree[...]
        // A first block that only holds `key:: value` lines is the page's own properties: write it bare, as Logseq does.
        if let first = nodes.first, first.children.isEmpty, isPropertiesOnly(first.block.text) {
            out += first.block.text + "\n\n"
            nodes = nodes.dropFirst()
        }
        func emit(_ node: BlockNode, depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            var lines = node.block.text.components(separatedBy: "\n")
            out += pad + "- " + lines.removeFirst() + "\n"
            for line in lines { out += pad + "  " + line + "\n" }
            if node.block.collapsed && !node.children.isEmpty { out += pad + "  collapsed:: true\n" }
            if referencedBlockIDs.contains(node.block.id) { out += pad + "  id:: \(node.block.id)\n" }
            for child in node.children { emit(child, depth: depth + 1) }
        }
        for node in nodes { emit(node, depth: 0) }
        return out
    }

    private static func isPropertiesOnly(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        return !lines.isEmpty && lines.allSatisfy { $0.contains(":: ") }
            && BlockSyntax.parse(text).properties.count == lines.count
    }
}

extension Graph {
    private var mirrorFolder: URL { folder.appendingPathComponent("mirror") }
    private var manifestURL: URL { mirrorFolder.appendingPathComponent(".manifest.json") }

    private func loadManifest() -> [String: String] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveManifest(_ m: [String: String]) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try enc.encode(m).write(to: manifestURL, options: .atomic)
    }

    /// Writes (or removes) the mirror file for one page, following renames through a small manifest.
    public func writeMirror(pageID: String) throws {
        var manifest = loadManifest()
        try writeMirror(pageID: pageID, manifest: &manifest)
        try saveManifest(manifest)
    }

    private func writeMirror(pageID: String, manifest: inout [String: String]) throws {
        let fm = FileManager.default
        let (page, referenced): (Page?, Set<String>) = try db.read { db in
            guard let page = try Page.fetchOne(db, key: pageID) else { return (nil, []) }
            let refs = try String.fetchAll(db, sql: """
                SELECT DISTINCT l.to_block FROM links l JOIN blocks b ON b.id = l.to_block
                WHERE l.to_block IS NOT NULL AND b.page_id = ?
                """, arguments: [pageID])
            return (page, Set(refs))
        }
        let nodes = page == nil ? [] : try self.tree(pageID: pageID)
        if let old = manifest[pageID] { try? fm.removeItem(at: mirrorFolder.appendingPathComponent(old)) }
        guard let page, !nodes.isEmpty else { manifest[pageID] = nil; return }
        let rel = MarkdownMirror.relativePath(for: page)
        let url = mirrorFolder.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(MarkdownMirror.render(page: page, tree: nodes, referencedBlockIDs: referenced).utf8).write(to: url, options: .atomic)
        manifest[pageID] = rel
    }

    /// Rewrites every page's file and removes files for pages that no longer exist or have no content.
    public func writeMirrorAll() throws {
        var manifest = loadManifest()
        let ids = try db.read { try String.fetchAll($0, sql: "SELECT id FROM pages") }
        for id in ids { try writeMirror(pageID: id, manifest: &manifest) }
        for stale in Set(manifest.keys).subtracting(ids) { try writeMirror(pageID: stale, manifest: &manifest) }
        try saveManifest(manifest)
    }
}

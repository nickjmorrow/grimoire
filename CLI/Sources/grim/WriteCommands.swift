import ArgumentParser
import Foundation
import GrimoireCore

/// Resolves where to write: an existing page, or the page-creating op to run first (journal aliases make journals).
private func resolveTarget(_ g: Graph, _ target: String) throws -> (pageID: String, prelude: [Op]) {
    let title = clean(target)
    if let jd = JournalDate.parse(title, today: .today()) {
        if try g.db.read({ try Page.fetchOne($0, key: jd.pageID) }) != nil { return (jd.pageID, []) }
        return (jd.pageID, [.createPage(id: jd.pageID, title: jd.title(), kind: .journal, journalDate: jd.iso)])
    }
    if let p = try g.page(titled: title) { return (p.id, []) }
    let id = Graph.pageID(forTitle: title)
    return (id, [.createPage(id: id, title: title, kind: .page, journalDate: nil)])
}

/// One command is one logged op, so one undo reverts all of it.
private func performAsOne(_ g: Graph, _ ops: [Op], author: Author) throws {
    try g.perform(ops.count == 1 ? ops : [.batch(ops)], author: author)
}

struct Append: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add Markdown blocks to the end of a page or journal ('today').")
    @OptionGroup var g: GlobalOptions
    @Argument var target: String
    @Argument var markdown: String
    func run() throws {
        try guarded {
            let graph = try g.open(), who = try g.actor(), start = nowMillis()
            let drafts = MarkdownBlocks.parse(clean(markdown))
            guard !drafts.isEmpty else { eprint("nothing to add"); throw ExitCode(1) }
            let (pageID, prelude) = try resolveTarget(graph, target)
            let place = Placement(pageID: pageID, parentID: nil, afterKey: try lastKey(graph, pageID: pageID, parentID: nil), beforeKey: nil)
            let (ops, ids) = insertOps(drafts, at: place)
            try performAsOne(graph, prelude + ops, author: who)
            try mirrorTouched(graph, since: start)
            if g.json { printJSON(["pageId": pageID, "blockIds": ids] as [String: Any]) } else { ids.forEach { print($0) } }
        }
    }
}

struct Insert: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Insert Markdown blocks after a block, under a block, or at the end of a page.")
    @OptionGroup var g: GlobalOptions
    @Option var page: String?
    @Option var parent: String?
    @Option var after: String?
    @Argument var markdown: String
    func run() throws {
        try guarded {
            let graph = try g.open(), who = try g.actor(), start = nowMillis()
            let drafts = MarkdownBlocks.parse(clean(markdown))
            guard !drafts.isEmpty else { eprint("nothing to add"); throw ExitCode(1) }
            let (ops, ids) = insertOps(drafts, at: try placement(graph, page: page, parent: parent, after: after))
            try performAsOne(graph, ops, author: who)
            try mirrorTouched(graph, since: start)
            if g.json { printJSON(["blockIds": ids]) } else { ids.forEach { print($0) } }
        }
    }
}

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Replace a block's text.")
    @OptionGroup var g: GlobalOptions
    @Argument var block: String
    @Argument var text: String
    func run() throws {
        try guarded {
            let graph = try g.open(), start = nowMillis()
            try graph.perform([.editText(blockID: block, text: clean(text))], author: try g.actor())
            try mirrorTouched(graph, since: start)
            if g.json { printJSON(["ok": true]) }
        }
    }
}

struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Move a block (with its children) after a block, under a block, or to the end of a page.")
    @OptionGroup var g: GlobalOptions
    @Argument var block: String
    @Option var page: String?
    @Option var parent: String?
    @Option var after: String?
    func run() throws {
        try guarded {
            let graph = try g.open(), start = nowMillis()
            let place = try placement(graph, page: page, parent: parent, after: after)
            let oldPage = try graph.db.read { try Block.fetchOne($0, key: block)?.pageId }
            try graph.perform([.moveBlock(blockID: block, pageID: place.pageID, parentID: place.parentID,
                                          orderKey: OrderKey.between(place.afterKey, place.beforeKey))], author: try g.actor())
            try mirrorTouched(graph, since: start)
            if let oldPage { try graph.writeMirror(pageID: oldPage) }
            if g.json { printJSON(["ok": true]) }
        }
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a block and its children (undoable).")
    @OptionGroup var g: GlobalOptions
    @Argument var block: String
    func run() throws {
        try guarded {
            let graph = try g.open(), start = nowMillis()
            try graph.perform([.deleteBlock(blockID: block)], author: try g.actor())
            try mirrorTouched(graph, since: start)
            if g.json { printJSON(["ok": true]) }
        }
    }
}

struct CreatePage: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create-page", abstract: "Create an empty page.")
    @OptionGroup var g: GlobalOptions
    @Argument var title: String
    func run() throws {
        try guarded {
            let graph = try g.open()
            try graph.perform([.createPage(id: Graph.pageID(forTitle: clean(title)), title: clean(title), kind: .page, journalDate: nil)], author: try g.actor())
            let page = try graph.page(titled: clean(title))!
            if g.json { printJSON(pageDict(page)) } else { print(page.id) }
        }
    }
}

struct DeletePage: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete-page", abstract: "Delete a page and all its blocks (undoable). A page other pages link to is emptied instead; the links stay.")
    @OptionGroup var g: GlobalOptions
    @Argument var title: String
    func run() throws {
        try guarded {
            let graph = try g.open()
            guard let page = try graph.page(titled: clean(title)) else { throw GraphError.pageNotFound(title) }
            let linking = try graph.backlinks(pageID: page.id).count
            try graph.perform([try graph.deletePageOp(pageID: page.id)], author: try g.actor())
            try graph.writeMirror(pageID: page.id)          // removes the page's mirror file
            if g.json { printJSON(["ok": true, "deleted": page.title, "linkedFrom": linking]) }
            else { print(linking > 0 ? "emptied \(page.title) (still linked from \(linking) page\(linking == 1 ? "" : "s"))" : "deleted \(page.title)") }
        }
    }
}

struct RenamePage: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename-page", abstract: "Rename a page and rewrite every link and tag that points to it.")
    @OptionGroup var g: GlobalOptions
    @Argument var old: String
    @Argument var new: String
    func run() throws {
        try guarded {
            let graph = try g.open(), start = nowMillis()
            guard let page = try graph.page(titled: old) else { throw GraphError.pageNotFound(old) }
            try graph.perform([.renamePage(id: page.id, title: clean(new))], author: try g.actor())
            try mirrorTouched(graph, since: start)
            if g.json { printJSON(["ok": true]) }
        }
    }
}

struct Favorite: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Favorite a page (or --off to remove it).")
    @OptionGroup var g: GlobalOptions
    @Argument var page: String
    @Flag var off = false
    func run() throws {
        try guarded {
            let graph = try g.open()
            guard let p = try graph.page(titled: page) else { throw GraphError.pageNotFound(page) }
            try graph.perform([.setFavorite(pageID: p.id, favorite: !off, order: nil)], author: try g.actor())
            if g.json { printJSON(["ok": true]) }
        }
    }
}

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Undo the last change(s) by the --author (default claude; 'any' undoes anyone's).")
    @OptionGroup var g: GlobalOptions
    @Option var last = 1
    func run() throws {
        try guarded {
            let graph = try g.open()
            let filter: Author? = g.author == "any" ? nil : try g.actor()
            let result = try graph.undoDetailed(author: filter, count: last)
            try graph.writeMirrorAll()
            if g.json { printJSON(["undone": result.undone, "skipped": result.skipped] as [String: Any]) }
            else {
                print("undid \(result.undone) change(s)")
                for s in result.skipped { eprint("skipped \(s)") }
            }
        }
    }
}

struct Attach: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Import a file as an asset; with --page also append it as an image/link block.")
    @OptionGroup var g: GlobalOptions
    @Argument var file: String
    @Option var page: String?
    func run() throws {
        try guarded {
            let graph = try g.open(), who = try g.actor(), start = nowMillis()
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { eprint("no such file: \(file)"); throw ExitCode(2) }
            let asset = try graph.importAsset(from: url, author: who)
            let ext = url.pathExtension
            let rel = "assets/" + (ext.isEmpty ? asset.hash : "\(asset.hash).\(ext)")
            if let page {
                let (pageID, prelude) = try resolveTarget(graph, page)
                let place = Placement(pageID: pageID, parentID: nil, afterKey: try lastKey(graph, pageID: pageID, parentID: nil), beforeKey: nil)
                try performAsOne(graph, prelude + insertOps([.init(text: "![\(asset.filename)](\(rel))", depth: 0)], at: place).ops, author: who)
                try mirrorTouched(graph, since: start)
            }
            if g.json { printJSON(["hash": asset.hash, "path": rel]) } else { print(rel) }
        }
    }
}

struct Reindex: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rebuild links, tags, properties and search from block text.")
    @OptionGroup var g: GlobalOptions
    func run() throws {
        try guarded { try g.open().reindex(); if g.json { printJSON(["ok": true]) } else { print("reindexed") } }
    }
}

struct Mirror: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write the Markdown mirror for one page, or --all.")
    @OptionGroup var g: GlobalOptions
    @Flag var all = false
    @Argument var page: String?
    func run() throws {
        try guarded {
            let graph = try g.open()
            if all { try graph.writeMirrorAll() }
            else if let page {
                guard let p = try graph.page(titled: page) else { throw GraphError.pageNotFound(page) }
                try graph.writeMirror(pageID: p.id)
            } else { eprint("give a page or --all"); throw ExitCode(1) }
            if g.json { printJSON(["ok": true]) }
        }
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write the whole graph as lossless JSON to a file.")
    @OptionGroup var g: GlobalOptions
    @Argument var path: String
    func run() throws {
        try guarded {
            try g.open().exportJSON(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            if g.json { printJSON(["ok": true]) }
        }
    }
}

struct Backup: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Copy the database and assets into a folder, check the copy, and thin old copies (14 daily, 8 weekly).")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "Folder to keep backups in.") var folder: String
    @Option(help: "Daily copies to keep.") var daily = 14
    @Option(help: "Weekly copies to keep.") var weekly = 8
    func run() throws {
        try guarded {
            let r = try g.open().backup(to: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath), daily: daily, weekly: weekly)
            if g.json { printJSON(["path": r.database.path, "assetsCopied": r.assetsCopied, "pruned": r.pruned.count]) }
            else { print("\(r.database.path) (+\(r.assetsCopied) assets, \(r.pruned.count) old copies removed)") }
        }
    }
}

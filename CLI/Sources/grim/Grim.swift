import ArgumentParser
import Foundation
import GrimoireCore

struct GlobalOptions: ParsableArguments {
    @Option(help: "Graph folder (default: $GRIMOIRE_GRAPH or ~/Grimoire).") var graph: String?
    @Flag(help: "Print JSON.") var json = false
    @Option(help: "Who is acting: me or claude (default). For undo and changes it is also the filter; 'any' means everyone.") var author: String?
    @Option(help: "Device name recorded in the op log.") var device: String?

    var graphURL: URL {
        let path = graph ?? ProcessInfo.processInfo.environment["GRIMOIRE_GRAPH"] ?? (NSHomeDirectory() + "/Grimoire")
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    func open() throws -> Graph {
        try Graph(folder: graphURL, device: device ?? "cli-" + (ProcessInfo.processInfo.hostName))
    }

    /// The acting author; `any` is only meaningful as an undo filter.
    func actor() throws -> Author {
        guard let a = Author(rawValue: author ?? "claude") else {
            eprint("--author must be me, claude or any"); throw ExitCode(1)
        }
        return a
    }
}

/// Maps Core errors to the documented exit codes: 2 not found, 3 conflict, 4 read-only violation.
func guarded(_ body: () throws -> Void) throws {
    do { try body() } catch let e as GraphError {
        switch e {
        case .pageNotFound(let x): eprint("page not found: \(x)"); throw ExitCode(2)
        case .blockNotFound(let x): eprint("block not found: \(x)"); throw ExitCode(2)
        case .titleTaken(let x): eprint("a page titled '\(x)' already exists"); throw ExitCode(3)
        case .cycle: eprint("a block can't move under itself"); throw ExitCode(3)
        case .readOnlyViolation: eprint("query is read-only"); throw ExitCode(4)
        case .undoBlocked(let why): eprint("can't undo: \(why)"); throw ExitCode(3)
        case .pageInUse(let t): eprint("page '\(t)' is linked from other blocks"); throw ExitCode(3)
        }
    }
}

/// Rewrites the Markdown mirror for every page changed since `start`.
func mirrorTouched(_ g: Graph, since start: Int64) throws {
    let ids = try g.db.read { db in
        try String.fetchAll(db, sql: "SELECT id FROM pages WHERE updated_at >= ?", arguments: [start])
    }
    for id in ids { try g.writeMirror(pageID: id) }
}

func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// Text arguments that start with "-" (a bullet list, "-5 degrees") would be read as options.
/// `main` marks them with a leading U+0001 and `clean` removes it where the text is used.
let textMarker = "\u{1}"
func clean(_ s: String) -> String { s.replacingOccurrences(of: textMarker, with: "") }
private func protect(_ arg: String) -> String {
    guard arg.hasPrefix("-"), arg.wholeMatch(of: /--?[A-Za-z][A-Za-z-]*(=.*)?/) == nil else { return arg }
    return textMarker + arg
}

@main
struct Grim: ParsableCommand {
    /// Global options may come before the subcommand (`grim --graph X today`); they are moved after it.
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst().map(protect))
        var leading: [String] = []
        while let first = args.first, ["--graph", "--author", "--device", "--json"].contains(first.split(separator: "=").first.map(String.init) ?? first) {
            leading.append(args.removeFirst())
            if first != "--json", !first.contains("="), !args.isEmpty { leading.append(args.removeFirst()) }
        }
        Grim.main(args + leading)
    }

    static let configuration = CommandConfiguration(
        commandName: "grim",
        abstract: "Read and edit a Grimoire graph.",
        subcommands: [
            Today.self, PageCmd.self, Journal.self, Search.self, Backlinks.self, Recent.self, Favorites.self,
            TagCmd.self, Prop.self, Query.self, Changes.self,
            Append.self, Insert.self, Edit.self, Move.self, Delete.self, CreatePage.self, DeletePage.self, RenamePage.self,
            Favorite.self, Undo.self, Attach.self, Reindex.self, Mirror.self, Export.self, ImportLogseq.self, Cards.self, SyncCmd.self, SyncSetup.self, SyncStatusCmd.self,
        ])
}

import ArgumentParser
import Foundation
import GrimoireCore

struct ImportLogseq: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-logseq",
        abstract: "Import a Logseq DB graph (from `logseq graph export --type edn`) into an empty Grimoire graph.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The EDN export file.") var export: String
    @Option(help: "Logseq's assets folder (<graph>/assets), to copy images and files.") var assets: String?
    @Flag(help: "Report what would be imported without touching the graph.") var dryRun = false
    @Flag(help: "Bring Logseq changes made since the first import into a graph that is already in use (nothing edited here is overwritten).") var update = false

    func run() throws {
        let url = URL(fileURLWithPath: (export as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { eprint("can't read \(export)"); throw ExitCode(2) }
        let assetsURL = assets.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        do {
            let datoms = try Datoms(exportText: text)
            if update {
                let graph = try g.open()
                let r = try LogseqUpdate.apply(datoms: datoms, assetsFolder: assetsURL, to: graph)
                try graph.writeMirrorAll()
                if g.json { print(String(decoding: try JSONEncoder.sorted.encode(r), as: UTF8.self)) }
                else {
                    print("added \(r.pagesAdded) page(s) and \(r.blocksAdded) block(s); updated \(r.blocksUpdated); removed \(r.blocksRemoved); \(r.assetsAdded) new asset(s); \(r.cardsUpdated) card schedule(s)")
                    if !r.keptYours.isEmpty { print("kept your version of \(r.keptYours.count) block(s) edited in both places") }
                }
                return
            }
            let report = dryRun
                ? try LogseqImporter.dryRun(datoms: datoms, assetsFolder: assetsURL)
                : try LogseqImporter.importGraph(datoms: datoms, assetsFolder: assetsURL, into: try g.open())
            if g.json {
                let data = try JSONEncoder.sorted.encode(report)
                print(String(decoding: data, as: UTF8.self))
            } else { print(Self.describe(report, dryRun: dryRun)) }
            if !dryRun { try g.open().writeMirrorAll() }
        } catch ImportError.graphNotEmpty {
            eprint("the target graph already has content; import only into an empty graph"); throw ExitCode(3)
        } catch ImportError.notADatomExport {
            eprint("that isn't a Logseq datom export (use: logseq graph export --type edn)"); throw ExitCode(1)
        } catch let e as EDNError {
            eprint("export file isn't valid EDN at byte \(e.offset): \(e.message)"); throw ExitCode(1)
        }
    }

    static func describe(_ r: ImportReport, dryRun: Bool) -> String {
        var lines = [dryRun ? "Dry run (nothing written):" : "Imported:",
                     "  pages \(r.pages), journals \(r.journals), blocks \(r.blocks), tasks \(r.tasks)",
                     "  tags \(r.tags), properties \(r.properties), favorites \(r.favorites), assets \(r.assets)",
                     "  skipped (recycle bin) \(r.skippedRecycled), merged duplicate pages \(r.mergedDuplicatePages)"]
        if !r.unresolvedReferences.isEmpty { lines.append("  unresolved references (\(r.unresolvedReferences.count)): " + r.unresolvedReferences.prefix(5).joined(separator: ", ") + (r.unresolvedReferences.count > 5 ? ", …" : "")) }
        if !r.missingAssetFiles.isEmpty { lines.append("  missing asset files (\(r.missingAssetFiles.count)): " + r.missingAssetFiles.prefix(5).joined(separator: ", ") + (r.missingAssetFiles.count > 5 ? ", …" : "")) }
        for w in r.warnings { lines.append("  warning: \(w)") }
        return lines.joined(separator: "\n")
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }
}

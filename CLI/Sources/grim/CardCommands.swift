import ArgumentParser
import Foundation
import GrimoireCore

private func scope(page: String?, chapter: String?, _ g: Graph) throws -> CardScope {
    var pageID: String?
    if let page {
        guard let p = try g.page(titled: page) else { throw GraphError.pageNotFound(page) }
        pageID = p.id
    }
    if let chapter { return .chapter(pageID: pageID, name: chapter) }
    return pageID.map(CardScope.page) ?? .all
}

private func cardDict(_ c: Card) -> [String: Any] {
    var d: [String: Any] = ["id": c.blockID, "page": c.pageTitle, "pageId": c.pageID, "front": c.front, "back": c.back, "new": c.isNew]
    if let s = c.state { d["due"] = s.due; d["reps"] = s.reps; d["lapses"] = s.lapses; d["stability"] = s.stability; d["difficulty"] = s.difficulty }
    return d
}

struct Cards: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cards", abstract: "Flashcards: blocks tagged #card (front = text, back = children), scheduled with FSRS.",
        subcommands: [CardsStatus.self, CardsNext.self, CardsReview.self, CardsImport.self])
}

struct CardsStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "How many cards are due, new and total.")
    @OptionGroup var g: GlobalOptions
    @Option(help: "Only this page.") var page: String?
    @Option(help: "Only cards under a block whose text contains this (e.g. \"ch 5\").") var chapter: String?
    func run() throws {
        try guarded {
            let graph = try g.open()
            let c = try graph.cardCounts(scope: try scope(page: page, chapter: chapter, graph))
            if g.json { printJSON(["due": c.due, "new": c.new, "total": c.total]) } else { print("due \(c.due), new \(c.new), total \(c.total)") }
        }
    }
}

struct CardsNext: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "next", abstract: "The next cards to study (due first, then new).")
    @OptionGroup var g: GlobalOptions
    @Option(help: "Only this page.") var page: String?
    @Option(help: "Only cards under a block whose text contains this.") var chapter: String?
    @Option(help: "How many.") var limit = 1
    @Option(help: "At most this many unseen cards.") var newLimit = 10
    func run() throws {
        try guarded {
            let graph = try g.open()
            let cards = try graph.nextCards(scope: try scope(page: page, chapter: chapter, graph), limit: limit, newLimit: newLimit)
            if g.json { printJSON(cards.map(cardDict)); return }
            if cards.isEmpty { print("nothing due"); return }
            for c in cards {
                print("[\(c.blockID)] \(c.pageTitle)\(c.isNew ? " (new)" : "")\n  Q: \(c.front)")
                for l in c.back { print("  A: \(l)") }
            }
        }
    }
}

struct CardsReview: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "review", abstract: "Record an answer: again, hard, good or easy.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The card's block id.") var block: String
    @Argument(help: "again | hard | good | easy") var rating: String
    func run() throws {
        try guarded {
            guard let r = ["again": Rating.again, "hard": .hard, "good": .good, "easy": .easy][rating.lowercased()] else {
                eprint("rating must be again, hard, good or easy"); throw ExitCode(1)
            }
            let graph = try g.open()
            let s = try graph.review(blockID: block, rating: r, author: try g.actor())
            let due = Date(timeIntervalSince1970: Double(s.due) / 1000)
            if g.json { printJSON(["id": block, "due": s.due, "stability": s.stability, "difficulty": s.difficulty, "reps": s.reps, "lapses": s.lapses]) }
            else { print("next review \(due.formatted(date: .abbreviated, time: .shortened))") }
        }
    }
}

struct CardsImport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import-logseq", abstract: "Add Logseq review schedules to a graph that was imported before cards were supported.")
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The EDN export file.") var export: String
    func run() throws {
        let url = URL(fileURLWithPath: (export as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { eprint("can't read \(export)"); throw ExitCode(2) }
        let n = try LogseqCards.importInto(try g.open(), datoms: try Datoms(exportText: text))
        print("imported \(n) card schedule\(n == 1 ? "" : "s")")
    }
}

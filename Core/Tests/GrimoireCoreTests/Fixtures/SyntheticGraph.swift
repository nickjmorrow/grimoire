import Foundation
@testable import GrimoireCore

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// A realistic graph: ordinary pages plus two years of journals, nested blocks, links, tags and properties.
enum SyntheticGraph {
    static let vocabulary = ["focaccia", "flour", "dough", "recipe", "career", "interview", "meeting", "notes", "idea", "project",
                             "design", "swift", "database", "replication", "journal", "walk", "puppy", "mood", "reading", "chapter",
                             "leader", "follower", "consensus", "latency", "index", "query", "sleep", "workout", "grocery", "plan"]
    static let tags = (0..<40).map { "tag\($0)" }

    @discardableResult
    static func build(in folder: URL, pages: Int, blocksPerPage: Int, seed: UInt64) throws -> Graph {
        var rng = SeededGenerator(seed: seed)
        let g = try Graph(folder: folder, device: "synthetic")
        let journalCount = min(730, pages / 3)
        var titles: [String] = []
        var creates: [Op] = []
        var journalDates: [JournalDate] = []
        var day = JournalDate(iso: "2024-10-05")!
        for _ in 0..<journalCount { journalDates.append(day); day = day.adding(days: 1) }
        for i in 0..<(pages - journalCount) {
            let title = "Page \(i) \(vocabulary[i % vocabulary.count])"
            titles.append(title)
            creates.append(.createPage(id: "p\(i)", title: title, kind: .page, journalDate: nil))
        }
        try g.perform(creates, author: .import)
        var pageIDs = (0..<(pages - journalCount)).map { "p\($0)" }
        for d in journalDates { pageIDs.append(try g.ensureJournal(d, author: .import)) }

        for (n, pageID) in pageIDs.enumerated() {
            var ops: [Op] = []
            var ids: [String] = []
            var lastKey: [String: String] = [:]
            for b in 0..<blocksPerPage {
                var words = (0..<Int.random(in: 4...12, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }
                if Int.random(in: 0..<4, using: &rng) == 0 { words.append("[[\(titles.randomElement(using: &rng)!)]]") }
                if Int.random(in: 0..<10, using: &rng) == 0 { words.append("#\(tags.randomElement(using: &rng)!)") }
                var text = words.joined(separator: " ")
                if Int.random(in: 0..<20, using: &rng) == 0 { text += "\nserves:: \(Int.random(in: 1...8, using: &rng))" }
                let parent: String? = (!ids.isEmpty && Int.random(in: 0..<10, using: &rng) < 3) ? ids.randomElement(using: &rng) : nil
                let slot = parent ?? ""
                let key = OrderKey.between(lastKey[slot], nil)
                lastKey[slot] = key
                let id = "b\(n)-\(b)"
                ids.append(id)
                ops.append(.insertBlock(id: id, pageID: pageID, parentID: parent, orderKey: key, text: text))
            }
            try g.perform(ops, author: .import)
        }
        return g
    }
}

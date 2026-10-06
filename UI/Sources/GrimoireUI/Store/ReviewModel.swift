import Foundation
import GrimoireCore
import Observation

/// One flashcard study session: a queue of cards, reveal, rate, undo. Cards answered "again" come back at the end of the queue.
@MainActor @Observable
public final class ReviewModel {
    public private(set) var queue: [Card] = []
    public private(set) var revealed = false
    public private(set) var answered = 0
    public private(set) var counts = CardCounts(due: 0, new: 0, total: 0)
    public private(set) var lastRating: Rating?
    @ObservationIgnored private var undoStack: [(card: Card, opID: Int64)] = []
    @ObservationIgnored private let graph: Graph
    @ObservationIgnored private let scope: CardScope
    @ObservationIgnored private let clock: () -> Int64
    @ObservationIgnored private let fsrs = FSRS()
    public var batchSize = 30
    public var newPerSession = 10

    public init(graph: Graph, scope: CardScope, clock: @escaping () -> Int64 = { Graph.nowMillis() }) {
        self.graph = graph; self.scope = scope; self.clock = clock
        load()
    }

    public var current: Card? { queue.first }
    public var isFinished: Bool { queue.isEmpty }
    public var canUndo: Bool { !undoStack.isEmpty }

    public func load() {
        counts = (try? graph.cardCounts(scope: scope, now: clock())) ?? counts
        queue = (try? graph.nextCards(scope: scope, now: clock() + 20 * 60_000, limit: batchSize, newLimit: newPerSession)) ?? []
        revealed = false
    }

    public func reveal() { if current != nil { revealed = true } }

    /// What each rating would schedule, as short labels ("10m", "4d"), for the buttons.
    public var intervalLabels: [Rating: String] {
        guard let c = current else { return [:] }
        let now = clock()
        return fsrs.preview(c.state, now: now).mapValues { Self.label(millis: $0.due - now) }
    }

    public func rate(_ rating: Rating) {
        guard let c = current, revealed else { return }
        let opID: Int64
        do { opID = try graph.reviewLogged(blockID: c.blockID, rating: rating, now: clock()).opID } catch { return }
        undoStack.append((c, opID))
        queue.removeFirst()
        answered += 1
        lastRating = rating
        if rating == .again, let refreshed = try? graph.card(blockID: c.blockID) { queue.append(refreshed) }
        revealed = false
        counts = (try? graph.cardCounts(scope: scope, now: clock())) ?? counts
        if queue.isEmpty { load() }
    }

    /// Takes back the last answer and shows that card again.
    public func undo() {
        guard let last = undoStack.popLast() else { return }
        _ = try? graph.undoOp(last.opID)
        queue.removeAll { $0.blockID == last.card.blockID }
        if let fresh = try? graph.card(blockID: last.card.blockID) { queue.insert(fresh, at: 0) }
        answered = max(0, answered - 1)
        revealed = false
        counts = (try? graph.cardCounts(scope: scope, now: clock())) ?? counts
    }

    static func label(millis: Int64) -> String {
        let m = Double(millis) / 60_000
        if m < 60 { return "\(max(1, Int(m.rounded())))m" }
        let d = m / 1440
        if d < 1 { return "\(Int((m / 60).rounded()))h" }
        if d < 30 { return "\(Int(d.rounded()))d" }
        if d < 365 { return "\(Int((d / 30).rounded()))mo" }
        return String(format: "%.1fy", d / 365)
    }
}

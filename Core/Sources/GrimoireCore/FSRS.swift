import Foundation

public enum Rating: Int, Codable, Sendable, CaseIterable { case again = 1, hard, good, easy }
public enum CardPhase: Int, Codable, Sendable { case new = 0, learning, review, relearning }

/// A card's memory state. Times are milliseconds since the epoch.
public struct CardState: Codable, Equatable, Sendable {
    public var due: Int64
    public var stability: Double
    public var difficulty: Double
    public var reps: Int
    public var lapses: Int
    public var phase: CardPhase
    public var lastReview: Int64?
    public init(due: Int64, stability: Double, difficulty: Double, reps: Int, lapses: Int, phase: CardPhase, lastReview: Int64?) {
        self.due = due; self.stability = stability; self.difficulty = difficulty; self.reps = reps; self.lapses = lapses; self.phase = phase; self.lastReview = lastReview
    }
}

/// FSRS-4.5 scheduling (the open spaced-repetition algorithm), with fixed default weights, no fuzz and a 10-minute relearn step.
public struct FSRS: Sendable {
    public var weights: [Double] = [0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474, 0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.587, 0.2272, 2.8755]
    public var requestRetention = 0.9
    public var maximumIntervalDays = 36_500.0
    public var againStepMillis: Int64 = 10 * 60_000

    static let decay = -0.5
    static let factor = 19.0 / 81.0
    static let day = 86_400_000.0

    public init() {}

    public func retrievability(_ s: CardState, now: Int64) -> Double {
        guard let last = s.lastReview, s.stability > 0 else { return 1 }
        let t = max(0, Double(now - last) / Self.day)
        return pow(1 + Self.factor * t / s.stability, Self.decay)
    }

    /// The state after answering `rating` at `now` (`state` nil = a card never reviewed).
    public func next(_ state: CardState?, _ rating: Rating, now: Int64) -> CardState { preview(state, now: now)[rating]! }

    /// All four outcomes, with intervals ordered again < hard < good < easy.
    public func preview(_ state: CardState?, now: Int64) -> [Rating: CardState] {
        var out: [Rating: CardState] = [:]
        var days: [Rating: Int] = [:]
        for r in Rating.allCases {
            let (s, d) = memory(after: r, from: state, now: now)
            let days1 = r == .again ? 0 : max(1, Int(min(maxInterval(s), maximumIntervalDays).rounded()))
            days[r] = days1
            let reps = (state?.reps ?? 0) + 1
            let lapsed = r == .again && state?.phase == .review
            let phase: CardPhase = r == .again ? (lapsed || state?.phase == .relearning ? .relearning : .learning) : .review
            out[r] = CardState(due: now, stability: s, difficulty: d, reps: reps, lapses: (state?.lapses ?? 0) + (lapsed ? 1 : 0), phase: phase, lastReview: now)
        }
        var hard = days[.hard]!, good = days[.good]!, easy = days[.easy]!
        good = max(good, hard); if good == hard, hard < Int(maximumIntervalDays), state != nil { good = hard + 1 }
        hard = min(hard, good); easy = max(easy, good + 1)
        out[.again]!.due = now + againStepMillis
        out[.hard]!.due = now + Int64(hard) * 86_400_000
        out[.good]!.due = now + Int64(good) * 86_400_000
        out[.easy]!.due = now + Int64(min(Double(easy), maximumIntervalDays)) * 86_400_000
        return out
    }

    private func maxInterval(_ stability: Double) -> Double {
        stability / Self.factor * (pow(requestRetention, 1 / Self.decay) - 1)
    }

    private func clampD(_ d: Double) -> Double { min(10, max(1, d)) }

    private func memory(after r: Rating, from state: CardState?, now: Int64) -> (stability: Double, difficulty: Double) {
        let w = weights, g = Double(r.rawValue)
        guard let s = state, s.reps > 0, s.lastReview != nil else {
            return (max(0.01, w[r.rawValue - 1]), clampD(w[4] - (g - 3) * w[5]))
        }
        let rec = retrievability(s, now: now)
        let d0good = clampD(w[4])
        let newD = clampD(w[7] * d0good + (1 - w[7]) * (s.difficulty - w[6] * (g - 3)))
        if r == .again {
            let stab = w[11] * pow(s.difficulty, -w[12]) * (pow(s.stability + 1, w[13]) - 1) * exp(w[14] * (1 - rec))
            return (max(0.01, min(stab, s.stability)), newD)
        }
        let hardPenalty = r == .hard ? w[15] : 1, easyBonus = r == .easy ? w[16] : 1
        let stab = s.stability * (1 + exp(w[8]) * (11 - s.difficulty) * pow(s.stability, -w[9]) * (exp(w[10] * (1 - rec)) - 1) * hardPenalty * easyBonus)
        return (max(0.01, stab), newD)
    }
}

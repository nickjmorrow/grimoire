import Foundation
import Testing
@testable import GrimoireCore

@Suite struct FSRSTests {
    let fsrs = FSRS()
    let t0: Int64 = 1_790_000_000_000
    let day: Int64 = 86_400_000

    @Test func newCardGoodGetsTheDefaultInitialStabilityAndAFourDayInterval() {
        let s = fsrs.next(nil, .good, now: t0)
        #expect(abs(s.stability - 3.7145) < 1e-9)
        #expect(abs(s.difficulty - 5.1618) < 1e-9)
        #expect(s.due == t0 + 4 * day)
        #expect(s.reps == 1 && s.lapses == 0 && s.phase == .review)
    }

    @Test func initialStabilityAndIntervalsOrderByRating() {
        let p = fsrs.preview(nil, now: t0)
        #expect(p[.again]!.stability < p[.hard]!.stability)
        #expect(p[.hard]!.stability < p[.good]!.stability)
        #expect(p[.good]!.stability < p[.easy]!.stability)
        #expect(p[.again]!.due == t0 + 10 * 60_000)
        #expect(p[.again]!.phase == .learning)
        #expect(p[.hard]!.due < p[.good]!.due && p[.good]!.due < p[.easy]!.due)
    }

    @Test func difficultyMovesWithRatingAndStaysInRange() {
        var s = fsrs.next(nil, .good, now: t0)
        let d0 = s.difficulty
        let harder = fsrs.next(s, .again, now: s.due)
        #expect(harder.difficulty > d0)
        for _ in 0..<40 { s = fsrs.next(s, .again, now: s.due) }
        #expect(s.difficulty <= 10 && s.difficulty >= 1)
        var e = fsrs.next(nil, .easy, now: t0)
        for _ in 0..<40 { e = fsrs.next(e, .easy, now: e.due) }
        #expect(e.difficulty >= 1)
    }

    @Test func recallGrowsStabilityAndLapseShrinksItAndCountsALapse() {
        let s = fsrs.next(nil, .good, now: t0)
        let ok = fsrs.next(s, .good, now: s.due)
        #expect(ok.stability > s.stability)
        let lapse = fsrs.next(s, .again, now: s.due)
        #expect(lapse.stability < s.stability)
        #expect(lapse.lapses == 1 && lapse.phase == .relearning)
        #expect(lapse.reps == 2)
    }

    @Test func lateReviewsGainMoreStabilityThanOnTimeOnes() {
        let s = fsrs.next(nil, .good, now: t0)
        let onTime = fsrs.next(s, .good, now: s.due)
        let late = fsrs.next(s, .good, now: s.due + 30 * day)
        #expect(late.stability > onTime.stability)
    }

    @Test func retrievabilityIsOneNowAndNinetyPercentAtTheStabilityInterval() {
        let s = fsrs.next(nil, .good, now: t0)
        #expect(fsrs.retrievability(s, now: t0) > 0.999)
        let atS = t0 + Int64(s.stability * Double(day))
        #expect(abs(fsrs.retrievability(s, now: atS) - 0.9) < 1e-6)
    }

    @Test func intervalsAreCappedAndAtLeastADay() {
        var s = fsrs.next(nil, .easy, now: t0)
        for _ in 0..<60 { s = fsrs.next(s, .easy, now: s.due) }
        #expect(s.due - s.lastReview! <= 36_500 * day)
        let hard = fsrs.next(nil, .hard, now: t0)
        #expect(hard.due - t0 >= day)
    }
}

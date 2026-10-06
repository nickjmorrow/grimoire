import Foundation
import Testing
@testable import GrimoireUI

struct TimeOfDayTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }
    private func date(_ h: Int, _ m: Int = 0, day: Int = 6) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))! }

    @Test func hoursMapToPhases() {
        let expected: [(Int, TimeOfDay)] = [(0, .night), (4, .night), (5, .dawn), (8, .dawn), (9, .day), (16, .day), (17, .dusk), (20, .dusk), (21, .night), (23, .night)]
        for (hour, phase) in expected { #expect(TimeOfDay.at(date(hour, 30), calendar: cal) == phase, "hour \(hour)") }
    }

    @Test func nextChangeIsTheNextBoundary() {
        #expect(TimeOfDay.nextChange(after: date(10), calendar: cal) == date(17))
        #expect(TimeOfDay.nextChange(after: date(17), calendar: cal) == date(21))
        #expect(TimeOfDay.nextChange(after: date(22), calendar: cal) == date(5, day: 7))
        #expect(TimeOfDay.nextChange(after: date(2), calendar: cal) == date(5))
    }

    @Test func nightIsTheOnlyPrimaryIcon() {
        #expect(TimeOfDay.night.iOSIconName == nil)
        #expect(TimeOfDay.allCases.filter { $0.iOSIconName == nil }.count == 1)
        #expect(Set(TimeOfDay.allCases.map(\.macImageName)).count == 4)
    }
}

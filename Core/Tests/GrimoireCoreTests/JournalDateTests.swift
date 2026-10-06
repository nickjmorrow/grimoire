import Testing
@testable import GrimoireCore

@Suite struct JournalDateTests {
    let today = JournalDate(iso: "2026-10-05")!

    @Test func pageIDIsDeterministicUUIDv5() {
        #expect(JournalDate(iso: "2026-10-05")!.pageID == "bd08754d-0f15-540c-9e70-8879385ec362")
        #expect(JournalDate(iso: "2024-02-29")!.pageID == "53c0e598-e602-58b5-9c67-2231446b703b")
    }

    @Test func defaultTitle() {
        #expect(today.title() == "2026-10-05 Monday")
    }

    @Test func parsesAliases() {
        for text in ["2026-10-05", "Oct 5th, 2026", "October 5, 2026", "2026-10-05 Monday", "today", "Today"] {
            #expect(JournalDate.parse(text, today: today) == today, "\(text)")
        }
        #expect(JournalDate.parse("yesterday", today: today) == JournalDate(iso: "2026-10-04"))
        #expect(JournalDate.parse("tomorrow", today: today) == JournalDate(iso: "2026-10-06"))
        #expect(JournalDate.parse("Oct 32nd, 2026", today: today) == nil)
        #expect(JournalDate.parse("recipe", today: today) == nil)
    }

    @Test func rejectsInvalidISO() {
        #expect(JournalDate(iso: "2026-02-30") == nil)
        #expect(JournalDate(iso: "2026-13-01") == nil)
        #expect(JournalDate(iso: "nope") == nil)
    }

    @Test func ordersChronologically() {
        #expect(JournalDate(iso: "2026-09-30")! < JournalDate(iso: "2026-10-01")!)
    }
}

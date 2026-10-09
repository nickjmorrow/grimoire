import Foundation

public struct JournalDate: Hashable, Comparable, Codable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    private static let namespace = UUID(uuidString: "08114a04-830e-52fa-811e-417f24c79f6a")!
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    public init?(year: Int, month: Int, day: Int) {
        var comps = DateComponents(); comps.year = year; comps.month = month; comps.day = day
        guard let date = Self.calendar.date(from: comps) else { return nil }
        let back = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    private var date: Date {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        return Self.calendar.date(from: c)!
    }

    public func title(format: String = "yyyy-MM-dd EEEE") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.string(from: date)
    }

    /// UUIDv5 of the ISO date under the journal namespace, so every device derives the same id.
    public var pageID: String { UUIDv5.make(namespace: Self.namespace, name: iso) }

    public static func < (a: JournalDate, b: JournalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public func adding(days: Int) -> JournalDate {
        let d = Self.calendar.date(byAdding: .day, value: days, to: date)!
        let c = Self.calendar.dateComponents([.year, .month, .day], from: d)
        return JournalDate(year: c.year!, month: c.month!, day: c.day!)!
    }

    public static func today(in tz: TimeZone = .current, now: Date = Date()) -> JournalDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: now)
        return JournalDate(year: c.year!, month: c.month!, day: c.day!)!
    }

    /// Resolves ISO dates, "Oct 5th, 2026", "October 5, 2026", an ISO date followed by a weekday, and today/yesterday/tomorrow.
    public static func parse(_ text: String, today: JournalDate) -> JournalDate? {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "today": return today
        case "yesterday": return today.adding(days: -1)
        case "tomorrow": return today.adding(days: 1)
        default: break
        }
        if let m = t.firstMatch(of: /^(\d{4}-\d{2}-\d{2})(?:\s+[A-Za-z]+)?$/) { return JournalDate(iso: String(m.1)) }
        if let m = t.firstMatch(of: /^([A-Za-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})$/) {
            let prefix = String(m.1.lowercased().prefix(3))
            guard let idx = months.firstIndex(of: prefix), let d = Int(m.2), let y = Int(m.3) else { return nil }
            return JournalDate(year: y, month: idx + 1, day: d)
        }
        return nil
    }
}

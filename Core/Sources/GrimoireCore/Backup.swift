import Foundation
import GRDB

public struct BackupResult: Sendable {
    public var database: URL
    public var assetsCopied: Int
    public var pruned: [URL]
}

extension Graph {
    static let backupPrefix = "grimoire-", backupSuffix = ".sqlite"

    /// Copies the database (SQLite online backup, safe while the app is open) and any new assets into `folder`, checks the copy, then thins old
    /// copies: the newest per day for `daily` days, plus the newest per ISO week for `weekly` weeks.
    @discardableResult
    public func backup(to folder: URL, now: Date = Date(), daily: Int = 14, weekly: Int = 8) throws -> BackupResult {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(Self.backupPrefix + Self.stamp(now) + Self.backupSuffix)
        let partial = target.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        do {
            let dest = try DatabaseQueue(path: partial.path)
            try db.backup(to: dest)
            let check = try dest.read { try String.fetchAll($0, sql: "PRAGMA integrity_check") }
            guard check == ["ok"] else { throw BackupError.corrupt(check.joined(separator: "; ")) }
            try dest.close()
        } catch { try? fm.removeItem(at: partial); throw error }
        try? fm.removeItem(at: target)
        try fm.moveItem(at: partial, to: target)

        var copied = 0
        let src = self.folder.appendingPathComponent("assets"), dst = folder.appendingPathComponent("assets")
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where !fm.fileExists(atPath: dst.appendingPathComponent(name).path) {
            try fm.copyItem(at: src.appendingPathComponent(name), to: dst.appendingPathComponent(name)); copied += 1
        }
        return BackupResult(database: target, assetsCopied: copied, pruned: try Self.prune(folder, daily: daily, weekly: weekly))
    }

    /// Backups in `folder`, newest first.
    public static func backups(in folder: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(backupPrefix) && $0.hasSuffix(backupSuffix) }
        return names.sorted(by: >).map { folder.appendingPathComponent($0) }
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: d)
    }

    static func prune(_ folder: URL, daily: Int, weekly: Int) throws -> [URL] {
        var cal = Calendar(identifier: .iso8601); cal.timeZone = .current
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        var keep = Set<URL>(), days = Set<String>(), weeks = Set<String>()
        let all = backups(in: folder)
        for url in all {                                                 // newest first
            let stem = String(url.lastPathComponent.dropFirst(backupPrefix.count).dropLast(backupSuffix.count))
            guard let date = f.date(from: stem) else { keep.insert(url); continue }      // not ours to judge
            let day = String(stem.prefix(8))
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date), week = "\(c.yearForWeekOfYear!)-\(c.weekOfYear!)"
            if days.count < daily, days.insert(day).inserted { keep.insert(url) }
            if weeks.count < weekly, weeks.insert(week).inserted { keep.insert(url) }
        }
        var removed: [URL] = []
        for url in all where !keep.contains(url) { try FileManager.default.removeItem(at: url); removed.append(url) }
        return removed
    }
}

public enum BackupError: Error, CustomStringConvertible {
    case corrupt(String)
    public var description: String { if case .corrupt(let s) = self { return "backup failed its integrity check: \(s)" }; return "" }
}

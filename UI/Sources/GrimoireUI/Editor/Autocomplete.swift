import Foundation
import GrimoireCore

public enum AutocompleteKind: Equatable, Sendable { case page, tag, blockRef, command }

/// What the user is in the middle of typing: `[[query`, `#query`, `((query` or `/query`.
public struct AutocompleteTrigger: Equatable, Sendable {
    public var kind: AutocompleteKind
    public var query: String
    /// UTF-16 range in the block's text, from the trigger characters up to the caret.
    public var range: NSRange
}

public struct AutocompleteItem: Equatable, Sendable {
    public var title: String
    public var detail: String?
    /// Text that replaces the trigger.
    public var insertion: String
    /// Where the caret goes, counted back from the end of the insertion (inside a code fence, say).
    public var caretBack: Int = 0
    public var isCreate = false
}

/// Where candidates come from. All closures take the user's query and are called on the main thread.
public struct AutocompleteSource {
    public var pages: (String) -> [String]
    public var tags: (String) -> [String]
    public var blocks: (String) -> [(id: String, text: String)]
    public init(pages: @escaping (String) -> [String] = { _ in [] }, tags: @escaping (String) -> [String] = { _ in [] },
                blocks: @escaping (String) -> [(id: String, text: String)] = { _ in [] }) {
        self.pages = pages; self.tags = tags; self.blocks = blocks
    }
}

public struct AutocompleteEdit: Equatable, Sendable {
    public var range: NSRange
    public var text: String
    /// Caret position (UTF-16, in the block's text) after the edit.
    public var caret: Int
}

public enum Autocomplete {
    // MARK: trigger detection

    public static func detect(text: String, caret: Int) -> AutocompleteTrigger? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        let before = ns.substring(to: caret) as NSString
        // [[ and (( : the last opener on this line with no closer after it.
        for (open, close, kind) in [("[[", "]]", AutocompleteKind.page), ("((", "))", .blockRef)] {
            let r = before.range(of: open, options: .backwards)
            guard r.location != NSNotFound else { continue }
            let q = before.substring(from: NSMaxRange(r))
            if q.contains(close) || q.contains("\u{2028}") || q.contains(open) || (kind == .page && q.contains("]")) { continue }
            return AutocompleteTrigger(kind: kind, query: q, range: NSRange(location: r.location, length: caret - r.location))
        }
        // # and / : a word start (start of text or after whitespace), then no whitespace up to the caret.
        var i = caret
        while i > 0 {
            let c = before.character(at: i - 1)
            if let u = UnicodeScalar(c), CharacterSet.whitespacesAndNewlines.contains(u) || c == 0x2028 { return nil }
            if c == 0x23 || c == 0x2F {                                            // # or /
                let atWordStart = i - 1 == 0 || { let p = before.character(at: i - 2); return UnicodeScalar(p).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false || p == 0x2028 }()
                guard atWordStart else { return nil }
                let q = before.substring(from: i)
                if c == 0x23 {
                    if q.contains("#") || q.contains("[") || q.contains("]") { return nil }
                    return AutocompleteTrigger(kind: .tag, query: q, range: NSRange(location: i - 1, length: caret - i + 1))
                }
                if q.contains("/") { return nil }
                return AutocompleteTrigger(kind: .command, query: q, range: NSRange(location: i - 1, length: caret - i + 1))
            }
            i -= 1
        }
        return nil
    }

    // MARK: ranking

    /// nil = no match. Higher is better: exact > prefix > word prefix > contains > fuzzy (in-order letters or a small typo).
    public static func score(query: String, title: String) -> Int? {
        let q = query.lowercased(), t = title.lowercased()
        if q.isEmpty { return 1 }
        if t == q { return 1000 }
        if t.hasPrefix(q) { return 800 - min(t.count - q.count, 100) }
        if t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 600 - min(t.count, 100) }
        if t.contains(q) { return 400 - min(t.count, 100) }
        return Graph.fuzzyScore(query: q, title: t).map { min($0, 100) }
    }

    // MARK: candidates

    public static func items(for trigger: AutocompleteTrigger, source: AutocompleteSource, limit: Int = 12, today: JournalDate = .today()) -> [AutocompleteItem] {
        switch trigger.kind {
        case .page:
            let titles = source.pages(trigger.query)
            var out = titles.prefix(limit).map { AutocompleteItem(title: $0, detail: nil, insertion: "[[\($0)]]") }
            let q = trigger.query.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty, !titles.contains(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) {
                out.append(AutocompleteItem(title: q, detail: "Create page", insertion: "[[\(q)]]", isCreate: true))
            }
            return out
        case .tag:
            var seen = Set<String>(), out: [AutocompleteItem] = []
            for name in source.tags(trigger.query) + source.pages(trigger.query) where seen.insert(name.lowercased()).inserted && out.count < limit {
                out.append(AutocompleteItem(title: name, detail: nil, insertion: tagText(name)))
            }
            let q = trigger.query
            if !q.isEmpty, !seen.contains(q.lowercased()) { out.append(AutocompleteItem(title: q, detail: "New tag", insertion: tagText(q), isCreate: true)) }
            return out
        case .blockRef:
            guard !trigger.query.isEmpty else { return [] }
            return source.blocks(trigger.query).prefix(limit).map { AutocompleteItem(title: $0.text, detail: nil, insertion: "((\($0.id)))") }
        case .command:
            return commands(today: today).compactMap { c -> (Int, AutocompleteItem)? in
                guard let s = max(score(query: trigger.query, title: c.title) ?? -1, c.keywords.compactMap { score(query: trigger.query, title: $0) }.max() ?? -1) as Int?, s >= 0 else { return nil }
                return (s, c.item)
            }.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        }
    }

    static func tagText(_ name: String) -> String { name.contains(where: \.isWhitespace) ? "#[[\(name)]]" : "#\(name)" }

    struct Command { var title: String; var keywords: [String]; var item: AutocompleteItem }

    static func commands(today: JournalDate) -> [Command] {
        func c(_ title: String, _ detail: String?, _ text: String, back: Int = 0, _ kw: [String] = []) -> Command {
            Command(title: title, keywords: kw, item: AutocompleteItem(title: title, detail: detail, insertion: text, caretBack: back))
        }
        let nl = "\u{2028}"
        return [
            c("Heading 1", "#", "# ", ["h1", "title"]), c("Heading 2", "##", "## ", ["h2"]), c("Heading 3", "###", "### ", ["h3"]),
            c("TODO", "task", "TODO ", ["task", "todo", "checkbox"]), c("DOING", "task", "DOING ", ["doing", "progress"]), c("DONE", "task", "DONE ", ["done"]),
            c("Code block", "```", "```" + nl + nl + "```", back: 4, ["code", "fence"]),
            c("Mermaid diagram", "```mermaid", "```mermaid" + nl + nl + "```", back: 4, ["diagram", "flowchart", "graph"]),
            c("Quote", ">", "> ", ["blockquote"]), c("Divider", "---", "---", ["hr", "rule", "line"]),
            c("Today", today.iso, "[[\(today.title())]]", ["date", "journal"]),
            c("Property", "key:: value", "property:: ", ["prop", "attribute"]),
            c("Card", "flashcard", " #card", ["flashcard", "srs"]),
        ]
    }

    // MARK: inserting

    /// The edit that replaces the trigger with the chosen item. Auto-paired closers right after the caret are consumed.
    public static func edit(for item: AutocompleteItem, trigger: AutocompleteTrigger, in text: String) -> AutocompleteEdit {
        let ns = text as NSString
        var range = trigger.range
        let end = NSMaxRange(range)
        let closer: String? = trigger.kind == .page ? "]]" : trigger.kind == .blockRef ? "))" : nil
        if let closer, end + closer.utf16.count <= ns.length, ns.substring(with: NSRange(location: end, length: closer.utf16.count)) == closer {
            range.length += closer.utf16.count
        }
        var insertion = item.insertion
        if trigger.kind == .tag || trigger.kind == .page || trigger.kind == .blockRef, !item.isCreate || true {
            // a space after a finished tag/link keeps typing flowing, unless text already follows
            let after = NSMaxRange(range)
            if trigger.kind == .tag, after >= ns.length || ns.character(at: after) != 0x20 { insertion += " " }
        }
        let caret = range.location + (insertion as NSString).length - item.caretBack
        return AutocompleteEdit(range: range, text: insertion, caret: caret)
    }
}

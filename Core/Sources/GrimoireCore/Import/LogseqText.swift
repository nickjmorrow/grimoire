import Foundation

/// Turns one Logseq block (title + status + tags + properties) into Grimoire block text.
extension Run {
    func className(_ tag: Int64) -> (builtin: String?, user: String?) {
        guard let ident = d.keyword(tag, ":db/ident") else { return (nil, nil) }
        if ident.hasPrefix(":logseq.class/") { return (String(ident.dropFirst(":logseq.class/".count)), nil) }
        if ident.hasPrefix(":user.class/") { return (nil, d.string(tag, ":block/title")) }
        return (nil, nil)
    }

    func userClassNames(of e: Int64) -> [String] { d.refs(e, ":block/tags").compactMap { className($0).user } }
    func builtinClassNames(of e: Int64) -> Set<String> { Set(d.refs(e, ":block/tags").compactMap { className($0).builtin }) }

    static func hashtag(_ name: String) -> String {
        let plain = !name.isEmpty && !name.contains(where: { $0.isWhitespace || ",.;:!?)(]}\"'`#[".contains($0) })
        return plain ? "#\(name)" : "#[[\(name)]]"
    }

    mutating func renderBlock(_ e: Int64) -> String {
        var text = resolveReferences(in: d.string(e, ":block/title") ?? "")
        text = rewriteAssetPaths(in: text)
        if text.isEmpty, let link = d.int(e, ":block/link") { text = linkText(link) }      // a checklist item that only points at something
        let builtin = builtinClassNames(of: e)
        let displayType = d.keyword(e, ":logseq.property.node/display-type")
        let isCode = displayType == ":code" || builtin.contains("Code")
        if let uuid = d.uuid(e), d.first(e, ":logseq.property.asset/checksum") != nil {
            let ext = d.string(e, ":logseq.property.asset/type") ?? ""
            let path = assetMap["\(uuid).\(ext)"] ?? { missing.insert("\(uuid).\(ext)"); return "assets/\(uuid).\(ext)" }()
            text = "![\(d.string(e, ":block/title") ?? "")](\(path))"
        } else if isCode {
            text = "```\(d.string(e, ":logseq.property.code/lang") ?? "")\n\(text)\n```"
        } else {
            if displayType == ":quote" || builtin.contains("Quote") { text = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") }
            if let h = d.int(e, ":logseq.property/heading"), (1...6).contains(h), !text.hasPrefix("#") { text = String(repeating: "#", count: Int(h)) + " " + text }
            if let n = numbering[e] { text = "\(n). " + text }
            if let status = d.int(e, ":logseq.property/status"), let ident = d.keyword(status, ":db/ident") {
                let marker = ["todo": "TODO", "doing": "DOING", "done": "DONE"][String(ident.split(separator: ".").last ?? "")]
                if let marker { text = text.isEmpty ? marker : "\(marker) \(text)"; report.tasks += 1 }
            }
        }
        var suffix = userClassNames(of: e).map(Run.hashtag)
        if builtin.contains("Card") { suffix.append("#card") }
        if builtin.contains("Template") { suffix.append("#template") }
        if !suffix.isEmpty {
            if isCode {                                   // tags go on their own line after the fence
                text += "\n" + suffix.joined(separator: " ")
            } else {
                let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                let first = ([String(parts.first ?? "")] + suffix).filter { !$0.isEmpty }.joined(separator: " ")
                text = parts.count > 1 ? first + "\n" + parts[1] : first
            }
        }
        let props = propertyLines(for: e, existingText: text)
        if !props.isEmpty { text = ([text].filter { !$0.isEmpty } + props).joined(separator: "\n") }
        return text
    }

    /// What a link-only block shows: a page link, a block reference, or the target's text.
    func linkText(_ target: Int64) -> String {
        if isPage(target), let l = link(toPage: target) { return l }
        if let u = d.uuid(target), blockUUIDs.contains(u) { return "((\(u)))" }
        return d.string(target, ":block/title") ?? ""
    }

    /// `[[uuid]]` → `[[Page Title]]` for pages, `((uuid))` for blocks; anything else is reported and left alone.
    mutating func resolveReferences(in text: String) -> String {
        guard text.contains("[[") else { return text }
        var unresolvedHere: [String] = []
        let out = text.replacing(/\[\[([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\]\]/) { m in
            let u = String(m.1).lowercased()
            if let title = uuidToPageTitle[u] { return "[[\(title)]]" }
            if let ent = d.entity(withUUID: u) {
                if d.first(ent, ":logseq.property.asset/checksum") != nil {          // an embedded image or file
                    let ext = d.string(ent, ":logseq.property.asset/type") ?? ""
                    let name = "\(u).\(ext)"
                    let path = assetMap[name] ?? { missing.insert(name); return "assets/\(name)" }()
                    return "![\(d.string(ent, ":block/title") ?? "")](\(path))"
                }
                if blockUUIDs.contains(u) { return "((\(u)))" }
                if let t = d.string(ent, ":block/title"), isPage(ent) {              // a built-in or recycled page
                    if isDeletedPure(ent) { warnedDeleted.insert(t) }
                    return "[[\(t)]]"
                }
            }
            unresolvedHere.append(u)
            return u        // plain text, not a link: a dead reference must not create a page
        }
        for u in unresolvedHere { unresolved.insert(u) }
        return out
    }

    func isDeletedPure(_ e: Int64) -> Bool {
        var cur: Int64? = e
        var hops = 0
        while let c = cur, hops < 64 {
            if d.int(c, ":logseq.property/deleted-at") != nil { return true }
            cur = d.int(c, ":block/parent"); hops += 1
        }
        return false
    }

    mutating func rewriteAssetPaths(in text: String) -> String {
        guard text.contains("assets/") else { return text }
        var missingHere: [String] = []
        let out = text.replacing(/(!?\[[^\]]*\])\((?:\.\.\/)?assets\/([0-9a-fA-F-]{36})\.([A-Za-z0-9]+)\)/) { m in
            let name = "\(String(m.2).lowercased()).\(m.3)"
            if let path = assetMap[name] { return "\(m.1)(\(path))" }
            missingHere.append(name)
            return String(m.0)
        }
        for n in missingHere { missing.insert(n) }
        return out
    }

    /// `key:: value` lines for a block's or page's user properties (skipping keys the text already spells out).
    func propertyLines(for e: Int64, existingText: String) -> [String] {
        let existing = existingText.components(separatedBy: "\n").map { $0.lowercased() }
        var out: [String] = []
        for attr in d.attributes(of: e).filter({ $0.hasPrefix(":user.property/") }).sorted() {
            guard let prop = d.entity(withIdent: attr), let key = d.string(prop, ":block/title") else { continue }
            if existing.contains(where: { $0.hasPrefix("\(key.lowercased()):: ") }) { continue }
            let type = d.keyword(prop, ":logseq.property/type") ?? ":default"
            let values = d.refs(e, attr).compactMap { valueString($0, type: type) }.filter { !$0.isEmpty }
            if !values.isEmpty { out.append("\(key):: \(values.joined(separator: ", "))") }
        }
        return out
    }

    func link(toPage p: Int64) -> String? { pageTitleFor[p].map { "[[\($0)]]" } ?? d.string(p, ":block/title").map { "[[\($0)]]" } }

    func valueString(_ v: Int64, type: String) -> String? {
        if isPage(v), let l = link(toPage: v) { return l }
        let scalar = d.first(v, ":logseq.property/value")
        let title = d.string(v, ":block/title")?.replacingOccurrences(of: "\n", with: " ")
        switch (type, scalar) {
        case (":node", .int(let t)?): return isPage(t) ? link(toPage: t) : title
        case (":number", .int(let n)?): return String(n)
        case (":number", .double(let x)?): return String(x)
        case (_, .string(let s)?): return s
        case (_, .int(let n)?): return isPage(n) ? link(toPage: n) : (title ?? String(n))
        case (_, .double(let x)?): return String(x)
        default: return title
        }
    }
}

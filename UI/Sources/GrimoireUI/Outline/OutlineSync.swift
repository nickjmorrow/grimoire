import GrimoireCore
import Foundation

/// Turns "what the editor shows now" into the smallest set of Core ops that make the database match.
public enum OutlineSync {
    public static func ops(old: OutlineDoc, new rawNew: OutlineDoc, pageID: String,
                           orderKeys: [String: String], newID: () -> String) -> [Op] {
        let new = rawNew.normalized(newID: newID)
        let newIDs = new.rows.map { $0.blockID! }

        // Old structure
        var oldParent: [String: String?] = [:], oldRow: [String: OutlineRow] = [:]
        for (i, r) in old.rows.enumerated() {
            guard let id = r.blockID else { continue }
            oldRow[id] = r
            oldParent[id] = .some(old.parentIndex(of: i).flatMap { old.rows[$0].blockID })
        }
        // New structure
        var newParent: [String: String?] = [:]
        var children: [String?: [String]] = [:]
        for (i, id) in newIDs.enumerated() {
            let p = new.parentIndex(of: i).map { newIDs[$0] }
            newParent[id] = .some(p)
            children[p, default: []].append(id)
        }

        // Order keys: keep as many existing keys as possible among siblings that stayed under the same parent.
        var finalKey: [String: String] = [:]
        for (parent, kids) in children {
            let stay = kids.map { id -> Bool in
                guard orderKeys[id] != nil, let op = oldParent[id] else { return false }
                return op == parent
            }
            let keptIndexes = longestIncreasing(kids.indices.filter { stay[$0] }, key: { orderKeys[kids[$0]]! })
            let kept = Set(keptIndexes)
            for i in kept { finalKey[kids[i]] = orderKeys[kids[i]]! }
            var prev: String? = nil
            for (i, id) in kids.enumerated() {
                if kept.contains(i) { prev = finalKey[id]; continue }
                let next = kids[(i + 1)...].enumerated().first(where: { kept.contains(i + 1 + $0.offset) }).map { finalKey[kids[i + 1 + $0.offset]]! }
                let key = OrderKey.between(prev, next)
                finalKey[id] = key
                prev = key
            }
        }

        var ops: [Op] = []
        // Inserts and moves in document order: a row's new parent always comes earlier, so it is already in place.
        for (i, id) in newIDs.enumerated() {
            let row = new.rows[i]
            let parent = newParent[id]!
            if oldRow[id] == nil {
                ops.append(.insertBlock(id: id, pageID: pageID, parentID: parent, orderKey: finalKey[id]!, text: row.text))
                if row.collapsed { ops.append(.setCollapsed(blockID: id, collapsed: true)) }
            } else if oldParent[id]! != parent || orderKeys[id] != finalKey[id] {
                ops.append(.moveBlock(blockID: id, pageID: pageID, parentID: parent, orderKey: finalKey[id]!))
            }
        }
        for (i, id) in newIDs.enumerated() {
            guard let old = oldRow[id] else { continue }
            if old.text != new.rows[i].text { ops.append(.editText(blockID: id, text: new.rows[i].text)) }
            if old.collapsed != new.rows[i].collapsed { ops.append(.setCollapsed(blockID: id, collapsed: new.rows[i].collapsed)) }
        }
        // Deletes last, once surviving children have been moved out. Only the roots of deleted groups: deleting one cascades.
        let kept = Set(newIDs)
        let deleted = Set(oldRow.keys).subtracting(kept)
        for r in old.rows {
            guard let id = r.blockID, deleted.contains(id) else { continue }
            if let p = oldParent[id]!, deleted.contains(p) { continue }
            ops.append(.deleteBlock(blockID: id))
        }
        return ops
    }

    /// Indexes (from `candidates`, in order) forming the longest strictly increasing run of keys.
    static func longestIncreasing(_ candidates: [Int], key: (Int) -> String) -> [Int] {
        var tails: [Int] = []                   // candidate positions ending runs of each length
        var prev = [Int?](repeating: nil, count: candidates.count)
        for (pos, c) in candidates.enumerated() {
            let k = key(c)
            var lo = 0, hi = tails.count
            while lo < hi { let mid = (lo + hi) / 2; if key(candidates[tails[mid]]) < k { lo = mid + 1 } else { hi = mid } }
            prev[pos] = lo > 0 ? tails[lo - 1] : nil
            if lo == tails.count { tails.append(pos) } else { tails[lo] = pos }
        }
        var out: [Int] = []
        var cur = tails.last
        while let c = cur { out.append(candidates[c]); cur = prev[c] }
        return out.reversed()
    }
}

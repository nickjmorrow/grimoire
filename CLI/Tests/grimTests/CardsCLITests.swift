import Foundation
import Testing

@Suite struct CardsCLITests {
    @Test func studyLoopThroughTheCLI() throws {
        let g = tempGraph()
        _ = try grim(["append", "Deck", "- What is FSRS? #card\n  - a scheduling algorithm\n- Second question #card\n  - answer", "--json"], graph: g)
        let status = try json(try grim(["cards", "status", "--json"], graph: g)) as! [String: Int]
        #expect(status == ["due": 0, "new": 2, "total": 2])
        let next = try json(try grim(["cards", "next", "--json"], graph: g)) as! [[String: Any]]
        #expect(next.count == 1 && next[0]["front"] as? String == "What is FSRS?" && (next[0]["back"] as? [String]) == ["a scheduling algorithm"])
        let id = next[0]["id"] as! String
        let r = try grim(["cards", "review", id, "good", "--json"], graph: g)
        #expect(r.code == 0)
        #expect((try json(r) as! [String: Any])["reps"] as? Int == 1)
        #expect((try json(try grim(["cards", "status", "--json"], graph: g)) as! [String: Int])["new"] == 1)
        #expect(try grim(["cards", "review", id, "meh"], graph: g).code == 1)
        #expect(try grim(["cards", "review", "nope", "good"], graph: g).code == 2)
    }
}

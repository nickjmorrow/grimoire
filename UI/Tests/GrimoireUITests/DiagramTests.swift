import Foundation
import Testing
@testable import GrimoireUI

@Suite struct DiagramSourceTests {
    @Test func findsAClosedMermaidFence() {
        #expect(DiagramSource.mermaid(in: "Plan\n```mermaid\ngraph TD\n  A-->B\n```") == "graph TD\n  A-->B")
        #expect(DiagramSource.mermaid(in: "```Mermaid\u{2028}graph LR\u{2028}A-->B\u{2028}```") == "graph LR\nA-->B")
    }
    @Test func ignoresOtherFencesUnclosedOrEmptyOnes() {
        #expect(DiagramSource.mermaid(in: "```swift\nlet x = 1\n```") == nil)
        #expect(DiagramSource.mermaid(in: "```mermaid\ngraph TD") == nil)
        #expect(DiagramSource.mermaid(in: "```mermaid\n```") == nil)
        #expect(DiagramSource.mermaid(in: "plain") == nil)
    }
    @Test func cacheKeysDependOnSourceAndTheme() {
        let a = DiagramSource.key(source: "graph TD", theme: "dark")
        #expect(a == DiagramSource.key(source: "graph TD", theme: "dark"))
        #expect(a != DiagramSource.key(source: "graph TD", theme: "light"))
        #expect(a != DiagramSource.key(source: "graph LR", theme: "dark"))
    }
}

#if os(macOS)
@Suite(.serialized) @MainActor struct MermaidRendererTests {
    @Test func rendersAFlowchartToAnImageAndCachesIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString)")
        let r = MermaidRenderer(cacheFolder: folder)
        let result = await r.render(source: "graph TD\n  A[Start] --> B[End]", theme: .midnightSun)
        guard case .image(let img) = result else { Issue.record("expected an image, got \(result)"); return }
        #expect(img.size.width > 40 && img.size.height > 30)
        #expect(r.cachedImage(source: "graph TD\n  A[Start] --> B[End]", theme: .midnightSun) != nil)
        #expect((try FileManager.default.contentsOfDirectory(atPath: folder.path)).count == 1)
    }

    @Test func badSourceGivesAReadableFailure() async throws {
        let r = MermaidRenderer(cacheFolder: nil)
        let result = await r.render(source: "this is not a diagram ->->", theme: .midnightSun)
        guard case .failure(let msg) = result else { Issue.record("expected failure"); return }
        #expect(!msg.isEmpty)
    }
}
#endif

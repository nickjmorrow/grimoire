import Foundation
import Testing
@testable import GrimoireCore

@Suite struct ChangeWatcherTests {
    @Test func versionChangesWhenAnotherConnectionWrites() throws {
        let folder = tempFolder()
        let app = try Graph(folder: folder, device: "app")
        let watcher = try ChangeWatcher(graph: app)
        let before = watcher.version()
        #expect(watcher.version() == before)                                   // stable while nothing happens
        let cli = try Graph(folder: folder, device: "cli")
        try cli.perform([.createPage(id: "p", title: "P", kind: .page, journalDate: nil)], author: .claude)
        #expect(watcher.version() != before)
        let mid = watcher.version()
        try app.perform([.createPage(id: "q", title: "Q", kind: .page, journalDate: nil)], author: .me)    // our own commits count too
        #expect(watcher.version() != mid)
    }
}

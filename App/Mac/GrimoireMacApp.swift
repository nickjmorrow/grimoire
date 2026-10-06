import GrimoireUI
import SwiftUI

@main
struct GrimoireMacApp: App {
    private let graphFolder: URL = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--graph"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]) }
        if let env = ProcessInfo.processInfo.environment["GRIMOIRE_GRAPH"] { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Grimoire")
    }()

    var body: some Scene {
        WindowGroup { AppRoot(graphFolder: graphFolder) }
            .defaultSize(width: 1240, height: 820)
            .commands { GrimoireMenuCommands() }
    }
}

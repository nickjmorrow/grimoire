import GrimoireUI
import SwiftUI

@main
struct GrimoireIOSApp: App {
    /// The graph lives in the app's Documents folder; sync (Settings → Sync) keeps it level with the hub.
    private let graphFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Grimoire")

    var body: some Scene {
        WindowGroup { AppRoot(graphFolder: graphFolder).ignoresSafeArea(.container, edges: .bottom) }
    }
}

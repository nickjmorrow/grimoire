import GrimoireCore
import SwiftUI

public struct AppRoot: View {
    @State private var store: GraphStore?
    @State private var failure: String?
    let graphFolder: URL

    public init(graphFolder: URL) { self.graphFolder = graphFolder }

    public var body: some View {
        Group {
            if let store { RootView(store: store).focusedSceneValue(\.graphStore, store) }
            else if let failure { Text("Can't open the graph at \(graphFolder.path)\n\(failure)").padding(40) }
            else { Color.clear }
        }
        .task {
            guard store == nil else { return }
            do { store = GraphStore(graph: try Graph(folder: graphFolder, device: "mac-app")) }
            catch { failure = "\(error)" }
        }
    }
}

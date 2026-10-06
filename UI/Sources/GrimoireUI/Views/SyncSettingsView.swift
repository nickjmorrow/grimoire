import GrimoireCore
import SwiftUI

/// Where to sync: the hub's address, this device's token and name. Saved to sync.json in the graph folder.
struct SyncSettingsView: View {
    let store: GraphStore
    @State private var url = ""
    @State private var token = ""
    @State private var device = ""
    @State private var message: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { store.settingsVisible = false }
            VStack(alignment: .leading, spacing: 14) {
                Text("Sync").font(.system(size: 17, weight: .semibold)).foregroundStyle(store.color(\.text))
                Text("Your sync hub keeps every device in step. Get the address and a token for this device from `grim-sync`.")
                    .font(.system(size: 12)).foregroundStyle(store.color(\.textDim))
                field("Hub address", "https://…:8447", text: $url)
                secure("Token", text: $token)
                field("This device's name", "iphone", text: $device)
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(store.color(\.warning)) }
                HStack {
                    Spacer()
                    Button("Cancel") { store.settingsVisible = false }.buttonStyle(.plain).foregroundStyle(store.color(\.textDim))
                    Button("Save & sync") { save() }.buttonStyle(.plain)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(store.color(\.accent))).foregroundStyle(store.color(\.background))
                }
            }
            .padding(20).frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 12).fill(store.color(\.surfaceRaised)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.color(\.border), lineWidth: 1))
            .padding(20)
        }
        .onAppear {
            if let c = SyncConfig.load(for: store.graph) { url = c.url.absoluteString; token = c.token; device = c.device }
        }
    }

    private func field(_ label: String, _ prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(store.color(\.textFaint))
            TextField(prompt, text: text).textFieldStyle(.plain).padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(store.color(\.background))).foregroundStyle(store.color(\.text))
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
        }
    }

    private func secure(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(store.color(\.textFaint))
            SecureField("", text: text).textFieldStyle(.plain).padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(store.color(\.background))).foregroundStyle(store.color(\.text))
        }
    }

    private func save() {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)), u.scheme?.hasPrefix("http") == true, !token.isEmpty, !device.isEmpty else {
            message = "Fill in all three fields (the address must start with https://)."; return
        }
        do {
            try SyncConfig(url: u, token: token.trimmingCharacters(in: .whitespaces), device: device.trimmingCharacters(in: .whitespaces)).save(for: store.graph)
            store.settingsVisible = false
            store.startSync()
        } catch { message = "Couldn't save: \(error)" }
    }
}

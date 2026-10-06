import GrimoireCore
import SwiftUI

/// What sync couldn't apply or send: changes the hub rejected, ones that no longer fit after another device's edits, and ones this version can't read.
/// They were already dropped from this device (nothing is stuck); the list is the record so nothing disappears silently.
struct SyncIssuesView: View {
    let store: GraphStore

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { store.issuesVisible = false }
            VStack(alignment: .leading, spacing: 12) {
                Text("Sync issues").font(.system(size: 17, weight: .semibold)).foregroundStyle(store.color(\.text))
                Text("These changes didn't make it to the other devices. Each was dropped here so sync keeps going; the text is shown so you can redo anything that mattered.")
                    .font(.system(size: 12)).foregroundStyle(store.color(\.textDim))
                if store.syncIssues.isEmpty {
                    Text("Nothing to show.").font(.system(size: 13)).foregroundStyle(store.color(\.textFaint))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(store.syncIssues.reversed()) { issue in row(issue) }
                        }
                    }
                    .frame(maxHeight: 360)
                }
                HStack {
                    Spacer()
                    Button("Close") { store.issuesVisible = false }.buttonStyle(.plain).foregroundStyle(store.color(\.textDim))
                    if !store.syncIssues.isEmpty {
                        Button("Clear all") { store.clearSyncIssues() }.buttonStyle(.plain)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(store.color(\.accent))).foregroundStyle(store.color(\.background))
                    }
                }
            }
            .padding(20).frame(maxWidth: 480)
            .background(RoundedRectangle(cornerRadius: 12).fill(store.color(\.surfaceRaised)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.color(\.border), lineWidth: 1))
            .padding(20)
        }
        .accessibilityIdentifier("sync-issues")
    }

    private func row(_ issue: SyncClient.Issue) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(label(issue.source)) · \(issue.at.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11)).foregroundStyle(store.color(\.textFaint))
            Text(issue.reason).font(.system(size: 12.5)).foregroundStyle(store.color(\.text)).textSelection(.enabled)
            Text(issue.payload).font(.system(size: 11, design: .monospaced)).foregroundStyle(store.color(\.textDim))
                .lineLimit(3).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 7).fill(store.color(\.background)))
        .accessibilityElement(children: .combine)
    }

    private func label(_ source: String) -> String {
        switch source {
        case "push": return "Rejected by the hub"
        case "pull": return "From the hub"
        case "rebase": return "After another device's edits"
        default: return source
        }
    }
}

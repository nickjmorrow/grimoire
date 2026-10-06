import SwiftUI

/// Shows at a glance whether what's written on this device has reached the hub: a cloud that is checked (synced), arrowed (changes waiting),
/// spinning (syncing), slashed (offline) or alarmed (error). Tapping syncs now and says what's going on.
struct SyncBadge: View {
    let store: GraphStore

    var body: some View {
        if store.syncStatus != .off {
            Button(action: tap) {
                HStack(spacing: 5) {
                    Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                        .symbolEffect(.pulse, isActive: store.syncStatus == .syncing)
                    if !store.compact { Text(label).font(.system(size: 11.5)).foregroundStyle(store.color(\.textFaint)) }
                }
                .padding(.horizontal, 6).frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(detail)
        }
    }

    private var waiting: Int { store.pendingChanges }
    private var hasUnsent: Bool { store.pendingChanges > 0 || store.typingUnsaved }

    private var symbol: String {
        switch store.syncStatus {
        case .off: return "icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .offline: return "icloud.slash"
        case .failed: return "exclamationmark.icloud"
        case .synced: return hasUnsent ? "icloud.and.arrow.up" : "checkmark.icloud"
        }
    }

    private var tint: Color {
        switch store.syncStatus {
        case .off: return .clear
        case .syncing: return store.color(\.accent)
        case .offline: return store.color(\.warning)
        case .failed: return store.color(\.danger)
        case .synced: return hasUnsent ? store.color(\.accent) : store.color(\.success)
        }
    }

    private var label: String {
        switch store.syncStatus {
        case .off: return ""
        case .syncing: return "Syncing…"
        case .offline: return waiting > 0 ? "Offline · \(waiting) unsent" : "Offline"
        case .failed: return "Sync error"
        case .synced(_, let c): return hasUnsent ? "Not synced yet" : (c > 0 ? "Synced · \(c) conflict\(c == 1 ? "" : "s") kept" : "Synced")
        }
    }

    private var detail: String {
        var parts = [label]
        if waiting > 0 { parts.append("\(waiting) change\(waiting == 1 ? "" : "s") waiting to send") }
        if store.typingUnsaved { parts.append("typing not saved yet") }
        if let t = store.lastSyncedAt { parts.append("last synced \(t.formatted(.relative(presentation: .named)))") }
        if let e = store.lastSyncError { parts.append(e) }
        return parts.joined(separator: " · ")
    }

    private func tap() {
        if case .failed = store.syncStatus, !store.syncIssues.isEmpty { store.showSyncIssues(); return }
        store.show(detail)
        store.syncNow()
    }
}

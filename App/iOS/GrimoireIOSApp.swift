import GrimoireUI
import SwiftUI
import UIKit

@main
struct GrimoireIOSApp: App {
    /// The graph lives in the app's Documents folder; sync (Settings → Sync) keeps it level with the hub.
    private let graphFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Grimoire")

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup { AppRoot(graphFolder: graphFolder).ignoresSafeArea(.container, edges: .bottom) }
            .onChange(of: scenePhase, initial: true) { _, phase in if phase == .active { Self.applyTimeOfDayIcon() } }
    }

    /// iOS only lets an app change its icon while it is in the foreground, so the icon follows the time of day as of the last time Grimoire was opened.
    /// Night is the primary icon (nil); dawn, day and dusk are alternates declared in project.yml. iOS shows its own "icon changed" notice on each switch.
    @MainActor private static var changingIcon = false
    @MainActor private static func applyTimeOfDayIcon() {
        let app = UIApplication.shared
        let wanted = TimeOfDay.at(Date()).iOSIconName
        guard !changingIcon, app.supportsAlternateIcons, app.alternateIconName != wanted else { return }
        changingIcon = true
        // iOS cancels an icon change requested while the scene is still coming up, so let it settle first
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            do { try await app.setAlternateIconName(wanted) } catch { NSLog("Grimoire: couldn't set the time-of-day icon: %@", error.localizedDescription) }
            changingIcon = false
        }
    }
}

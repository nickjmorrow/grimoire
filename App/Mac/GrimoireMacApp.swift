import AppKit
import GrimoireUI
import SwiftUI

/// Keeps the Dock icon on the current time of day (dawn, day, dusk or night) while the app runs.
/// Finder and Launchpad show the bundle's night icon, since macOS only lets a running app change its own Dock icon.
@MainActor final class DockIconUpdater: NSObject, NSApplicationDelegate {
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        refresh()
        // the clock can jump (sleep, travel, manual change), so re-check on wake and on a system clock change as well as at each boundary
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let now = Date()
        if let image = NSImage(named: TimeOfDay.at(now).macImageName) { NSApp.applicationIconImage = image }
        timer?.invalidate()
        let next = TimeOfDay.nextChange(after: now)
        timer = Timer.scheduledTimer(withTimeInterval: max(next.timeIntervalSince(now), 1) + 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

@main
struct GrimoireMacApp: App {
    @NSApplicationDelegateAdaptor(DockIconUpdater.self) private var dockIcon

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

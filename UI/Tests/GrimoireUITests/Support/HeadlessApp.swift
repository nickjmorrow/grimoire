#if os(macOS)
import AppKit
import GrimoireCore
import SwiftUI
@testable import GrimoireUI

/// Tests that inject keystrokes into a hidden window need a real GUI session; hosted CI runners don't have one, so those suites skip there (they run locally).
let hasGUISession = ProcessInfo.processInfo.environment["CI"] == nil

/// The whole window (sidebar, panes, editors) hosted in a window that is never shown, driven by injected events.
@MainActor
final class HeadlessApp {
    let graph: Graph
    let store: GraphStore
    let window: NSWindow
    let host: NSHostingView<RootView>
    static var keepAlive: [HeadlessApp] = []

    init(graph: Graph, size: NSSize = NSSize(width: 1180, height: 780), theme: String? = nil) {
        _ = NSApplication.shared
        self.graph = graph
        let defaults = UserDefaults(suiteName: "headless-\(UUID().uuidString)")!
        store = GraphStore(graph: graph, defaults: defaults)
        if let theme { store.themes.select(name: theme) }
        host = NSHostingView(rootView: RootView(store: store))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        HeadlessApp.keepAlive.append(self)
    }

    /// Lets timers, saves and SwiftUI updates run.
    func settle(_ seconds: Double = 0.5) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
    }

    /// Like `settle`, but returns as soon as `condition` holds (up to `timeout`), so slower machines don't depend on fixed sleeps.
    func settle(until condition: () -> Bool, timeout: Double = 10) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
    }

    func textViews() -> [OutlineTextView] {
        var out: [OutlineTextView] = []
        func walk(_ v: NSView) { if let t = v as? OutlineTextView { out.append(t) }; v.subviews.forEach(walk) }
        walk(host)
        return out.sorted { $0.convert($0.bounds, to: host).minY > $1.convert($1.bounds, to: host).minY }   // top to bottom
    }

    @discardableResult func focus(_ tv: OutlineTextView) -> OutlineTextView { window.makeFirstResponder(tv); return tv }
    func type(_ text: String) { EventInjector.type(text, in: window) }
    func key(_ name: String, _ mods: [String] = []) { EventInjector.key(name, mods: mods, in: window) }

    func snapshot(_ name: String) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
#endif

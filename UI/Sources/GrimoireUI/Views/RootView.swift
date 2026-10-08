import GrimoireCore
import SwiftUI

struct RootView: View {
    let store: GraphStore
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private var compact: Bool { false }
    #endif

    var body: some View {
        ZStack {
            if compact { compactLayout } else { regularLayout }
            if store.settingsVisible { SyncSettingsView(store: store).transition(.opacity) }
            if store.issuesVisible { SyncIssuesView(store: store).transition(.opacity) }
            if store.paletteVisible { PaletteView(store: store).transition(.opacity) }
            if let toast = store.toast {
                VStack { Spacer(); Text(toast).font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(store.color(\.surfaceRaised))).foregroundStyle(store.color(\.text)).padding(.bottom, 28) }
                    .transition(.opacity)
            }
        }
        .background(store.color(\.background))
        .background { alternateShortcuts }
        .confirmationDialog("Delete “\(store.pageAwaitingDeletion?.title ?? "")”?",
                            isPresented: Binding(get: { store.pageAwaitingDeletion != nil }, set: { if !$0 { store.pageAwaitingDeletion = nil } }),
                            titleVisibility: .visible, presenting: store.pageAwaitingDeletion) { page in
            Button("Delete Page", role: .destructive) { store.deletePage(id: page.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            let n = store.pageAwaitingDeletionLinks
            Text(n == 0 ? "The page and everything on it will be deleted."
                 : "Everything on it will be deleted. It's linked from \(n) page\(n == 1 ? "" : "s"); those links stay and open an empty page.")
        }
        #if os(macOS)
        .background(OpaqueWindow(color: store.theme.colors.platformColor(\.background)))
        #endif
        .onChange(of: compact, initial: true) { _, c in store.compact = c; if c { store.sidebarVisible = false } }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 440)
        #endif
        .preferredColorScheme(store.theme.appearance == .dark ? .dark : .light)
        .onAppear { store.start(); store.startSync() }
    }

    /// Second keys for commands (⌘K opens the same page switcher as ⌘P). They have no menu item, so invisible buttons carry them.
    private var alternateShortcuts: some View {
        ZStack {
            ForEach(CommandRegistry.all.filter { !$0.alternates.isEmpty }) { c in
                ForEach(Array(c.alternates.enumerated()), id: \.offset) { _, alt in
                    Button("") { c.run(store) }.keyboardShortcut(alt.keyboardShortcut).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
            }
        }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                Sidebar(store: store).frame(width: 224)
                Divider().overlay(store.color(\.border))
            }
            HStack(spacing: 0) {
                ForEach(Array(store.panes.enumerated()), id: \.element.id) { i, pane in
                    if i > 0 { Divider().overlay(store.color(\.border)) }
                    PaneView(store: store, pane: pane).frame(minWidth: 340)
                }
            }
        }
    }

    /// iPhone: one pane at a time; the sidebar slides over it.
    private var compactLayout: some View {
        ZStack(alignment: .leading) {
            PaneView(store: store, pane: store.focusedPane)
            if store.sidebarVisible {
                Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { store.sidebarVisible = false }
                HStack(spacing: 0) { Sidebar(store: store).frame(width: 290); Divider().overlay(store.color(\.border)) }
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.sidebarVisible)
        #if os(iOS)
        .onChange(of: store.sidebarVisible) { _, visible in
            // The editor's keyboard and toolbar would otherwise stay up over the lower half of the sidebar.
            if visible { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        #endif
    }
}

#if os(macOS)
import AppKit

/// Makes the hosting window fully opaque in the theme's background colour, so the window server composites it without blending.
struct OpaqueWindow: NSViewRepresentable {
    let color: NSColor
    func makeNSView(context: Context) -> NSView { Probe(color: color) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.color = color; (view as? Probe)?.apply() }

    final class Probe: NSView {
        var color: NSColor
        init(color: NSColor) { self.color = color; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didEndLiveResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.sweep() })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.sweep() }
            #if true
            if ProcessInfo.processInfo.environment["GRIMOIRE_ZOOM"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { window.zoom(nil) } }
            #endif
            if let path = ProcessInfo.processInfo.environment["GRIMOIRE_LOG_RESIZE"] {
                for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification, NSApplication.didChangeScreenParametersNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                        let line = "\(Date().timeIntervalSince1970) \(n.name.rawValue) \((n.object as? NSWindow)?.frame.debugDescription ?? "")\n"
                        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
                    })
                }
            }
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        func apply() { guard let window else { return }; window.isOpaque = true; window.backgroundColor = color; sweep() }

        /// macOS 26+ puts a live-blur "scroll pocket" in every scroll view that touches the window edge. This app's panes are flat, so hide them.
        func sweep() {
            guard let root = window?.contentView else { return }
            func walk(_ v: NSView) {
                if String(describing: type(of: v)) == "NSScrollPocket", !v.isHidden { v.isHidden = true }
                v.subviews.forEach(walk)
            }
            walk(root)
        }
    }
}
#endif

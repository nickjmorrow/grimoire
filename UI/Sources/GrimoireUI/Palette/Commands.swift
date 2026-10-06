import Foundation
import GrimoireCore
#if canImport(AppKit)
import AppKit
#endif

/// A keyboard shortcut, kept as plain data so the registry can be checked for collisions and shown in the palette.
public struct Shortcut: Hashable, Sendable {
    public var key: String                      // one character, lowercase ("t", "k", "[", "\\", "1")
    public var command = true
    public var shift = false
    public var option = false
    public var control = false
    public init(_ key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key; self.command = command; self.shift = shift; self.option = option; self.control = control
    }
    public var display: String { (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased() }
}

public struct AppCommand: Identifiable {
    public let id: String
    public let title: String
    public var keywords: [String] = []
    public var shortcut: Shortcut?
    /// Extra keys for the same command (no menu item of their own).
    public var alternates: [Shortcut] = []
    public var symbol = "command"
    /// Appears in the menu bar under this menu (nil = palette only).
    public var menu: String?
    public var isEnabled: @MainActor (GraphStore) -> Bool = { _ in true }
    public let run: @MainActor (GraphStore) -> Void
}

/// Every command the app offers; the palette and the menu bar are both built from this list.
public enum CommandRegistry {
    public static let all: [AppCommand] = [
        AppCommand(id: "palette", title: "Go to Page or Search", keywords: ["open", "find", "quick open", "go to"], shortcut: Shortcut("p"), alternates: [Shortcut("k")], symbol: "magnifyingglass", menu: "Go") { $0.showPalette(.all) },
        AppCommand(id: "commands", title: "Command Palette", keywords: ["commands", "run"], shortcut: Shortcut("p", shift: true), symbol: "command", menu: "Go") { $0.showPalette(.commands) },
        AppCommand(id: "search", title: "Search Everything", keywords: ["find", "blocks"], shortcut: Shortcut("f", shift: true), symbol: "text.magnifyingglass", menu: "Go") { $0.showPalette(.search) },
        AppCommand(id: "today", title: "Go to Today", keywords: ["journal", "journals"], shortcut: Shortcut("t"), symbol: "calendar", menu: "Go") { $0.openToday() },
        AppCommand(id: "back", title: "Back", shortcut: Shortcut("["), symbol: "chevron.left", menu: "Go",
                   isEnabled: { $0.focusedPane.canGoBack }) { $0.back() },
        AppCommand(id: "forward", title: "Forward", shortcut: Shortcut("]"), symbol: "chevron.right", menu: "Go",
                   isEnabled: { $0.focusedPane.canGoForward }) { $0.forward() },
        AppCommand(id: "all-pages", title: "All Pages", keywords: ["list"], symbol: "doc.text", menu: "Go") { $0.open(.allPages) },
        AppCommand(id: "tags", title: "Tags", keywords: ["list"], symbol: "number", menu: "Go") { $0.open(.tags) },
        AppCommand(id: "review", title: "Review Flashcards", keywords: ["cards", "study", "quiz", "srs"], shortcut: Shortcut("r", shift: true), symbol: "rectangle.stack", menu: "Go") { $0.open(.review(page: nil, block: nil)) },
        AppCommand(id: "review-page", title: "Review Cards on This Page", keywords: ["cards", "study"], shortcut: Shortcut("r", option: true), symbol: "rectangle.stack", menu: "Go",
                   isEnabled: { if case .page = $0.focusedPane.location { return true } else { return false } }) {
            if case .page(let id) = $0.focusedPane.location { $0.open(.review(page: id, block: nil)) } },
        AppCommand(id: "review-bullet", title: "Review Cards Under This Bullet", keywords: ["cards", "study", "chapter", "section"], shortcut: Shortcut("r"), symbol: "rectangle.stack", menu: "Go",
                   isEnabled: { $0.caretReviewCandidate != nil }) { $0.reviewCardsAtCaret() },
        AppCommand(id: "new-page", title: "New Page", keywords: ["create"], shortcut: Shortcut("n"), symbol: "plus", menu: "File") { $0.newPage() },
        AppCommand(id: "toggle-favorite", title: "Toggle Favorite", keywords: ["star", "pin"], shortcut: Shortcut("d"), symbol: "star", menu: "File",
                   isEnabled: { if case .page = $0.focusedPane.location { return true } else { return false } }) { $0.toggleFavoriteOfFocusedPage() },
        AppCommand(id: "split", title: "Open in Split Pane", keywords: ["side by side", "split", "duplicate"], shortcut: Shortcut("\\", shift: true), symbol: "rectangle.split.2x1", menu: "View",
                   isEnabled: { $0.panes.count < GraphStore.maxPanes }) { $0.open($0.focusedPane.location, newPane: true) },
        AppCommand(id: "close-pane", title: "Close Pane", shortcut: Shortcut("w"), symbol: "xmark", menu: "File") { $0.closeFocusedPaneOrWindow() },
        AppCommand(id: "focus-1", title: "Focus Pane 1", shortcut: Shortcut("1"), menu: "View") { $0.focusPane(at: 0) },
        AppCommand(id: "focus-2", title: "Focus Pane 2", shortcut: Shortcut("2"), menu: "View", isEnabled: { $0.panes.count > 1 }) { $0.focusPane(at: 1) },
        AppCommand(id: "focus-3", title: "Focus Pane 3", shortcut: Shortcut("3"), menu: "View", isEnabled: { $0.panes.count > 2 }) { $0.focusPane(at: 2) },
        AppCommand(id: "sidebar", title: "Toggle Sidebar", keywords: ["hide", "show"], shortcut: Shortcut("\\"), symbol: "sidebar.left", menu: "View") { $0.sidebarVisible.toggle() },
        AppCommand(id: "undo-claude", title: "Undo Claude's Last Change", keywords: ["revert", "ai"], symbol: "arrow.uturn.backward") { $0.undoClaudesLastChange() },
        AppCommand(id: "sync-settings", title: "Sync Settings", keywords: ["hub", "token", "server", "settings", "preferences"], shortcut: Shortcut(","), symbol: "arrow.triangle.2.circlepath") { $0.settingsVisible = true },
        AppCommand(id: "sync-now", title: "Sync Now", keywords: ["push", "pull"], symbol: "arrow.triangle.2.circlepath", isEnabled: { $0.syncStatus != .off }) { $0.syncNow() },
        AppCommand(id: "reload", title: "Reload Graph", keywords: ["refresh"], symbol: "arrow.clockwise") { $0.reloadGraph() },
        AppCommand(id: "reindex", title: "Rebuild Search Index", keywords: ["reindex", "repair"], symbol: "wrench.and.screwdriver") { $0.rebuildIndexes() },
        AppCommand(id: "export-mirror", title: "Export Markdown Mirror", keywords: ["markdown", "files", "write"], symbol: "square.and.arrow.up") { $0.exportMirror() },
    ]

    public static func command(_ id: String) -> AppCommand? { all.first { $0.id == id } }
}

// MARK: what the commands do

@MainActor extension GraphStore {
    public func showPalette(_ mode: PaletteMode) { paletteMode = mode; paletteVisible = true }

    public func newPage() {
        var title = "Untitled", n = 1
        while (try? graph.page(titled: title)) != nil { n += 1; title = "Untitled \(n)" }
        if let id = pageID(forTitle: title, create: true) { open(.page(id)) }
    }

    public func toggleFavoriteOfFocusedPage() {
        if case .page(let id) = focusedPane.location { toggleFavorite(pageID: id) }
    }

    public func closeFocusedPaneOrWindow() {
        if panes.count > 1 { closePane(focusedPaneID) }
        else {
            #if canImport(AppKit)
            NSApp.keyWindow?.performClose(nil)
            #endif
        }
    }

    public func undoClaudesLastChange() {
        flushAll()
        do {
            let r = try graph.undoDetailed(author: .claude, count: 1)
            show(r.undone > 0 ? "Undid Claude's last change" : (r.skipped.isEmpty ? "Nothing of Claude's to undo" : "Claude's last change can't be undone cleanly"))
        } catch { show("Couldn't undo: \(error)") }
        databaseChanged()
    }

    public func reloadGraph() { themes.reload(); databaseChanged(); show("Reloaded") }

    public func rebuildIndexes() {
        flushAll()
        do { try graph.reindex(); show("Search index rebuilt") } catch { show("Couldn't rebuild: \(error)") }
        databaseChanged()
    }

    public func exportMirror() {
        flushAll()
        do { try graph.writeMirrorAll(); show("Markdown mirror written to \(graph.folder.lastPathComponent)/mirror") } catch { show("Couldn't export: \(error)") }
    }
}

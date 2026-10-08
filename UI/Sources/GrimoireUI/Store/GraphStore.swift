import Foundation
import GrimoireCore
import Observation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Everything the window needs: the graph, the panes, the lists in the sidebar, the theme, and live change tracking.
@MainActor @Observable
public final class GraphStore {
    public let graph: Graph
    public let themes: ThemeStore
    public private(set) var panes: [Pane]
    public var focusedPaneID: UUID
    public var sidebarVisible = true
    public var paletteVisible = false
    public var settingsVisible = false
    public var issuesVisible = false
    /// What sync couldn't apply or send (rejected or unreadable changes), for the Sync Issues panel.
    public private(set) var syncIssues: [SyncClient.Issue] = []
    /// True on a phone-sized window: one pane, sidebar as a drawer.
    public var compact = false
    public var paletteMode: PaletteMode = .all
    public var toast: String?
    /// The page the delete confirmation is asking about, and how many other pages link to it.
    public var pageAwaitingDeletion: Page?
    public private(set) var pageAwaitingDeletionLinks = 0
    /// Shown at the foot of the sidebar.
    public private(set) var syncStatus: SyncStatus = .off
    /// Why the last sync failed (the sidebar's sync line shows it when tapped while offline or in error).
    public private(set) var lastSyncError: String?
    /// Changes made on this device that the hub doesn't have yet (saved ops waiting to be sent), and typing not yet saved.
    public private(set) var pendingChanges = 0
    public private(set) var typingUnsaved = false
    public private(set) var lastSyncedAt: Date?
    /// True when everything written here has reached the hub.
    public var allSynced: Bool {
        if case .synced = syncStatus { return pendingChanges == 0 && !typingUnsaved }
        return false
    }
    public private(set) var favorites: [Page] = []
    public private(set) var recents: [Page] = []
    /// Cards due now (shown beside Review in the sidebar).
    public private(set) var dueCards = 0
    /// Bumped on every database commit; views that list things read it to refresh.
    public private(set) var revision = 0
    public static let maxPanes = 3

    @ObservationIgnored private var watcher: ChangeWatcher?
    @ObservationIgnored private var lastVersion: Int64 = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pollSource: DispatchSourceTimer?
    @ObservationIgnored private let pollQueue = DispatchQueue(label: "grimoire.poll", qos: .utility)
    @ObservationIgnored private var quitObserver: NSObjectProtocol?
    @ObservationIgnored private var models: [WeakModel] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var syncClient: SyncClient?
    @ObservationIgnored private var syncTransport: SyncTransport?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncFailures = 0
    @ObservationIgnored private var retryNotBefore = Date.distantPast
    @ObservationIgnored private var syncTimer: Timer?
    @ObservationIgnored private var syncKick: DispatchWorkItem?

    private struct WeakModel { weak var model: PageEditorModel? }

    public init(graph: Graph, defaults: UserDefaults = .standard) {
        self.graph = graph
        self.defaults = defaults
        self.themes = ThemeStore(folder: graph.folder.appendingPathComponent("themes"))
        let restored = GraphStore.restorePanes(defaults, key: GraphStore.key(graph))
        let initial = restored.isEmpty ? [Pane(location: .journals)] : restored
        self.panes = initial
        self.focusedPaneID = initial[0].id
        refreshLists()
    }

    public var theme: Theme { themes.current }
    public var focusedPane: Pane { panes.first { $0.id == focusedPaneID } ?? panes[0] }

    // MARK: change tracking

    public func start() {
        guard pollSource == nil else { return }
        watcher = try? ChangeWatcher(graph: graph)
        lastVersion = watcher?.version() ?? 0
        themes.startWatching()
        #if canImport(AppKit)
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushAndWait() }
        }
        #endif
        // The database is checked for outside changes on a background queue; the main thread only hears about real changes.
        let watcher = self.watcher
        let source = DispatchSource.makeTimerSource(queue: pollQueue)
        source.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let watcher else { return }
            let v = watcher.version()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.noteVersion(v) } }
        }
        source.resume()
        pollSource = source
    }

    // MARK: sync

    /// Starts syncing with the hub when the graph has a `sync.json` (or a transport is given, for tests).
    public func startSync(transport: SyncTransport? = nil, deviceID: String? = nil, interval: TimeInterval = 30) {
        if let transport { syncTransport = transport; syncClient = SyncClient(graph: graph, deviceID: deviceID) }
        else if let cfg = SyncConfig.load(for: graph) { syncTransport = cfg.transport(); syncClient = cfg.client(for: graph) }
        else { syncStatus = .off; return }
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.syncNow(manual: false) } }
        syncNow()
    }

    /// Syncs soon (after local edits settle).
    public func kickSync() {
        guard syncClient != nil else { return }
        syncKick?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.syncNow(manual: false) } }
        syncKick = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    /// `manual` syncs (the button, the palette) always try; the timer and the after-edit kick wait out the backoff after repeated failures.
    public func syncNow(manual: Bool = true) {
        guard let client = syncClient, let transport = syncTransport, !syncing else { return }
        if !manual, Date() < retryNotBefore { return }
        syncing = true
        syncStatus = .syncing
        flushAll()
        Task { @MainActor in
            do {
                let report = try await client.sync(using: transport)
                lastSyncError = nil
                lastSyncedAt = Date()
                syncFailures = 0; retryNotBefore = .distantPast
                refreshPending()
                refreshIssues()
                syncStatus = report.rejected > 0 ? .failed("\(report.rejected) change(s) were rejected by the hub; open Sync Issues") : .synced(Date(), conflicts: report.conflicts)
                if report.pulled > 0 || report.rejected > 0 { lastVersion = watcher?.version() ?? lastVersion; databaseChanged() }
            } catch {
                lastSyncError = "\(error)"
                syncFailures += 1
                retryNotBefore = Date().addingTimeInterval(SyncClient.retryDelay(afterFailures: syncFailures))
                refreshPending()
                refreshIssues()
                let pending = (try? client.pendingCount()) ?? 0
                syncStatus = (error is URLError) ? .offline(pending: pending) : .failed("\(error)")
            }
            syncing = false
        }
    }

    public func stop() { quitObserver.map(NotificationCenter.default.removeObserver); quitObserver = nil; pollSource?.cancel(); pollSource = nil; themes.stopWatching(); syncTimer?.invalidate(); flushAll() }

    func noteVersion(_ v: Int64) {
        guard v != lastVersion else { return }
        lastVersion = v
        databaseChanged()
    }

    /// Call after any write the store made itself (the watcher also notices, but this is immediate).
    public func databaseChanged() {
        revision += 1
        refreshPending()
        kickSync()
        refreshLists()
        models.removeAll { $0.model == nil }
        for m in models { m.model?.externalChangeDetected() }
    }

    /// Candidates for the editor's `[[`, `#`, `((` popups.
    public var autocompleteSource: AutocompleteSource {
        let graph = self.graph
        return AutocompleteSource(
            pages: { q in ((try? graph.pages(matching: q, limit: 12)) ?? []).map(\.title) },
            tags: { q in (try? graph.tagNames(matching: q, limit: 12)) ?? [] },
            blocks: { q in
                ((try? graph.search(q, limit: 12)) ?? []).compactMap { hit in
                    guard let id = hit.blockID else { return nil }
                    return (id: id, text: hit.snippet.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: ""))
                }
            })
    }

    private static let blockRefPattern = try! NSRegularExpression(pattern: #"\(\(([0-9a-fA-F-]{36})\)\)"#)

    /// Replaces `((block-id))` references with the text of the block they point to (for read-only display; the editor keeps the raw reference).
    public func expandBlockRefs(_ text: String) -> String {
        guard text.contains("((") else { return text }
        var out = text
        for m in Self.blockRefPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let idRange = Range(m.range(at: 1), in: text), let whole = Range(m.range, in: out) else { continue }
            let id = String(text[idRange]).lowercased()
            var snippet = (try? graph.db.read { try String.fetchOne($0, sql: "SELECT text FROM blocks WHERE id = ?", arguments: [id]) }) ?? nil
            snippet = snippet?.components(separatedBy: "\n").first
            let short = snippet.map { $0.count > 120 ? String($0.prefix(120)) + "…" : $0 } ?? "(missing block)"
            out.replaceSubrange(whole, with: "“\(short)”")
        }
        return out
    }

    public func register(_ model: PageEditorModel) {
        models.append(WeakModel(model: model))
        model.onEdited = { [weak self] in self?.typingUnsaved = true }
    }

    /// Re-counts the unsent changes (cheap: one count on an indexed column).
    public func refreshIssues() { syncIssues = (try? syncClient?.issueList()) ?? [] }

    public func showSyncIssues() { refreshIssues(); issuesVisible = true }

    public func clearSyncIssues() {
        do { try syncClient?.clearIssues() } catch { show("Couldn't clear: \(error)") }
        refreshIssues()
        if syncIssues.isEmpty { issuesVisible = false; if case .failed = syncStatus { syncStatus = .synced(Date(), conflicts: 0) } }
    }

    public func refreshPending() {
        pendingChanges = (try? syncClient?.pendingCount()) ?? 0
        typingUnsaved = models.contains { $0.model?.isDirty == true }
    }
    /// Saves everything and waits (used when the app is quitting).
    public func flushAndWait() { flushAll(); for m in models { m.model?.waitUntilIdle() } }
    public func flushAll() { for m in models { m.model?.flush() } }

    public func refreshLists() {
        favorites = (try? graph.favorites()) ?? []
        refreshRecents()
        dueCards = (try? graph.cardCounts().due) ?? 0
    }

    // MARK: recents
    private static let recentLimit = 12
    private var visitedKey: String { "visited:" + graph.folder.path }
    /// Page ids in the order they were opened here, newest first (this device only).
    private var visited: [String] {
        get { defaults.stringArray(forKey: visitedKey) ?? [] }
        set { defaults.set(Array(newValue.prefix(40)), forKey: visitedKey) }
    }

    /// Pages you opened, newest first; if fewer than the limit, the rest are the most recently edited pages.
    func refreshRecents() {
        var out: [Page] = visited.lazy.compactMap { self.page(id: $0) }.prefix(Self.recentLimit).map { $0 }
        if out.count < Self.recentLimit {
            let have = Set(out.map(\.id))
            out += ((try? graph.recentPages(limit: Self.recentLimit)) ?? []).filter { !have.contains($0.id) }.prefix(Self.recentLimit - out.count)
        }
        recents = out
    }

    /// Remembers that the page now showing in the focused pane was visited.
    private func noteVisit() {
        guard case .page(let id) = focusedPane.location else { return }
        visited = [id] + visited.filter { $0 != id }
        refreshRecents()
    }

    // MARK: navigation

    public func open(_ location: Location, newPane: Bool = false, in paneID: UUID? = nil) {
        flushAll()
        if newPane, panes.count < GraphStore.maxPanes {
            let p = Pane(location: location)
            panes.append(p)
            focusedPaneID = p.id
        } else {
            if compact { sidebarVisible = false }
            let id = paneID ?? focusedPaneID
            if let i = panes.firstIndex(where: { $0.id == id }) { panes[i].go(to: location); focusedPaneID = id }
            else { panes[0].go(to: location); focusedPaneID = panes[0].id }
        }
        savePanes()
        noteVisit()
    }

    public func back(in id: UUID? = nil) { mutate(id) { $0.goBack() } }
    public func forward(in id: UUID? = nil) { mutate(id) { $0.goForward() } }

    private func mutate(_ id: UUID?, _ f: (inout Pane) -> Void) {
        flushAll()
        let target = id ?? focusedPaneID
        if let i = panes.firstIndex(where: { $0.id == target }) { f(&panes[i]) }
        savePanes()
        noteVisit()
    }

    public func closePane(_ id: UUID) {
        guard panes.count > 1, let i = panes.firstIndex(where: { $0.id == id }) else { return }
        flushAll()
        panes.remove(at: i)
        if focusedPaneID == id { focusedPaneID = panes[max(0, i - 1)].id }
        savePanes()
    }

    public func focusPane(at index: Int) { if panes.indices.contains(index) { focusedPaneID = panes[index].id } }

    public func openToday(newPane: Bool = false) { open(.journals, newPane: newPane) }

    /// Follows a link from a block. Pages that don't exist yet are created.
    public func openLink(_ target: LinkTarget, newPane: Bool) {
        switch target {
        case .page(let title), .tag(let title):
            if let id = pageID(forTitle: title, create: true) { open(.page(id), newPane: newPane) }
        case .url(let url):
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        case .block(let id):
            if let b = try? graph.db.read({ try Block.fetchOne($0, key: id) }) { open(.page(b.pageId), newPane: newPane) }
        }
    }

    public func pageID(forTitle title: String, create: Bool) -> String? {
        if let p = try? graph.page(titled: title) { return p.id }
        guard create else { return nil }
        let id = Graph.pageID(forTitle: title)
        do { try graph.perform([.createPage(id: id, title: title, kind: .page, journalDate: nil)], author: .me) } catch { return nil }
        databaseChanged()
        return id
    }

    public func block(id: String) -> Block? { try? graph.db.read { try Block.fetchOne($0, key: id) } }

    // MARK: flashcards on a page
    /// The bullet the caret is in (set by the page editor), so "review cards under this bullet" knows what "this" is.
    public struct CaretBlock: Equatable { public let pageID: String; public let blockID: String }
    @ObservationIgnored public var caretBlock: CaretBlock?

    /// The caret's bullet, or the nearest enclosing one, holding cards: the closest with two or more (a chapter, not the card being
    /// edited), else the closest with any. nil when the focused pane isn't that page or nothing around the caret has cards.
    public var caretReviewCandidate: (pageID: String, blockID: String)? {
        guard let c = caretBlock, case .page(let id) = focusedPane.location, id == c.pageID else { return nil }
        var fallback: String?, cur: String? = c.blockID
        while let b = cur {
            let n = (try? graph.cardCounts(scope: .block(b)).total) ?? 0
            if n >= 2 { return (c.pageID, b) }
            if n == 1, fallback == nil { fallback = b }
            cur = block(id: b)?.parentId
        }
        return fallback.map { (c.pageID, $0) }
    }

    public func reviewCardsAtCaret(newPane: Bool = false) {
        guard let t = caretReviewCandidate else { show("No flashcards under this bullet"); return }
        open(.review(page: t.pageID, block: t.blockID), newPane: newPane)
    }

    public func page(id: String) -> Page? { try? graph.db.read { try Page.fetchOne($0, key: id) } }

    public func toggleFavorite(pageID: String) {
        guard let p = page(id: pageID) else { return }
        _ = try? graph.perform([.setFavorite(pageID: pageID, favorite: !p.favorite, order: nil)], author: .me)
        databaseChanged()
    }

    public func rename(pageID: String, to title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        do { try graph.perform([.renamePage(id: pageID, title: clean)], author: .me) }
        catch GraphError.titleTaken { show("A page titled “\(clean)” already exists"); return false }
        catch { show("Couldn't rename: \(error)"); return false }
        databaseChanged()
        return true
    }

    /// Asks to confirm deleting a page.
    public func requestDeletePage(_ pageID: String) {
        guard let p = page(id: pageID) else { return }
        pageAwaitingDeletionLinks = (try? graph.backlinks(pageID: pageID).count) ?? 0
        pageAwaitingDeletion = p
    }

    /// Deletes a page and its blocks (a linked page is only emptied, see `Graph.deletePageOp`); panes showing it go back.
    public func deletePage(id: String) {
        flushAndWait()
        guard let p = page(id: id) else { return }
        do { try graph.perform([try graph.deletePageOp(pageID: id)], author: .me) }
        catch { show("Couldn't delete: \(error)"); return }
        for i in panes.indices { panes[i].forget(.page(id)) }
        visited.removeAll { $0 == id }
        savePanes()
        databaseChanged()
        show("Deleted “\(p.title)”")
    }

    public func show(_ message: String) {
        toast = message
        Task { @MainActor in try? await Task.sleep(nanoseconds: 2_500_000_000); if self.toast == message { self.toast = nil } }
    }

    // MARK: persistence of the window layout

    private static func key(_ graph: Graph) -> String { "panes:" + graph.folder.path }

    private func savePanes() {
        if let data = try? JSONEncoder().encode(panes.map(\.location)) { defaults.set(data, forKey: GraphStore.key(graph)) }
    }

    private static func restorePanes(_ defaults: UserDefaults, key: String) -> [Pane] {
        guard let data = defaults.data(forKey: key), let locs = try? JSONDecoder().decode([Location].self, from: data) else { return [] }
        return locs.prefix(maxPanes).map { Pane(location: $0) }
    }
}

public enum SyncStatus: Equatable {
    case off, syncing, synced(Date, conflicts: Int), offline(pending: Int), failed(String)

    public var label: String {
        switch self {
        case .off: return ""
        case .syncing: return "Syncing…"
        case .synced(_, let c): return c > 0 ? "Synced · \(c) conflict\(c == 1 ? "" : "s") kept" : "Synced"
        case .offline(let n): return n > 0 ? "Offline · \(n) pending" : "Offline"
        case .failed: return "Sync error"
        }
    }
}

import Foundation

/// What a pane is showing.
public enum Location: Hashable, Codable, Sendable {
    case journals
    case page(String)          // page id
    case allPages
    case tags
    case search(String)
    case review(page: String?, block: String?)      // block = review only the cards inside that bullet
}

public struct Pane: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var location: Location
    public var back: [Location] = []
    public var forward: [Location] = []
    public init(id: UUID = UUID(), location: Location) { self.id = id; self.location = location }

    public mutating func go(to new: Location) {
        guard new != location else { return }
        back.append(location)
        forward.removeAll()
        location = new
    }
    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }
    public mutating func goBack() { guard let l = back.popLast() else { return }; forward.append(location); location = l }
    public mutating func goForward() { guard let l = forward.popLast() else { return }; back.append(location); location = l }
    /// Drops a location that no longer exists (a deleted page) from the history; if it's showing, the pane goes back.
    public mutating func forget(_ gone: Location) {
        back.removeAll { $0 == gone }
        forward.removeAll { $0 == gone }
        if location == gone { location = back.popLast() ?? .allPages }
    }
}

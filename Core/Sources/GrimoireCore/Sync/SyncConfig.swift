import Foundation

/// Where and as whom this install syncs: `sync.json` in the graph folder (it holds a token, so it stays out of the synced data and is mode 600).
public struct SyncConfig: Codable, Sendable, Equatable {
    public var url: URL
    public var token: String
    /// The name the hub knows this install by.
    public var device: String
    /// Sent as the Host header. Lets a device reach the hub by its tailnet IP (when MagicDNS is off) while the proxy still routes by name.
    public var hostHeader: String?
    public init(url: URL, token: String, device: String, hostHeader: String? = nil) { self.url = url; self.token = token; self.device = device; self.hostHeader = hostHeader }

    public static func file(in graph: Graph) -> URL { graph.folder.appendingPathComponent("sync.json") }

    public static func load(for graph: Graph) -> SyncConfig? {
        try? JSONDecoder().decode(SyncConfig.self, from: Data(contentsOf: file(in: graph)))
    }

    public func save(for graph: Graph) throws {
        let url = Self.file(in: graph)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func transport() -> HTTPSyncTransport { HTTPSyncTransport(baseURL: url, token: token, hostHeader: hostHeader) }
    public func client(for graph: Graph) -> SyncClient { SyncClient(graph: graph, deviceID: device) }
}

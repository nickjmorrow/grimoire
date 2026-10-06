import Foundation

/// An op as stored on the hub, in the one global order.
public struct RemoteOp: Codable, Sendable, Equatable {
    public var seq: Int64
    public var device: String
    public var originLocalID: Int64
    public var author: String
    public var payload: String          // the Op as JSON
    public var createdAt: Int64
    public init(seq: Int64, device: String, originLocalID: Int64, author: String, payload: String, createdAt: Int64) {
        self.seq = seq; self.device = device; self.originLocalID = originLocalID; self.author = author; self.payload = payload; self.createdAt = createdAt
    }
}

/// An op a device has made and not yet had sequenced.
public struct OutgoingOp: Codable, Sendable, Equatable {
    public var localID: Int64
    public var author: String
    public var payload: String
    public var createdAt: Int64
    public init(localID: Int64, author: String, payload: String, createdAt: Int64) {
        self.localID = localID; self.author = author; self.payload = payload; self.createdAt = createdAt
    }
}

public struct SeqAssignment: Codable, Sendable, Equatable { public var localID: Int64; public var seq: Int64 }
public struct Rejection: Codable, Sendable, Equatable { public var localID: Int64; public var reason: String }

public enum PushResult: Codable, Sendable, Equatable {
    /// Ops were applied on the hub and given sequence numbers; `rejected` ones could not be applied there.
    case accepted(assigned: [SeqAssignment], rejected: [Rejection])
    /// Someone else got in first: pull up to `head`, rebase, and push again.
    case behind(head: Int64)
}

/// How a device talks to the hub. The HTTP version lives beside the server; tests use an in-process one.
public protocol SyncTransport: Sendable {
    func pull(since: Int64) async throws -> [RemoteOp]
    func push(base: Int64, device: String, ops: [OutgoingOp]) async throws -> PushResult
    func putAsset(hash: String, data: Data) async throws
    func getAsset(hash: String) async throws -> Data?
}

public struct SyncReport: Sendable, Equatable {
    public var pulled = 0, pushed = 0, rejected = 0, conflicts = 0, assetsDown = 0, assetsUp = 0
    public init() {}
}

public enum SyncError: Error, Equatable {
    case couldNotCatchUp, rollbackFailed(String), assetHashMismatch(String)
    /// The graph has history that cannot be replayed (an import) and the hub already holds data, so the two cannot be merged automatically.
    case needsReset
}

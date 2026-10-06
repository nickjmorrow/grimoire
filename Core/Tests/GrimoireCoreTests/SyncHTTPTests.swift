import Foundation
import Testing
@testable import GrimoireCore

/// Routes URLSession requests to a SyncHTTP in the same process.
final class HubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var http: SyncHTTP?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var q: [String: String] = [:]
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.forEach { q[$0.name] = $0.value }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream { s.open(); var buf = [UInt8](repeating: 0, count: 65536); while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(contentsOf: buf[0..<n]) }; s.close() }
        let r = Self.http!.handle(method: request.httpMethod ?? "GET", path: url.path, query: q, authorization: request.value(forHTTPHeaderField: "Authorization"), body: body)
        let resp = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": r.contentType])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct SyncHTTPTests {
    func transport(token: String, http: SyncHTTP) -> HTTPSyncTransport {
        HubURLProtocol.http = http
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [HubURLProtocol.self]
        return HTTPSyncTransport(baseURL: URL(string: "https://hub.test")!, token: token, session: URLSession(configuration: cfg))
    }

    @Test func twoDevicesSyncThroughTheHTTPLayer() async throws {
        let hub = SyncHub(graph: try Graph(folder: tempFolder(), device: "hub"))
        let http = SyncHTTP(hub: hub, tokens: ["tok-a": "A", "tok-b": "B"])
        let a = try Graph(folder: tempFolder(), device: "A"), b = try Graph(folder: tempFolder(), device: "B")
        try a.perform([.createPage(id: "p", title: "Over HTTP", kind: .page, journalDate: nil), .insertBlock(id: "x", pageID: "p", parentID: nil, orderKey: "a", text: "hello")], author: .me)
        try await SyncClient(graph: a).sync(using: transport(token: "tok-a", http: http))
        try await SyncClient(graph: b).sync(using: transport(token: "tok-b", http: http))
        #expect(try syncState(a) == syncState(b))
    }

    @Test func badOrMissingTokensAreRefusedAndTheDeviceComesFromTheToken() async throws {
        let hub = SyncHub(graph: try Graph(folder: tempFolder(), device: "hub"))
        let http = SyncHTTP(hub: hub, tokens: ["tok-a": "A"])
        let t = transport(token: "wrong", http: http)
        await #expect(throws: SyncHTTPError.self) { _ = try await t.pull(since: 0) }
        // a device that claims to be someone else is recorded under its token's name
        let good = transport(token: "tok-a", http: http)
        let op = OutgoingOp(localID: 1, author: "me", payload: String(decoding: try JSONEncoder().encode(Op.createPage(id: "p", title: "T", kind: .page, journalDate: nil)), as: UTF8.self), createdAt: 1)
        _ = try await good.push(base: 0, device: "mallory", ops: [op])
        #expect(try hub.pull(since: 0).first?.device == "A")
    }

    @Test func assetsRoundTripAndBadHashesAreRejected() async throws {
        let hub = SyncHub(graph: try Graph(folder: tempFolder(), device: "hub"))
        let t = transport(token: "t", http: SyncHTTP(hub: hub, tokens: ["t": "A"]))
        let hash = SHA256Hex.of(Data("bytes".utf8))
        try await t.putAsset(hash: hash, data: Data("bytes".utf8))
        #expect(try await t.getAsset(hash: hash) == Data("bytes".utf8))
        await #expect(throws: SyncHTTPError.self) { try await t.putAsset(hash: String(repeating: "ab", count: 32), data: Data("wrong".utf8)) }
        #expect(try await t.getAsset(hash: String(repeating: "cd", count: 32)) == nil)
        #expect(try await t.getAsset(hash: "../../etc/passwd") == nil)
    }
}

import Foundation

/// The hub's HTTP API as a pure function, so it can be tested without sockets. The server in `grim-sync` only does the networking.
///
///     POST /sync/pull?since=N       → [RemoteOp]
///     POST /sync/push               {base, ops:[OutgoingOp]} → PushResult   (device comes from the bearer token)
///     PUT  /sync/asset/<sha256>?filename=x   raw bytes
///     GET  /sync/asset/<sha256>     raw bytes, 404 when unknown
public struct SyncHTTP: Sendable {
    public let hub: SyncHub
    /// Bearer token → device name.
    public let tokens: [String: String]
    public static let maxBody = 64 * 1024 * 1024

    public init(hub: SyncHub, tokens: [String: String]) { self.hub = hub; self.tokens = tokens }

    public struct Response: Sendable { public var status: Int; public var contentType = "application/json"; public var body: Data
        public init(status: Int, contentType: String = "application/json", body: Data) { self.status = status; self.contentType = contentType; self.body = body } }

    struct PushBody: Codable { var base: Int64; var ops: [OutgoingOp] }

    /// True when the Authorization header carries a known token (checked before large bodies are read).
    public func isAuthorized(_ authorization: String?) -> Bool {
        guard let a = authorization, a.hasPrefix("Bearer ") else { return false }
        return tokens[String(a.dropFirst(7))] != nil
    }

    public func handle(method: String, path: String, query: [String: String], authorization: String?, body: Data) -> Response {
        guard let auth = authorization, auth.hasPrefix("Bearer "), let device = tokens[String(auth.dropFirst(7))] else { return text(401, "unauthorized") }
        do {
            switch (method, path) {
            case ("POST", "/sync/pull"):
                guard let since = Int64(query["since"] ?? "0") else { return text(400, "bad since") }
                return json(try hub.pull(since: since))
            case ("POST", "/sync/push"):
                guard let b = try? JSONDecoder().decode(PushBody.self, from: body) else { return text(400, "bad body") }
                return json(try hub.push(device: device, base: b.base, ops: b.ops))
            case ("GET", _) where path.hasPrefix("/sync/asset/"):
                guard let url = hub.assetURL(hash: String(path.dropFirst("/sync/asset/".count))), let data = try? Data(contentsOf: url) else { return text(404, "no such asset") }
                return Response(status: 200, contentType: "application/octet-stream", body: data)
            case ("PUT", _) where path.hasPrefix("/sync/asset/"):
                let hash = String(path.dropFirst("/sync/asset/".count))
                guard body.count <= Self.maxBody else { return text(413, "too large") }
                try hub.putAsset(hash: hash, filename: query["filename"], data: body)
                return text(204, "")
            default: return text(404, "not found")
            }
        } catch let e as SyncError { return text(400, "\(e)") }
        catch { return text(500, "\(error)") }
    }

    private func text(_ status: Int, _ s: String) -> Response { Response(status: status, contentType: "text/plain", body: Data(s.utf8)) }
    private func json<T: Encodable>(_ v: T) -> Response { Response(status: 200, body: (try? JSONEncoder().encode(v)) ?? Data("null".utf8)) }
}

/// Talks to a `grim-sync` server over HTTPS (Tailscale) with this device's bearer token.
public final class HTTPSyncTransport: SyncTransport, @unchecked Sendable {
    let base: URL
    let token: String
    let session: URLSession
    let hostHeader: String?

    public init(baseURL: URL, token: String, hostHeader: String? = nil, session: URLSession = .shared) { base = baseURL; self.token = token; self.hostHeader = hostHeader; self.session = session }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> (Data, Int) {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let hostHeader { req.setValue(hostHeader, forHTTPHeaderField: "Host") }
        req.httpBody = body
        req.timeoutInterval = 90
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func pull(since: Int64) async throws -> [RemoteOp] {
        let (data, status) = try await request("POST", "sync/pull", query: [URLQueryItem(name: "since", value: String(since))])
        guard status == 200 else { throw SyncHTTPError.status(status, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode([RemoteOp].self, from: data)
    }

    public func push(base: Int64, device: String, ops: [OutgoingOp]) async throws -> PushResult {
        let body = try JSONEncoder().encode(SyncHTTP.PushBody(base: base, ops: ops))
        let (data, status) = try await request("POST", "sync/push", body: body)
        guard status == 200 else { throw SyncHTTPError.status(status, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder().decode(PushResult.self, from: data)
    }

    public func putAsset(hash: String, data: Data) async throws {
        let (resp, status) = try await request("PUT", "sync/asset/\(hash)", body: data)
        guard status == 204 else { throw SyncHTTPError.status(status, String(decoding: resp, as: UTF8.self)) }
    }

    public func getAsset(hash: String) async throws -> Data? {
        let (data, status) = try await request("GET", "sync/asset/\(hash)")
        if status == 404 { return nil }
        guard status == 200 else { throw SyncHTTPError.status(status, String(decoding: data, as: UTF8.self)) }
        return data
    }
}

public enum SyncHTTPError: Error { case status(Int, String) }

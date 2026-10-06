import ArgumentParser
import Foundation
import GrimoireCore
import Network

/// The sync hub: serves `SyncHTTP` on a local port; `tailscale serve` puts HTTPS in front of it (tailnet only).
struct GrimSync: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "grim-sync", abstract: "Grimoire sync hub (HTTP on 127.0.0.1; put `tailscale serve` in front).")
    @Option(help: "The hub graph folder.") var graph: String = NSHomeDirectory() + "/Grimoire-hub"
    @Option(help: "JSON file mapping bearer tokens to device names, e.g. {\"<token>\": \"iphone\"}.") var tokens: String
    @Option(help: "Port on 127.0.0.1.") var port: UInt16 = 8780

    func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: (tokens as NSString).expandingTildeInPath))
        guard let map = try JSONSerialization.jsonObject(with: data) as? [String: String], !map.isEmpty else {
            FileHandle.standardError.write(Data("tokens file must be a non-empty JSON object of token → device\n".utf8)); throw ExitCode(1)
        }
        let hub = SyncHub(graph: try Graph(folder: URL(fileURLWithPath: (graph as NSString).expandingTildeInPath), device: "hub"))
        let http = SyncHTTP(hub: hub, tokens: map)
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        let queue = DispatchQueue(label: "grim-sync")
        listener.newConnectionHandler = { conn in Connection(conn, http: http, queue: queue).start() }
        listener.stateUpdateHandler = { if case .ready = $0 { print("grim-sync listening on 127.0.0.1:\(port), \(map.count) device(s)") ; fflush(stdout) } }
        listener.start(queue: queue)
        dispatchMain()
    }
}

/// One HTTP/1.1 request per connection (the clients are URLSession and curl; keep-alive is not needed).
final class Connection {
    let conn: NWConnection, http: SyncHTTP, queue: DispatchQueue
    var buffer = Data()
    var responded = false
    init(_ c: NWConnection, http: SyncHTTP, queue: DispatchQueue) { conn = c; self.http = http; self.queue = queue }

    func start() { conn.start(queue: queue); receive() }

    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
            if responded { return }
            if let data { buffer.append(data) }
            if error != nil { conn.cancel(); return }
            if let req = parse() { respond(req) } else if responded { return } else if done { conn.cancel() } else if buffer.count > SyncHTTP.maxBody + 65536 { send(413, "too large") } else { receive() }
        }
    }

    struct Request { var method: String; var path: String; var query: [String: String]; var auth: String?; var body: Data }

    func parse() -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in head.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard http.isAuthorized(headers["authorization"]) else { send(401, "unauthorized"); return nil }
        guard length <= SyncHTTP.maxBody else { send(413, "too large"); return nil }
        guard buffer.count >= end.upperBound + length else { return nil }
        let body = buffer[end.upperBound..<(end.upperBound + length)]
        let comps = URLComponents(string: String(parts[1]))
        var q: [String: String] = [:]
        comps?.queryItems?.forEach { q[$0.name] = $0.value }
        return Request(method: String(parts[0]), path: comps?.path ?? String(parts[1]), query: q, auth: headers["authorization"], body: Data(body))
    }

    func respond(_ r: Request) {
        let res = http.handle(method: r.method, path: r.path, query: r.query, authorization: r.auth, body: r.body)
        send(res.status, nil, res)
    }

    func send(_ status: Int, _ text: String?, _ res: SyncHTTP.Response? = nil) {
        responded = true
        let body = res?.body ?? Data((text ?? "").utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\nContent-Type: \(res?.contentType ?? "text/plain")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }
}

GrimSync.main()

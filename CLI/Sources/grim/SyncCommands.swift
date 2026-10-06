import ArgumentParser
import Foundation
import GrimoireCore

/// Runs async work from a synchronous command.
func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task { do { box.value = .success(try await body()) } catch { box.value = .failure(error) }; sem.signal() }
    sem.wait()
    return try box.value!.get()
}
final class ResultBox<T: Sendable>: @unchecked Sendable { var value: Result<T, Error>? }

struct SyncCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Sync this graph with the hub (needs sync.json; see sync-setup).")
    @OptionGroup var g: GlobalOptions
    func run() throws {
        let graph = try g.open()
        guard let cfg = SyncConfig.load(for: graph) else { eprint("not set up: run `grim sync-setup --url … --token … --name …`"); throw ExitCode(2) }
        let client = cfg.client(for: graph), transport = cfg.transport()
        do {
            let r = try blocking { try await client.sync(using: transport) }
            if g.json { printJSON(["pulled": r.pulled, "pushed": r.pushed, "rejected": r.rejected, "conflicts": r.conflicts]) }
            else { print("pulled \(r.pulled), pushed \(r.pushed)\(r.conflicts > 0 ? ", \(r.conflicts) conflict(s) kept as siblings" : "")\(r.rejected > 0 ? ", \(r.rejected) rejected" : "")") }
        } catch { eprint("sync failed: \(error)"); throw ExitCode(5) }
    }
}

struct SyncSetup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync-setup", abstract: "Save the hub address, this install's token and its device name.")
    @OptionGroup var g: GlobalOptions
    @Option(help: "Hub URL, e.g. https://hub.example.ts.net:8447") var url: String
    @Option(help: "This device's bearer token.") var token: String
    @Option(help: "Name the hub knows this device by.") var name: String
    @Option(help: "Host header to send (reach the hub by IP while the proxy routes by name).") var hostHeader: String?
    func run() throws {
        guard let u = URL(string: url), u.scheme != nil else { eprint("bad url"); throw ExitCode(1) }
        try SyncConfig(url: u, token: token, device: name, hostHeader: hostHeader).save(for: try g.open())
        print("saved")
    }
}

struct SyncStatusCmd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync-status", abstract: "Unsent changes, last synced position and any sync issues.")
    @OptionGroup var g: GlobalOptions
    func run() throws {
        let graph = try g.open()
        let c = SyncClient(graph: graph)
        let issues = try c.issues()
        let out: [String: Any] = ["configured": SyncConfig.load(for: graph) != nil, "pending": try c.pendingCount(), "lastSeq": try c.lastSeq(), "issues": issues.map { $0.reason }]
        if g.json { printJSON(out) } else { print("pending \(out["pending"]!), last seq \(out["lastSeq"]!), \(issues.count) issue(s)"); issues.suffix(5).forEach { print("  \($0.source): \($0.reason)") } }
    }
}

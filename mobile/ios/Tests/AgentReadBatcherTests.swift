import Foundation

@MainActor private final class Agent {
    var batches: [[String]] = []
    var singles: [String] = []
    var batchFailure: AgentError?
    var delay: Duration = .milliseconds(5)

    func single(_ path: String) async throws -> AgentHTTPResponse {
        singles.append(path)
        try await Task.sleep(for: delay)
        return try Self.envelope(path)
    }
    func batch(_ paths: [String]) async throws -> AgentHTTPResponse {
        batches.append(paths)
        try await Task.sleep(for: delay)
        if let batchFailure { throw batchFailure }
        let responses = paths.map { path -> [String: Any] in
            path.hasSuffix("missing") ? ["status": 404, "body": ["ok": false, "error": "not found"]]
                : ["status": 200, "body": ["ok": true, "data": ["path": path]]]
        }
        return AgentHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["responses": responses]]))
    }
    static func envelope(_ path: String) throws -> AgentHTTPResponse {
        AgentHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": ["path": path]]))
    }
}

private func path(of response: AgentHTTPResponse) -> String? {
    ((try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]).flatMap { ($0["data"] as? [String: Any])?["path"] as? String }
}

@MainActor private func reads(_ batcher: AgentReadBatcher, _ paths: [String], scope: String = "local") async -> [String: Result<AgentHTTPResponse, Error>] {
    await withTaskGroup(of: (String, Result<AgentHTTPResponse, Error>).self) { group in
        for path in paths {
            group.addTask { @MainActor in
                do { return (path, .success(try await batcher.read(scope: scope, path: path))) }
                catch { return (path, .failure(error)) }
            }
        }
        var results: [String: Result<AgentHTTPResponse, Error>] = [:]
        for await (path, result) in group { results[path] = result }
        return results
    }
}

@main struct AgentReadBatcherTests {
    @MainActor static func main() async throws {
        // Reads started together share one batch; each caller receives its own response and status.
        do {
            let agent = Agent()
            let batcher = AgentReadBatcher(single: agent.single, batch: agent.batch)
            let paths = ["/api/battery", "/api/cpu", "/api/network/signal", "/api/thermal-missing"]
            let results = await reads(batcher, paths)
            precondition(agent.batches.count == 1 && Set(agent.batches[0]) == Set(paths) && agent.singles.isEmpty)
            for path in paths {
                let response = try results[path]!.get()
                if path.hasSuffix("missing") { precondition(response.status == 404) }
                else { precondition(response.status == 200 && pathOf(response) == path) }
            }
        }
        // A lone read is not wrapped in a batch.
        do {
            let agent = Agent()
            let batcher = AgentReadBatcher(single: agent.single, batch: agent.batch)
            let response = try await batcher.read(scope: "local", path: "/api/speedtest/progress")
            precondition(agent.batches.isEmpty && agent.singles == ["/api/speedtest/progress"] && pathOf(response) == "/api/speedtest/progress")
        }
        // An agent without the route is detected once; later windows for that scope go straight to single reads.
        do {
            let agent = Agent()
            agent.batchFailure = .serverError("not found")
            let batcher = AgentReadBatcher(single: agent.single, batch: agent.batch)
            let first = await reads(batcher, ["/api/a", "/api/b", "/api/c"])
            precondition(agent.batches.count == 1 && Set(agent.singles) == ["/api/a", "/api/b", "/api/c"])
            precondition(first.values.allSatisfy { (try? $0.get()) != nil })
            _ = await reads(batcher, ["/api/d", "/api/e"])
            precondition(agent.batches.count == 1 && agent.singles.count == 5)
            // Another router or route keeps its own capability.
            _ = await reads(batcher, ["/api/f", "/api/g"], scope: "relay")
            precondition(agent.batches.count == 2)
        }
        // More than the limit splits into several batches; nothing is dropped.
        do {
            let agent = Agent()
            let batcher = AgentReadBatcher(single: agent.single, batch: agent.batch)
            let paths = (0..<21).map { "/api/read-\($0)" }
            let results = await reads(batcher, paths)
            precondition(agent.batches.map(\.count).sorted() == [5, 16])
            precondition(paths.allSatisfy { (try? results[$0]!.get()).flatMap(pathOf) == $0 })
        }
        // A transport failure is every waiter's answer; it is not retried as single reads.
        do {
            let agent = Agent()
            agent.batchFailure = .serverUnreachable
            let batcher = AgentReadBatcher(single: agent.single, batch: agent.batch)
            let results = await reads(batcher, ["/api/a", "/api/b"])
            precondition(agent.singles.isEmpty)
            for result in results.values {
                guard case .failure(AgentError.serverUnreachable) = result else { preconditionFailure("expected unreachable") }
            }
        }
        // Reads from different scopes never share a batch.
        do {
            let agent = Agent()
            let batcher = AgentReadBatcher(single: agent.single, batch: agent.batch)
            async let local = reads(batcher, ["/api/a", "/api/b"], scope: "local")
            async let relay = reads(batcher, ["/api/c", "/api/d"], scope: "relay")
            _ = await (local, relay)
            precondition(agent.batches.allSatisfy { Set($0) == ["/api/a", "/api/b"] || Set($0) == ["/api/c", "/api/d"] || $0.count == 1 }
                         && agent.batches.count + agent.singles.count >= 2)
        }
        // Cancelling one caller ends its wait without disturbing the others.
        do {
            let agent = Agent()
            agent.delay = .milliseconds(50)
            let batcher = AgentReadBatcher(single: agent.single, batch: agent.batch)
            let cancelled = Task { @MainActor in try await batcher.read(scope: "local", path: "/api/slow") }
            let kept = Task { @MainActor in try await batcher.read(scope: "local", path: "/api/kept") }
            try await Task.sleep(for: .milliseconds(15))
            let started = ContinuousClock.now
            cancelled.cancel()
            do { _ = try await cancelled.value; preconditionFailure("cancelled read returned") }
            catch is CancellationError {}
            precondition(started.duration(to: .now) < .milliseconds(40), "cancellation waited for the batch")
            let keptResponse = try await kept.value
            precondition(pathOf(keptResponse) == "/api/kept")
        }
        print("AgentReadBatcher tests passed")
    }
}

private func pathOf(_ response: AgentHTTPResponse) -> String? { path(of: response) }

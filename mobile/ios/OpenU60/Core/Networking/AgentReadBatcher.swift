import Foundation

/// Coalesces reads issued together — a dashboard tick's fan-out, a screen's parallel loads — into
/// one `POST /api/batch`. Over the relay or P2P every request is a full round trip and one of the
/// router's few management slots; batched, a tick costs one. An agent without the endpoint answers
/// "not found" once, and that scope reads individually from then on.
@MainActor
final class AgentReadBatcher {
    typealias Single = @MainActor (String) async throws -> AgentHTTPResponse
    typealias Batch = @MainActor ([String]) async throws -> AgentHTTPResponse

    static let limit = 16
    private let window: Duration
    private let single: Single
    private let batch: Batch
    private var scope: String?
    private var queued: [UUID: String] = [:]
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<AgentHTTPResponse, Error>] = [:]
    private var flush: Task<Void, Never>?
    private var unsupported: Set<String> = []

    init(window: Duration = .milliseconds(4), single: @escaping Single, batch: @escaping Batch) {
        self.window = window
        self.single = single
        self.batch = batch
    }

    func read(scope: String, path: String) async throws -> AgentHTTPResponse {
        if unsupported.contains(scope) { return try await single(path) }
        if self.scope != scope { dispatch() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                self.scope = scope
                waiters[id] = continuation
                queued[id] = path
                order.append(id)
                if order.count >= Self.limit {
                    dispatch()
                } else if flush == nil {
                    flush = Task { [weak self, window] in
                        try? await Task.sleep(for: window)
                        self?.dispatch()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }

    private func dispatch() {
        flush?.cancel()
        flush = nil
        guard let scope else { return }
        let ids = order.filter { waiters[$0] != nil }
        let entries = ids.compactMap { id in queued[id].map { (id, $0) } }
        order.removeAll()
        queued.removeAll()
        self.scope = nil
        guard !entries.isEmpty else { return }
        Task { await self.run(entries, scope: scope) }
    }

    private func run(_ entries: [(UUID, String)], scope: String) async {
        let paths = entries.reduce(into: [String]()) { if !$0.contains($1.1) { $0.append($1.1) } }
        guard paths.count > 1, !unsupported.contains(scope) else {
            await individually(entries)
            return
        }
        let results: [String: AgentHTTPResponse]
        do {
            results = try Self.decode(try await batch(paths), paths: paths)
        } catch AgentError.serverError(let code) where code == "not found" || code == "agent_response_too_large" {
            // An agent without the route; or a combined answer too large for the relay limit.
            if code == "not found" { unsupported.insert(scope) }
            await individually(entries)
            return
        } catch {
            for (id, _) in entries { finish(id, .failure(error)) }
            return
        }
        for (id, path) in entries {
            finish(id, results[path].map { .success($0) } ?? .failure(AgentError.decodingError("Batch response is missing \(path)")))
        }
    }

    private func individually(_ entries: [(UUID, String)]) async {
        await withTaskGroup(of: Void.self) { group in
            for (id, path) in entries {
                group.addTask { @MainActor in
                    do { self.finish(id, .success(try await self.single(path))) }
                    catch { self.finish(id, .failure(error)) }
                }
            }
        }
    }

    private func finish(_ id: UUID, _ result: Result<AgentHTTPResponse, Error>) {
        queued[id] = nil
        waiters.removeValue(forKey: id)?.resume(with: result)
    }

    private nonisolated static func decode(_ response: AgentHTTPResponse, paths: [String]) throws -> [String: AgentHTTPResponse] {
        guard let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              value["ok"] as? Bool == true, let data = value["data"] as? [String: Any],
              let responses = data["responses"] as? [[String: Any]], responses.count == paths.count else {
            throw AgentError.decodingError("Invalid batch response")
        }
        var results: [String: AgentHTTPResponse] = [:]
        for (path, entry) in zip(paths, responses) {
            guard let status = entry["status"] as? Int, (100...599).contains(status), let body = entry["body"],
                  JSONSerialization.isValidJSONObject(body) else { throw AgentError.decodingError("Invalid batch response") }
            results[path] = AgentHTTPResponse(status: status, data: try JSONSerialization.data(withJSONObject: body))
        }
        return results
    }
}

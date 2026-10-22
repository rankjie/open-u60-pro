import Foundation

/// Shares read work across consumers; cancelling one screen does not cancel another's read.
@MainActor
final class AgentReadPool {
    private var scope: String?
    private var generation = 0
    private var pending: [String: (id: UUID, task: Task<AgentHTTPResponse, Error>)] = [:]

    func invalidate() {
        generation += 1
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
    }

    func invalidate(prefix: String) {
        for key in pending.keys.filter({ $0 == prefix || $0.hasPrefix(prefix + "/") || $0.hasPrefix(prefix + "?") }) {
            pending.removeValue(forKey: key)?.task.cancel()
        }
    }

    func read(scope: String, path: String, load: @escaping @MainActor () async throws -> AgentHTTPResponse) async throws -> AgentHTTPResponse {
        if self.scope != scope { invalidate(); self.scope = scope }
        if let existing = pending[path] { return try await existing.task.value }
        let id = UUID(), generation = generation
        let task = Task { @MainActor in
            defer { if self.pending[path]?.id == id { self.pending[path] = nil } }
            let data = try await load()
            try Task.checkCancellation()
            guard self.generation == generation, self.pending[path]?.id == id else { throw CancellationError() }
            return data
        }
        pending[path] = (id, task)
        return try await task.value
    }
}

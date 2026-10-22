import Foundation
import Observation

/// Current SIM state belongs to the selected router, independently of the visible tab.
@Observable
@MainActor
final class SIMState {
    enum LineStatus: Equatable {
        case loading, available(CellularLine), unavailable, failed

        var label: String {
            switch self {
            case .loading: return "Loading SIM line…"
            case .available(let line): return "From \(line.label)"
            case .unavailable: return "SIM line unavailable"
            case .failed: return "Could not load SIM line"
            }
        }
    }

    private(set) var line: LineStatus = .loading
    private(set) var error: String?
    private(set) var identityRevision = 0
    @ObservationIgnored private var device: String?
    @ObservationIgnored private var identity = SimIdentityTracker()
    @ObservationIgnored private var updatedAt: Date?
    @ObservationIgnored private var payload: [String: Any]?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inFlight: (id: UUID, task: Task<[String: Any], Error>)?
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func selectDevice(_ device: String) {
        guard self.device != device else { return }
        self.device = device
        generation += 1
        inFlight?.task.cancel()
        inFlight = nil
        identity = SimIdentityTracker()
        identityRevision += 1
        invalidate()
    }

    func observeIdentity(_ data: [String: Any]?) {
        let sameSIM = identity.isSameSIM(data)
        if identity.observe(data) {
            identityRevision += 1
            if !sameSIM || data?["sim_phase"] as? String == "leaving" {
                invalidate()
            } else {
                payload = nil
                updatedAt = nil
            }
        }
    }

    /// Explicit reads stay live; the app's monitor reuses a recent successful read from any screen.
    func read(force: Bool = true, fetch: @escaping @MainActor () async throws -> [String: Any]) async throws -> [String: Any] {
        if let inFlight { return try await inFlight.task.value }
        if !force, let payload, let updatedAt, now().timeIntervalSince(updatedAt) < 30 { return payload }
        let id = UUID(), generation = generation
        let task = Task { @MainActor in
            defer { if self.inFlight?.id == id { self.inFlight = nil } }
            do {
                let data = try await fetch()
                try Task.checkCancellation()
                guard self.generation == generation else { throw CancellationError() }
                try self.accept(data)
                return data
            } catch {
                if self.generation == generation, !error.isCancellation {
                    // A failed refresh cannot turn a previously confirmed line into "no SIM".
                    self.error = error.localizedDescription
                    if self.line == .loading { self.line = .failed }
                }
                throw error
            }
        }
        inFlight = (id, task)
        return try await task.value
    }

    /// A saved number is returned by the same SIM API and must reach every consumer immediately.
    func updateNumber(_ data: [String: Any]) throws {
        generation += 1
        inFlight?.task.cancel()
        inFlight = nil
        try accept(data)
    }

    private func accept(_ data: [String: Any]) throws {
        guard identity.isCurrent(data) else { throw CancellationError() }
        guard data["sim_phase"] as? String != "leaving" else { throw CancellationError() }
        let current = try CellularLine.current(data)
        payload = data
        updatedAt = now()
        line = current.map(LineStatus.available) ?? .unavailable
        error = nil
    }

    private func invalidate() {
        line = .loading
        error = nil
        payload = nil
        updatedAt = nil
    }
}

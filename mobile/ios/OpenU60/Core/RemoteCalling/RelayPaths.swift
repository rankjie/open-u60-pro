import Foundation
import Observation

/// A QUIC entry to the same calling service, as advertised in the server's hello.
struct CallingDoor: Codable, Hashable {
    let address: String
    let label: String

    /// `quic://host:port#pin`, the same form the server validates.
    var endpoint: (host: String, port: UInt16, pin: String)? {
        guard address.hasPrefix("quic://"), let hash = address.firstIndex(of: "#") else { return nil }
        let pin = String(address[address.index(after: hash)...])
        var authority = String(address[address.index(address.startIndex, offsetBy: 7)..<hash])
        if authority.hasSuffix("/") { authority.removeLast() }
        let host: Substring, port: Substring
        if authority.hasPrefix("[") {
            guard let close = authority.range(of: "]:") else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<close.lowerBound]
            port = authority[close.upperBound...]
        } else {
            guard let colon = authority.lastIndex(of: ":") else { return nil }
            host = authority[..<colon]; port = authority[authority.index(after: colon)...]
        }
        guard !host.isEmpty, !host.contains(where: { "/@?# ".contains($0) }), let number = UInt16(port), number > 0,
              pin.count == 43, pin.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return (String(host), number, pin)
    }

    /// Doors from a hello or status payload; malformed entries are dropped, not trusted.
    static func list(_ value: Any?) -> [CallingDoor] {
        (value as? [Any] ?? []).compactMap { item in
            guard let item = item as? [String: Any],
                  let address = item["address"] as? String, let label = item["label"] as? String,
                  !label.isEmpty, label.count <= 32 else { return nil }
            let door = CallingDoor(address: address, label: label)
            return door.endpoint == nil ? nil : door
        }
    }
}

/// A started local forwarder to one door.
@MainActor protocol DoorTunnel: AnyObject {
    func start() async throws -> UInt16
    func stop()
}

/// The ways this phone can reach its calling service: the HTTPS address and each door.
/// Before a connection the paths are probed end to end; the manual preference wins when it
/// answers, otherwise the fastest path does.
@Observable @MainActor
final class RelayPaths {
    static let direct = "direct"

    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
        var latency: TimeInterval?
        /// nil while the probe is still running.
        var reachable: Bool?
    }

    private(set) var options: [Option] = []
    private(set) var current = RelayPaths.direct
    @ObservationIgnored private var tunnels: [String: (tunnel: any DoorTunnel, port: UInt16)] = [:]
    @ObservationIgnored private let makeTunnel: @MainActor (CallingDoor) -> (any DoorTunnel)?
    @ObservationIgnored private let probe: @MainActor (URL, String) async -> TimeInterval?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var selecting: Task<URL, Never>?

    init(makeTunnel: @escaping @MainActor (CallingDoor) -> (any DoorTunnel)?,
         probe: @escaping @MainActor (URL, String) async -> TimeInterval? = RelayPaths.status) {
        self.makeTunnel = makeTunnel
        self.probe = probe
    }

    /// Base URL for requests on the current path.
    func base(server: URL) -> URL {
        guard current != Self.direct, let port = tunnels[current]?.port,
              let url = URL(string: "http://127.0.0.1:\(port)") else { return server }
        return url
    }

    /// Selections run one at a time, so two of them never start a tunnel for the same door.
    @discardableResult
    func select(server: URL, token: String, doors: [CallingDoor], preference: String?) async -> URL {
        let previous = selecting
        let task = Task { @MainActor in
            _ = await previous?.value
            return await self.measure(server: server, token: token, doors: doors, preference: preference)
        }
        selecting = task
        return await task.value
    }

    private func measure(server: URL, token: String, doors: [CallingDoor], preference: String?) async -> URL {
        let addresses = Set(doors.map(\.address))
        for (address, entry) in tunnels where !addresses.contains(address) {
            entry.tunnel.stop(); tunnels[address] = nil
        }
        var candidates: [(id: String, label: String, base: URL)] = [(Self.direct, "Direct", server)]
        for door in doors {
            if tunnels[door.address] == nil, let tunnel = makeTunnel(door) {
                if let port = try? await tunnel.start() { tunnels[door.address] = (tunnel, port) } else { tunnel.stop() }
            }
            if let port = tunnels[door.address]?.port, let base = URL(string: "http://127.0.0.1:\(port)") {
                candidates.append((door.address, door.label, base))
            }
        }
        options = candidates.map { Option(id: $0.id, label: $0.label, latency: nil, reachable: nil) }
            + doors.filter { door in !candidates.contains { $0.id == door.address } }
                .map { Option(id: $0.address, label: $0.label, latency: nil, reachable: false) }
        // The choice is made shortly after the first answer, from the measured latencies of the
        // paths that answered by then, so a dead door costs nothing. The short grace absorbs
        // answers that completed together but resumed out of order. A manual choice waits for
        // its own answer and falls back if it fails. The other probes keep filling the list.
        let generation = UUID()
        self.generation = generation
        let preferred = preference.flatMap { id in candidates.contains { $0.id == id } ? id : nil }
        enum Event { case answered(reachable: Bool), graceOver }
        let (events, sink) = AsyncStream.makeStream(of: Event.self)
        for candidate in candidates {
            Task { @MainActor [probe] in
                let latency = await probe(candidate.base, token)
                // A newer selection or stop() supersedes this one.
                guard self.generation == generation else { sink.finish(); return }
                if let index = self.options.firstIndex(where: { $0.id == candidate.id }) {
                    self.options[index].latency = latency
                    self.options[index].reachable = latency != nil
                }
                sink.yield(.answered(reachable: latency != nil))
            }
        }
        var pending = candidates.count
        var graceStarted = false, graceOver = false
        var choice: String?
        for await event in events {
            switch event {
            case .answered(let reachable):
                pending -= 1
                if reachable, !graceStarted {
                    graceStarted = true
                    Task { try? await Task.sleep(for: .milliseconds(50)); sink.yield(.graceOver) }
                }
            case .graceOver:
                graceOver = true
            }
            let answered = options.filter { $0.reachable == true }
            if let preferred, answered.contains(where: { $0.id == preferred }) { choice = preferred; break }
            let preferredOpen = preferred.map { id in options.contains { $0.id == id && $0.reachable == nil } } ?? false
            if graceOver || pending == 0, !preferredOpen,
               let fastest = answered.min(by: { ($0.latency ?? .infinity) < ($1.latency ?? .infinity) }) {
                choice = fastest.id; break
            }
            if pending == 0 { break }
        }
        sink.finish()
        current = choice ?? Self.direct
        return base(server: server)
    }

    func stop() {
        generation = UUID()
        for entry in tunnels.values { entry.tunnel.stop() }
        tunnels.removeAll()
        options = []
        current = Self.direct
    }

    /// An authenticated status request: the whole path to the service, not only the first hop.
    static func status(_ base: URL, _ token: String) async -> TimeInterval? {
        var request = URLRequest(url: base.appending(path: "v1/status"), timeoutInterval: 4)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let started = ContinuousClock.now
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        let elapsed = started.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

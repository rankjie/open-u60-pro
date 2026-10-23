import Foundation
import Network
import Observation

struct AgentRelayAccess: Sendable {
    let server: URL
    let token: String
    let routerID: UUID
    let serverTime: TimeInterval
}

struct AgentHTTPResponse: Sendable {
    let status: Int
    let data: Data
}
typealias AgentPeerRequest = @MainActor (Data, UUID, TimeInterval, AgentRelayAccess) async throws -> AgentHTTPResponse?

/// Whether the phone has an interface that can lead to a private LAN (Wi-Fi, wired, or a VPN),
/// and a counter that changes with every network change.
struct LocalNetworkState: Equatable {
    var lan: Bool
    var generation: Int
}

@MainActor
final class LocalNetworkPath {
    static let shared = LocalNetworkPath()
    /// Until the first update nothing is known, so the LAN is still tried.
    private(set) var state = LocalNetworkState(lan: true, generation: 0)
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let lan = path.status == .satisfied && [.wifi, .wiredEthernet, .other].contains { path.usesInterfaceType($0) }
            Task { @MainActor in
                let shared = LocalNetworkPath.shared
                shared.state = LocalNetworkState(lan: lan, generation: shared.state.generation + 1)
            }
        }
        monitor.start(queue: .main)
    }
}

/// One effect identifier spans local and server delivery. Only the device may claim it.
@Observable @MainActor
final class AgentTransport {
    enum Route { case connecting, local, p2p, relay, unavailable }
    private(set) var route: Route = .connecting
    @ObservationIgnored private let load: @Sendable (URLRequest, Int) async throws -> AgentHTTPResponse
    @ObservationIgnored private var probe: (key: String, task: Task<LocalIdentity?, Error>)?
    @ObservationIgnored private var cached: (key: String, identity: LocalIdentity?, until: ContinuousClock.Instant, network: Int)?
    @ObservationIgnored private let network: @MainActor () -> LocalNetworkState
    @ObservationIgnored private var active = 0

    private struct LocalIdentity {
        let time: TimeInterval
        let observed: ContinuousClock.Instant
        var now: TimeInterval { time + observed.duration(to: .now).seconds }
    }

    /// One connection pool for every request to the agent. tiny_http parks a worker thread per
    /// open connection, so the pool stays at the agent's thread count instead of iOS's six per
    /// host per session; keep-alive then reuses those sockets across ticks.
    nonisolated static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 22
        return URLSession(configuration: config)
    }

    init(session: URLSession = AgentTransport.makeSession(),
         load: (@Sendable (URLRequest, Int) async throws -> AgentHTTPResponse)? = nil,
         network: @escaping @MainActor () -> LocalNetworkState = { LocalNetworkState(lan: true, generation: 0) }) {
        self.network = network
        self.load = load ?? { request, limit in
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw AgentError.serverUnreachable }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw AgentError.decodingError("Agent response exceeds the size limit") }
                data.append(byte)
            }
            return AgentHTTPResponse(status: response.statusCode, data: data)
        }
    }

    func send(method: String, path: String, body: Data?, baseURL: String, access: AgentRelayAccess,
              peer: AgentPeerRequest? = nil,
              token: @MainActor () -> String?, reauthenticate: @MainActor () async -> Bool) async throws -> AgentHTTPResponse {
        guard (body?.count ?? 0) <= 65536 else { throw AgentError.serverError("Request exceeds the size limit") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        // Dashboard reads share the router's finite worker pool with calls and push receipts.
        while active >= 6 {
            guard .now < deadline else { throw AgentError.timeout }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        active += 1
        defer { active -= 1 }
        let effectID = UUID()
        let id = effectID.uuidString.lowercased()
        let encoded = (body ?? Data()).base64EncodedString()
        let read = method == "GET" || (method == "POST" && (path == "/api/sms/list" || path == "/api/batch"))
        func payload(time: TimeInterval) throws -> Data {
            let remaining = ContinuousClock.now.duration(to: deadline).seconds
            guard remaining >= 1 else { throw AgentError.timeout }
            return try JSONSerialization.data(withJSONObject: ["requestId": id, "method": method,
                "path": path, "body": encoded, "expiresAt": Int(time + remaining)])
        }
        if let identity = try await localIdentity(baseURL: baseURL, routerID: access.routerID) {
            do {
                if token() == nil { _ = await reauthenticate() }
                if let localToken = token() {
                    var request = try Self.request(baseURL + "/api/management", token: localToken, timeout: 5)
                    request.httpBody = try payload(time: identity.now)
                    var response = try await load(request, 524288)
                    if response.status == 401, await reauthenticate(), let fresh = token() {
                        request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                        request.httpBody = try payload(time: identity.now)
                        response = try await load(request, 524288)
                    }
                    if response.status != 401 {
                        route = .local
                        return response
                    }
                }
            } catch {
                guard Self.isConnectionFailure(error) else { throw error }
                // The response may have been lost after execution. Relay the same effect ID;
                // a durable device claim then reports completed/unknown without executing twice.
                cached = nil
            }
        }
        try Task.checkCancellation()
        if let peer {
            let elapsed = 20 - ContinuousClock.now.duration(to: deadline).seconds
            do {
                if let response = try await peer(payload(time: access.serverTime + elapsed), effectID,
                                                 ContinuousClock.now.duration(to: deadline).seconds, access) {
                    route = .p2p
                    return response
                }
            } catch {
                guard Self.isConnectionFailure(error) else { throw error }
                // The router journal owns the effect across P2P and relay as well.
            }
        }
        try Task.checkCancellation()
        let serverStart = ContinuousClock.now
        let elapsed = 20 - serverStart.duration(to: deadline).seconds
        do {
            var request = try Self.request(access.server.appending(path: "v1/agent").absoluteString,
                                           token: access.token, timeout: max(1, serverStart.duration(to: deadline).seconds))
            request.httpBody = try payload(time: access.serverTime + elapsed)
            let response = try await load(request, 786432)
            guard (200..<300).contains(response.status) else {
                route = .unavailable
                let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
                let code = value?["error"] as? String
                if response.status == 401 { throw AgentError.remoteUnauthorized }
                if !read, code == "agent_outcome_unknown" || code == "agent_request_completed" || code == "agent_request_in_progress" {
                    throw AgentError.outcomeUnknown
                }
                throw AgentError.serverError(code ?? "Relay HTTP \(response.status)")
            }
            guard let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  value["requestId"] as? String == id, let status = value["status"] as? Int,
                  (200...599).contains(status), let body = value["body"] as? String,
                  let data = Data(base64Encoded: body), data.count <= 524288,
                  data.base64EncodedString() == body else { throw AgentError.decodingError("Invalid agent relay response") }
            route = .relay
            return AgentHTTPResponse(status: status, data: data)
        } catch {
            if Self.isConnectionFailure(error) {
                route = .unavailable
                if !read { throw AgentError.outcomeUnknown }
                throw AgentError.serverUnreachable
            }
            throw error
        }
    }

    /// False only when the agent's address is private and the phone has no interface that can
    /// lead there: on cellular alone a LAN probe can only time out. Any other address is tried.
    func mayReachLocally(baseURL: String) -> Bool {
        network().lan || !Self.isPrivate(URL(string: baseURL)?.host(percentEncoded: false))
    }

    private static func isPrivate(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host.hasSuffix(".local") { return true }
        if let address = IPv4Address(host) {
            let b = [UInt8](address.rawValue)
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        }
        if let address = IPv6Address(host) {
            let b = [UInt8](address.rawValue)
            return (b[0] == 0xfe && b[1] & 0xc0 == 0x80) || b[0] & 0xfe == 0xfc
        }
        return false
    }

    private func localIdentity(baseURL: String, routerID: UUID) async throws -> LocalIdentity? {
        guard mayReachLocally(baseURL: baseURL) else { return nil }
        let key = baseURL + "/" + routerID.uuidString
        let generation = network().generation
        if let cached, cached.key == key, cached.network == generation, .now < cached.until { return cached.identity }
        if let probe, probe.key == key { return try await probe.task.value }
        let load = load
        let task = Task<LocalIdentity?, Error> {
            guard let url = URL(string: baseURL + "/api/identity") else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.25
            do {
                let response = try await load(request, 4096)
                guard response.status == 200,
                      let value = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                      value["ok"] as? Bool == true, let data = value["data"] as? [String: Any],
                      data["protocol"] as? Int == 1, let id = data["routerId"] as? String,
                      UUID(uuidString: id) == routerID, let time = data["agentTime"] as? Double,
                      (946684800..<4102444800).contains(time) else { return nil }
                return LocalIdentity(time: time, observed: .now)
            } catch {
                if Self.isConnectionFailure(error) || error is DecodingError || error is CocoaError { return nil }
                throw error
            }
        }
        probe = (key, task)
        defer { if probe?.key == key { probe = nil } }
        let result = try await task.value
        cached = (key, result, .now.advanced(by: .seconds(result == nil ? 2 : 3)), generation)
        return result
    }

    /// A local acknowledgement is queue admission; CallKit still waits for the canonical result.
    func deliverCall(_ command: Data, baseURL: String, routerID: UUID,
                     token: @MainActor () -> String?, reauthenticate: @MainActor () async -> Bool) async throws -> Bool {
        guard try await localIdentity(baseURL: baseURL, routerID: routerID) != nil else { return false }
        if token() == nil { _ = await reauthenticate() }
        guard let token = token() else { return false }
        var request = try Self.request(baseURL + "/api/calling/command", token: token, timeout: 2)
        request.httpBody = command
        do {
            let response = try await load(request, 4096)
            guard response.status == 202,
                  let value = try JSONSerialization.jsonObject(with: response.data) as? [String:Any],
                  value["ok"] as? Bool == true, let data = value["data"] as? [String:Any],
                  data["queued"] as? Bool == true else { return false }
            route = .local
            return true
        } catch {
            if Self.isConnectionFailure(error) { cached = nil; return false }
            throw error
        }
    }

    private static func request(_ value: String, token: String, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: value) else { throw AgentError.serverUnreachable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if let error = error as? AgentError {
            switch error { case .serverUnreachable, .timeout, .networkError: return true; default: return false }
        }
        return false
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let value = components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

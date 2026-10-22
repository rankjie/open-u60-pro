import CryptoKit
import Foundation
import Network

enum RelayTunnelError: Error {
    /// The gateway presented a certificate other than the pinned one.
    case pinMismatch
    /// No QUIC handshake completed before the deadline (gateway unreachable or silent).
    case handshakeTimeout
    /// The shared QUIC connection ended before a stream could be opened on it.
    case connectionClosed
}

/// A loopback TCP port that reaches a relay gateway's upstream through one shared QUIC connection.
///
/// The gateway (`relay-tunnel/`) carries one TCP connection per bidirectional QUIC stream, byte
/// for byte, so HTTP and WebSocket clients keep working unchanged against `127.0.0.1:<port>`.
/// The gateway is trusted by the SHA-256 of its DER certificate, which travels with the relay
/// address, so no domain or public CA is involved.
@MainActor final class RelayTunnel {
    static let alpn = "openu60-tunnel/1"
    /// The name in the gateway's self-signed certificate. Identity comes from the pin, not this.
    private static let serverName = "openu60-relay"
    /// Network.framework never reports a failed handshake on a connection group: an unreachable
    /// gateway or a rejected certificate leave it in setup forever. This deadline ends the wait.
    private static let handshakeTimeout: TimeInterval = 10

    private let endpoint: NWEndpoint
    private let pin: Data
    /// Every Network.framework callback runs here; byte copying never touches the main actor.
    private let queue = DispatchQueue(label: "RelayTunnel")
    private var listener: NWListener?
    private var group: NWConnectionGroup?
    private var connecting: Task<NWConnectionGroup, Error>?
    /// A started, unused stream left by `probe()`.
    private var spare: (group: NWConnectionGroup, stream: NWConnection)?
    private var pipes: [ObjectIdentifier: Pipe] = [:]

    init(host: String, port: UInt16, pin: Data) {
        precondition(pin.count == 32, "A relay pin is a SHA-256 digest")
        self.endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        self.pin = pin
    }

    /// Unpadded base64url, as carried in relay addresses. Non-canonical encodings are rejected,
    /// matching the gateway's own parser.
    nonisolated static func pin(fromBase64URL text: String) -> Data? {
        guard text.utf8.count == 43, !text.contains(where: { "+/=".contains($0) }) else { return nil }
        let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let data = Data(base64Encoded: base64), data.count == 32, data.base64EncodedString() == base64 else { return nil }
        return data
    }

    /// Starts the loopback listener and returns its port. The QUIC connection is opened lazily by
    /// the first local connection (or `probe()`).
    func start() async throws -> UInt16 {
        precondition(listener == nil, "RelayTunnel already started")
        let parameters = NWParameters.tcp
        // Loopback only: anything on the LAN could otherwise ride the tunnel.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] tcp in
            Task { @MainActor in
                guard let self else { return tcp.cancel() }
                await self.forward(tcp)
            }
        }
        let ready = Once<Void>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.finish(.success(()))
            case .failed(let error), .waiting(let error): ready.finish(.failure(error))
            case .cancelled: ready.finish(.failure(CancellationError()))
            default: break
            }
        }
        self.listener = listener
        do {
            try await ready.wait { listener.start(queue: queue) }
        } catch {
            listener.cancel()
            if self.listener === listener { self.listener = nil }
            throw error
        }
        return listener.port!.rawValue
    }

    /// Ensures the QUIC connection is up and returns its smoothed round-trip time.
    ///
    /// The value is the transport's own RTT estimate (from ACKs of the handshake, keep-alives and
    /// traffic), read from a data transfer report. Reports only exist for started streams, and a
    /// started stream sends nothing until it carries data, so the stream is kept as the spare for
    /// the next local connection; cancelling it would reach the gateway as a reset and make it
    /// open an upstream connection for nothing.
    func probe() async throws -> TimeInterval {
        let (group, stream) = try await openStream()
        spare = (group, stream)
        let report = await withCheckedContinuation { (c: CheckedContinuation<NWConnection.DataTransferReport, Never>) in
            stream.startDataTransferReport().collect(queue: queue) { c.resume(returning: $0) }
        }
        return report.aggregatePathReport.transportSmoothedRTT
    }

    /// Cancels the listener, the QUIC connection and every forwarded connection.
    func stop() {
        listener?.cancel(); listener = nil
        group?.cancel(); group = nil
        // Not cancelled: that would reach the gateway as a reset before the connection closes.
        spare = nil
        for pipe in pipes.values { pipe.close() }
        pipes.removeAll()
    }

    /// The shared QUIC connection, re-established when the previous one failed or closed.
    /// Concurrent callers share one handshake.
    private func connection() async throws -> NWConnectionGroup {
        if let connecting { return try await connecting.value }
        if let group, group.state == .ready { return group }
        group?.cancel()
        let task = Task { try await establish() }
        connecting = task
        defer { connecting = nil }
        return try await task.value
    }

    private func establish() async throws -> NWConnectionGroup {
        let handshake = Once<Void>()
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: parameters(handshake))
        // The gateway never opens streams; refuse any it tries.
        group.newConnectionHandler = { $0.cancel() }
        group.stateUpdateHandler = { state in
            switch state {
            case .ready: handshake.finish(.success(()))
            case .failed(let error): handshake.finish(.failure(error))
            case .cancelled: handshake.finish(.failure(CancellationError()))
            // `.waiting(ENETDOWN)` is reported transiently before every successful handshake.
            default: break
            }
        }
        self.group = group
        do {
            try await handshake.wait {
                group.start(queue: queue)
                queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) {
                    handshake.finish(.failure(RelayTunnelError.handshakeTimeout))
                }
            }
        } catch {
            group.cancel()
            throw error
        }
        // NAT bindings on carrier networks expire after about 30 s of silence. Set on the group's
        // metadata it takes effect (verified against an idle timeout) though reading it back
        // still reports `.off`.
        (group.metadata(definition: NWProtocolQUIC.definition) as! NWProtocolQUIC.Metadata).keepAlive = .seconds(15)
        return group
    }

    private func parameters(_ handshake: Once<Void>) -> NWParameters {
        let quic = NWProtocolQUIC.Options(alpn: [Self.alpn])
        quic.direction = .bidirectional
        quic.idleTimeout = 60_000
        quic.initialMaxStreamsUnidirectional = 0
        let security = quic.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(security, Self.serverName)
        // Replaces only chain and hostname validation; the TLS 1.3 CertificateVerify signature is
        // still checked by the handshake, so the peer must hold the pinned certificate's key.
        let pin = pin
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
            let matches = leaf.map { Data(SHA256.hash(data: SecCertificateCopyData($0) as Data)) == pin } ?? false
            if !matches { handshake.finish(.failure(RelayTunnelError.pinMismatch)) }
            complete(matches)
        }, queue)
        return NWParameters(quic: quic)
    }

    /// A started stream on the shared connection. QUIC opens streams implicitly, so this costs
    /// no round trip and nothing reaches the gateway before the first byte.
    private func openStream() async throws -> (NWConnectionGroup, NWConnection) {
        let group = try await connection()
        if let spare {
            // A spare from an earlier, dead connection is simply dropped with it.
            self.spare = nil
            if spare.group === group, spare.stream.state == .ready { return (group, spare.stream) }
        }
        guard let stream = NWConnection(from: group) else { throw RelayTunnelError.connectionClosed }
        let ready = Once<Void>()
        stream.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.finish(.success(()))
            case .failed(let error), .waiting(let error): ready.finish(.failure(error))
            case .cancelled: ready.finish(.failure(CancellationError()))
            default: break
            }
        }
        do {
            try await ready.wait { stream.start(queue: queue) }
        } catch {
            stream.cancel()
            throw error
        }
        return (group, stream)
    }

    private func forward(_ tcp: NWConnection) async {
        // Accepted just before `stop()`; reconnecting now would outlive the tunnel.
        guard listener != nil else { return tcp.cancel() }
        let pipe = Pipe(tcp: tcp, queue: queue) { [weak self] id in
            Task { @MainActor in self?.pipes[id] = nil }
        }
        pipes[ObjectIdentifier(pipe)] = pipe
        do {
            let (_, stream) = try await openStream()
            pipe.attach(stream)
        } catch {
            // The local client sees a closed socket, never data from an unverified peer.
            pipe.close()
        }
    }
}

/// Resumes a continuation exactly once. Network.framework may deliver further state updates
/// after the one that decided the outcome, so handlers cannot simply resume. `finish` is only
/// called on the tunnel's serial queue, by callbacks that `start` (run once the continuation is
/// stored) sets in motion.
private final class Once<Value>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Error>?

    func wait(_ start: () -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Copies one TCP connection over one QUIC stream in both directions, preserving half-close: a
/// client that finishes its request still receives the response.
private final class Pipe: @unchecked Sendable {
    // Mutable state is only touched on `queue`.
    private let tcp: NWConnection
    private var stream: NWConnection?
    private let queue: DispatchQueue
    private var open = 2
    private var finished: ((ObjectIdentifier) -> Void)?

    init(tcp: NWConnection, queue: DispatchQueue, finished: @escaping (ObjectIdentifier) -> Void) {
        self.tcp = tcp; self.queue = queue; self.finished = finished
        tcp.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: close(graceful: false)
            default: break
            }
        }
        tcp.start(queue: queue)
    }

    /// Takes a started, ready stream and copies both ways.
    func attach(_ stream: NWConnection) {
        queue.async { [self] in
            guard finished != nil else { return stream.cancel() }
            self.stream = stream
            stream.stateUpdateHandler = { [self] state in
                switch state {
                case .failed, .cancelled: close(graceful: false)
                default: break
                }
            }
            copy(from: tcp, to: stream)
            copy(from: stream, to: tcp)
        }
    }

    func close() { queue.async { [self] in close(graceful: false) } }

    private func copy(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            guard finished != nil else { return }
            if error != nil { return close(graceful: false) }
            // TCP and a QUIC stream are each one message, so completion is the peer's FIN, and
            // completing the default stream context sends ours. Switching to `.finalMessage` for the
            // last chunk would start a second message that waits forever behind the open first one.
            destination.send(content: data, contentContext: .defaultStream, isComplete: isComplete,
                             completion: .contentProcessed { [self] error in
                guard finished != nil else { return }
                if error != nil { return close(graceful: false) }
                if !isComplete { return copy(from: source, to: destination) }
                open -= 1
                if open == 0 { close(graceful: true) }
            })
        }
    }

    private func close(graceful: Bool) {
        guard let finished else { return }
        self.finished = nil
        if graceful { tcp.cancel(); stream?.cancel() } else { tcp.forceCancel(); stream?.forceCancel() }
        finished(ObjectIdentifier(self))
    }
}

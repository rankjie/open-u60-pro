import Foundation
import WebRTC

@MainActor protocol ManagementPeerConnection: AnyObject {
    var isReady: Bool { get }
    func signal(_ value: [String: Any]) async throws
    func request(_ data: Data, id: UUID, timeout: TimeInterval) async throws -> AgentHTTPResponse
    func close()
}
typealias ManagementPeerFactory = @MainActor (UUID, UUID, [CallingICEServer], @escaping (String, [String: Any]) -> Void,
    @escaping () -> Void) throws -> any ManagementPeerConnection

@MainActor final class ManagementPeer: NSObject, ManagementPeerConnection {
    private let factory = RTCPeerConnectionFactory()
    private var connection: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var candidates: [CallingICECandidate] = []
    private var frames = PeerFrames()
    private var pending: [UUID: CheckedContinuation<AgentHTTPResponse, Error>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private let id: UUID
    private let router: UUID
    private let send: (String, [String: Any]) -> Void
    private let failed: () -> Void
    private(set) var isReady = false
    private var helloSent = false

    init(id: UUID, router: UUID, servers: [CallingICEServer], send: @escaping (String, [String: Any]) -> Void,
         failed: @escaping () -> Void) throws {
        self.id = id; self.router = router; self.send = send; self.failed = failed
        super.init()
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls) }
        guard let peer = factory.peerConnection(with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw CallingError.media("management_peer_creation_failed")
        }
        connection = peer
    }
    func signal(_ value: [String: Any]) async throws {
        guard let connection else { throw URLError(.networkConnectionLost) }
        if let description = value["description"] as? [String: Any] {
            guard connection.remoteDescription == nil, description["type"] as? String == "offer",
                  let sdp = description["sdp"] as? String, sdp.utf8.count <= 32768 else { throw CallingError.invalidResponse }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
            for candidate in candidates { try await add(candidate) }; candidates.removeAll()
            let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { c in
                connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { value, error in
                    if let error { c.resume(throwing: error) }
                    else if let value { c.resume(returning: value) }
                    else { c.resume(throwing: CallingError.invalidResponse) }
                }
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                connection.setLocalDescription(answer) { error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
            send("description", ["type": "answer", "sdp": answer.sdp])
        } else if let raw = value["candidate"] as? [String: Any] {
            let candidate = try JSONDecoder().decode(CallingICECandidate.self, from: JSONSerialization.data(withJSONObject: raw))
            if connection.remoteDescription == nil {
                guard candidates.count < 64 else { throw CallingError.invalidResponse }
                candidates.append(candidate)
            } else { try await add(candidate) }
        } else { throw CallingError.invalidResponse }
    }
    private func add(_ value: CallingICECandidate) async throws {
        guard let connection else { throw URLError(.networkConnectionLost) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.add(RTCIceCandidate(sdp: value.candidate, sdpMLineIndex: value.sdpMLineIndex, sdpMid: value.sdpMid)) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
    func request(_ data: Data, id: UUID, timeout: TimeInterval) async throws -> AgentHTTPResponse {
        guard isReady, let channel, channel.readyState == .open else { throw URLError(.networkConnectionLost) }
        guard pending.count < 6, channel.bufferedAmount < 1048576 else { throw URLError(.networkConnectionLost) }
        let parts = try PeerFrames.encode(data, id: id)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { c in
                pending[id] = c
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.complete(id, .failure(URLError(.timedOut)))
                }
                for part in parts {
                    if !channel.sendData(RTCDataBuffer(data: part, isBinary: true)) {
                        complete(id, .failure(URLError(.networkConnectionLost))); break
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(id, .failure(CancellationError())) }
        }
    }
    private func receive(_ data: Data, binary: Bool) {
        guard connection != nil else { return }
        do {
            guard binary else { throw CallingError.invalidResponse }
            guard let (messageID, bytes) = try frames.receive(data) else { return }
            guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw CallingError.invalidResponse }
            if value["type"] as? String == "peer_ready" {
                guard !isReady, messageID == id,
                      (value["sessionId"] as? String).flatMap(UUID.init(uuidString:)) == id,
                      (value["routerId"] as? String).flatMap(UUID.init(uuidString:)) == router,
                      let time = value["agentTime"] as? Double, (946684800..<4102444800).contains(time) else { throw CallingError.invalidResponse }
                isReady = true
            } else {
                guard isReady, value["type"] as? String == "agent_result",
                      (value["requestId"] as? String).flatMap(UUID.init(uuidString:)) == messageID,
                      let status = value["status"] as? Int, (200...599).contains(status),
                      let raw = value["body"] as? String, let body = Data(base64Encoded: raw),
                      body.count <= 524288, body.base64EncodedString() == raw else { throw CallingError.invalidResponse }
                complete(messageID, .success(AgentHTTPResponse(status: status, data: body)))
            }
        } catch {
            for id in Array(pending.keys) { complete(id, .failure(error)) }
            close(); failed()
        }
    }
    private func greet() {
        guard !helloSent, let channel, channel.readyState == .open else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["type":"peer_hello", "sessionId":id.uuidString.lowercased()])
            for frame in try PeerFrames.encode(data, id: id) {
                guard channel.sendData(RTCDataBuffer(data: frame, isBinary: true)) else { throw URLError(.networkConnectionLost) }
            }
            helloSent = true
        } catch { close(); failed() }
    }
    private func complete(_ id: UUID, _ result: Result<AgentHTTPResponse, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    func close() {
        isReady = false; helloSent = false
        channel?.delegate = nil; channel?.close(); channel = nil
        connection?.delegate = nil; connection?.close(); connection = nil
        candidates.removeAll(); frames = PeerFrames()
        for id in Array(pending.keys) { complete(id, .failure(URLError(.networkConnectionLost))) }
    }
}
extension ManagementPeer: RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let value: [String: Any] = ["candidate": candidate.sdp, "sdpMid": candidate.sdpMid as Any? ?? NSNull(), "sdpMLineIndex": candidate.sdpMLineIndex]
        Task { @MainActor [weak self] in self?.send("candidate", value) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, self.connection === peerConnection, self.channel == nil,
                  dataChannel.label == "openu60-management-v1", dataChannel.isOrdered else { dataChannel.close(); return }
            self.channel = dataChannel; dataChannel.delegate = self
            self.greet()
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        if newState == .failed || newState == .closed {
            Task { @MainActor [weak self] in
                guard let self, self.connection === peerConnection else { return }
                self.close(); self.failed()
            }
        }
    }
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open {
            Task { @MainActor [weak self] in
                guard let self, self.channel === dataChannel else { return }
                self.greet()
            }
        }
        if dataChannel.readyState == .closed {
            Task { @MainActor [weak self] in
                guard let self, self.channel === dataChannel else { return }
                self.close(); self.failed()
            }
        }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data, binary = buffer.isBinary
        let channelID = ObjectIdentifier(dataChannel)
        // Preserve the ordered channel's callback order while entering the UI actor.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.channel.map(ObjectIdentifier.init) == channelID else { return }
            self.receive(data, binary: binary)
        }
    }
}

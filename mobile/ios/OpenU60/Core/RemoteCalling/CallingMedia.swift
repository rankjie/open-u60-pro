import AVFoundation
import Foundation
import WebRTC

struct CallingICECandidate: Codable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int32
}
struct CallingICEServer: Codable {
    let urls: [String]
    let username: String?
    let credential: String?
}

@MainActor
protocol CallingMediaConnection: AnyObject {
    func answer(sdp: String) async throws -> String
    func add(_ value: CallingICECandidate) async throws
    func mute(_ muted: Bool)
    func close()
}

@MainActor
final class CallingMedia: NSObject, CallingMediaConnection {
    private let factory = RTCPeerConnectionFactory()
    private var connection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var pendingCandidates: [CallingICECandidate] = []
    let callId: UUID
    let send: (String, [String: Any]) -> Void
    let stateChanged: (RTCPeerConnectionState) -> Void

    init(callId: UUID, servers: [CallingICEServer], muted: Bool, relayOnly: Bool = false, send: @escaping (String, [String: Any]) -> Void,
         stateChanged: @escaping (RTCPeerConnectionState) -> Void) throws {
        self.callId = callId
        self.send = send
        self.stateChanged = stateChanged
        super.init()
        let config = Self.configuration(servers: servers, relayOnly: relayOnly)
#if DEBUG && OPENU60_NATIVE_CALLKIT_PROBE
        if Foundation.ProcessInfo.processInfo.arguments.contains("--native-callkit-relay") { config.iceTransportPolicy = .relay }
#endif
        guard let peer = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw CallingError.media("peer_creation_failed")
        }
        connection = peer
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil,
            optionalConstraints: ["googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true"]))
        let track = factory.audioTrack(with: source, trackId: "microphone")
        track.isEnabled = !muted
        audioTrack = track
        peer.add(track, streamIds: [callId.uuidString.lowercased()])
    }

    /// Live call audio: the jitter buffer holds at most 25 packets (500 ms) and catches up
    /// quickly, so a burst from the router after a network or CPU stall is played or dropped
    /// at once instead of becoming delay for the rest of the call (WebRTC allows 4 s).
    static func configuration(servers: [CallingICEServer], relayOnly: Bool) -> RTCConfiguration {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceTransportPolicy = relayOnly ? .relay : .all
        config.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username ?? "", credential: $0.credential ?? "") }
        config.audioJitterBufferMaxPackets = 25
        config.audioJitterBufferFastAccelerate = true
        return config
    }

    func answer(sdp: String) async throws -> String {
        guard let connection else { throw CallingError.media("peer_closed") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        for candidate in pendingCandidates { try await add(candidate) }
        pendingCandidates.removeAll()
        let description: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                if let error { continuation.resume(throwing: error) }
                else if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: CallingError.media("missing_answer")) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return description.sdp
    }
    func add(_ value: CallingICECandidate) async throws {
        guard let connection else { throw CallingError.media("peer_closed") }
        if connection.remoteDescription == nil {
            guard pendingCandidates.count < 64 else { throw CallingError.media("too_many_candidates") }
            pendingCandidates.append(value)
            return
        }
        let candidate = RTCIceCandidate(sdp: value.candidate, sdpMLineIndex: value.sdpMLineIndex, sdpMid: value.sdpMid)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func packetCounts() async throws -> (received: Int, sent: Int, route: String) {
        guard let connection else { throw CallingError.media("peer_closed") }
        return await withCheckedContinuation { continuation in
            connection.statistics { report in
                var received = 0, sent = 0
                for value in report.statistics.values {
                    if value.type == "inbound-rtp", let count = value.values["packetsReceived"] as? NSNumber { received += count.intValue }
                    if value.type == "outbound-rtp", let count = value.values["packetsSent"] as? NSNumber { sent += count.intValue }
                }
                let transport = report.statistics.values.first { $0.type == "transport" }
                let pairID = transport?.values["selectedCandidatePairId"] as? String
                let pair = pairID.flatMap { report.statistics[$0] }
                let localID = pair?.values["localCandidateId"] as? String
                let candidate = localID.flatMap { report.statistics[$0] }
                let kind = candidate?.values["candidateType"] as? String ?? "checking"
                let proto = candidate?.values["protocol"] as? String ?? "checking"
                continuation.resume(returning: (received, sent, "\(kind)/\(proto)"))
            }
        }
    }
    func mute(_ muted: Bool) { audioTrack?.isEnabled = !muted }
    func close() {
        audioTrack?.isEnabled = false
        connection?.delegate = nil
        connection?.close()
        connection = nil
        audioTrack = nil
        pendingCandidates.removeAll()
    }
}

extension CallingMedia: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let value: [String: Any] = ["candidate": candidate.sdp, "sdpMid": candidate.sdpMid as Any? ?? NSNull(), "sdpMLineIndex": candidate.sdpMLineIndex]
        Task { @MainActor [weak self] in self?.send("candidate", value) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in self?.stateChanged(newState) }
    }
}

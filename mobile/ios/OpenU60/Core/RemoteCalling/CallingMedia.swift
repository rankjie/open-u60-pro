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
final class CallingMedia: NSObject {
    private let factory = RTCPeerConnectionFactory()
    private var connection: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var pendingCandidates: [CallingICECandidate] = []
    let callId: UUID
    let send: (String, [String: Any]) -> Void
    let stateChanged: (RTCPeerConnectionState) -> Void

    init(callId: UUID, servers: [CallingICEServer], send: @escaping (String, [String: Any]) -> Void,
         stateChanged: @escaping (RTCPeerConnectionState) -> Void) throws {
        self.callId = callId
        self.send = send
        self.stateChanged = stateChanged
        super.init()
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username ?? "", credential: $0.credential ?? "") }
        guard let peer = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw CallingError.media("peer_creation_failed")
        }
        connection = peer
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil,
            optionalConstraints: ["googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true"]))
        let track = factory.audioTrack(with: source, trackId: "microphone")
        audioTrack = track
        peer.add(track, streamIds: [callId.uuidString.lowercased()])
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

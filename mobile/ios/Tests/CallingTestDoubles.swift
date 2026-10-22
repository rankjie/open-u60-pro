import Foundation
import CallKit
import WebRTC

@MainActor final class AgentClient {
    func getJSON(_ path: String) async throws -> [String: Any] { throw CallingError.invalidResponse }
    func postJSON(_ path: String, body: [String: Any] = [:]) async throws -> [String: Any] { throw CallingError.invalidResponse }
}

final class TestEndAction: CXEndCallAction {
    private(set) var fulfilled = false
    override func fulfill() { fulfilled = true; super.fulfill() }
}
final class TestAnswerAction: CXAnswerCallAction {
    private(set) var fulfilled = false
    override func fulfill() { fulfilled = true; super.fulfill() }
}
final class TestDTMFAction: CXPlayDTMFCallAction {
    private(set) var fulfilled = false
    override func fulfill() { fulfilled = true; super.fulfill() }
}

@MainActor final class TestProvider: CXProvider {
    var endedCalls: [UUID] = []
    var endedReasons: [UUID: CXCallEndedReason] = [:]
    init() { super.init(configuration: CXProviderConfiguration()) }
    override func reportCall(with UUID: UUID, endedAt dateEnded: Date?, reason endedReason: CXCallEndedReason) {
        endedCalls.append(UUID)
        endedReasons[UUID] = endedReason
    }
    override func reportNewIncomingCall(with UUID: UUID, update: CXCallUpdate, completion: @escaping (Error?) -> Void) { completion(nil) }
    override func reportOutgoingCall(with UUID: UUID, connectedAt dateConnected: Date?) {}
}

@MainActor final class TestSocket: CallingSocket {
    var response: URLResponse?
    var queue: [URLSessionWebSocketTask.Message] = []
    var receiving: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    var messages: [[String: Any]] = []
    var cancelled = false
    var holdSends = false
    var onMessage: (([String:Any]) -> Void)?
    var blockedSend: CheckedContinuation<Void, Error>?
    func resume() {}
    func emit(_ value: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: value)
        let message = URLSessionWebSocketTask.Message.data(bytes)
        if let receiving { self.receiving = nil; receiving.resume(returning: message) }
        else { queue.append(message) }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if cancelled { throw CancellationError() }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { receiving = $0 }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if cancelled { throw CancellationError() }
        if holdSends { try await withCheckedThrowingContinuation { blockedSend = $0 } }
        guard case .string(let string) = message else { throw CallingError.invalidResponse }
        let value = try JSONSerialization.jsonObject(with: Data(string.utf8)) as! [String: Any]
        messages.append(value)
        if value["type"] as? String == "ping" { emit(["type":"pong"]) }
        if value["type"] as? String == "command" {
            emit(["type":"result", "requestId":value["requestId"]!, "callId":value["callId"]!, "ok":true])
        }
        onMessage?(value)
    }
    func cancel(with code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelled = true
        let sending = blockedSend; blockedSend = nil; sending?.resume(throwing: CancellationError())
        let receiving = receiving; self.receiving = nil; receiving?.resume(throwing: CancellationError())
    }
}

@MainActor final class TestMedia: CallingMediaConnection {
    let changed: (RTCPeerConnectionState) -> Void
    let sender: (String, [String: Any]) -> Void
    var muted = false
    var closed = false
    let relayOnly: Bool
    init(muted: Bool, relayOnly: Bool, sender: @escaping (String,[String:Any]) -> Void, changed: @escaping (RTCPeerConnectionState) -> Void) { self.muted = muted; self.relayOnly = relayOnly; self.sender = sender; self.changed = changed }
    func answer(sdp: String) async throws -> String { "v=0\r\n" }
    func add(_ value: CallingICECandidate) async throws {}
    func mute(_ muted: Bool) { self.muted = muted }
    func close() { closed = true }
}

@MainActor final class TestManagementPeer: ManagementPeerConnection {
    var isReady = true
    var closed = false
    var requests: [Data] = []
    var onRequest: ((Data) throws -> AgentHTTPResponse)?
    func signal(_ value: [String: Any]) async throws {}
    func request(_ data: Data, id: UUID, timeout: TimeInterval) async throws -> AgentHTTPResponse {
        requests.append(data)
        return try onRequest?(data) ?? AgentHTTPResponse(status:200, data:Data("{}".utf8))
    }
    func close() { closed = true; isReady = false }
}

@MainActor final class Fixture {
    let provider = TestProvider()
    var sockets = [TestSocket()]
    var socket: TestSocket { sockets.last! }
    var hello: [String:Any] = [:]
    var holdPermission = false
    var permission: CheckedContinuation<Bool,Never>?
    func openSocket() -> TestSocket {
        if socket.cancelled { let next=TestSocket();sockets.append(next);next.emit(hello) }
        return socket
    }
    let router = UUID()
    let endpoint = UUID()
    var media: [TestMedia] = []
    var peers: [TestManagementPeer] = []
    var peerReady = true
    lazy var manager = RemoteCallingManager(provider: provider,
        credentials: CallingCredentials(serverURL: URL(string: "https://synthetic.invalid")!, phoneToken: String(repeating:"x",count:43),
            requestId: UUID(), endpointId: endpoint, routerId: router), bootstrap: false,
        socketFactory: { [unowned self] _ in self.openSocket() },
        requestMicrophone: { [unowned self] in
            if self.holdPermission { return await withCheckedContinuation { self.permission = $0 } }
            return true
        },
        deviceInfo: { CallingDeviceInfo(name: "iPhone 16 Pro", model: "iPhone17,1") },
        peerFactory: { [unowned self] _,_,_,_,_ in
            let peer = TestManagementPeer(); peer.isReady = self.peerReady; self.peers.append(peer); return peer
        },
        mediaFactory: { [unowned self] _,_,muted,relayOnly,sender,changed in let value = TestMedia(muted:muted,relayOnly:relayOnly,sender:sender,changed: changed); self.media.append(value); return value })
    func snapshot(_ id: UUID, state: String = "active", sequence: Int = 1) -> [String: Any] {
        ["type":"call", "callId":id.uuidString, "routerId":router.uuidString, "direction":"incoming", "state":state,
         "number":"12345", "mediaReady":state == "active", "updatedAt":1_800_000_000, "sequence":sequence,
         "answeredAt": state == "active" ? 1_800_000_000 as Any : NSNull()]
    }
    func offer(_ id: UUID) { socket.emit(["type":"signal","callId":id.uuidString,"description":["type":"offer","sdp":"v=0\r\n"]]) }
    func connect(calls: [[String:Any]]) async throws {
        hello = ["type":"hello","protocol":1,"role":"phone","endpointId":endpoint.uuidString,
            "routerId":router.uuidString,"routerOnline":true,"voipPushConfigured":true,"iceServers":[],"calls":calls]
        socket.emit(hello)
        manager.connect()
        try await wait { self.manager.isConnected }
    }
    func start(_ id: UUID) async throws {
        try await connect(calls:[snapshot(id)])
        offer(id); try await wait { self.media.count == 1 }
    }
}
@MainActor func wait(seconds: Int = 2, _ predicate: () -> Bool) async throws {
    let until = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !predicate() { if .now >= until { throw CallingError.operationTimeout }; try await Task.sleep(for:.milliseconds(5)) }
}

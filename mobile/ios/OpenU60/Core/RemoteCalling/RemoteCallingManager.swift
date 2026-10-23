import AVFoundation
import CallKit
import Foundation
import Observation
import PushKit
import WebRTC
import os
#if DEBUG && OPENU60_NATIVE_CALLKIT_PROBE
import UIKit
#endif

@MainActor
protocol CallingSocket: AnyObject {
    var response: URLResponse? { get }
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel(with code: URLSessionWebSocketTask.CloseCode, reason: Data?)
}
extension URLSessionWebSocketTask: CallingSocket {}
extension RelayTunnel: DoorTunnel {}

typealias CallingMediaFactory = @MainActor (UUID, [CallingICEServer], Bool, Bool, @escaping (String, [String: Any]) -> Void,
    @escaping (RTCPeerConnectionState) -> Void) throws -> any CallingMediaConnection

enum RemoteCallState: String, Decodable { case dialing, ringing, answering, active, ended }
enum RemoteCallDirection: String, Decodable { case incoming, outgoing }
struct RemoteCall: Decodable, Identifiable {
    let callId: UUID
    let routerId: UUID
    let direction: RemoteCallDirection
    let state: RemoteCallState
    let number: String
    let reason: String?
    let mediaReady: Bool
    let updatedAt: Int
    let sequence: Int
    var answeredAt: Int? = nil
    var phone: CallPhone? = nil
    var id: UUID { callId }
    var connectedDate: Date? {
        guard state == .active, let answeredAt, answeredAt > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(answeredAt))
    }
}

struct CallPresentationRequest: Equatable {
    let callID: UUID
    let revision = UUID()
}

@Observable @MainActor
final class RemoteCallingManager: NSObject {
    private(set) var isPaired = false
    private(set) var pairingRejected = false
    private(set) var isConnected = false
    private(set) var routerOnline = false
    private(set) var call: RemoteCall? { didSet { onCallChanged?(call) } }
    private(set) var callPresentationRequest: CallPresentationRequest?
    private(set) var muted = false
    private(set) var speaker = false
    @ObservationIgnored private var audioSessionActive = false
    private(set) var errorMessage: String?
    private(set) var pushConfigured = false
    private(set) var audioConnected = false
    private(set) var serverAddress = SavedCallingCredentials.defaultServer.absoluteString
    private(set) var servers: [CallingServerChoice] = []
    private(set) var pairingRevision = UUID()
    private(set) var serverOperationInProgress = false
    private(set) var managementPeerStatus = "Not connected"
    /// HTTPS and QUIC door paths to the selected service, with their last measured latency.
    let paths: RelayPaths
    private(set) var pathPreference: String?
    @ObservationIgnored private var doors: [CallingDoor] = []
    var hasSavedPairing: Bool { isPaired || servers.contains(where: \.isPaired) }
    var hasPendingPairing: Bool { servers.first(where: { $0.id == serverAddress })?.hasPendingPairing == true }

    @ObservationIgnored private let provider: CXProvider
    @ObservationIgnored private let controller = CXCallController()
    @ObservationIgnored private let http = CallingHTTPClient()
    @ObservationIgnored private var registry: PKPushRegistry?
    @ObservationIgnored private var credentials: CallingCredentials?
    @ObservationIgnored var localCommandDelivery: (@MainActor ([String:Any], UUID) async throws -> Bool)?
    @ObservationIgnored var commandAdmission: (@MainActor ([String:Any], String) async throws -> [String:Any])?
    @ObservationIgnored var deviceConnectionRequest: (@MainActor (String, URL, String, [String:Any]?) async throws -> [String:Any])?
    @ObservationIgnored var onSMSReceived: (@MainActor (UUID, UUID, String?, [String: Any]) -> Void)?
    @ObservationIgnored var onCallChanged: (@MainActor (RemoteCall?) -> Void)?
    @ObservationIgnored private var serverClock: (TimeInterval, ContinuousClock.Instant)?
    var managementAccess: AgentRelayAccess? {
        guard isPaired, let credentials, let routerID = credentials.routerId else { return nil }
        let now: TimeInterval
        if let (time, observed) = serverClock {
            let elapsed = observed.duration(to: .now).components
            now = time + Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        } else { now = Date().timeIntervalSince1970 }
        return AgentRelayAccess(server: serverBase(credentials), token: credentials.phoneToken, routerID: routerID, serverTime: now)
    }
    @ObservationIgnored private var socket: (any CallingSocket)?
    @ObservationIgnored private var session: URLSession
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var media: (any CallingMediaConnection)?
    @ObservationIgnored private var iceServers: [CallingICEServer] = []
    @ObservationIgnored private var candidates: [CallingICECandidate] = []
    @ObservationIgnored private var pushToken: String?
    @ObservationIgnored private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var deadlines: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reported: Set<UUID> = []
    @ObservationIgnored private var ended: Set<UUID> = []
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var mediaGeneration: UUID?
    @ObservationIgnored private var lastSignalingReceipt: ContinuousClock.Instant?
    @ObservationIgnored private var requestedMedia: UUID?
    /// The media request that prepares a ringing call's audio; its refusal is not an error.
    @ObservationIgnored private var prepareRequest: UUID?
    /// Each call is prepared at most once; after a refusal or failure the answer negotiates.
    @ObservationIgnored private var preparedCall: UUID?
    @ObservationIgnored private var relayFallbackCall: UUID?
    @ObservationIgnored private var mediaRecovery: Task<Void, Never>?
    @ObservationIgnored private var managementPeer: (any ManagementPeerConnection)?
    @ObservationIgnored private var peerSessionID: UUID?
    @ObservationIgnored private var peerLease: Task<Void, Never>?
    @ObservationIgnored private var peerRetryAfter: ContinuousClock.Instant = .now
    @ObservationIgnored private var peerSupported = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.beexio.openu60", category: "RemoteCalling")

    @ObservationIgnored private let socketFactory: @MainActor (URLRequest) -> any CallingSocket
    @ObservationIgnored private let mediaFactory: CallingMediaFactory
    @ObservationIgnored private let peerFactory: ManagementPeerFactory
    @ObservationIgnored private let requestMicrophone: @MainActor () async -> Bool
    @ObservationIgnored private let deviceInfo: @MainActor () throws -> CallingDeviceInfo
    @ObservationIgnored private let loadSavedCredentials: @MainActor () throws -> SavedCallingCredentials
    @ObservationIgnored private let saveCredentials: @MainActor (SavedCallingCredentials) throws -> Void

    init(provider injectedProvider: CXProvider? = nil, credentials injectedCredentials: CallingCredentials? = nil,
         bootstrap: Bool = true, socketFactory: (@MainActor (URLRequest) -> any CallingSocket)? = nil,
         loadCredentials: @escaping @MainActor () throws -> SavedCallingCredentials = { try CallingCredentialStore.load() },
         saveCredentials: @escaping @MainActor (SavedCallingCredentials) throws -> Void = { try CallingCredentialStore.save($0) },
         requestMicrophone: @escaping @MainActor () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
         deviceInfo: @escaping @MainActor () throws -> CallingDeviceInfo = { try CallingDeviceInfo.current() },
         peerFactory: @escaping ManagementPeerFactory = { try ManagementPeer(id: $0, router: $1, servers: $2, send: $3, failed: $4) },
         mediaFactory: @escaping CallingMediaFactory = { try CallingMedia(callId: $0, servers: $1, muted: $2, relayOnly: $3, send: $4, stateChanged: $5) }) {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber, .generic]
        provider = injectedProvider ?? CXProvider(configuration: configuration)
        let transport = URLSessionConfiguration.ephemeral
        transport.timeoutIntervalForRequest = 20
        transport.urlCache = nil
        let nativeSession = URLSession(configuration: transport)
        session = nativeSession
        self.socketFactory = socketFactory ?? { nativeSession.webSocketTask(with: $0) }
        self.mediaFactory = mediaFactory
        self.peerFactory = peerFactory
        self.requestMicrophone = requestMicrophone
        self.deviceInfo = deviceInfo
        self.loadSavedCredentials = loadCredentials
        self.saveCredentials = saveCredentials
        paths = RelayPaths(makeTunnel: { door in
            guard let endpoint = door.endpoint, let pin = RelayTunnel.pin(fromBase64URL: endpoint.pin) else { return nil }
            return RelayTunnel(host: endpoint.host, port: endpoint.port, pin: pin)
        })
        super.init()
        provider.setDelegate(self, queue: .main)
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        if !bootstrap {
            credentials = injectedCredentials
            isPaired = injectedCredentials?.endpointId != nil
            if let injectedCredentials { serverAddress = injectedCredentials.serverURL.absoluteString }
            return
        }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        do { try reloadCredentials() } catch { present(error) }
    }

    func requestCallPresentation() {
        guard let call, call.state != .ended else { return }
        callPresentationRequest = CallPresentationRequest(callID: call.callId)
    }

    func foreground() {
#if DEBUG && OPENU60_NATIVE_CALLKIT_PROBE
        if nativeProbeSnapshot != nil { resumeSignaling(); return }
#endif
        do { try reloadCredentials() } catch { present(error) }
        resumeSignaling()
        if let call, call.state == .ended { finish(call.callId, reason: .remoteEnded) }
    }
    private func reloadCredentials() throws {
        try applySavedCredentials(loadSavedCredentials())
    }
    private func applySavedCredentials(_ saved: SavedCallingCredentials) throws {
        let changed = serverAddress != saved.selectedServer.absoluteString ||
            credentials?.endpointId != saved.active?.endpointId || credentials?.phoneToken != saved.active?.phoneToken
        if changed {
            guard call == nil || call?.state == .ended else { throw CallingError.server("call_in_progress") }
            disconnect()
            credentials = saved.active
            serverAddress = saved.selectedServer.absoluteString
            isPaired = saved.active?.endpointId != nil
            pairingRejected = false
            pushConfigured = false
            serverClock = nil
            lastSignalingReceipt = nil
            iceServers = []
            errorMessage = nil
            pairingRevision = UUID()
            paths.stop()
        }
        doors = saved.doors
        pathPreference = saved.pathPreference
        servers = saved.choices
        if isPaired { connect() }
    }
    private func requireServerChangeAllowed() throws {
        guard call == nil || call?.state == .ended, pending.isEmpty else { throw CallingError.server("call_in_progress") }
        guard !serverOperationInProgress else { throw CallingError.server("server_operation_in_progress") }
    }
    /// The base URL for service requests on the current path: the HTTPS address or a door.
    private func serverBase(_ credentials: CallingCredentials) -> URL {
        paths.base(server: credentials.serverURL)
    }
    /// nil returns to automatic choice. The socket reconnects on the chosen path.
    func choosePath(_ preference: String?) throws {
        var saved = try loadSavedCredentials()
        saved.pathPreference = preference
        try saveCredentials(saved)
        pathPreference = preference
        disconnect()
        connect()
    }
    private func learnDoors(_ advertised: [CallingDoor]) {
        guard advertised != doors else { return }
        do {
            var saved = try loadSavedCredentials()
            guard saved.active?.phoneToken == credentials?.phoneToken else { return }
            saved.doors = advertised
            try saveCredentials(saved)
            doors = advertised
        } catch { present(error) }
        // Measure the new list now rather than at the next reconnection, so the path list
        // shows every door; requests already follow the current choice.
        guard let credentials else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.paths.select(server: credentials.serverURL, token: credentials.phoneToken,
                                    doors: self.doors, preference: self.pathPreference)
        }
    }
    func addServer(_ address: String) throws {
        guard !serverOperationInProgress else { throw CallingError.server("server_operation_in_progress") }
        var saved = try loadSavedCredentials()
        try saved.addServer(CallingCredentialStore.serverURL(address))
        try saveCredentials(saved)
        servers = saved.choices
    }
    func selectServer(_ address: URL) throws {
        try requireServerChangeAllowed()
        var saved = try loadSavedCredentials()
        try saved.selectServer(address)
        try saveCredentials(saved)
        try applySavedCredentials(saved)
        Task { do { try await registerPushToken() } catch { present(error) } }
    }
    func selectScannedDevice(_ connection: DeviceConnectionQRCode) throws {
        try requireServerChangeAllowed()
        let device = try DeviceConnectionCode(connection.code)
        var saved = try loadSavedCredentials()
        if !saved.choices.contains(where: { $0.address == connection.server }) { try saved.addServer(connection.server) }
        try saved.selectServer(connection.server)
        if let active = saved.active, active.routerId != device.routerID {
            throw CallingError.server("already_connected_to_another_router")
        }
        if let pending = saved.pending, let router = pending.routerId, router != device.routerID {
            throw CallingError.server("pending_connection_other_router")
        }
        try saveCredentials(saved)
        try applySavedCredentials(saved)
        Task { do { try await registerPushToken() } catch { present(error) } }
    }
    func removeServer(_ address: URL) throws {
        guard !serverOperationInProgress else { throw CallingError.server("server_operation_in_progress") }
        var saved = try loadSavedCredentials()
        try saved.removeServer(address)
        try saveCredentials(saved)
        servers = saved.choices
    }
    func pair(server: String, code: String) async throws {
        try requireServerChangeAllowed()
        serverOperationInProgress = true
        defer { serverOperationInProgress = false }
        let url = try CallingCredentialStore.serverURL(server)
        var saved = try loadSavedCredentials()
        guard saved.selectedServer == url else { throw CallingError.server("select_server_first") }
        let next: CallingCredentials
        if let pending = saved.pending, pending.serverURL == url { next = pending }
        else { next = CallingCredentials(serverURL: url, phoneToken: try CallingCredentialStore.token(), requestId: UUID()) }
        saved.pending = next
        try saveCredentials(saved)
        let response = try await http.request("v1/pair", server: url, method: "POST",
            body: ["code": code, "phoneToken": next.phoneToken, "requestId": next.requestId.uuidString.lowercased()])
        guard let endpoint = response["endpointId"] as? String, let endpointId = UUID(uuidString: endpoint),
              let router = response["routerId"] as? String, let routerId = UUID(uuidString: router), response["role"] as? String == "phone" else { throw CallingError.invalidResponse }
        var active = next
        active.endpointId = endpointId
        active.routerId = routerId
        guard call == nil || call?.state == .ended else { throw CallingError.server("call_in_progress") }
        saved.active = active
        saved.pending = nil
        try saveCredentials(saved)
        try applySavedCredentials(saved)
        try await registerPushToken()
    }
    func connectDevice(code: String, password: String) async throws {
        try requireServerChangeAllowed()
        let device = try DeviceConnectionCode(code)
        if isPaired, !pairingRejected, credentials?.routerId == device.routerID { resumeSignaling(); return }
        serverOperationInProgress = true
        defer { serverOperationInProgress = false }
        var saved = try loadSavedCredentials()
        let server = saved.selectedServer
        guard saved.active == nil || (pairingRejected && saved.active?.routerId == device.routerID) else { throw CallingError.server("already_connected_to_another_router") }
        var next: CallingCredentials
        if let pending = saved.pending {
            guard pending.routerId == nil || pending.routerId == device.routerID else { throw CallingError.server("pending_connection_other_router") }
            next = pending
        }
        else { next = CallingCredentials(serverURL:server, phoneToken:try CallingCredentialStore.token(), requestId:UUID()) }
        next.routerId = device.routerID
        saved.pending = next
        try saveCredentials(saved)
        servers = saved.choices
        do {
            let key = try await connectionHTTP("v1/connect/\(device.routerID.uuidString.lowercased())", server:server, method:"GET")
            guard let raw = key["publicKey"] as? String, let publicKey = Data(base64Encoded:raw), publicKey.count == 65,
                  let time = key["serverTime"] as? Double, (946684800..<4102444800).contains(time),
                  (key["routerId"] as? String).flatMap(UUID.init(uuidString:)) == device.routerID else { throw CallingError.invalidResponse }
            let envelope = try DeviceConnectionCode.seal(password:password, publicKey:publicKey, routerID:device.routerID,
                requestID:next.requestId, phoneToken:next.phoneToken, serverTime:time)
            let result = try await connectionHTTP("v1/connect", server:server, method:"POST", body:envelope)
            guard result["role"] as? String == "phone", let raw = result["endpointId"] as? String, let endpoint = UUID(uuidString:raw),
                  (result["routerId"] as? String).flatMap(UUID.init(uuidString:)) == device.routerID else { throw CallingError.invalidResponse }
            var active = next; active.endpointId = endpoint; active.routerId = device.routerID
            saved.active = active; saved.pending = nil
            try saveCredentials(saved)
            try applySavedCredentials(saved)
            try await registerPushToken()
        } catch {
            if case CallingError.server(let code) = error,
               ["incorrect_router_password", "connection_login_expired", "invalid_connection_envelope", "connection_rate_limited", "connection_verification_failed"].contains(code) {
                saved.pending = nil; try saveCredentials(saved)
                servers = saved.choices
            }
            throw error
        }
    }
    private func connectionHTTP(_ path: String, server: URL, method: String, body: [String:Any]? = nil) async throws -> [String:Any] {
        if let deviceConnectionRequest { return try await deviceConnectionRequest(path, server, method, body) }
        return try await http.request(path, server:server, method:method, body:body)
    }
    func forgetPairing() async throws {
        try requireServerChangeAllowed()
        serverOperationInProgress = true
        defer { serverOperationInProgress = false }
        var saved = try loadSavedCredentials()
        if let credentials = saved.active ?? saved.pending {
            do { _ = try await http.request("v1/phone", server: serverBase(credentials), token: credentials.phoneToken, method: "DELETE") }
            catch CallingError.server(let code) where code == "unauthorized" { /* This pairing has already been revoked or was never admitted. */ }
        }
        guard call == nil || call?.state == .ended else { throw CallingError.server("call_in_progress") }
        saved.active = nil
        saved.pending = nil
        try saveCredentials(saved)
        try applySavedCredentials(saved)
    }
    func enableRouter(client: AgentClient, invitation: String, server: String) async throws {
        try requireServerChangeAllowed()
        guard try CallingCredentialStore.serverURL(server) == CallingCredentialStore.serverURL(serverAddress) else {
            throw CallingError.server("select_server_first")
        }
        _ = try await client.postJSON("/api/remote-calling/configure", body: ["serverURL": server, "invitation": invitation])
        let pairing = try await client.postJSON("/api/remote-calling/pairing")
        guard let code = pairing["code"] as? String else { throw CallingError.invalidResponse }
        try await pair(server: server, code: code)
    }
    func pairLocalRouter(client: AgentClient) async throws {
        let status = try await client.getJSON("/api/remote-calling/status")
        guard status["enabled"] as? Bool == true, status["configured"] as? Bool == true,
              let server = status["serverURL"] as? String, let router = status["routerId"] as? String,
              UUID(uuidString:router) != nil else { throw CallingError.server("router_setup_required") }
        guard try CallingCredentialStore.serverURL(server) == CallingCredentialStore.serverURL(serverAddress) else {
            throw CallingError.server("router_uses_different_server")
        }
        let pairing = try await client.postJSON("/api/remote-calling/pairing")
        guard pairing["routerId"] as? String == router, let code = pairing["code"] as? String else { throw CallingError.invalidResponse }
        try await pair(server:server,code:code)
    }
    func start(number: String) async throws {
        guard call == nil else { throw CallingError.server("call_in_progress") }
        guard number.range(of: "^\\+?[0-9*#]{1,30}$", options: .regularExpression) != nil else { throw CallingError.server("invalid_number") }
        let allowed = await requestMicrophone()
        guard allowed else { throw CallingError.microphoneDenied }
        try await ready()
        guard call == nil else { throw CallingError.server("call_in_progress") }
        let id = UUID()
        guard let credentials, let routerId = credentials.routerId else { throw CallingError.disconnected }
        call = RemoteCall(callId: id, routerId: routerId, direction: .outgoing, state: .dialing,
            number: number, reason: nil, mediaReady: false, updatedAt: Int(Date().timeIntervalSince1970), sequence: 0)
        errorMessage = nil
        do { try await controller.request(CXTransaction(action: CXStartCallAction(call: id, handle: CXHandle(type: .phoneNumber, value: number)))) }
        catch { if call?.callId == id { call = nil }; throw error }
    }
    func answer() async throws {
        guard let call else { throw CallingError.server("no_active_call") }
        try await controller.request(CXTransaction(action: CXAnswerCallAction(call: call.callId)))
    }
    func hangup() async throws {
        guard let call else { throw CallingError.server("no_active_call") }
        try await controller.request(CXTransaction(action: CXEndCallAction(call: call.callId)))
    }
    func toggleMute() async throws {
        guard let call else { throw CallingError.server("no_active_call") }
        try await controller.request(CXTransaction(action: CXSetMutedCallAction(call: call.callId, muted: !muted)))
    }
    func dtmf(_ digits: String) async throws {
        guard let call else { throw CallingError.server("no_active_call") }
        try await controller.request(CXTransaction(action: CXPlayDTMFCallAction(call: call.callId, digits: digits, type: .singleTone)))
    }
    func toggleSpeaker() throws {
        guard call != nil else { throw CallingError.server("no_active_call") }
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        if audioSessionActive { try audio.overrideOutputAudioPort(speaker ? .none : .speaker) }
        speaker.toggle()
    }
    func present(_ error: Error) {
        if let error = error as? CallingError { errorMessage = error.localizedDescription }
        else if let error = error as? AgentError { errorMessage = error.localizedDescription }
        else if let error = error as? URLError { errorMessage = "Calling service network error (\(error.code.rawValue))." }
        else { errorMessage = "The calling operation failed. Please reconnect and check the call state." }
        logger.error("Calling operation failed: \(String(reflecting: type(of: error)), privacy: .public)")
    }
    func resumeSignaling(at now: ContinuousClock.Instant = .now) {
        if connectionTask != nil && (socket == nil || lastSignalingReceipt.map { $0.duration(to: now) > .seconds(30) } == true) { disconnect() }
        connect()
    }
    func connect() {
        guard connectionTask == nil, credentials != nil, !pairingRejected else { return }
        let generation = UUID()
        connectionGeneration = generation
        connectionTask = Task { [weak self] in
            guard let self else { return }
            var delay = 1
            while !Task.isCancelled, let credentials = self.credentials {
                do {
                    // Every attempt re-measures the paths; a door forwards to the same service.
                    let base = await self.paths.select(server: serverBase(credentials), token: credentials.phoneToken,
                                                       doors: self.doors, preference: self.pathPreference)
                    guard self.connectionGeneration == generation, !Task.isCancelled else { return }
                    var url = base.appending(path: "v1/socket")
                    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CallingError.invalidServer }
                    // TLS on the direct path; a door's QUIC link already encrypts its loopback hop.
                    components.scheme = base.scheme == "https" ? "wss" : "ws"
                    guard let websocketURL = components.url else { throw CallingError.invalidServer }
                    url = websocketURL
                    var request = URLRequest(url: url)
                    request.setValue("Bearer \(credentials.phoneToken)", forHTTPHeaderField: "Authorization")
                    let socket = self.socketFactory(request)
                    self.socket = socket
                    self.lastSignalingReceipt = .now
                    socket.resume()
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard self.connectionGeneration == generation, !Task.isCancelled else { return }
                        let data: Data
                        switch message {
                        case .string(let value): guard let bytes = value.data(using: .utf8) else { throw CallingError.invalidResponse }; data = bytes
                        case .data(let value): data = value
                        @unknown default: throw CallingError.invalidResponse
                        }
                        guard data.count <= 65536, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CallingError.invalidResponse }
                        self.lastSignalingReceipt = .now
                        try await self.receive(value)
                        delay = 1
                    }
                } catch {
                    if self.connectionGeneration == generation, !Task.isCancelled {
                        if (self.socket?.response as? HTTPURLResponse)?.statusCode == 401 {
                            self.pairingRejected = true
                            self.present(CallingError.server("pairing_revoked"))
                        } else { self.present(error) }
                    }
                }
                guard self.connectionGeneration == generation else { return }
                self.isConnected = false
                self.closeManagementPeer(retry: false)
                self.routerOnline = false
                self.heartbeat?.cancel()
                self.socket?.cancel(with: .goingAway, reason: nil)
                self.socket = nil
                for id in Array(self.pending.keys) { self.complete(id, outcome: .failure(CallingError.disconnected)) }
                if Task.isCancelled || self.pairingRejected { break }
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                delay = min(delay * 2, 30)
            }
        }
    }
    func disconnect() {
        closeManagementPeer(retry: false)
        peerSupported = false
        connectionGeneration = UUID()
        connectionTask?.cancel(); connectionTask = nil
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        isConnected = false; routerOnline = false
        for id in Array(pending.keys) { complete(id, outcome: .failure(CallingError.disconnected)) }
    }
    private func ready() async throws {
        guard credentials != nil else { throw CallingError.disconnected }
        resumeSignaling()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !isConnected {
            if ContinuousClock.now >= deadline { throw CallingError.disconnected }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func send(_ value: [String: Any]) async throws {
        guard let socket, isConnected else { throw CallingError.disconnected }
        let bytes = try JSONSerialization.data(withJSONObject: value)
        guard let string = String(data: bytes, encoding: .utf8) else { throw CallingError.invalidResponse }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        try await socket.send(.string(string))
    }
    func peerManagementRequest(_ data: Data, id: UUID, timeout: TimeInterval) async throws -> AgentHTTPResponse? {
        guard isConnected, routerOnline, peerSupported, timeout > 1 else { return nil }
        let generation = connectionGeneration
        if peerSessionID == nil {
            guard .now >= peerRetryAfter else { return nil }
            let sessionID = UUID()
            peerSessionID = sessionID
            managementPeerStatus = "Connecting"
            do { try await send(["type": "peer_open", "sessionId": sessionID.uuidString.lowercased()]) }
            catch {
                if peerSessionID == sessionID { closeManagementPeer(retry: true) }
                if error.isCancellation { throw error }
                if error is URLError { return nil }
                if let calling = error as? CallingError, case .disconnected = calling { return nil }
                throw error
            }
        }
        guard connectionGeneration == generation else { throw CancellationError() }
        guard let sessionID = peerSessionID else { return nil }
        let until = ContinuousClock.now.advanced(by: .seconds(min(4, timeout / 2)))
        while peerSessionID == sessionID, managementPeer?.isReady != true, .now < until {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard connectionGeneration == generation else { throw CancellationError() }
        guard peerSessionID == sessionID, let peer = managementPeer, peer.isReady else {
            if peerSessionID == sessionID { closeManagementPeer(retry: true, notify: true) }
            return nil
        }
        managementPeerStatus = "Connected"
        do { return try await peer.request(data, id: id, timeout: min(4, timeout / 2)) }
        catch {
            if error is URLError, !error.isCancellation, peerSessionID == sessionID { closeManagementPeer(retry: true, notify: true) }
            throw error
        }
    }
    private func closeManagementPeer(retry: Bool, notify: Bool = false) {
        let id = peerSessionID
        peerSessionID = nil
        managementPeer?.close(); managementPeer = nil
        peerLease?.cancel(); peerLease = nil
        peerRetryAfter = .now.advanced(by: .seconds(retry ? 15 : 0))
        managementPeerStatus = retry ? "Using relay; retrying automatically" : "Not connected"
        if notify, let id, isConnected {
            Task { [weak self] in
                do { try await self?.send(["type": "peer_close", "sessionId": id.uuidString.lowercased()]) }
                catch { if !error.isCancellation { self?.logger.notice("Management peer close was not delivered") } }
            }
        }
    }
    private func receivePeer(_ value: [String: Any]) async throws {
        guard let raw = value["sessionId"] as? String, let id = UUID(uuidString: raw) else { throw CallingError.invalidResponse }
        guard id == peerSessionID else { return }
        if value["type"] as? String == "peer_closed" { closeManagementPeer(retry: true); return }
        do {
            if value["type"] as? String == "peer_session" {
                guard managementPeer == nil, let credentials,
                      (value["phoneId"] as? String).flatMap(UUID.init(uuidString:)) == credentials.endpointId,
                      (value["routerId"] as? String).flatMap(UUID.init(uuidString:)) == credentials.routerId,
                      let router = credentials.routerId, let expires = value["expiresAt"] as? Double,
                      let now = managementAccess?.serverTime, expires > now, expires <= now + 301,
                      let servers = value["iceServers"] as? [[String: Any]] else { throw CallingError.invalidResponse }
                let ice = try JSONDecoder().decode([CallingICEServer].self, from: JSONSerialization.data(withJSONObject: servers))
                guard ice.allSatisfy({ $0.urls.allSatisfy { $0.hasPrefix("stun:") } }) else { throw CallingError.invalidResponse }
                managementPeer = try peerFactory(id, router, ice, { [weak self] kind, payload in
                    Task { @MainActor in
                        guard let self, self.peerSessionID == id else { return }
                        do { try await self.send(["type":"peer_signal", "sessionId":id.uuidString.lowercased(), kind:payload]) }
                        catch { self.closeManagementPeer(retry: true) }
                    }
                }, { [weak self] in
                    guard let self, self.peerSessionID == id else { return }
                    self.closeManagementPeer(retry: true, notify: true)
                })
                peerLease = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(expires - now)) } catch { return }
                    if self?.peerSessionID == id { self?.closeManagementPeer(retry: false, notify: true) }
                }
            } else {
                guard let peer = managementPeer else { throw CallingError.invalidResponse }
                try await peer.signal(value)
            }
        } catch {
            // A failed P2P negotiation leaves the authenticated relay available.
            closeManagementPeer(retry: true, notify: true)
            logger.notice("Management peer negotiation failed: \(String(reflecting: type(of: error)), privacy: .public)")
        }
    }
    private func command(_ action: String, callId: UUID, number: String? = nil, digits: String? = nil) async throws {
        try await ready()
        guard action == "hangup" || (call?.callId == callId && !ended.contains(callId)) else { throw CallingError.server("call_ended") }
        let id = UUID()
        var body: [String: Any] = ["type": "command", "requestId": id.uuidString.lowercased(), "callId": callId.uuidString.lowercased(), "action": action]
        if let number { body["number"] = number }
        if let digits { body["digits"] = digits }
        if action == "dial" || action == "answer" {
            let device = try deviceInfo()
            body["device"] = ["name": device.name, "model": device.model]
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(22)) } catch { return }
                self?.complete(id, outcome: .failure(CallingError.operationTimeout))
            }
            Task { [weak self] in
                guard let self else { return }
                guard self.pending[id] != nil else { return }
                if action != "hangup", self.call?.callId != callId || self.ended.contains(callId) {
                    self.complete(id, outcome: .failure(CallingError.server("call_ended"))); return
                }
                do { try await self.deliverCommand(body, id: id) } catch { self.complete(id, outcome: .failure(error)) }
            }
        }
    }
    private func deliverCommand(_ body: [String:Any], id: UUID) async throws {
        // Answer and dial are what the user waits on. Away from home, probing the LAN address and
        // opening a P2P channel take seconds; the open socket reaches the router in one hop.
        if ["answer", "dial"].contains(body["action"] as? String), routerOnline { try await send(body); return }
        guard let localCommandDelivery, let routerID = credentials?.routerId else { try await send(body); return }
        let admission: [String:Any]
        do { admission = try await admit(body, delivery: "local") }
        catch let error as URLError where error.code != .cancelled {
            // A lost admission response can safely use WSS with the same operation ID.
            try await send(body); return
        }
        guard pending[id] != nil else { return }
        guard let command = admission["command"] as? [String:Any],
              command["requestId"] as? String == body["requestId"] as? String,
              command["callId"] as? String == body["callId"] as? String,
              command["action"] as? String == body["action"] as? String,
              command["number"] as? String == body["number"] as? String,
              command["digits"] as? String == body["digits"] as? String,
              command["type"] as? String == "command", command["expiresAt"] as? Int != nil,
              let status = admission["status"] as? String else { throw CallingError.invalidResponse }
        if status != "pending" {
            guard status == "done" || status == "expired", let ok = admission["ok"] as? Bool else { throw CallingError.invalidResponse }
            if ok { complete(id, outcome: .success(())) }
            else { complete(id, outcome: .failure(CallingError.server(try Self.errorCode(admission["error"])))) }
            return
        }
        if try await localCommandDelivery(command, routerID) { return }
        guard pending[id] != nil else { return }
        if let rawProof = admission["proof"] {
            guard let proof = rawProof as? [String:Any],
                  (proof["phoneId"] as? String).flatMap(UUID.init(uuidString:)) == credentials?.endpointId,
                  let mac = proof["mac"] as? String, mac.range(of:"^[A-Za-z0-9_-]{43}$", options:.regularExpression) != nil else { throw CallingError.invalidResponse }
            do {
                let data = try JSONSerialization.data(withJSONObject: ["type":"peer_call", "requestId":id.uuidString.lowercased(), "command":command, "proof":proof])
                if let response = try await peerManagementRequest(data, id: id, timeout: 8) {
                    if response.status == 202 {
                        guard let value = try JSONSerialization.jsonObject(with: response.data) as? [String:Any],
                              value["ok"] as? Bool == true, let payload = value["data"] as? [String:Any], payload["queued"] as? Bool == true,
                              (payload["requestId"] as? String).flatMap(UUID.init(uuidString:)) == id else { throw CallingError.invalidResponse }
                        return
                    }
                    if ![429,503,504].contains(response.status) {
                        guard let value = try JSONSerialization.jsonObject(with:response.data) as? [String:Any] else { throw CallingError.invalidResponse }
                        throw CallingError.server(try Self.errorCode(value["error"]))
                    }
                }
            } catch let error as URLError where error.code != .cancelled {
                // Admission and execution retain their original ID and expiry on relay retry.
            }
        }
        guard pending[id] != nil else { return }
        _ = try await admit(body, delivery: "relay")
    }
    private func admit(_ body: [String:Any], delivery: String) async throws -> [String:Any] {
        if let commandAdmission { return try await commandAdmission(body, delivery) }
        guard let credentials else { throw CallingError.disconnected }
        var request = body
        request["delivery"] = delivery
        return try await http.request("v1/call-operation", server: serverBase(credentials), token: credentials.phoneToken,
                                      method: "POST", body: request)
    }
    private func complete(_ id: UUID, outcome: Result<Void, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: outcome)
    }
    private func receive(_ value: [String: Any]) async throws {
        guard let type = value["type"] as? String else { throw CallingError.invalidResponse }
        switch type {
        case "sms_received":
            guard let event = value["eventId"] as? String, let eventID = UUID(uuidString:event),
                  let router = value["routerId"] as? String, let routerID = UUID(uuidString:router),
                  routerID == credentials?.routerId else { throw CallingError.invalidResponse }
            onSMSReceived?(eventID, routerID, value["messageId"] as? String, value)
        case "hello":
            guard value["protocol"] as? Int == 1, value["role"] as? String == "phone",
                  let endpoint = value["endpointId"] as? String, UUID(uuidString: endpoint) == credentials?.endpointId,
                  let router = value["routerId"] as? String, UUID(uuidString: router) == credentials?.routerId,
                  let online = value["routerOnline"] as? Bool, let push = value["voipPushConfigured"] as? Bool,
                  let calls = value["calls"] as? [[String: Any]],
                  let servers = value["iceServers"] as? [[String: Any]] else { throw CallingError.invalidResponse }
            iceServers = try JSONDecoder().decode([CallingICEServer].self, from: JSONSerialization.data(withJSONObject: servers))
            peerSupported = value["peerManagement"] as? Bool == true
            learnDoors(CallingDoor.list(value["doors"]))
            if let time = value["serverTime"] as? Double {
                guard (946684800..<4102444800).contains(time) else { throw CallingError.invalidResponse }
                serverClock = (time, .now)
            }
            pushConfigured = push
            isConnected = true
            routerOnline = online
            errorMessage = nil
            heartbeat?.cancel()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(15))
                        guard let self else { return }
                        if self.lastSignalingReceipt.map({ $0.duration(to: .now) > .seconds(30) }) == true { self.resumeSignaling(); return }
                        try await self.send(["type": "ping"])
                    } catch { return }
                }
            }
            // Clear a request from the previous socket before snapshots can start
            // negotiation. Clearing afterward requests two competing router peers.
            if media == nil { requestedMedia = nil }
            for value in calls { try await update(value) }
            if calls.isEmpty, let call, reported.contains(call.callId) { finish(call.callId, reason: .remoteEnded) }
            if let call { try await requestMediaIfNeeded(call) }
            Task { do { try await registerPushToken() } catch { present(error) } }
        case "peer_session", "peer_signal", "peer_closed": try await receivePeer(value)
        case "ice_servers":
            guard let servers = value["iceServers"] as? [[String: Any]] else { throw CallingError.invalidResponse }
            iceServers = try JSONDecoder().decode([CallingICEServer].self, from: JSONSerialization.data(withJSONObject: servers))
        case "call": try await update(value)
        case "signal": try await signal(value)
        case "result":
            guard let raw = value["requestId"] as? String, let id = UUID(uuidString: raw), let ok = value["ok"] as? Bool else { throw CallingError.invalidResponse }
            if ok { complete(id, outcome: .success(())) }
            else { complete(id, outcome: .failure(CallingError.server(try Self.errorCode(value["error"])))) }
        case "error":
            let code = try Self.errorCode(value["error"])
            if let raw = value["requestId"] as? String, let id = UUID(uuidString: raw), id == prepareRequest {
                // A server or router that cannot prepare leaves audio to the answer.
                prepareRequest = nil; if media == nil { requestedMedia = nil }; break
            }
            if let raw = value["requestId"] as? String, let id = UUID(uuidString: raw), id == peerSessionID {
                closeManagementPeer(retry: true); break
            }
            if let raw = value["requestId"] as? String, let id = UUID(uuidString: raw) { complete(id, outcome: .failure(CallingError.server(code))) }
            else if code != "call_ended" { present(CallingError.server(code)) }
        case "pong", "accepted": break
        case "presence":
            guard let online = value["routerOnline"] as? Bool else { throw CallingError.invalidResponse }
            routerOnline = online
            peerSupported = value["peerManagement"] as? Bool == true
            if !online { closeManagementPeer(retry: false) }
            if online, media == nil, let call { requestedMedia = nil; try await requestMediaIfNeeded(call) }
        default: throw CallingError.invalidResponse
        }
    }
    private func update(_ value: [String: Any]) async throws {
        let next = try JSONDecoder().decode(RemoteCall.self, from: JSONSerialization.data(withJSONObject: value))
        guard next.routerId == credentials?.routerId else { throw CallingError.invalidResponse }
        if ended.contains(next.callId) { return }
        if let call, call.callId == next.callId, next.sequence < call.sequence { return }
        if next.state == .ended {
            let reason: CXCallEndedReason
            switch next.reason {
            case "answered_elsewhere": reason = .answeredElsewhere
            case "declined_on_device": reason = .declinedElsewhere
            case "no_answer": reason = .unanswered
            case "remote_hangup": reason = .remoteEnded
            default: reason = .failed
            }
            finish(next.callId, reason: reason)
            return
        }
        if let current = call, current.callId != next.callId { finish(current.callId, reason: .failed) }
        let restoringCall = call?.callId != next.callId && next.state != .ringing
        if call?.callId != next.callId { errorMessage = nil }
        call = next
        if restoringCall { requestCallPresentation() }
        if next.direction == .incoming, next.state == .ringing, !reported.contains(next.callId) {
            reportIncoming(id: next.callId, number: next.number, expired: false, completion: {})
        }
        if next.direction == .incoming, next.state == .ringing { try await prepareMedia(next) }
        if next.direction == .incoming || next.state == .active { try await requestMediaIfNeeded(next) }
        if next.direction == .outgoing, next.state == .active && next.mediaReady {
            provider.reportOutgoingCall(with: next.callId, connectedAt: Date())
        }
    }
    /// While a call rings, its audio connection is prepared so that answering only has to pick
    /// up the call. Nothing is heard or sent until CallKit activates audio after the answer.
    private func prepareMedia(_ call: RemoteCall) async throws {
        guard routerOnline, media == nil, requestedMedia != call.callId, preparedCall != call.callId else { return }
        requestedMedia = call.callId
        preparedCall = call.callId
        let id = UUID()
        prepareRequest = id
        try await send(["type": "media_request", "requestId": id.uuidString.lowercased(),
                        "callId": call.callId.uuidString.lowercased(), "prepare": true])
    }
    private func requestMediaIfNeeded(_ call: RemoteCall) async throws {
        // Every paired phone rings; only the phone whose answer was admitted owns audio.
        guard call.direction != .incoming || call.state != .ringing else { return }
        guard call.state != .ended, media == nil, requestedMedia != call.callId else { return }
        requestedMedia = call.callId
        try await send(["type": "media_request", "callId": call.callId.uuidString.lowercased()])
    }
    private func signal(_ value: [String: Any]) async throws {
        guard let raw = value["callId"] as? String, let id = UUID(uuidString: raw) else { throw CallingError.invalidResponse }
        if ended.contains(id) { return }
        guard call?.callId == id else { throw CallingError.invalidResponse }
        if let description = value["description"] as? [String: Any] {
            guard description["type"] as? String == "offer", let sdp = description["sdp"] as? String, sdp.count <= 32768 else { throw CallingError.invalidResponse }
            let generation = UUID()
            mediaGeneration = generation
            media?.close(); media = nil
            media = try mediaFactory(id, iceServers, muted, relayFallbackCall == id, { [weak self] kind, payload in
                Task { @MainActor in
                    guard let self, self.mediaGeneration == generation, self.call?.callId == id, !self.ended.contains(id) else { return }
                    do { try await self.send(["type": "signal", "callId": id.uuidString.lowercased(), kind: payload]) }
                    catch { self.present(error) }
                }
            }, { [weak self] state in
                guard let self, self.mediaGeneration == generation, self.call?.callId == id, !self.ended.contains(id) else { return }
                self.audioConnected = state == .connected
                if state == .connected { self.mediaRecovery?.cancel(); self.mediaRecovery = nil }
                if state == .failed {
                    // A connection prepared while ringing is simply dropped; answering renegotiates.
                    if self.call?.state == .ringing {
                        self.mediaGeneration = nil; self.media?.close(); self.media = nil
                        self.requestedMedia = nil; self.candidates.removeAll()
                    } else { self.recoverMedia(id) }
                }
            })
            guard let media else { throw CallingError.media("peer_creation_failed") }
            let answer: String
            do { answer = try await media.answer(sdp: sdp) }
            catch {
                if mediaGeneration == generation { mediaGeneration = nil; media.close(); self.media = nil; requestedMedia = nil; candidates.removeAll() }
                throw CallingError.media("negotiation_failed")
            }
            guard mediaGeneration == generation, call?.callId == id, !ended.contains(id) else { return }
            try await send(["type": "signal", "callId": id.uuidString.lowercased(), "description": ["type": "answer", "sdp": answer]])
            for candidate in candidates { try await media.add(candidate) }
            candidates.removeAll()
        } else if let payload = value["candidate"] as? [String: Any] {
            let candidate = try JSONDecoder().decode(CallingICECandidate.self, from: JSONSerialization.data(withJSONObject: payload))
            if let media { do { try await media.add(candidate) } catch { throw CallingError.media("candidate_rejected") } }
            else { guard candidates.count < 64 else { throw CallingError.media("too_many_candidates") }; candidates.append(candidate) }
        } else { throw CallingError.invalidResponse }
    }
    private func recoverMedia(_ id: UUID) {
        guard call?.callId == id, !ended.contains(id) else { return }
        let hasRelay = iceServers.contains { $0.urls.contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") } }
        guard relayFallbackCall != id, hasRelay else {
            present(CallingError.media("connection_failed"))
            Task { do { try await hangup() } catch { present(error); finish(id, reason: .failed) } }
            return
        }
        relayFallbackCall = id
        mediaGeneration = nil
        media?.close(); media = nil; requestedMedia = nil; candidates.removeAll()
        mediaRecovery?.cancel()
        mediaRecovery = Task { [weak self] in
            guard let self else { return }
            do {
                try await ready()
                guard let call, call.callId == id, !ended.contains(id) else { return }
                try await requestMediaIfNeeded(call)
                try await Task.sleep(for: .seconds(12))
                guard self.call?.callId == id, !audioConnected else { return }
                throw CallingError.media("relay_connection_timeout")
            } catch is CancellationError { return }
            catch {
                guard self.call?.callId == id, !ended.contains(id) else { return }
                present(error)
                do { try await hangup() } catch { present(error); finish(id, reason: .failed) }
            }
        }
    }
    static func errorCode(_ value: Any?) throws -> String {
        guard let code = value as? String, code.range(of: "^[a-z0-9_]{1,80}$", options: .regularExpression) != nil else { throw CallingError.invalidResponse }
        return code
    }
#if DEBUG && OPENU60_NATIVE_CALLKIT_PROBE
    @ObservationIgnored private var nativeProbeSnapshot: (CallingCredentials?, String, Bool)?
    private(set) var nativeProbePushReceipts = 0
    private(set) var nativeProbePushInBackground = false
    func beginNativeProbe(_ fixture: CallingCredentials) async throws {
        guard call == nil, fixture.endpointId != nil, fixture.routerId != nil else {
            throw CallingError.server("call_in_progress")
        }
        _ = try CallingCredentialStore.serverURL(fixture.serverURL.absoluteString)
        if nativeProbeSnapshot != nil {
            guard credentials?.endpointId == fixture.endpointId else {throw CallingError.server("verification_already_active")}
        } else {
            nativeProbeSnapshot = (credentials, serverAddress, provider.configuration.includesCallsInRecents)
            disconnect()
            credentials = fixture
            serverAddress = fixture.serverURL.absoluteString
            isPaired = true
            muted = true
            let config = provider.configuration
            config.includesCallsInRecents = false
            provider.configuration = config
        }
        let deadline = ContinuousClock.now.advanced(by:.seconds(15))
        while pushToken == nil {
            if ContinuousClock.now >= deadline {throw CallingError.server("push_token_unavailable")}
            try await Task.sleep(for:.milliseconds(50))
        }
        try await registerPushToken()
        connect()
    }
    func nativeProbePacketCounts() async throws -> (received: Int, sent: Int, route: String) {
        guard let peer = media as? CallingMedia else {throw CallingError.media("peer_not_ready")}
        return try await peer.packetCounts()
    }
    func endNativeProbe() async {
        guard let saved = nativeProbeSnapshot else {return}
        if let call {
            do {try await command("hangup",callId:call.callId)} catch {present(error)}
            finish(call.callId,reason:.remoteEnded)
        }
        disconnect()
        credentials = saved.0
        serverAddress = saved.1
        isPaired = saved.0?.endpointId != nil
        let config = provider.configuration
        config.includesCallsInRecents = saved.2
        provider.configuration = config
        nativeProbeSnapshot = nil
        if isPaired {connect()}
    }
#endif
    private func configureAudioSession() throws {
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        try audio.setConfiguration(RTCAudioSessionConfiguration.webRTC())
    }
    private func registerPushToken() async throws {
        guard let credentials, let pushToken else { return }
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "OpenU60PushEnvironment") as? String,
              environment == "sandbox" || environment == "production" else { throw CallingError.server("invalid_push_environment") }
        _ = try await http.request("v1/push-token", server: serverBase(credentials), token: credentials.phoneToken, method: "PUT",
            body: ["token": pushToken, "environment": environment])
    }
    private func finish(_ id: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: id, endedAt: Date(), reason: reason)
        ended.insert(id)
        if ended.count > 128 { ended = [id] }
        reported.remove(id)
        if call?.callId == id {
            mediaRecovery?.cancel(); mediaRecovery = nil; relayFallbackCall = nil
            mediaGeneration = nil
            media?.close(); media = nil; call = nil; requestedMedia = nil
            callPresentationRequest = nil
            audioConnected = false; muted = false; speaker = false; candidates.removeAll()
            RTCAudioSession.sharedInstance().isAudioEnabled = false
        }
    }
    private func reportIncoming(id: UUID, number: String, expired: Bool, completion: @escaping () -> Void) {
        if reported.contains(id) { completion(); return }
        reported.insert(id)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: number.isEmpty || number == "Unknown" ? .generic : .phoneNumber, value: number.isEmpty ? "Unknown" : number)
        update.hasVideo = false
        update.supportsDTMF = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            Task { @MainActor in
                guard let self else { completion(); return }
                if error != nil { self.reported.remove(id); self.errorMessage = "The system could not present the incoming call." }
                else if expired { self.finish(id, reason: .unanswered) }
                else { self.resumeSignaling() }
                completion()
            }
        }
    }
}

extension RemoteCallingManager: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        if let call {
            let id = call.callId
            Task { do { try await command("hangup", callId: id) } catch { present(error) } }
            finish(id, reason: .failed)
        }
    }
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard call?.callId == action.callUUID, !ended.contains(action.callUUID) else { action.fail(); return }
        requestCallPresentation()
        Task {
            do {
                try configureAudioSession()
                reported.insert(action.callUUID)
                provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
                try await command("dial", callId: action.callUUID, number: action.handle.value)
                guard call?.callId == action.callUUID, !ended.contains(action.callUUID) else { action.fail(); return }
                action.fulfill()
            } catch { present(error); action.fail(); finish(action.callUUID, reason: .failed) }
        }
    }
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard call?.callId == action.callUUID, !ended.contains(action.callUUID) else { action.fail(); return }
        // CallKit can answer without changing the call ID or foregrounding our view.
        requestCallPresentation()
        Task {
            var fulfilled = false
            do {
                let allowed = await requestMicrophone()
                guard allowed else { throw CallingError.microphoneDenied }
                try configureAudioSession()
                guard call?.callId == action.callUUID, !ended.contains(action.callUUID) else { action.fail(); return }
                // CallKit activates audio while the router picks up, not after it confirms; a
                // failed answer then ends the call. Audio not prepared while ringing is requested
                // once the answer is admitted.
                action.fulfill(); fulfilled = true
                if media == nil { requestedMedia = nil }
                try await command("answer", callId: action.callUUID)
            }
            catch {
                if !fulfilled { action.fail() }
                if !ended.contains(action.callUUID) {
                    present(error)
                    finish(action.callUUID, reason: .failed)
                }
            }
        }
    }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let id = action.callUUID
        finish(id, reason: .remoteEnded)
        action.fulfill()
        Task { do { try await command("hangup", callId: id) } catch { present(error) } }
    }
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard call?.callId == action.callUUID, !ended.contains(action.callUUID) else { action.fail(); return }
        media?.mute(action.isMuted)
        muted = action.isMuted
        action.fulfill()
    }
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        Task { do { try await command("dtmf", callId: action.callUUID, digits: action.digits); action.fulfill() } catch { present(error); action.fail() } }
    }
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let callAction = action as? CXCallAction else { return }
        let id = callAction.callUUID
        guard !ended.contains(id) else { return }
        finish(id, reason: .failed)
        Task { do { try await command("hangup", callId: id) } catch { present(error) } }
    }
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioSessionActive = true
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = call.map { !ended.contains($0.callId) } == true
        if speaker {
            let audio = RTCAudioSession.sharedInstance()
            audio.lockForConfiguration()
            defer { audio.unlockForConfiguration() }
            do { try audio.overrideOutputAudioPort(.speaker) }
            catch { present(error) }
        }
    }
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioSessionActive = false
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    }
}

extension RemoteCallingManager: @preconcurrency PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        pushToken = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { do { try await registerPushToken() } catch { present(error) } }
    }
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        pushToken = nil
        guard let credentials else { return }
        Task {
            do { _ = try await http.request("v1/push-token", server: serverBase(credentials), token: credentials.phoneToken, method: "DELETE") }
            catch { present(error) }
        }
    }
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let value = payload.dictionaryPayload
        guard let raw = value["callId"] as? String, let id = UUID(uuidString: raw),
              let router = value["routerId"] as? String, let routerId = UUID(uuidString: router),
              let expiry = value["expiresAt"] as? Int, let number = value["handle"] as? String,
              number.count <= 64, routerId == credentials?.routerId else {
            // Even a malformed VoIP push must complete the system call-reporting lifecycle.
            reportIncoming(id: UUID(), number: "OpenU60", expired: true, completion: completion)
            return
        }
#if DEBUG && OPENU60_NATIVE_CALLKIT_PROBE
        if nativeProbeSnapshot != nil {
            nativeProbePushReceipts += 1
            nativeProbePushInBackground = UIApplication.shared.applicationState != .active
        }
#endif
        let expired = expiry <= Int(Date().timeIntervalSince1970) || ended.contains(id)
        if call == nil, !expired {
            call = RemoteCall(callId: id, routerId: routerId, direction: .incoming, state: .ringing,
                number: number, reason: nil, mediaReady: false, updatedAt: Int(Date().timeIntervalSince1970), sequence: 0)
        }
        reportIncoming(id: id, number: number, expired: expired, completion: completion)
    }
}

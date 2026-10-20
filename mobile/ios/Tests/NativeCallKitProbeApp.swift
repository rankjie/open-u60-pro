#if DEBUG && OPENU60_NATIVE_CALLKIT_PROBE
import SwiftUI
import CallKit
import Observation
import WebRTC

struct NativeCallKitProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var probe = NativeCallKitProbe()
    var body: some View {
        NavigationStack {
            Form {
                Section("Native CallKit / synthetic router") {
                    Text(probe.status).accessibilityIdentifier("probe-status")
                    Text("Synthetic downlink, muted uplink; no cellular gateway.").font(.footnote)
                    Button("Simulate incoming") { probe.incoming() }.disabled(probe.manager.call != nil)
                    Button("Background incoming (3s)") { probe.backgroundIncoming() }.disabled(probe.manager.call != nil)
                    Button("Start outgoing") { probe.perform { try await probe.manager.start(number: "+999000001") } }.disabled(probe.manager.call != nil)
                    Button("Answer in app") { probe.perform { try await probe.manager.answer() } }.disabled(probe.manager.call == nil)
                    Button("End call") { probe.perform { try await probe.manager.hangup() } }.disabled(probe.manager.call == nil)
                    Button("Toggle mute") { probe.perform { try await probe.manager.toggleMute() } }.disabled(probe.manager.call == nil)
                }
                Section("Observed system state") {
                    Text("CallKit connected: \(probe.systemConnected ? "yes" : "no")")
                    Text("Audio activated: \(probe.audioActivated ? "yes" : "no")")
                    Text("Muted: \(probe.manager.muted ? "yes" : "no")")
                    Text("Completed system calls: \(probe.endedCalls)")
                    Text("Native packets received: \(probe.nativeReceived), sent: \(probe.nativeSent)")
                    Text("Gateway packets received: \(probe.gatewayReceived), sent: \(probe.gatewaySent)")
                    if let error = probe.manager.errorMessage { Text(error).foregroundStyle(.red) }
                    ForEach(Array(probe.events.enumerated()),id:\.offset) { _,entry in Text(entry).font(.caption) }
                }
            }
            .navigationTitle("CallKit test")
            .toolbar {
                ToolbarItem(placement:.topBarLeading) {
                    Button("Back to OpenU60",systemImage:"chevron.left") {
                        Task {await probe.stop();dismiss()}
                    }
                }
            }
            .interactiveDismissDisabled()
            .task { await probe.start() }
        }
    }
}

@Observable @MainActor final class NativeCallKitProbe: NSObject, @preconcurrency CXCallObserverDelegate {
    var status = "Connecting fixture"
    var events: [String] = []
    var systemConnected = false
    var audioActivated = false
    var endedCalls = 0
    var nativeReceived = 0
    var nativeSent = 0
    var gatewayReceived = 0
    var gatewaySent = 0
    private let router = UUID(uuidString:"00000000-0000-4000-8000-000000000001")!
    private let endpoint = UUID(uuidString:"00000000-0000-4000-8000-000000000002")!
    private let socket = NativeProbeSocket()
    private let observer = CXCallObserver()
    private let provider: CXProvider = {
        let config=CXProviderConfiguration();config.includesCallsInRecents=false;config.supportsVideo=false
        config.maximumCallGroups=1;config.maximumCallsPerCallGroup=1;config.supportedHandleTypes=[.phoneNumber,.generic]
        return CXProvider(configuration:config)
    }()
    private var current: UUID?
    private var closed: Set<UUID> = []
    private var media: CallingMedia?
    @ObservationIgnored lazy var manager: RemoteCallingManager = {
        RemoteCallingManager(provider:provider, credentials: CallingCredentials(serverURL: URL(string:"https://synthetic.invalid")!,
            phoneToken: String(repeating:"x",count:43),requestId:UUID(),endpointId:endpoint,routerId:router), bootstrap:false,
            socketFactory: { [unowned self] _ in self.socket },
            mediaFactory: { [unowned self] id,servers,_,sender,changed in
                let value=try CallingMedia(callId:id,servers:servers,muted:true,send:sender,stateChanged:changed)
                self.media=value
                return value
            })
    }()
    override init() { super.init(); observer.setDelegate(self,queue:.main) }
    func start() async {
        RTCSetMinDebugLogLevel(.none)
        socket.inspect = { [weak self] value in
            guard let self else {return}
            if value["type"] as? String == "probe_stats" {
                self.gatewayReceived=value["received"] as! Int;self.gatewaySent=value["sent"] as! Int
            } else if value["type"] as? String == "call",let raw=value["callId"] as? String {self.current=UUID(uuidString:raw)}
        }
        manager.connect()
        do { try await awaitConnection();status="Ready" }
        catch { status="Fixture connection failed";return }
        while !Task.isCancelled {
            audioActivated=RTCAudioSession.sharedInstance().isAudioEnabled && RTCAudioSession.sharedInstance().isActive
            if manager.call != nil,let media {
                do {let count=try await media.packetCounts();nativeReceived=count.received;nativeSent=count.sent}
                catch {status="Media statistics unavailable"}
            }
            do {try await Task.sleep(for:.milliseconds(250))} catch {return}
        }
    }
    private func awaitConnection() async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(10))
        while !manager.isConnected {
            if ContinuousClock.now >= deadline {throw CallingError.disconnected}
            try await Task.sleep(for:.milliseconds(20))
        }
    }
    func stop() async {
        if manager.call != nil {
            do {try await manager.hangup()} catch {manager.present(error)}
        }
        manager.disconnect()
        provider.invalidate()
    }
    func incoming() {
        guard manager.isConnected,manager.call==nil else {return}
        perform {try await self.socket.sendProbeIncoming()}
    }
    func backgroundIncoming() {
        let task=UIApplication.shared.beginBackgroundTask(withName:"CallKit QA incoming",expirationHandler:nil)
        Task { @MainActor in
            defer {if task != .invalid {UIApplication.shared.endBackgroundTask(task)}}
            do {try await Task.sleep(for:.seconds(3))} catch {return}
            events.append("Incoming while background: \(UIApplication.shared.applicationState != .active)")
            incoming()
        }
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {do {try await action()} catch {manager.present(error)}}
    }
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard call.uuid==current || call.uuid==manager.call?.callId else {return}
        systemConnected=call.hasConnected && !call.hasEnded
        if call.hasEnded,closed.insert(call.uuid).inserted {endedCalls+=1;status="System call ended"}
        else if call.hasConnected {status="System call connected";if !manager.muted {perform {try await self.manager.toggleMute()}}}
        else {status=call.isOutgoing ? "System outgoing call" : "System incoming call"}
        events.append("CXCall outgoing=\(call.isOutgoing) connected=\(call.hasConnected) ended=\(call.hasEnded)")
    }
}


@MainActor final class NativeProbeSocket: CallingSocket {
    private let task: URLSessionWebSocketTask = {
        guard let raw=Bundle.main.object(forInfoDictionaryKey:"OpenU60NativeProbeURL") as? String,let url=URL(string:raw),url.scheme=="ws" else {
            preconditionFailure("An explicit private LAN fixture URL is required")
        }
        return URLSession(configuration:.ephemeral).webSocketTask(with:url)
    }()
    var inspect: (([String:Any])->Void)?
    func resume() {task.resume()}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {try await task.send(message)}
    func cancel(with code: URLSessionWebSocketTask.CloseCode,reason:Data?) {task.cancel(with:code,reason:reason)}
    func receive() async throws -> URLSessionWebSocketTask.Message {
        while true {
            let message=try await task.receive();let data:Data
            switch message {case .data(let value):data=value;case .string(let value):data=Data(value.utf8);@unknown default:throw CallingError.invalidResponse}
            let value=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            inspect?(value)
            if value["type"] as? String != "probe_stats" {return message}
        }
    }
    func sendProbeIncoming() async throws {try await task.send(.string("{\"type\":\"probe_incoming\"}"))}
}

#endif

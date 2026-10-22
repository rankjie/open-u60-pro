import CryptoKit
import Foundation

@MainActor private final class DeviceConnectionFixture {
    let router = UUID(), endpoint = UUID()
    let first = URL(string:"https://first.synthetic.invalid/openu60")!
    let second = URL(string:"https://second.synthetic.invalid/openu60")!
    let key = try! P256.KeyAgreement.PrivateKey(rawRepresentation:Data(repeating:1, count:32))
    var saved: SavedCallingCredentials
    var failSave = false
    var outcome = "success"
    var payloads: [[String:Any]] = []
    var sockets: [TestSocket] = []
    init() throws {
        let active = CallingCredentials(serverURL:first, phoneToken:String(repeating:"a",count:43), requestId:UUID(), endpointId:UUID(), routerId:UUID())
        saved = SavedCallingCredentials(active:active)
        try saved.addServer(second); try saved.selectServer(second)
    }
    lazy var manager = RemoteCallingManager(provider:TestProvider(), bootstrap:false,
        socketFactory:{ [unowned self] _ in
            let socket = TestSocket(); self.sockets.append(socket)
            let active = self.saved.active!
            socket.emit(["type":"hello", "protocol":1, "role":"phone", "endpointId":active.endpointId!.uuidString,
                "routerId":active.routerId!.uuidString, "routerOnline":true, "voipPushConfigured":true, "iceServers":[], "calls":[]])
            return socket
        }, loadCredentials:{ [unowned self] in self.saved }, saveCredentials:{ [unowned self] value in
            if self.failSave { throw CallingError.server("synthetic_storage_failure") }; self.saved = value
        })
    func prepare() {
        manager.foreground()
        manager.deviceConnectionRequest = { [unowned self] path, server, method, body in
            precondition(server == self.second && self.saved.pending != nil)
            if method == "GET" {
                return ["routerId":self.router.uuidString, "serverTime":1_800_000_000.0,
                    "publicKey":self.key.publicKey.x963Representation.base64EncodedString()]
            }
            precondition(path == "v1/connect")
            self.payloads.append(body!)
            if self.outcome == "network" { throw URLError(.timedOut) }
            if self.outcome == "password" { throw CallingError.server("incorrect_router_password") }
            return ["role":"phone", "routerId":self.router.uuidString, "endpointId":self.endpoint.uuidString]
        }
    }
}

@MainActor func checkDeviceConnections(expect: (Bool, String) -> Void) async throws {
    func scanned(_ server: URL, _ router: UUID) throws -> DeviceConnectionQRCode {
        let data = try JSONSerialization.data(withJSONObject:["type":"openu60-connect", "version":1,
            "device":"U60-\(router.uuidString)", "server":server.absoluteString])
        return try DeviceConnectionQRCode(String(decoding:data, as:UTF8.self))
    }
    let scan = try DeviceConnectionFixture(); scan.prepare()
    let third = URL(string:"https://third.synthetic.invalid:8443/remote")!
    try scan.manager.selectScannedDevice(scanned(third, scan.router))
    expect(scan.saved.selectedServer == third && scan.saved.choices.count == 3 &&
        scan.saved.choices.first(where:{$0.address == scan.first})!.isPaired,
        "scanning a new server must select it and preserve existing phone authorizations")
    do {
        try scan.manager.selectScannedDevice(scanned(scan.first, scan.router))
        expect(false, "a QR for another router must not overwrite an existing authorization")
    } catch CallingError.server(let code) where code == "already_connected_to_another_router" {}
    expect(scan.saved.selectedServer == third, "rejected scans must leave the selected server unchanged")
    var pending = CallingCredentials(serverURL:scan.second, phoneToken:String(repeating:"p",count:43), requestId:UUID())
    pending.routerId = UUID()
    try scan.saved.selectServer(scan.second); scan.saved.pending = pending
    try scan.saved.selectServer(third)
    do {
        try scan.manager.selectScannedDevice(scanned(scan.second, scan.router))
        expect(false, "a scan must not replace a pending approval for another device")
    } catch CallingError.server(let code) where code == "pending_connection_other_router" {}
    scan.failSave = true
    do {
        try scan.manager.selectScannedDevice(scanned(URL(string:"https://fourth.synthetic.invalid")!, scan.router))
        expect(false, "a failed save must not report that the scanned server was selected")
    } catch CallingError.server(let code) where code == "synthetic_storage_failure" {}
    expect(scan.saved.selectedServer == third && scan.saved.choices.count == 3,
        "failed persistence must leave the saved server profiles unchanged")
    scan.manager.disconnect(); scan.manager.deviceConnectionRequest = nil
    for outcome in ["success", "network", "password", "storage"] {
        let f = try DeviceConnectionFixture(); f.prepare(); f.outcome = outcome; f.failSave = outcome == "storage"
        let before = f.saved.choices.first(where:{$0.address == f.first})!
        do {
            try await f.manager.connectDevice(code:"U60-\(f.router.uuidString)", password:"synthetic-device-password")
            expect(outcome == "success", "failed enrollment must not report success")
        } catch {
            expect(outcome != "success", "a device-approved connection must complete")
        }
        switch outcome {
        case "success":
            expect(f.saved.active?.routerId == f.router && f.saved.pending == nil && f.manager.isPaired,
                "device approval must persist the selected phone authorization")
        case "network":
            let id = f.saved.pending?.requestId
            expect(id != nil && f.saved.active == nil, "network loss must retain an actionable pending credential")
            do {
                try await f.manager.connectDevice(code:"U60-\(UUID().uuidString)", password:"synthetic-device-password")
                expect(false, "a pending credential must remain bound to its original device")
            } catch CallingError.server(let code) where code == "pending_connection_other_router" {}
            expect(f.saved.pending?.requestId == id && f.payloads.count == 1, "a different device string must not discard or transmit the pending credential")
            f.outcome = "success"
            try await f.manager.connectDevice(code:"U60-\(f.router.uuidString)", password:"synthetic-device-password")
            expect(f.saved.active?.requestId == id && f.payloads.count == 2 &&
                f.payloads[0]["phoneToken"] as? String == f.payloads[1]["phoneToken"] as? String,
                "an uncertain approval retry must reuse its request and phone credential")
        case "password": expect(f.saved.pending == nil && f.saved.active == nil, "a rejected password must permit a fresh corrected attempt")
        default: expect(f.payloads.isEmpty && f.saved.pending == nil, "failed persistence must prevent external approval work")
        }
        expect(f.saved.choices.first(where:{$0.address == f.first})?.isPaired == before.isPaired,
            "connecting another server must preserve existing phone authorizations")
        if f.saved.active != nil { try await wait { f.manager.isConnected } }
        f.manager.disconnect(); f.manager.deviceConnectionRequest = nil
    }
    let f = try DeviceConnectionFixture(); f.prepare()
    try await f.manager.connectDevice(code:"U60-\(f.router.uuidString)", password:"synthetic-device-password")
    try await wait { f.manager.isConnected }
    let previousToken = f.saved.active!.phoneToken
    f.sockets.last!.response = HTTPURLResponse(url:f.second, statusCode:401, httpVersion:nil, headerFields:nil)
    f.sockets.last!.cancel(with:.policyViolation, reason:nil)
    try await wait { f.manager.pairingRejected }
    try await f.manager.connectDevice(code:"U60-\(f.router.uuidString)", password:"synthetic-device-password")
    expect(!f.manager.pairingRejected && f.saved.active?.phoneToken != previousToken && f.payloads.count == 2,
        "a revoked phone must be able to authenticate again with the device password")
    f.manager.disconnect(); f.manager.deviceConnectionRequest = nil
}

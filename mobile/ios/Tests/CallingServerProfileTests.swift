import Foundation
import CallKit

@MainActor func checkServerProfiles(expect: (Bool, String) -> Void) throws {
    let first = URL(string: "https://first.synthetic.invalid/openu60")!
    let second = URL(string: "https://second.synthetic.invalid:8443/openu60")!
    let third = URL(string: "https://third.synthetic.invalid/openu60")!
    let a = CallingCredentials(serverURL: first, phoneToken: String(repeating: "a", count: 43),
        requestId: UUID(), endpointId: UUID(), routerId: UUID())
    let b = CallingCredentials(serverURL: second, phoneToken: String(repeating: "b", count: 43),
        requestId: UUID(), endpointId: UUID(), routerId: UUID())
    let retry = CallingCredentials(serverURL: second, phoneToken: String(repeating: "c", count: 43), requestId: UUID())
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    let legacy = try JSONSerialization.data(withJSONObject: [
        "active": JSONSerialization.jsonObject(with: encoder.encode(a)),
        "pending": JSONSerialization.jsonObject(with: encoder.encode(retry))])
    var saved = try decoder.decode(SavedCallingCredentials.self, from: legacy)
    expect(saved.selectedServer == first && saved.active?.phoneToken == a.phoneToken,
           "The existing single-server pairing must remain selected after migration")
    expect(saved.choices.count == 2 && saved.choices.first(where: { $0.address == second })?.hasPendingPairing == true,
           "A pending pairing on another server must survive migration and remain actionable")
    try saved.selectServer(second)
    expect(saved.pending?.requestId == retry.requestId && saved.active == nil,
           "Selecting an unpaired server must preserve its retry and never reuse another server's credential")
    saved.active = b
    try saved.selectServer(first)
    expect(saved.active?.endpointId == a.endpointId, "Switching back must restore the original pairing")
    try saved.selectServer(second)
    saved = try decoder.decode(SavedCallingCredentials.self, from: encoder.encode(saved))
    expect(saved.selectedServer == second && saved.active?.phoneToken == b.phoneToken && saved.pending?.requestId == retry.requestId,
           "Selected server, independent credentials, and pending pairing must persist across launch")
    saved.active = nil; saved.pending = nil
    try saved.selectServer(first)
    expect(saved.active?.endpointId == a.endpointId, "Forgetting one pairing must preserve the others")
    try saved.removeServer(second)
    try saved.addServer(third)
    expect(saved.selectedServer == first && saved.choices.count == 2,
           "Adding or removing an inactive address must keep the current server selected")
    func rejected(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
    expect(rejected { try saved.addServer(third) }, "Duplicate server addresses must be rejected")
    expect(rejected { try saved.removeServer(first) }, "Removing the selected server requires an explicit replacement")
    expect(try CallingCredentialStore.serverURL(second.absoluteString) == second, "Custom HTTPS ports and paths must be retained")
    for invalid in ["http://plain.synthetic.invalid", "https://user:password@synthetic.invalid", "https://synthetic.invalid/?token=x", "https://synthetic.invalid/#fragment", "https://synthetic.invalid:0", "https://synthetic.invalid:65536"] {
        expect(rejected { _ = try CallingCredentialStore.serverURL(invalid) }, "Invalid or unsupported server URLs must fail explicitly")
    }
    var malformed = try JSONSerialization.jsonObject(with: encoder.encode(saved)) as! [String: Any]
    malformed["selectedServer"] = second.absoluteString
    expect(rejected { _ = try decoder.decode(SavedCallingCredentials.self, from: JSONSerialization.data(withJSONObject: malformed)) },
           "A missing selected profile must fail rather than silently choose another server")
    malformed["selectedServer"] = first.absoluteString
    let profile = (malformed["profiles"] as! [[String: Any]])[0]
    malformed["profiles"] = [profile, profile]
    expect(rejected { _ = try decoder.decode(SavedCallingCredentials.self, from: JSONSerialization.data(withJSONObject: malformed)) },
           "Duplicate stored profiles must fail rather than make credential ownership ambiguous")
}

@MainActor private final class ServerSelectionFixture {
    let provider = TestProvider()
    let first = URL(string: "https://first.synthetic.invalid/openu60")!
    let second = URL(string: "https://second.synthetic.invalid:8443/openu60")!
    let third = URL(string: "https://third.synthetic.invalid/openu60")!
    var saved: SavedCallingCredentials
    var failSave = false
    var sockets: [TestSocket] = []
    var requests: [URLRequest] = []

    init() throws {
        let a = CallingCredentials(serverURL: first, phoneToken: String(repeating: "a", count: 43),
            requestId: UUID(), endpointId: UUID(), routerId: UUID())
        let b = CallingCredentials(serverURL: second, phoneToken: String(repeating: "b", count: 43),
            requestId: UUID(), endpointId: UUID(), routerId: UUID())
        saved = SavedCallingCredentials(active: a)
        try saved.addServer(second); try saved.selectServer(second); saved.active = b
        try saved.selectServer(first)
    }
    lazy var manager = RemoteCallingManager(provider: provider, bootstrap: false,
        socketFactory: { [unowned self] request in
            self.requests.append(request)
            let socket = TestSocket(); self.sockets.append(socket)
            let active = self.saved.active!
            socket.emit(["type": "hello", "protocol": 1, "role": "phone", "endpointId": active.endpointId!.uuidString,
                "routerId": active.routerId!.uuidString, "routerOnline": true, "voipPushConfigured": true,
                "iceServers": [], "calls": []])
            return socket
        },
        loadCredentials: { [unowned self] in self.saved },
        saveCredentials: { [unowned self] value in
            if self.failSave { throw CallingError.server("synthetic_storage_failure") }
            self.saved = value
        })
}

@MainActor func checkServerSelection(expect: (Bool, String) -> Void) async throws {
    let f = try ServerSelectionFixture()
    f.manager.foreground()
    try await wait { f.manager.isConnected }
    let firstEndpoint = f.saved.active!.endpointId
    let firstSocket = f.sockets.last!
    let firstRevision = f.manager.pairingRevision
    try f.manager.addServer(f.third.absoluteString)
    expect(f.manager.serverAddress == f.first.absoluteString && f.manager.isConnected,
           "Adding an undeployed address must preserve the active connection")
    try f.manager.selectServer(f.second)
    expect(firstSocket.cancelled && !f.manager.isConnected && !f.manager.pushConfigured,
           "Switching must close the old socket and clear its connection and push status")
    try await wait { f.manager.isConnected }
    expect(f.saved.selectedServer == f.second && f.manager.managementAccess?.server == f.second,
           "Management and calling must follow the persisted selected server")
    expect(f.manager.managementAccess?.token == f.saved.active?.phoneToken &&
           f.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(f.saved.active!.phoneToken)",
           "HTTP management and WSS signaling must use the selected server's credential")
    expect(f.manager.pairingRevision != firstRevision, "Switching paired servers must refresh notification registration")
    let socketCount = f.sockets.count
    try f.manager.selectServer(f.third)
    await Task.yield()
    expect(!f.manager.isPaired && f.manager.managementAccess == nil && f.sockets.count == socketCount && f.manager.hasSavedPairing,
           "An unpaired server must not borrow credentials or connect, while the normal app remains available")
    try f.manager.selectServer(f.first)
    try await wait { f.manager.isConnected }
    expect(f.saved.active?.endpointId == firstEndpoint, "Selecting the original server must reuse its preserved pairing")
    let currentSocket = f.sockets.last!
    f.failSave = true
    do { try f.manager.selectServer(f.second); expect(false, "A storage failure must fail selection") }
    catch CallingError.server(let code) where code == "synthetic_storage_failure" {}
    expect(f.manager.serverAddress == f.first.absoluteString && !currentSocket.cancelled,
           "Failed persistence must leave the active connection unchanged")
    f.failSave = false
    let id = UUID()
    currentSocket.emit(["type": "call", "callId": id.uuidString, "routerId": f.saved.active!.routerId!.uuidString,
        "direction": "incoming", "state": "ringing", "number": "12345", "mediaReady": false,
        "updatedAt": 1_800_000_000, "sequence": 1])
    try await wait { f.manager.call != nil }
    do { try f.manager.selectServer(f.second); expect(false, "An active call must prevent server selection") }
    catch CallingError.server(let code) where code == "call_in_progress" {}
    expect(f.saved.selectedServer == f.first && !currentSocket.cancelled,
           "Rejected switching must preserve the current call's server")
    currentSocket.emit(["type": "call", "callId": id.uuidString, "routerId": f.saved.active!.routerId!.uuidString,
        "direction": "incoming", "state": "ended", "number": "12345", "mediaReady": false,
        "updatedAt": 1_800_000_001, "sequence": 2])
    try await wait { f.manager.call == nil }
    f.manager.disconnect()
}

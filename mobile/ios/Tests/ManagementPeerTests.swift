import Foundation
import CallKit

@MainActor func checkManagementPeers(expect: @escaping (Bool, String) -> Void) async throws {
    func enable(_ f: Fixture, wrongRouter: Bool = false) {
        f.socket.onMessage = { value in
            if value["type"] as? String == "peer_open" {
                f.socket.emit(["type":"peer_session", "sessionId":value["sessionId"]!, "phoneId":f.endpoint.uuidString,
                    "routerId":(wrongRouter ? UUID() : f.router).uuidString,
                    "expiresAt":Date().timeIntervalSince1970 + 299, "iceServers":[["urls":["stun:synthetic.invalid:3478"]]]])
            }
        }
        f.socket.emit(["type":"presence", "routerOnline":true, "peerManagement":true])
    }
    let data = Data("{}".utf8)
    do {
        let f = Fixture(); try await f.connect(calls:[])
        let absent = try await f.manager.peerManagementRequest(data, id:UUID(), timeout:8)
        expect(absent == nil && f.peers.isEmpty, "old agents must continue using relay without P2P messages")
        enable(f); try await Task.sleep(for:.milliseconds(20))
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<6 { group.addTask { @MainActor in
                let result = try await f.manager.peerManagementRequest(data, id:UUID(), timeout:8)
                expect(result?.status == 200, "concurrent management requests must share a direct peer")
            } }
            try await group.waitForAll()
        }
        expect(f.peers.count == 1 && f.media.isEmpty, "management negotiation must not create call media")
        expect(f.socket.messages.filter { $0["type"] as? String == "peer_open" }.count == 1, "parallel dashboard reads must share one introduction")
        f.manager.disconnect()
        expect(f.peers[0].closed, "server disconnection must close the admitted management peer")
        f.socket.onMessage = nil
    }
    do {
        let f = Fixture(); try await f.connect(calls:[]); enable(f, wrongRouter:true)
        try await Task.sleep(for:.milliseconds(20))
        let result = try await f.manager.peerManagementRequest(data, id:UUID(), timeout:8)
        expect(result == nil && f.peers.isEmpty && f.manager.isConnected, "a mismatched router introduction must leave only the authenticated relay usable")
        f.manager.disconnect(); f.socket.onMessage = nil
    }
    do {
        let f = Fixture(); f.peerReady = false; try await f.connect(calls:[]); enable(f)
        try await Task.sleep(for:.milliseconds(20))
        let start = ContinuousClock.now
        let result = try await f.manager.peerManagementRequest(data, id:UUID(), timeout:1.2)
        expect(result == nil && start.duration(to:.now) < .seconds(2), "failed punching must have a finite wait")
        let retry = try await f.manager.peerManagementRequest(data, id:UUID(), timeout:8)
        expect(retry == nil && f.peers.count == 1 && f.peers[0].closed, "failed punching must back off while relay remains usable")
        f.manager.disconnect(); f.socket.onMessage = nil
    }
    do {
        let f = Fixture(), id = UUID(); try await f.start(id); enable(f)
        try await Task.sleep(for:.milliseconds(20))
        _ = try await f.manager.peerManagementRequest(data, id:UUID(), timeout:8)
        var deliveries: [String] = []
        f.manager.localCommandDelivery = { _,_ in false }
        f.manager.commandAdmission = { body, delivery in
            deliveries.append(delivery); var command = body; command["expiresAt"] = 1_800_000_020
            return ["command":command, "status":"pending", "proof":["phoneId":f.endpoint.uuidString, "mac":String(repeating:"x",count:43)]]
        }
        f.peers[0].onRequest = { data in
            let payload = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            let command = payload["command"] as! [String:Any]
            expect(payload["requestId"] as? String == command["requestId"] as? String, "P2P calls must keep their server-admitted operation ID")
            expect((payload["proof"] as? [String:Any])?["phoneId"] as? String == f.endpoint.uuidString, "P2P must forward the admitted phone's proof")
            f.socket.emit(["type":"result", "requestId":command["requestId"]!, "ok":true])
            return AgentHTTPResponse(status:202, data:try JSONSerialization.data(withJSONObject:["ok":true,"data":["queued":true,"requestId":command["requestId"]!]]))
        }
        let action = TestDTMFAction(call:id, digits:"1", type:.singleTone)
        f.manager.provider(f.provider, perform:action)
        try await wait { action.fulfilled }
        expect(deliveries == ["local"], "an admitted P2P call command must not be delivered again by the relay")
        f.manager.disconnect(); f.socket.onMessage = nil
    }
}

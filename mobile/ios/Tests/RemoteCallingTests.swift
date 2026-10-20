import Foundation
import CallKit
import WebRTC

@main struct RemoteCallingTests {
    @MainActor static func main() async throws {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        for localAccepted in [true, false] {
            let f = Fixture(); let id = UUID(); try await f.start(id)
            var admissions: [(UUID, String)] = []
            var delivered: UUID?
            f.manager.commandAdmission = { body, delivery in
                let operation = UUID(uuidString: body["requestId"] as! String)!
                admissions.append((operation, delivery))
                var canonical = body; canonical["expiresAt"] = 1_800_000_020
                if delivery == "relay" {
                    f.socket.emit(["type":"result","requestId":operation.uuidString,"callId":id.uuidString,"ok":true])
                }
                return ["command":canonical,"status":"pending"]
            }
            f.manager.localCommandDelivery = { command, router in
                expect(router == f.router, "local call control must target the paired router")
                delivered = UUID(uuidString:command["requestId"] as! String)!
                if localAccepted { f.socket.emit(["type":"result","requestId":delivered!.uuidString,"callId":id.uuidString,"ok":true]) }
                return localAccepted
            }
            let action = TestDTMFAction(call:id,digits:"12#",type:.singleTone)
            f.manager.provider(f.provider, perform:action)
            try await wait { action.fulfilled }
            expect(admissions.map(\.1) == (localAccepted ? ["local"] : ["local","relay"]), "call control must prefer LAN then relay an uncertain admission")
            expect(admissions.allSatisfy { $0.0 == delivered }, "both routes must retain the canonical operation ID")
            expect(!f.socket.messages.contains { $0["action"] as? String == "dtmf" }, "a confirmed local command must not be sent through another execution path")
            f.manager.commandAdmission = nil; f.manager.localCommandDelivery = nil; f.manager.disconnect()
        }
        do {
            let f = Fixture(); let id = UUID(); try await f.start(id)
            f.socket.emit(["type":"ice_servers", "iceServers":[["urls":["turn:synthetic.invalid:3478"]]]])
            f.socket.emit(f.snapshot(id, sequence: 2))
            try await wait { f.manager.call?.sequence == 2 }
            f.manager.provider(f.provider, perform: CXSetMutedCallAction(call:id, muted:true))
            let before = f.socket.messages.filter { $0["type"] as? String == "media_request" }.count
            f.media[0].changed(.failed)
            try await wait { f.socket.messages.filter { $0["type"] as? String == "media_request" }.count == before + 1 }
            expect(f.manager.call?.callId == id && f.media[0].closed, "a failed direct path must retain CallKit ownership while replacing its peer")
            f.offer(id); try await wait { f.media.count == 2 }
            expect(f.media[1].relayOnly && f.media[1].muted, "the recovery peer must require TURN and preserve mute")
            f.media[1].changed(.connected)
            f.media[0].changed(.failed)
            expect(f.manager.audioConnected && !f.media[1].closed, "a stale direct failure must not close a recovered relay")
            expect(!f.socket.messages.contains { $0["action"] as? String == "dial" || $0["action"] as? String == "hangup" }, "media recovery must neither redial nor hang up the existing call")
            f.manager.disconnect()
        }
        do {
            let f = Fixture(); let id = UUID()
            try await f.connect(calls: [f.snapshot(id, state: "ringing")])
            f.socket.emit(f.snapshot(id, state: "ringing", sequence: 2))
            try await wait { f.manager.call?.sequence == 2 }
            expect(f.socket.messages.filter { $0["type"] as? String == "media_request" }.count == 1,
                   "a reconnect snapshot must request one peer, even before its offer arrives")
            f.manager.disconnect()
        }
        do {
            let f = Fixture(); let id = UUID(); try await f.start(id)
            f.manager.provider(f.provider, perform: CXSetMutedCallAction(call:id,muted:true))
            expect(f.media[0].muted, "mute must disable the existing microphone track")
            f.offer(id); try await wait { f.media.count == 2 }
            expect(f.media[1].muted, "renegotiating media must preserve microphone mute")
            f.media[1].changed(.connected); f.media[0].changed(.failed)
            expect(f.manager.audioConnected,"a replaced peer must not fail its replacement within the same call")
            f.manager.disconnect()
        }
        do {
            let f = Fixture(); let old = UUID(); try await f.start(old)
            f.socket.emit(f.snapshot(old,state:"ended",sequence:2)); try await wait { f.manager.call == nil }
            let current = UUID(); f.socket.emit(f.snapshot(current)); try await wait { f.manager.call?.callId == current }
            f.offer(current); try await wait { f.media.count == 2 }
            f.media[1].changed(.connected)
            f.media[0].changed(.failed)
            expect(f.manager.audioConnected, "a previous media failure must not change the current call")
            let end = TestEndAction(call:old)
            f.manager.provider(f.provider, perform:end)
            expect(end.fulfilled,"the local end action must finish without waiting for network acknowledgement")
            expect(!f.media[1].closed, "a late end action must not close the new call's media")
            try await wait { f.socket.messages.contains { $0["action"] as? String == "hangup" } }
            f.manager.disconnect()
        }
        do {
            let f=Fixture();let id=UUID();try await f.start(id);f.media[0].changed(.connected)
            f.manager.resumeSignaling(at: .now.advanced(by: .seconds(31)))
            try await wait {f.sockets.count==2 && f.manager.isConnected}
            expect(f.sockets[0].cancelled,"a stale socket must be replaced on wakeup")
            expect(!f.media[0].closed && f.manager.audioConnected,"signaling reconnection must preserve established media")
            f.manager.disconnect()
        }
        do {
            let f=Fixture();let id=UUID();try await f.start(id)
            f.socket.holdSends=true
            f.media[0].sender("candidate",["candidate":"candidate:synthetic", "sdpMid":"0", "sdpMLineIndex":0])
            try await wait(seconds:8) {f.sockets.count==2 && f.manager.isConnected}
            expect(f.sockets[0].cancelled,"a stalled WebSocket write must be cancelled by its deadline")
            f.manager.disconnect()
        }
        do {
            let f=Fixture();let id=UUID();try await f.start(id);f.media[0].changed(.connected)
            let historical=UUID();f.socket.emit(f.snapshot(historical,state:"ended",sequence:99))
            try await wait {f.provider.endedCalls.contains(historical)}
            expect(f.manager.call?.callId==id && f.manager.audioConnected && !f.media[0].closed,"an ended historical call must not replace or close the current call")
            f.manager.disconnect()
        }
        do {
            let f=Fixture();f.holdPermission=true;try await f.connect(calls:[])
            let attempt=Task { @MainActor in
                do {try await f.manager.start(number:"12345");return false}
                catch CallingError.server(let code) where code=="call_in_progress" {return true}
                catch {return false}
            }
            try await wait {f.permission != nil}
            let incoming=UUID();f.socket.emit(f.snapshot(incoming));try await wait {f.manager.call?.callId==incoming}
            f.permission?.resume(returning:true);f.permission=nil
            expect(await attempt.value,"an incoming call during microphone permission must prevent a new dial")
            expect(f.manager.call?.callId==incoming && !f.socket.messages.contains {$0["action"] as? String=="dial"},"the real incoming call must retain ownership")
            f.manager.disconnect()
        }
        for message in failures { print("FAIL:",message) }
        if !failures.isEmpty { exit(1) }
        print("Remote calling lifecycle checks passed")
    }
}

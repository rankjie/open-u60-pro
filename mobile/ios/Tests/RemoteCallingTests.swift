import Foundation
import CallKit
import WebRTC

@main struct RemoteCallingTests {
    @MainActor static func main() async throws {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        try checkServerProfiles(expect: expect)
        try await checkServerSelection(expect: expect)
        try await checkManagementPeers(expect: expect)
        try await checkDeviceConnections(expect: expect)
        expect(CallingDeviceInfo.displayName(assigned: "iPhone", model: "iPhone17,1") == "iPhone 16 Pro", "generic device names must identify the observed 16 Pro hardware")
        expect(CallingDeviceInfo.displayName(assigned: "iPhone", model: "iPhone18,1") == "iPhone 17 Pro", "the 17 Pro must remain distinct from the 16 Pro")
        expect(CallingDeviceInfo.displayName(assigned: "Office phone", model: "iPhone17,1") == "Office phone", "an available assigned name must be preserved")
        expect(CallingDeviceInfo.displayName(assigned: "iPhone", model: "future-model") == "iPhone (future-model)", "unmapped hardware must retain its actual model identifier")
        do {
            let f = Fixture(); let id = UUID()
            try await f.connect(calls: [f.snapshot(id)])
            let connected = f.manager.call?.connectedDate
            expect(connected == Date(timeIntervalSince1970: 1_800_000_000), "the timer must use the carrier's connected time")
            var reconnect = f.snapshot(id, sequence: 2); reconnect["updatedAt"] = 1_800_000_020; reconnect["mediaReady"] = false
            f.socket.emit(reconnect); try await wait { f.manager.call?.sequence == 2 }
            expect(f.manager.call?.connectedDate == connected, "an audio reconnect must not reset call duration")
            f.manager.disconnect()
        }
        do {
            let f = Fixture(); let id = UUID()
            try await f.connect(calls: [f.snapshot(id, state: "ringing")])
            expect(f.manager.callPresentationRequest == nil, "a background ring must wait for the user to open or answer it")
            f.holdPermission = true
            let action = TestAnswerAction(call: id)
            f.manager.provider(f.provider, perform: action)
            expect(f.manager.callPresentationRequest?.callID == id,
                   "CallKit answer must request the current call screen before asynchronous permission or modem work")
            let request = f.manager.callPresentationRequest
            try await wait { f.permission != nil }
            f.socket.emit(f.snapshot(id, state: "ringing", sequence: 2))
            try await wait { f.manager.call?.sequence == 2 }
            expect(f.manager.callPresentationRequest == request, "a repeated ringing snapshot must not replace the answer navigation request")
            f.permission?.resume(returning: true); f.permission = nil
            try await wait { action.fulfilled }
            try await wait { f.socket.messages.contains { $0["action"] as? String == "answer" } }
            expect((f.socket.messages.first { $0["action"] as? String == "answer" })?["device"] as? [String:String]
                   == ["name":"iPhone 16 Pro","model":"iPhone17,1"], "the actual answering phone must accompany its admitted answer")
            f.manager.requestCallPresentation()
            expect(f.manager.callPresentationRequest?.callID == id && f.manager.callPresentationRequest != request,
                   "opening an ongoing call again must navigate even when the call ID has not changed")
            let end = TestEndAction(call: id)
            f.manager.provider(f.provider, perform: end)
            expect(f.manager.callPresentationRequest == nil, "an ended call must not leave navigation pending for a later app launch")
            f.manager.provider(f.provider, perform: TestAnswerAction(call: id))
            f.manager.requestCallPresentation()
            expect(f.manager.callPresentationRequest == nil, "a stale answer or foreground without a call must not reopen the call screen")
            try await wait { f.socket.messages.contains { $0["action"] as? String == "hangup" } }
            f.manager.disconnect()
        }
        for state in ["answering", "active"] {
            let f = Fixture(); let id = UUID()
            try await f.connect(calls: [f.snapshot(id, state: state)])
            expect(f.manager.callPresentationRequest?.callID == id,
                   "restoring an answered call must retain navigation until the normal app is ready")
            f.manager.disconnect()
        }
        do {
            let f = Fixture(); let id = UUID()
            try await f.connect(calls: [f.snapshot(id, state: "answering")])
            expect(f.media.isEmpty, "answering starts before the media offer arrives")
            f.manager.provider(f.provider, perform: CXSetMutedCallAction(call: id, muted: true))
            expect(f.manager.muted, "mute must be selectable before media exists")
            try f.manager.toggleSpeaker()
            expect(f.manager.speaker, "speaker must be selectable before CallKit activates audio")
            f.offer(id); try await wait { f.media.count == 1 }
            expect(f.media[0].muted, "the first microphone track must inherit the preselected mute")
            f.manager.disconnect()
        }
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
        func mediaRequests(_ f: Fixture) -> [[String: Any]] { f.socket.messages.filter { $0["type"] as? String == "media_request" } }
        do {
            let f = Fixture(); let id = UUID()
            try await f.connect(calls: [f.snapshot(id, state: "ringing")])
            try await wait { mediaRequests(f).count == 1 }
            expect(mediaRequests(f)[0]["prepare"] as? Bool == true, "a ringing phone must prepare audio before the user answers")
            f.socket.emit(f.snapshot(id, state: "ringing", sequence: 2))
            try await wait { f.manager.call?.sequence == 2 }
            f.offer(id); try await wait { f.media.count == 1 }
            f.media[0].changed(.connected)
            f.manager.provider(f.provider, perform: TestAnswerAction(call: id))
            try await wait { f.socket.messages.contains { $0["action"] as? String == "answer" } }
            f.socket.emit(f.snapshot(id, state: "answering", sequence: 3))
            try await wait { f.manager.call?.sequence == 3 }
            expect(mediaRequests(f).count == 1 && f.media.count == 1 && !f.media[0].closed,
                   "answering must keep the prepared connection instead of negotiating again")
            f.manager.disconnect()
        }
        do {
            let f = Fixture(); let id = UUID()
            try await f.connect(calls: [f.snapshot(id, state: "ringing")])
            try await wait { mediaRequests(f).count == 1 }
            f.socket.emit(["type":"error","requestId":mediaRequests(f)[0]["requestId"]!,"error":"call_not_claimed"])
            f.socket.emit(f.snapshot(id, state: "ringing", sequence: 2))
            try await wait { f.manager.call?.sequence == 2 }
            expect(f.manager.errorMessage == nil, "a server that cannot prepare audio must not show an error")
            f.manager.provider(f.provider, perform: TestAnswerAction(call: id))
            try await wait { f.socket.messages.contains { $0["action"] as? String == "answer" } }
            f.socket.emit(f.snapshot(id, state: "answering", sequence: 3))
            try await wait { mediaRequests(f).count == 2 }
            expect(mediaRequests(f)[1]["prepare"] == nil, "without prepared audio the admitted answer must request it")
            f.manager.disconnect()
        }
        do {
            let f = Fixture(); let id = UUID()
            try await f.connect(calls: [f.snapshot(id, state: "ringing")])
            try await wait { mediaRequests(f).count == 1 }
            f.offer(id); try await wait { f.media.count == 1 }
            f.media[0].changed(.failed)
            try await Task.sleep(for: .milliseconds(50))
            expect(f.media[0].closed && f.manager.call?.callId == id && mediaRequests(f).count == 1
                   && !f.socket.messages.contains { $0["action"] as? String == "hangup" },
                   "a prepared connection that fails while ringing must be dropped without ending the call")
            f.manager.provider(f.provider, perform: TestAnswerAction(call: id))
            try await wait { f.socket.messages.contains { $0["action"] as? String == "answer" } }
            f.socket.emit(f.snapshot(id, state: "answering", sequence: 2))
            try await wait { mediaRequests(f).count == 2 }
            f.manager.disconnect()
        }
        do {
            let f = Fixture(); let id = UUID()
            try await f.connect(calls: [f.snapshot(id, state: "ringing")])
            try await wait { mediaRequests(f).count == 1 }
            var probed = false
            f.manager.commandAdmission = { _, _ in probed = true; return [:] }
            f.manager.localCommandDelivery = { _, _ in probed = true; return false }
            f.socket.holdSends = true
            let action = TestAnswerAction(call: id)
            f.manager.provider(f.provider, perform: action)
            try await wait { action.fulfilled }
            expect(!f.socket.messages.contains { $0["action"] as? String == "answer" },
                   "CallKit must activate audio before the router confirms the answer")
            f.socket.holdSends = false; f.socket.blockedSend?.resume(); f.socket.blockedSend = nil
            try await wait { f.socket.messages.contains { $0["action"] as? String == "answer" } }
            expect(!probed, "an answer must go over the open socket, not wait for LAN or P2P probes")
            f.manager.commandAdmission = nil; f.manager.localCommandDelivery = nil; f.manager.disconnect()
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
        for reason in ["answered_elsewhere", "declined_on_device"] {
            let f = Fixture(); let id = UUID()
            try await f.connect(calls: [f.snapshot(id, state: "ringing")])
            var ended = f.snapshot(id, state: "ended", sequence: 2); ended["reason"] = reason
            f.socket.emit(ended)
            try await wait { f.provider.endedReasons[id] != nil }
            expect(f.manager.call == nil && f.media.isEmpty, "another phone's answer must close ringing without opening audio")
            expect(f.provider.endedReasons[id] == (reason == "answered_elsewhere" ? .answeredElsewhere : .declinedElsewhere),
                   "CallKit must receive the correct multi-device end reason")
            f.socket.emit(f.snapshot(id, state: "ringing", sequence: 1))
            try await Task.sleep(for: .milliseconds(10))
            expect(f.manager.call == nil, "a delayed ring cannot resurrect a call handled on another phone")
            f.manager.disconnect()
        }
        do {
            let f = Fixture()
            f.socket.response = HTTPURLResponse(url: URL(string: "https://synthetic.invalid/v1/socket")!, statusCode: 401, httpVersion: nil, headerFields: nil)
            f.manager.connect()
            try await wait { f.socket.receiving != nil }
            f.socket.receiving?.resume(throwing: URLError(.badServerResponse)); f.socket.receiving = nil
            try await wait { f.manager.pairingRejected }
            expect(f.manager.errorMessage?.contains("Pair it") == true, "a rejected pairing must explain how to reconnect")
            expect(!f.manager.isConnected, "a rejected pairing cannot appear connected")
            f.manager.disconnect()
        }
        for message in failures { print("FAIL:",message) }
        if !failures.isEmpty { exit(1) }
        print("Remote calling lifecycle checks passed")
    }
}

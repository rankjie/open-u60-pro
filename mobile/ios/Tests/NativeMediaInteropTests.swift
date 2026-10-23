import Foundation
import WebRTC

@MainActor final class NativeMediaInterop {
    let socket = URLSession.shared.webSocketTask(with: URL(string:"ws://127.0.0.1:49171/native-fixture")!)
    var media: CallingMedia?
    var callId: String?
    var connected = false
    var pending: [CallingICECandidate] = []
    func send(_ value: [String:Any]) async throws {
        let data=try JSONSerialization.data(withJSONObject:value)
        try await socket.send(.string(String(decoding:data,as:UTF8.self)))
    }
    func run() async throws {
        let session=RTCAudioSession.sharedInstance();session.useManualAudio=true;session.isAudioEnabled=false
        socket.resume()
        let deadline=Task {do {try await Task.sleep(for:.seconds(20))}catch{return};socket.cancel(with:.goingAway,reason:nil)}
        defer {deadline.cancel();media?.close();socket.cancel(with:.normalClosure,reason:nil)}
        while true {
            let message=try await socket.receive();let data:Data
            switch message {case .data(let bytes):data=bytes;case .string(let text):data=Data(text.utf8);@unknown default:throw CallingError.invalidResponse}
            let value=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            if value["type"] as? String == "probe_stats" {
                if connected,let media {
                    let counts=try await media.packetCounts()
                    if counts.received>0 {try await send(["type":"probe_done","connected":true,"received":counts.received]);print("Real iOS Google WebRTC received synthetic G.711 packets:",counts.received);return}
                }
                continue
            }
            guard let raw=value["callId"] as? String,let id=UUID(uuidString:raw) else {throw CallingError.invalidResponse}
            callId=raw
            if let description=value["description"] as? [String:Any],let sdp=description["sdp"] as? String {
                let peer=try CallingMedia(callId:id,servers:[],muted:true,send:{ [weak self] kind,payload in
                    Task {@MainActor in do {try await self?.send(["type":"signal","callId":raw,kind:payload])} catch {self?.socket.cancel(with:.goingAway,reason:nil)}}
                },stateChanged:{[weak self] state in self?.connected=state == .connected})
                media=peer
                let answer=try await peer.answer(sdp:sdp)
                try await send(["type":"signal","callId":raw,"description":["type":"answer","sdp":answer]])
                for value in pending {try await peer.add(value)};pending=[]
            } else if let payload=value["candidate"] as? [String:Any] {
                let candidate=try JSONDecoder().decode(CallingICECandidate.self,from:JSONSerialization.data(withJSONObject:payload))
                if let media {try await media.add(candidate)}else{pending.append(candidate)}
            }
        }
    }
}
@main struct NativeMediaInteropTests {
    @MainActor static func main() async {
        RTCSetMinDebugLogLevel(.none)
        // Call audio never queues seconds behind a burst: WebRTC's default allows 200 packets.
        let config=CallingMedia.configuration(servers:[],relayOnly:true)
        precondition(config.audioJitterBufferMaxPackets==25 && config.audioJitterBufferFastAccelerate && config.iceTransportPolicy == .relay)
        let client=NativeMediaInterop()
        do {try await client.run()} catch {
            // Never print SDP, ICE credentials, candidate strings, or SDK error descriptions.
            print("Native media interop failed:",String(reflecting:type(of:error)),(error as NSError).domain,(error as NSError).code)
            exit(1)
        }
    }
}

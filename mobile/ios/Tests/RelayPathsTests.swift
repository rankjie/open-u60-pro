import Foundation

@MainActor private final class FakeTunnel: DoorTunnel {
    static var started: [String] = []
    static var stopped: [String] = []
    let address: String; let port: UInt16; let fails: Bool
    init(_ address: String, port: UInt16, fails: Bool = false) { self.address = address; self.port = port; self.fails = fails }
    func start() async throws -> UInt16 {
        if fails { throw URLError(.cannotConnectToHost) }
        Self.started.append(address); return port
    }
    func stop() { Self.stopped.append(address) }
}

@main struct RelayPathsTests {
    @MainActor static func main() async {
        let pin = String(repeating: "A", count: 43)
        let server = URL(string: "https://relay.example/openu60")!
        let hangzhou = CallingDoor(address: "quic://114.55.246.231:47853#\(pin)", label: "Hangzhou")
        let netherlands = CallingDoor(address: "quic://[2001:db8::1]:47853#\(pin)", label: "Netherlands")
        let broken = CallingDoor(address: "quic://203.0.113.9:47853#\(pin)", label: "Broken")

        // Door parsing follows the server's rule; malformed advertisements are dropped.
        precondition(hangzhou.endpoint! == ("114.55.246.231", 47853, pin))
        precondition(netherlands.endpoint!.host == "2001:db8::1")
        precondition(CallingDoor(address: "quic://door.example:9/#\(pin)", label: "x").endpoint?.host == "door.example")
        for bad in ["https://x:1#\(pin)", "quic://x#\(pin)", "quic://x:1", "quic://x:0#\(pin)", "quic://u@x:1#\(pin)", "quic://x:1#short"] {
            precondition(CallingDoor(address: bad, label: "x").endpoint == nil, bad)
        }
        let advertised = CallingDoor.list([["address": hangzhou.address, "label": "Hangzhou"], ["address": "quic://bad", "label": "x"],
                                           ["address": netherlands.address, "label": ""], "junk"])
        precondition(advertised == [hangzhou])

        // Latency per base URL; the broken door's tunnel never starts.
        var latency: [String: TimeInterval?] = ["https://relay.example/openu60": 0.180, "http://127.0.0.1:5001": 0.040, "http://127.0.0.1:5002": 0.090]
        let paths = RelayPaths(makeTunnel: { door in
            switch door.address {
            case hangzhou.address: return FakeTunnel(door.address, port: 5001)
            case netherlands.address: return FakeTunnel(door.address, port: 5002)
            default: return FakeTunnel(door.address, port: 5003, fails: true)
            }
        }, probe: { base, token in
            precondition(token == "phone-token")
            // A probe takes as long as the path's latency, like a real one; failures time out.
            let value = latency[base.absoluteString] ?? nil
            try? await Task.sleep(for: .milliseconds(Int((value ?? 0.3) * 1000)))
            return value
        })

        // Automatic: the fastest answering path.
        var base = await paths.select(server: server, token: "phone-token", doors: [hangzhou, netherlands, broken], preference: nil)
        precondition(paths.current == hangzhou.address && base.absoluteString == "http://127.0.0.1:5001")
        precondition(paths.options.map(\.id) == [RelayPaths.direct, hangzhou.address, netherlands.address, broken.address])
        precondition(paths.options.last?.reachable == false)
        // Late probes still fill in the list after the choice.
        try? await Task.sleep(for: .milliseconds(400))
        precondition(paths.options.first { $0.id == netherlands.address }?.latency == 0.090)
        // Tunnels are reused across selections.
        _ = await paths.select(server: server, token: "phone-token", doors: [hangzhou, netherlands], preference: nil)
        precondition(FakeTunnel.started.filter { $0 == hangzhou.address }.count == 1)

        // A manual choice wins while it answers, and falls back when it stops answering.
        base = await paths.select(server: server, token: "phone-token", doors: [hangzhou, netherlands], preference: RelayPaths.direct)
        precondition(paths.current == RelayPaths.direct && base == server)
        latency["https://relay.example/openu60"] = .some(nil)
        base = await paths.select(server: server, token: "phone-token", doors: [hangzhou, netherlands], preference: RelayPaths.direct)
        precondition(paths.current == hangzhou.address)

        // A door the server stops advertising is closed.
        _ = await paths.select(server: server, token: "phone-token", doors: [netherlands], preference: nil)
        precondition(FakeTunnel.stopped.contains(hangzhou.address) && paths.current == netherlands.address)

        // Nothing answers: the direct address remains the target, so failures stay visible.
        latency = [:]
        base = await paths.select(server: server, token: "phone-token", doors: [netherlands], preference: nil)
        precondition(paths.current == RelayPaths.direct && base == server)
        paths.stop()
        precondition(paths.options.isEmpty && FakeTunnel.stopped.contains(netherlands.address))
        print("Relay paths: door parsing, fastest choice, manual preference, fallback and tunnel reuse passed")
    }
}

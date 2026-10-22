import CryptoKit
import Foundation

// Blocking loopback clients, run off the cooperative pool so 30 of them can wait at once.

private func connectTCP(_ address: String, _ port: UInt16, timeout: Int) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0)
    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    precondition(inet_pton(AF_INET, address, &addr.sin_addr) == 1)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if connected != 0 { close(fd); return nil }
    return fd
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

/// Reads until `done` says the bytes are complete or the peer closes. Nil on reset or timeout.
private func read(_ fd: Int32, until done: (Data) -> Bool = { _ in false }) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while !done(data) {
        let n = Foundation.read(fd, &buffer, buffer.count)
        if n < 0 { return nil }
        if n == 0 { break }
        data.append(buffer, count: n)
    }
    return data
}

private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: body()) } }
}

/// Sends `payload`, half-closes, and reads the reply to EOF. Nil when the connection was refused,
/// reset or timed out; empty when it was closed without data.
private func exchange(_ port: UInt16, _ payload: Data, timeout: Int = 10) async -> Data? {
    await offMain {
        guard let fd = connectTCP("127.0.0.1", port, timeout: timeout) else { return nil }
        defer { close(fd) }
        guard writeAll(fd, payload), shutdown(fd, SHUT_WR) == 0 else { return nil }
        return read(fd)
    }
}

/// Two requests on one connection without half-close: bytes must flow before any FIN.
private func keepAlive(_ port: UInt16) async -> [String]? {
    await offMain {
        guard let fd = connectTCP("127.0.0.1", port, timeout: 10) else { return nil }
        defer { close(fd) }
        var bodies: [String] = []
        for path in ["/first", "/second/\(UUID().uuidString)"] {
            guard writeAll(fd, Data("GET \(path) HTTP/1.1\r\nHost: relay\r\n\r\n".utf8)) else { return nil }
            let complete: (Data) -> Bool = { data in
                guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.hasPrefix("Content-Length: ") }
                    .map { Int($0.dropFirst(16))! } ?? 0
                return data.count - end.upperBound >= length
            }
            guard let response = read(fd, until: complete), complete(response) else { return nil }
            let text = String(decoding: response, as: UTF8.self)
            precondition(text.hasPrefix("HTTP/1.1 200 OK\r\n"), "Unexpected response: \(text)")
            bodies.append(String(text[text.range(of: "\r\n\r\n")!.upperBound...]))
            precondition(bodies.last == "path:\(path)")
        }
        return bodies
    }
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// The first IPv4 address of a non-loopback interface, if the machine has one.
private func lanAddress() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var cursor = list
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
              entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        return String(cString: host)
    }
    return nil
}

@main struct RelayTunnelTests {
    /// Arguments: <gateway-host> <gateway-udp-port> <pin> <gateway-pid> <gateway-binary> <identity-dir> <upstream-tcp-port> <upstream-log>
    @MainActor static func main() async throws {
        setlinebuf(stdout)
        let arguments = CommandLine.arguments
        precondition(arguments.count == 9, "usage: RelayTunnelTests <host> <port> <pin> <gateway-pid> <gateway> <identity> <upstream-port> <upstream-log>")
        let host = arguments[1], gatewayPort = UInt16(arguments[2])!, pinText = arguments[3]
        let gatewayPID = pid_t(arguments[4])!, gatewayBinary = arguments[5], identity = arguments[6]
        let upstreamPort = UInt16(arguments[7])!
        let upstreamLog = arguments[8]
        let upstreamConnections = { ((try? String(contentsOfFile: upstreamLog, encoding: .utf8)) ?? "").components(separatedBy: "accepted").count - 1 }

        // Pins: the gateway's own text round-trips; anything non-canonical is refused.
        let pin = RelayTunnel.pin(fromBase64URL: pinText)!
        precondition(pin.count == 32 && base64URL(pin) == pinText)
        let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        precondition(RelayTunnel.pin(fromBase64URL: base64URL(random)) == random)
        precondition(RelayTunnel.pin(fromBase64URL: base64URL(Data(SHA256.hash(data: Data("certificate".utf8))))) != nil)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var trailing = Array(pinText)
        trailing[42] = alphabet[alphabet.firstIndex(of: trailing[42])! + 1]  // sets a padding bit
        for bad in ["not a pin", String(pinText.dropLast()), pinText + "A", pinText + "=", String(trailing),
                    base64URL(Data(repeating: 0xfb, count: 32)).replacingOccurrences(of: "-", with: "+"),
                    base64URL(Data(repeating: 0xff, count: 33)), ""] {
            precondition(RelayTunnel.pin(fromBase64URL: bad) == nil, "Accepted pin \(bad)")
        }

        let tunnel = RelayTunnel(host: host, port: gatewayPort, pin: pin)
        let port = try await tunnel.start()
        precondition(port > 0)
        if let lan = lanAddress() {
            let reached = await offMain { connectTCP(lan, port, timeout: 2).map { close($0); return true } ?? false }
            precondition(!reached, "The tunnel port must only listen on loopback (reached via \(lan))")
            print("loopback only: refused on \(lan)")
        }

        // (e) The first probe performs the handshake; RTT is the transport's own estimate.
        let rtt = try await tunnel.probe()
        precondition(rtt > 0 && rtt < 0.5, "Unexpected RTT \(rtt)")
        let again = try await tunnel.probe()
        precondition(again > 0 && again < 0.5)
        print("probe: rtt \(rtt * 1000) ms, then \(again * 1000) ms")
        // Network.framework's internal stream 0 and the probe's spare stream carry no request,
        // so the gateway must not open service connections for them.
        try await Task.sleep(for: .milliseconds(300))
        precondition(upstreamConnections() == 0, "Unused streams opened \(upstreamConnections()) upstream connections")
        print("unused streams: no upstream connections")

        // (a) A large body crosses many QUIC packets and arrives intact after the client's half-close.
        let large = Data((0..<300_000).map { UInt8(($0 * 7 + 3) % 251) })
        let reply = await exchange(port, large)!
        precondition(reply.count == large.count + 5 && reply.prefix(5) == Data("echo:".utf8) && reply.dropFirst(5) == large)
        let empty = await exchange(port, Data())
        precondition(empty == Data("echo:".utf8), "An empty request must still be half-closed through")
        print("300 KB round trip after half-close: ok")

        // Keep-alive traffic flows both ways before either side closes.
        let bodies = await keepAlive(port)
        precondition(bodies?.count == 2)
        print("HTTP/1.1 keep-alive: ok")

        // (b) Concurrent connections share one QUIC connection without mixing bytes.
        let replies = await withTaskGroup(of: (Data, Data?).self) { group in
            for i in 0..<30 {
                let body = Data("request-\(i)-".utf8) + Data((0..<Int.random(in: 1...40_000)).map { _ in UInt8.random(in: 0...255) })
                group.addTask { (body, await exchange(port, body)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        precondition(replies.count == 30)
        for (body, reply) in replies { precondition(reply == Data("echo:".utf8) + body, "A concurrent reply was mixed up or lost") }
        print("30 concurrent connections: ok")

        // (c) A gateway with another certificate is refused before any byte reaches the client.
        var wrong = pin
        wrong[0] ^= 1
        let impostor = RelayTunnel(host: host, port: gatewayPort, pin: wrong)
        let impostorPort = try await impostor.start()
        let refusedAt = ContinuousClock.now
        let leaked = await exchange(impostorPort, Data("secret".utf8))
        precondition(leaked == nil || leaked!.isEmpty, "Upstream data reached a client with the wrong pin")
        precondition(refusedAt.duration(to: .now) < .seconds(5), "A pin mismatch must fail the handshake, not time out")
        do {
            _ = try await impostor.probe()
            preconditionFailure("A wrong pin was accepted")
        } catch RelayTunnelError.pinMismatch {}
        impostor.stop()
        print("wrong pin: refused (\(leaked == nil ? "reset" : "closed"))")

        // A silent address times out instead of waiting forever. Runs alongside the restart check.
        let silentPort = await offMain { () -> UInt16 in
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            return UInt16(bigEndian: addr.sin_port)  // left bound and unread for the life of the test
        }
        let silent = RelayTunnel(host: "127.0.0.1", port: silentPort, pin: pin)
        let silentCheck = Task { @MainActor () throws -> Duration in
            let started = ContinuousClock.now
            do {
                _ = try await silent.probe()
                preconditionFailure("A silent gateway completed a handshake")
            } catch RelayTunnelError.handshakeTimeout {}
            return started.duration(to: .now)
        }

        // (d) The gateway restarts on the same port and identity; the next connection reconnects.
        precondition(kill(gatewayPID, SIGKILL) == 0)
        while kill(gatewayPID, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let restarted = Process()
        restarted.executableURL = URL(fileURLWithPath: gatewayBinary)
        restarted.arguments = [identity, "\(host):\(gatewayPort)", "127.0.0.1:\(upstreamPort)"]
        let output = Pipe()
        restarted.standardOutput = output
        try restarted.run()
        defer { restarted.terminate() }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        precondition(line.hasSuffix(" pin \(pinText)\n"), "The restarted gateway must keep its pin: \(line)")
        // The old QUIC connection only ends at its idle timeout: a killed gateway sends no close,
        // and the new process cannot produce a stateless reset the client would accept.
        let restartedAt = ContinuousClock.now
        var attempts = 0
        var recovered: Data?
        while recovered == nil, restartedAt.duration(to: .now) < .seconds(100) {
            attempts += 1
            let body = Data("after-restart-\(attempts)".utf8)
            let reply = await exchange(port, body, timeout: 80)
            if reply == Data("echo:".utf8) + body { recovered = reply } else {
                precondition(reply == nil || reply!.isEmpty, "Partial reply across a restart")
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        precondition(recovered != nil, "No reconnect after the gateway restarted")
        let recovery = restartedAt.duration(to: .now)
        let rttAfterRestart = try await tunnel.probe()
        precondition(rttAfterRestart > 0)
        print("restart: reconnected after \(attempts) attempt(s), \(recovery)")

        let timedOut = try await silentCheck.value
        precondition(timedOut >= .seconds(9) && timedOut < .seconds(15))
        silent.stop()
        print("silent gateway: handshake timeout after \(timedOut)")

        tunnel.stop()
        try await Task.sleep(for: .milliseconds(100))
        let afterStop = await exchange(port, Data("closed".utf8), timeout: 2)
        precondition(afterStop == nil, "The port must close on stop()")
        print("RelayTunnel tests passed")
    }
}

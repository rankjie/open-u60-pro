import Foundation

struct ConnectedDevice: Identifiable { let id = UUID(); let name: String; let ipAddress: String; let macAddress: String }
enum DeviceParser {
    static func parseHostHints(_ hints: [String: Any]) -> [ConnectedDevice] { [] }
    static func enrichWithDHCP(devices: inout [ConnectedDevice], leases: [[String: Any]]) {}
}
@MainActor final class AgentClient {
    var writes: [[String: Any]] = []
    var posts: [String] = []
    var holdScan = false
    var scanGate: CheckedContinuation<Void, Never>?
    var failure: Error?
    var data: [String: Any] = ["config": ["mode": "hotspot", "band": "5g", "ssid": "Home", "security": "mixed", "has_password": true, "mac_mode": "factory", "clone_mac": ""],
                               "phase": "hotspot", "busy": false, "connectivity": "unknown", "networks": []]
    func getJSON(_ path: String) async throws -> [String: Any] { data }
    func putJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        if let failure { throw failure }
        writes.append(body); return ["operation_id": "synthetic-operation"]
    }
    func postJSON(_ path: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        posts.append(path)
        if holdScan { await withCheckedContinuation { scanGate = $0 } }
        if let failure { throw failure }
        return [:]
    }
}

@main struct WiFiInternetTests {
    @MainActor static func main() async throws {
        func network(_ ssid: String, _ bssid: String, _ signal: Int, _ frequency: Int = 5200,
                     _ security: String = "wpa2", _ supported: Bool = true) -> WiFiUpstreamNetwork {
            WiFiUpstreamNetwork(ssid: ssid, bssid: bssid, frequency: frequency, signal: signal, security: security, supported: supported)
        }
        let raw = [network("Home", "02:00:00:00:00:01", -70), network("Home", "02:00:00:00:00:02", -40),
                   network("Home", "02:00:00:00:00:03", -20, 2412), network("Cafe", "02:00:00:00:00:04", -50, 5200, "open"),
                   network("Home", "02:00:00:00:00:05", -10, 5200, "open")]
        let grouped = WiFiUpstreamNetwork.grouped(raw, band: .five)
        precondition(grouped.count == 2 && grouped.first?.ssid == "Home")
        precondition(grouped.first?.bssid == "02:00:00:00:00:02", "Merge same-name APs, respecting the chosen band and protected network")
        precondition(WiFiUpstreamNetwork.grouped(raw, band: .two).first?.bssid == "02:00:00:00:00:03")
        let client = AgentClient()
        let model = WiFiInternetViewModel(client: client)
        await model.scanUpstreamIfVisible(choosingUpstream: false)
        precondition(client.posts.isEmpty, "An unresolved internet source must not start a Wi-Fi scan")
        model.status = try JSONDecoder().decode(WiFiInternetStatus.self, from: JSONSerialization.data(withJSONObject: client.data))
        await model.scanUpstreamIfVisible(choosingUpstream: false)
        precondition(client.posts.isEmpty && model.upstreamScanBand(choosingUpstream: false) == nil,
                     "Opening SIM hotspot shows cellular settings without scanning upstream Wi-Fi")
        await model.scanUpstreamIfVisible(choosingUpstream: true)
        precondition(client.posts == ["/api/wifi/uplink/scan"], "Explicitly choosing Wi-Fi repeater scans while SIM is still selected")
        func status(_ phase: String, _ connectivity: String, ip: String? = nil, busy: Bool = false) throws -> WiFiInternetStatus {
            var data = client.data
            var config = data["config"] as! [String: Any]
            config["mode"] = "repeater"
            data["config"] = config; data["phase"] = phase
            data["connectivity"] = connectivity; data["busy"] = busy
            if let ip { data["ipv4"] = ip }
            return try JSONDecoder().decode(WiFiInternetStatus.self, from: JSONSerialization.data(withJSONObject: data))
        }
        let failed = try status("failed", "unknown")
        precondition(failed.label == "Connection failed" && failed.upstreamLabel == "Home · 5 GHz")
        precondition(failed.sourceLabel == "Wi-Fi repeater", "A failed connection still identifies the selected uplink")
        let connecting = try status("connecting", "unknown", busy: true)
        let online = try status("connected", "online", ip: "192.0.2.10")
        let missingAddress = try status("connected", "online")
        let captive = try status("connected", "captive", ip: "192.0.2.10")
        client.posts.removeAll(); model.status = online
        await model.scanUpstreamIfVisible(choosingUpstream: false)
        precondition(client.posts == ["/api/wifi/uplink/scan"], "The current Wi-Fi repeater still opens its upstream scan")
        precondition(connecting.label == "Connecting…")
        precondition(online.label == "Online")
        precondition(missingAddress.label == "Not connected", "An old online probe cannot claim a missing upstream address is connected")
        precondition(captive.label == "Sign-in required")
        model.status = failed; model.ssid = "Unsubmitted network"
        let reconnected = await model.reconnect()
        precondition(reconnected && client.writes.last?["ssid"] as? String == "Home")
        precondition(client.writes.last?["password"] == nil)
        client.writes.removeAll()
        model.status = try JSONDecoder().decode(WiFiInternetStatus.self, from: JSONSerialization.data(withJSONObject: client.data))
        model.select(network("Home", "02:00:00:00:00:01", -40, 5200, "mixed"))
        precondition(model.hasSavedPassword)
        let savedConnection = await model.connect(); precondition(savedConnection)
        precondition(client.writes.count == 1 && client.writes[0]["mode"] as? String == "repeater")
        precondition(client.writes[0]["password"] == nil, "A confirmed saved network reuses the router-owned password")
        precondition(model.busy && model.status?.phase == "pending", "Admission immediately disables conflicting actions")

        model.status = try JSONDecoder().decode(WiFiInternetStatus.self, from: JSONSerialization.data(withJSONObject: client.data))
        model.otherNetwork()
        precondition(model.security == .auto && model.ssid.isEmpty)
        model.ssid = "Hidden"; model.password = "synthetic-password"
        let hiddenConnection = await model.connect(); precondition(hiddenConnection)
        precondition(client.writes.last?["security"] as? String == "auto")
        precondition(client.writes.last?["password"] as? String == "synthetic-password")
        precondition(model.password.isEmpty)

        model.status = try JSONDecoder().decode(WiFiInternetStatus.self, from: JSONSerialization.data(withJSONObject: client.data))
        client.failure = AgentError.serverError("synthetic-failure")
        let failedConnection = await model.connect(); precondition(!failedConnection && model.error?.contains("synthetic-failure") == true)
        client.failure = nil; client.holdScan = true
        let scan = Task { await model.scan() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while client.scanGate == nil && ContinuousClock.now < deadline { await Task.yield() }
        precondition(model.scanning && model.scanInProgress, "Scan loading begins before the router responds")
        client.scanGate?.resume(); await scan.value
        precondition(!model.scanning && !model.scanInProgress)
        print("Wi-Fi selection, grouping, credential reuse, admission and scan loading passed")
    }
}

import Foundation
import Observation

enum WiFiInternetMode: String, Codable { case hotspot, repeater }
enum WiFiInternetBand: String, Codable, CaseIterable, Identifiable {
    case two = "2g", five = "5g"
    var id: Self { self }
    var label: String { self == .two ? "2.4 GHz" : "5 GHz" }
    var hotspotLabel: String { self == .two ? "5 GHz" : "2.4 GHz" }
}
enum WiFiInternetSecurity: String, Codable, CaseIterable, Identifiable {
    case auto, open, wpa2, wpa3, mixed
    var id: Self { self }
    var label: String {
        switch self { case .auto: "Auto"; case .open: "Open"; case .wpa2: "WPA2 Personal"; case .wpa3: "WPA3 Personal"; case .mixed: "WPA2 / WPA3" }
    }
}
struct WiFiUpstreamNetwork: Decodable, Identifiable {
    let ssid: String, bssid: String, frequency: Int, signal: Int, security: String
    let supported: Bool
    var id: String { ssid }

    static func grouped(_ networks: [Self], band: WiFiInternetBand) -> [Self] {
        let candidates = networks.filter { band == .two ? $0.frequency < 2500 : $0.frequency >= 4900 }
        return Dictionary(grouping: candidates, by: \.ssid).values.compactMap { accessPoints in
            // A protected network must not be silently downgraded to an open namesake.
            let protected = accessPoints.filter { $0.supported && $0.security != "open" }
            let supported = accessPoints.filter(\.supported)
            return (protected.isEmpty ? (supported.isEmpty ? accessPoints : supported) : protected)
                .sorted { $0.signal == $1.signal ? $0.bssid < $1.bssid : $0.signal > $1.signal }.first
        }.sorted { $0.signal == $1.signal ? $0.ssid < $1.ssid : $0.signal > $1.signal }
    }
}
struct WiFiInternetConfig: Codable {
    let mode: WiFiInternetMode, band: WiFiInternetBand, ssid: String, security: WiFiInternetSecurity
    let hasPassword: Bool, macMode: String, cloneMac: String, ttl: Int?
    enum CodingKeys: String, CodingKey {
        case mode, band, ssid, security, ttl
        case hasPassword = "has_password", macMode = "mac_mode", cloneMac = "clone_mac"
    }
}
struct WiFiInternetStatus: Decodable {
    let config: WiFiInternetConfig, phase: String, busy: Bool, connectivity: String
    let error: String?, scanError: String?, ipv4: String?, portalURL: String?
    let networks: [WiFiUpstreamNetwork]
    enum CodingKeys: String, CodingKey {
        case config, phase, busy, connectivity, error, ipv4, networks
        case scanError = "scan_error", portalURL = "portal_url"
    }
    var label: String {
        if busy && (phase == "pending" || phase == "connecting") { return "Connecting…" }
        if phase == "hotspot" { return "SIM hotspot" }
        if phase == "failed" { return "Connection failed" }
        guard ipv4 != nil else { return "Not connected" }
        switch connectivity {
        case "online": return "Online"
        case "captive": return "Sign-in required"
        case "limited": return "Connected without internet"
        case "disconnected": return "Reconnecting…"
        default: return "Checking internet…"
        }
    }
    var sourceLabel: String { config.mode == .repeater ? "Wi-Fi repeater" : "SIM hotspot" }
    var upstreamLabel: String { "\(config.ssid) · \(config.band.label)" }
}

@MainActor @Observable
final class WiFiInternetViewModel {
    var status: WiFiInternetStatus?
    var error: String?
    var refreshError: String?
    var band = WiFiInternetBand.two
    var ssid = ""
    var security = WiFiInternetSecurity.auto
    var password = ""
    var macMode = "factory"
    var cloneMAC = ""
    var fixedTTL = false
    var ttl = "64"
    var submitting = false
    var scanning = false
    var devices: [ConnectedDevice] = []
    private var initialized = false
    private let client: AgentClient

    init(client: AgentClient) { self.client = client }

    var busy: Bool { submitting || status?.busy == true }
    var hasSavedPassword: Bool {
        guard let config = status?.config else { return false }
        return config.hasPassword && config.ssid == ssid && (config.security == security || security == .auto)
    }
    var networks: [WiFiUpstreamNetwork] {
        WiFiUpstreamNetwork.grouped(status?.networks ?? [], band: band)
    }
    var scanInProgress: Bool { scanning || (status?.busy == true && status?.phase != "pending" && status?.phase != "connecting") }
    func upstreamScanBand(choosingUpstream: Bool) -> WiFiInternetBand? {
        guard let status, choosingUpstream || status.config.mode == .repeater else { return nil }
        return band
    }
    func scanUpstreamIfVisible(choosingUpstream: Bool) async {
        guard upstreamScanBand(choosingUpstream: choosingUpstream) != nil else { return }
        await scan()
    }
    var portalURL: URL? {
        guard let value = status?.portalURL, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    func monitor() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await refresh()
                failures = 0
            } catch {
                if Task.isCancelled { return }
                if !error.isCancellation { self.refreshError = "Couldn’t refresh Wi-Fi status: \(error.localizedDescription)" }
                failures = min(failures + 1, 4)
            }
            let interval = failures == 0 ? (busy || scanning ? 2 : 10) : min(30, 2 * (1 << failures))
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
        }
    }

    private func refresh() async throws {
        let data = try await client.getJSON("/api/wifi/uplink")
        let decoded = try JSONDecoder().decode(WiFiInternetStatus.self, from: JSONSerialization.data(withJSONObject: data))
        status = decoded
        if !initialized { load(decoded.config); initialized = true }
        refreshError = nil
    }
    private func load(_ config: WiFiInternetConfig) {
        band = config.band; ssid = config.ssid; security = config.security
        resetAdvanced()
    }
    func resetAdvanced() {
        guard let config = status?.config else { return }
        macMode = config.macMode; cloneMAC = config.cloneMac
        fixedTTL = config.ttl != nil
        ttl = config.ttl.map(String.init) ?? "64"
    }
    func select(_ network: WiFiUpstreamNetwork) {
        guard network.supported, let security = WiFiInternetSecurity(rawValue: network.security) else { return }
        password = ""; error = nil
        ssid = network.ssid; self.security = security
    }
    func otherNetwork() {
        ssid = ""; password = ""; security = .auto; error = nil
    }
    func connect() async -> Bool { await apply(.repeater) }
    func reconnect() async -> Bool {
        resetAdvanced()
        return await saveAdvanced()
    }
    func useHotspot() async { _ = await apply(.hotspot) }
    func saveAdvanced() async -> Bool {
        guard let config = status?.config, config.mode == .repeater else {
            error = "Connect to a Wi-Fi network before changing its advanced settings."; return false
        }
        ssid = config.ssid; security = config.security; band = config.band; password = ""
        return await connect()
    }
    private func apply(_ mode: WiFiInternetMode) async -> Bool {
        guard !busy else { return false }
        var body: [String: Any] = ["mode": mode.rawValue]
        if mode == .repeater {
            guard !ssid.isEmpty, ssid.utf8.count <= 32 else { error = "Enter a network name of up to 32 bytes."; return false }
            if security != .open && security != .auto && password.isEmpty && !hasSavedPassword {
                error = "Enter the Wi-Fi password."; return false
            }
            let saved = password.isEmpty && hasSavedPassword
            let effectiveSecurity = saved ? status!.config.security : security
            body.merge(["band": band.rawValue, "ssid": ssid, "security": effectiveSecurity.rawValue,
                        "mac_mode": macMode, "clone_mac": cloneMAC], uniquingKeysWith: { _, new in new })
            if !saved { body["password"] = password }
            if fixedTTL {
                guard let value = Int(ttl), (1...255).contains(value) else { error = "TTL must be between 1 and 255."; return false }
                body["ttl"] = value
            }
        }
        submitting = true; error = nil
        defer { submitting = false }
        do {
            _ = try await client.putJSON("/api/wifi/uplink", body: body)
            password = ""
            // Show the admitted operation immediately; a wireless restart may interrupt the next read.
            if let prior = status {
                status = WiFiInternetStatus(config: prior.config, phase: "pending", busy: true,
                    connectivity: "unknown", error: nil, scanError: prior.scanError,
                    ipv4: nil, portalURL: nil, networks: prior.networks)
            }
            return true
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
            return false
        }
    }
    func scan() async {
        guard !busy, !scanning else { return }
        scanning = true; error = nil
        defer { scanning = false }
        do {
            _ = try await client.postJSON("/api/wifi/uplink/scan", body: ["band": band.rawValue])
            // Keep loading visible until the asynchronous router scan finishes.
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            repeat {
                try await refresh()
                if status?.busy == false { return }
                try await Task.sleep(for: .milliseconds(500))
            } while ContinuousClock.now < deadline
            error = "The Wi-Fi scan is taking longer than expected. Its status will keep updating."
        } catch { if !error.isCancellation { self.error = error.localizedDescription } }
    }
    func checkInternet() async {
        guard !busy else { return }
        submitting = true; error = nil; defer { submitting = false }
        do { _ = try await client.postJSON("/api/wifi/uplink/portal") }
        catch { if !error.isCancellation { self.error = error.localizedDescription } }
    }
    func loadDevices() async {
        do {
            let data = try await client.getJSON("/api/network/clients")
            guard let hosts = data["hosts"] as? [String: Any] else { throw AgentError.decodingError("Missing connected devices") }
            var devices = DeviceParser.parseHostHints(hosts)
            if let leases = data["dhcp_leases"] as? [[String: Any]] { DeviceParser.enrichWithDHCP(devices: &devices, leases: leases) }
            self.devices = devices
        } catch { if !error.isCancellation { self.error = "Couldn’t load connected devices: \(error.localizedDescription)" } }
    }
}

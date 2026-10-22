import Foundation
import Security

struct CallingCredentials: Codable {
    let serverURL: URL
    let phoneToken: String
    let requestId: UUID
    var endpointId: UUID?
    var routerId: UUID?
}

struct CallingServerProfile: Codable {
    let address: URL
    var active: CallingCredentials?
    var pending: CallingCredentials?
}

struct CallingServerChoice: Identifiable {
    let address: URL
    let isPaired: Bool
    let hasPendingPairing: Bool
    var id: String { address.absoluteString }
}

struct SavedCallingCredentials: Codable {
    static let defaultServer = URL(string: "https://nl1.gmdns.net/openu60")!
    private(set) var profiles: [CallingServerProfile]
    private(set) var selectedServer: URL
    private var selectedIndex: Int { profiles.firstIndex { $0.address == selectedServer }! }
    var active: CallingCredentials? {
        get { profiles[selectedIndex].active }
        set { profiles[selectedIndex].active = newValue }
    }
    var pending: CallingCredentials? {
        get { profiles[selectedIndex].pending }
        set { profiles[selectedIndex].pending = newValue }
    }
    var choices: [CallingServerChoice] {
        profiles.map { CallingServerChoice(address: $0.address, isPaired: $0.active?.endpointId != nil,
                                           hasPendingPairing: $0.pending != nil) }
    }

    init(active: CallingCredentials? = nil, pending: CallingCredentials? = nil) {
        selectedServer = active?.serverURL ?? pending?.serverURL ?? Self.defaultServer
        profiles = [CallingServerProfile(address: selectedServer, active: active)]
        if let pending {
            if let index = profiles.firstIndex(where: { $0.address == pending.serverURL }) { profiles[index].pending = pending }
            else { profiles.append(CallingServerProfile(address: pending.serverURL, pending: pending)) }
        }
    }

    mutating func addServer(_ address: URL) throws {
        guard !profiles.contains(where: { $0.address == address }) else { throw CallingError.server("server_already_saved") }
        profiles.append(CallingServerProfile(address: address))
    }
    mutating func selectServer(_ address: URL) throws {
        guard profiles.contains(where: { $0.address == address }) else { throw CallingError.server("server_not_saved") }
        selectedServer = address
    }
    mutating func removeServer(_ address: URL) throws {
        guard address != selectedServer else { throw CallingError.server("select_another_server_first") }
        guard let index = profiles.firstIndex(where: { $0.address == address }) else { throw CallingError.server("server_not_saved") }
        guard profiles[index].active == nil, profiles[index].pending == nil else { throw CallingError.server("forget_server_pairing_first") }
        profiles.remove(at: index)
    }

    private enum CodingKeys: String, CodingKey { case version, profiles, selectedServer, active, pending }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.version) || values.contains(.profiles) {
            guard try values.decode(Int.self, forKey: .version) == 2 else { throw CallingError.server("invalid_saved_servers") }
            profiles = try values.decode([CallingServerProfile].self, forKey: .profiles)
            selectedServer = try values.decode(URL.self, forKey: .selectedServer)
        } else {
            let legacy = Self(active: try values.decodeIfPresent(CallingCredentials.self, forKey: .active),
                              pending: try values.decodeIfPresent(CallingCredentials.self, forKey: .pending))
            profiles = legacy.profiles
            selectedServer = legacy.selectedServer
        }
        guard !profiles.isEmpty, Set(profiles.map(\.address)).count == profiles.count,
              profiles.contains(where: { $0.address == selectedServer }) else { throw CallingError.server("invalid_saved_servers") }
        for profile in profiles {
            _ = try CallingCredentialStore.serverURL(profile.address.absoluteString)
            guard [profile.active, profile.pending].compactMap({ $0 }).allSatisfy({ $0.serverURL == profile.address }) else {
                throw CallingError.server("invalid_saved_servers")
            }
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .version)
        try values.encode(profiles, forKey: .profiles)
        try values.encode(selectedServer, forKey: .selectedServer)
    }
}

enum CallingError: LocalizedError {
    case invalidServer, invalidResponse, server(String), disconnected, operationTimeout, microphoneDenied
    case credentialStore(OSStatus), media(String)
    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter an HTTPS server address without a username, password, or query."
        case .invalidResponse: return "The calling server returned an invalid response."
        case .server("unauthorized"), .server("pairing_revoked"):
            return "This iPhone's pairing is no longer valid. Pair it with your U60 again."
        case .server("answered_elsewhere"):
            return "The call was answered on another device."
        case .server("call_in_progress"):
            return "Finish the current call before changing servers or pairing."
        case .server("incorrect_router_password"):
            return "The router password is incorrect."
        case .server("router_not_found"):
            return "Check the device string and selected server."
        case .server("connection_rate_limited"):
            return "Too many connection attempts. Wait a minute and try again."
        case .server("connection_login_expired"), .server("connection_timed_out"):
            return "The connection attempt timed out. Try again."
        case .server("already_connected_to_another_router"):
            return "This server profile is already connected to another U60."
        case .server("pending_connection_other_router"):
            return "Finish or forget the pending connection to the other U60 before connecting this device."
        case .server("server_operation_in_progress"):
            return "Wait for the current server operation to finish."
        case .server("router_uses_different_server"):
            return "This U60 is enrolled on another server. Select that server or enroll the router on the selected server."
        case .server("select_server_first"):
            return "Select this server before pairing."
        case .server("server_already_saved"):
            return "This server address is already saved."
        case .server("select_another_server_first"):
            return "Select another server before removing this address."
        case .server("forget_server_pairing_first"):
            return "Select this server and forget its pairing before removing the address."
        case .server("invalid_saved_servers"):
            return "The saved server settings are invalid."
        case .server(let code): return "Calling service: \(code.replacingOccurrences(of: "_", with: " "))."
        case .disconnected: return "The calling service is disconnected."
        case .operationTimeout: return "The router did not confirm the operation in time. The call state is being checked."
        case .microphoneDenied: return "Allow microphone access in Settings to make calls."
        case .credentialStore(let status): return "Calling credentials are unavailable (\(status)). Unlock the iPhone and try again."
        case .media(let code): return "Call audio: \(code.replacingOccurrences(of: "_", with: " "))."
        }
    }
}

enum CallingCredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.beexio.openu60.remote-calling",
         kSecAttrAccount as String: "paired-phone"]
    }
    static func load() throws -> SavedCallingCredentials {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return SavedCallingCredentials() }
        guard status == errSecSuccess else { throw CallingError.credentialStore(status) }
        guard let data = item as? Data else { throw CallingError.invalidResponse }
        return try JSONDecoder().decode(SavedCallingCredentials.self, from: data)
    }
    static func save(_ credentials: SavedCallingCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let changes = [kSecValueData as String: data,
                       kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as [String: Any]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CallingError.credentialStore(status) }
    }
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw CallingError.credentialStore(status) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func serverURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw CallingError.invalidServer }
        if let port = url.port, !(1...65535).contains(port) { throw CallingError.invalidServer }
        return url
    }
}

@MainActor
final class CallingHTTPClient {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.urlCache = nil
        session = URLSession(configuration: config)
    }
    func request(_ path: String, server: URL, token: String? = nil, method: String = "GET",
                 body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: server.appending(path: path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65536 else { throw CallingError.invalidResponse }
            data.append(byte)
        }
        guard let response = response as? HTTPURLResponse,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CallingError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let code = value["error"] as? String
            guard let code, code.range(of: "^[a-z0-9_]{1,80}$", options: .regularExpression) != nil else { throw CallingError.invalidResponse }
            throw CallingError.server(code)
        }
        return value
    }
}

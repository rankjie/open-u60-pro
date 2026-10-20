import Foundation
import Security

struct CallingCredentials: Codable {
    let serverURL: URL
    let phoneToken: String
    let requestId: UUID
    var endpointId: UUID?
    var routerId: UUID?
}

struct SavedCallingCredentials: Codable {
    var active: CallingCredentials?
    var pending: CallingCredentials?
}

enum CallingError: LocalizedError {
    case invalidServer, invalidResponse, server(String), disconnected, operationTimeout, microphoneDenied
    case credentialStore(OSStatus), media(String)
    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter an HTTPS server address without a username, password, or query."
        case .invalidResponse: return "The calling server returned an invalid response."
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
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw CallingError.invalidServer }
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

import CryptoKit
import Foundation

struct DeviceConnectionQRCode {
    static let invalidMessage = "Scan the Connect app QR code displayed on your U60."
    let code: String
    let server: URL

    init(_ value: String) throws {
        struct Payload: Decodable {
            let type: String
            let version: Int
            let device: String
            let server: String
        }
        guard value.utf8.count <= 4096,
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(value.utf8)),
              payload.type == "openu60-connect", payload.version == 1,
              let device = try? DeviceConnectionCode(payload.device),
              let address = try? CallingCredentialStore.serverURL(payload.server) else {
            throw AgentError.serverError(Self.invalidMessage)
        }
        code = "U60-\(device.routerID.uuidString.lowercased())"
        server = address
    }
}

struct DeviceConnectionCode {
    let routerID: UUID
    init(_ string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.uppercased().hasPrefix("U60-") ? String(trimmed.dropFirst(4)) : trimmed
        guard let id = UUID(uuidString: raw), id.uuid.6 >> 4 == 4 else {
            throw AgentError.serverError("Enter the connection string displayed on your U60.")
        }
        routerID = id
    }
    static func seal(password: String, publicKey: Data, routerID: UUID, requestID: UUID,
                     phoneToken: String, serverTime: TimeInterval) throws -> [String: Any] {
        guard !password.isEmpty, password.utf8.count <= 256 else { throw AgentError.serverError("Enter the router password.") }
        let key = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: .P256_SHA256_AES_GCM_256,
                                     info: Data("OpenU60 device connect v1".utf8))
        let aad = Data("OpenU60 connect v1\n\(routerID.uuidString.lowercased())\n\(requestID.uuidString.lowercased())\n\(phoneToken)".utf8)
        var plaintext = try JSONSerialization.data(withJSONObject: ["password":password, "expiresAt":Int(serverTime) + 60])
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let ciphertext = try sender.seal(plaintext, authenticating: aad)
        return ["routerId":routerID.uuidString.lowercased(), "requestId":requestID.uuidString.lowercased(),
                "phoneToken":phoneToken, "enc":sender.encapsulatedKey.base64EncodedString(), "ciphertext":ciphertext.base64EncodedString()]
    }
}

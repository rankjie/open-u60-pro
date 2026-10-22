import Foundation
import CryptoKit

/// The same message event arrives over APNs or the authenticated signaling socket.
struct SMSDelivery: Codable, Equatable {
    struct Metadata: Codable, Equatable {
        let date: String
        let tag: Int
        let memStore: String
        let groupId: String
        let line: CellularLine?
    }
    let eventID: UUID
    let routerID: UUID
    let messageID: Int
    let sender: String
    let text: String
    let part: Int
    let parts: Int
    let metadata: Metadata?
    let expiresAt: TimeInterval?

    init(_ payload: [String: Any]) throws {
        guard let id = payload["eventId"] as? String, let eventID = UUID(uuidString: id),
              let router = payload["routerId"] as? String, let routerID = UUID(uuidString: router),
              let rawID = payload["messageId"] as? String, let messageID = Int(rawID), messageID >= 0 else { throw SMSDeliveryError.invalid }
        let alert = (payload["aps"] as? [String: Any])?["alert"] as? [String: Any]
        let sender = payload["sender"] as? String ?? alert?["title"] as? String ?? ""
        let text = payload["text"] as? String ?? alert?["body"] as? String ?? ""
        let part = payload["part"] as? Int ?? 1, parts = payload["parts"] as? Int ?? 1
        guard (1...64).contains(parts), (1...parts).contains(part), sender.utf8.count <= 512, text.utf8.count <= 65536 else { throw SMSDeliveryError.invalid }
        self.eventID = eventID; self.routerID = routerID; self.messageID = messageID
        self.sender = sender; self.text = text; self.part = part; self.parts = parts
        expiresAt = payload["expiresAt"] as? Double
        if let value = payload["message"] as? [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: value)
            metadata = try JSONDecoder().decode(Metadata.self, from: data)
            guard let metadata, [0, 1].contains(metadata.tag), metadata.date.count <= 64,
                  metadata.memStore.count <= 16, metadata.groupId.count <= 128 else { throw SMSDeliveryError.invalid }
            _ = try CellularLine.decode(value["line"])
        } else { metadata = nil }
    }

    func message(content: String) throws -> SMSMessage {
        guard let metadata, !sender.isEmpty else { throw SMSDeliveryError.invalid }
        return SMSMessage(id: messageID, number: sender, content: content,
            date: try SMSParser.validatedDate(metadata.date), tag: SMSTag(rawValue: metadata.tag)!,
            groupId: metadata.groupId, memStore: metadata.memStore, line: metadata.line)
    }
}

enum SMSDeliveryError: LocalizedError {
    case invalid, conflictingParts
    var errorDescription: String? { "The U60 returned inconsistent SMS event data. The inbox will be reconciled." }
}

extension SMSMessage {
    /// Read state and line annotations can change without changing the underlying stored SMS.
    var storageKey: String {
        let value = "\(id)|\(number.utf8.count):\(number)|\(date.timeIntervalSince1970)|\(memStore)|\(content)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

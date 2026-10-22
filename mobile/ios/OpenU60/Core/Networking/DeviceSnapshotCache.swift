import Foundation

/// A complete list snapshot belongs to a router, regardless of its current network address.
struct DeviceSnapshotCache<Value: Codable> {
    private struct Snapshot: Codable {
        let routerID: UUID
        let value: Value
    }
    let directory: URL

    func load(routerID: UUID) throws -> Value? {
        let url = file(routerID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard snapshot.routerID == routerID else { throw CocoaError(.fileReadCorruptFile) }
        return snapshot.value
    }

    func save(_ value: Value, routerID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try JSONEncoder().encode(Snapshot(routerID: routerID, value: value)).write(to: file(routerID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func file(_ routerID: UUID) -> URL {
        directory.appending(path: routerID.uuidString.lowercased() + ".json")
    }
}

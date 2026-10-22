import Foundation

/// Bounded application messages over the ordered, reliable WebRTC data channel.
struct PeerFrames {
    static let chunk = 12288
    static let limit = 786432
    private struct Partial {
        let total: Int
        var data: Data
        let since: ContinuousClock.Instant
    }
    private var partial: [UUID: Partial] = [:]

    static func encode(_ data: Data, id: UUID) throws -> [Data] {
        guard !data.isEmpty, data.count <= limit else { throw AgentError.decodingError("Peer message exceeds the size limit") }
        var uuid = id.uuid
        let identifier = withUnsafeBytes(of: &uuid) { Data($0) }
        return stride(from: 0, to: data.count, by: chunk).map { offset in
            var frame = Data([1]); frame.append(identifier)
            for value in [data.count, offset] {
                frame.append(contentsOf: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
            }
            frame.append(data.subdata(in: offset..<min(data.count, offset + chunk)))
            return frame
        }
    }
    mutating func receive(_ frame: Data) throws -> (UUID, Data)? {
        partial = partial.filter { $0.value.since.duration(to: .now) < .seconds(10) }
        guard frame.count > 25, frame.count <= 25 + Self.chunk, frame[0] == 1 else { throw invalid() }
        let id = frame.subdata(in: 1..<17).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        func integer(_ offset: Int) -> Int { frame[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) } }
        let total = integer(17), offset = integer(21)
        guard total > 0, total <= Self.limit, offset + frame.count - 25 <= total else { throw invalid() }
        if partial[id] == nil {
            guard offset == 0, partial.count < 8 else { throw invalid() }
            partial[id] = Partial(total: total, data: Data(), since: .now)
        }
        guard var value = partial[id], value.total == total, value.data.count == offset else { throw invalid() }
        value.data.append(frame.subdata(in: 25..<frame.count))
        if value.data.count == total { partial.removeValue(forKey: id); return (id, value.data) }
        partial[id] = value
        return nil
    }
    private func invalid() -> AgentError { .decodingError("Invalid management peer frame") }
}

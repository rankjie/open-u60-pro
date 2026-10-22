import AVFoundation
import Foundation

// The library's transport boundary is exercised with an isolated recording source.
@MainActor final class AgentClient {
    var requestedPaths: [String] = []
    func get<T: Decodable>(_ path: String) async throws -> T {
        requestedPaths.append(path)
        return try JSONDecoder().decode(T.self, from: Data("{\"items\":[],\"nextOffset\":null}".utf8))
    }
    func deleteJSON(_ path: String) async throws -> [String: Any] { throw RecordingError.noDevice }
    func putJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] { throw RecordingError.noDevice }
}
enum RemoteCallState { case active, ended }
struct RemoteCall { let id: UUID; let routerId: UUID; let state: RemoteCallState; let mediaReady: Bool }
@MainActor private final class Identity { var router = UUID() }
@MainActor private final class Source: CallRecordingRemote {
    var audio: Data
    var complete = false
    var invalid = false
    var offline = false
    var deleted = false
    var offsets: [UInt64] = []
    var changed: (() -> Void)?
    var sharedTranscript: CallRecordingTranscript?
    var listed: [CallRecording]?
    var historyRequests = 0
    var failPage: Int?
    let id = UUID()
    init(_ audio: Data) { self.audio = audio }
    var record: CallRecording {
        var record = CallRecording(id: id, number: "+12025550123", direction: "incoming", state: complete ? "ended" : "active",
            startedAt: 1_792_666_200, answeredAt: 1_792_666_200, endedAt: complete ? 1_792_666_300 : nil, reason: nil,
            recordingState: complete ? "complete" : "recording", recordingError: nil, bytes: UInt64(audio.count), durationMs: UInt64(audio.count - 44) / 32)
        record.hasTranscript = sharedTranscript != nil
        if deleted { record.recordingState = "deleted"; record.bytes = 0; record.durationMs = 0 }
        return record
    }
    func history(offset: Int) async throws -> CallRecordingPage {
        historyRequests += 1
        if failPage == offset { throw URLError(.timedOut) }
        if offline { throw URLError(.notConnectedToInternet) }
        let items = listed ?? [record]
        return CallRecordingPage(items: Array(items.dropFirst(offset).prefix(100)), nextOffset: offset + 100 < items.count ? offset + 100 : nil)
    }
    func recordingChunk(id: UUID, offset: UInt64) async throws -> CallRecordingChunk {
        if offline { throw URLError(.notConnectedToInternet) }
        precondition(id == self.id && offset <= audio.count)
        offsets.append(offset); changed?()
        return CallRecordingChunk(id: id, offset: invalid ? offset + 4 : offset, totalBytes: UInt64(audio.count), complete: complete,
            audio: audio.subdata(in: Int(offset)..<min(audio.count, Int(offset) + 65536)))
    }
    func deleteRecording(id: UUID) async throws { precondition(id == self.id); deleted = true; sharedTranscript = nil }
    func recordingTranscript(id: UUID) async throws -> CallRecordingTranscript? { if offline { throw URLError(.notConnectedToInternet) }; return sharedTranscript }
    func saveRecordingTranscript(id: UUID, transcript: CallRecordingTranscript) async throws { if offline { throw URLError(.notConnectedToInternet) }; sharedTranscript = transcript }
}
private func wav() -> Data {
    let samples = 80_000; var data = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    append(UInt32(samples * 4 + 36)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(2))
    append(UInt32(8000)); append(UInt32(32000)); append(UInt16(4)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(samples * 4))
    for _ in 0..<samples { append(Int16(1000)); append(Int16(-2000)) }
    return data
}
@main private struct CallRecordingTests {
    @MainActor static func main() async throws {
        let client = AgentClient()
        _ = try await client.history(offset: 0)
        _ = try await client.history(offset: 100)
        precondition(client.requestedPaths == ["/api/call-history", "/api/call-history/page/100"], "History must include calls without recordings")
        let directory = FileManager.default.temporaryDirectory.appending(path: "recordings-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = Identity(), full = wav(), source = Source(full.prefix(100044))
        let starting = Source(full.prefix(44))
        let startingLibrary = CallRecordingLibrary(remote: starting, identity: { identity.router }, directory: directory.appending(path: "starting"))
        await startingLibrary.refresh()
        _ = try await startingLibrary.download(starting.record)
        precondition(startingLibrary.items[0].local && !startingLibrary.items[0].localComplete,
                     "A live recording may expose only its header before the first audio frame")
        let library = CallRecordingLibrary(remote: source, identity: { identity.router }, directory: directory)
        await library.refresh(); precondition(library.items.count == 1 && library.items[0].remote && !library.items[0].local)
        precondition(library.lastOutgoingNumber == nil, "An incoming call must never be recalled as the last outgoing number")
        let olderOutgoing = CallRecording(id: UUID(), number: "+12025550124", direction: "outgoing", state: "ended",
            startedAt: 1_792_667_100, answeredAt: 1_792_667_110, endedAt: 1_792_667_130, reason: "local_hangup",
            recordingState: "none", recordingError: nil, bytes: 0, durationMs: 0)
        let lastOutgoing = CallRecording(id: UUID(), number: "+12025550125", direction: "outgoing", state: "ended",
            startedAt: 1_792_667_200, answeredAt: nil, endedAt: 1_792_667_210, reason: "busy",
            recordingState: "none", recordingError: nil, bytes: 0, durationMs: 0)
        let missed = CallRecording(id: UUID(), number: "+12025550126", direction: "incoming", state: "ended",
            startedAt: 1_792_667_300, answeredAt: nil, endedAt: 1_792_667_310, reason: "remote_hangup",
            recordingState: "none", recordingError: nil, bytes: 0, durationMs: 0)
        source.listed = [lastOutgoing, source.record, missed, olderOutgoing]
        await library.refresh()
        precondition(library.items.count == 4 && library.items[0].recording.id == missed.id)
        precondition(library.lastOutgoingNumber == lastOutgoing.number, "Recall must choose the newest outgoing attempt, not a newer missed call")
        precondition(missed.isMissed && missed.outcome == "Missed" && !missed.hasRecording && missed.connectedDuration == nil)
        precondition(olderOutgoing.connectedDuration == .seconds(20), "History duration must use connected time rather than audio-file length")
        precondition(lastOutgoing.outcome == "Not connected")
        let cachedHistory = CallRecordingLibrary(remote: source, identity: { identity.router }, directory: directory)
        precondition(cachedHistory.items.count == 4 && cachedHistory.lastOutgoingNumber == lastOutgoing.number,
                     "Calls without audio must appear synchronously after a cold start")
        source.offline = true; await cachedHistory.refresh()
        precondition(cachedHistory.items.count == 4 && cachedHistory.errorMessage != nil,
                     "An offline refresh must retain all cached history")
        source.offline = false
        let requests = source.historyRequests
        await library.refresh(force: false)
        precondition(source.historyRequests == requests, "Reopening a fresh list must reuse it")
        do { _ = try await library.download(missed); preconditionFailure("A missed call cannot download a nonexistent recording") }
        catch RecordingError.noRecording {}
        precondition(source.offsets.isEmpty)
        source.listed = nil; await library.refresh()
        let partial = try await library.download(source.record)
        let partialData = try Data(contentsOf: partial); precondition(partialData.count == 100044)
        precondition(library.items[0].local && !library.items[0].localComplete)
        // Reconstructing the library proves that a partial download is durable and resumable.
        let recovered = CallRecordingLibrary(remote: source, identity: { identity.router }, directory: directory)
        await recovered.refresh(); precondition(recovered.items[0].local && !recovered.items[0].localComplete)
        source.audio = full; source.complete = true; source.offsets = []
        let finished = try await recovered.download(source.record)
        precondition(source.offsets.first == 100044 && source.offsets.last == 0)
        let finishedData = try Data(contentsOf: finished); precondition(finishedData == full)
        let player = try AVAudioPlayer(contentsOf: finished)
        precondition(player.numberOfChannels == 2 && abs(player.duration - 10) < 0.01)
        await recovered.refresh(); precondition(recovered.items.count == 1 && recovered.items[0].localComplete && recovered.items[0].remote)
        var attributed = source.record
        attributed.phone = CallPhone(id: UUID(), name: "iPhone 17 Pro", model: "iPhone18,1")
        attributed.line = CellularLine(iccid: "890000000000000001", number: "+12025550101", source: "manual")
        source.listed = [attributed]; await recovered.refresh()
        precondition(recovered.items[0].recording.deviceName == "iPhone 17 Pro")
        _ = try await recovered.download(attributed)
        let offlineLibrary = CallRecordingLibrary(remote: source, identity: { identity.router }, directory: directory)
        source.offline = true; await offlineLibrary.refresh()
        precondition(offlineLibrary.items[0].recording.phone == attributed.phone)
        precondition(offlineLibrary.items[0].recording.line == attributed.line, "A call's line must survive offline relaunch independently of the current SIM")
        precondition(source.record.deviceName == "Device not recorded")
        source.offline = false
        source.listed = (0..<100).map { _ in
            CallRecording(id: UUID(), number: nil, direction: "incoming", state: "ended", startedAt: 1_792_666_300,
                answeredAt: nil, endedAt: 1_792_666_301, reason: nil, recordingState: "complete", recordingError: nil, bytes: 44, durationMs: 0)
        } + [source.record]
        source.failPage = 100
        await recovered.refresh()
        precondition(recovered.items.count == 1 && recovered.items[0].recording.phone == attributed.phone,
                     "A failed later page must not replace the complete cached history")
        let afterFailedPage = CallRecordingLibrary(remote: source, identity: { identity.router }, directory: directory)
        precondition(afterFailedPage.items.count == 1, "Partial pagination must never be persisted as a complete list")
        source.failPage = nil
        await recovered.refresh(); precondition(recovered.items.count == 101 && recovered.items.first(where: { $0.id == source.id })?.remote == true)
        source.listed = nil; await recovered.refresh()
        source.offline = true; await recovered.refresh()
        precondition(recovered.items.count == 1 && recovered.localURL(source.id) != nil && recovered.errorMessage != nil)
        source.offline = false; try await recovered.saveTranscript("Synthetic local transcript", locale: "en-US", id: source.id)
        let transcript = try recovered.transcript(source.id); precondition(transcript == "Synthetic local transcript")
        let otherPhone = CallRecordingLibrary(remote: source, identity: { identity.router }, directory: directory.appending(path: "other-phone"))
        await otherPhone.refresh(); let shared = try await otherPhone.loadTranscript(source.id); precondition(shared == transcript)
        _ = try await otherPhone.download(source.record)
        try await recovered.delete(source.id)
        precondition(recovered.items.count == 1 && !recovered.items[0].hasAudio && !FileManager.default.fileExists(atPath: finished.path))
        precondition(recovered.items[0].recording.recordingState == "deleted", "Deleting audio must retain the call history")
        let deletedAudio = CallRecordingLibrary(remote: source, identity: { identity.router }, directory: directory)
        precondition(deletedAudio.items.count == 1 && !deletedAudio.items[0].hasAudio,
                     "A deleted recording must stay deleted after a cold start")
        await otherPhone.refresh(); precondition(otherPhone.items.count == 1 && otherPhone.items[0].local && !otherPhone.items[0].remoteAudio)
        try await otherPhone.saveTranscript("Local copy transcript", locale: "en-US", id: source.id)
        let localOnlyText = try otherPhone.transcript(source.id); precondition(localOnlyText == "Local copy transcript" && source.sharedTranscript == nil)

        let broken = Source(full); broken.complete = true; broken.invalid = true
        let check = CallRecordingLibrary(remote: broken, identity: { identity.router }, directory: directory.appending(path: "invalid"))
        await check.refresh()
        do { _ = try await check.download(broken.record); preconditionFailure("Invalid chunk accepted") }
        catch RecordingError.invalidChunk {}
        precondition(check.items[0].local && !check.items[0].localComplete)
        broken.invalid = false
        _ = try await check.download(broken.record); precondition(check.items[0].localComplete)

        let switching = Source(full); switching.complete = true
        let guarded = CallRecordingLibrary(remote: switching, identity: { identity.router }, directory: directory.appending(path: "switch"))
        await guarded.refresh(); switching.changed = { identity.router = UUID() }
        do { _ = try await guarded.download(switching.record); preconditionFailure("Changed device accepted") }
        catch RecordingError.deviceChanged {}
        switching.changed = nil; await guarded.refresh(); precondition(!guarded.items[0].local)
        identity.router = UUID(); guarded.loadCached()
        precondition(guarded.items.isEmpty, "A new router must never display another router's cached calls")
        let corruptDirectory = directory.appending(path: "corrupt")
        let corruptCache = DeviceSnapshotCache<[CallRecording]>(directory: corruptDirectory.appending(path: "History"))
        try corruptCache.save([missed], routerID: identity.router)
        try Data("invalid".utf8).write(to: corruptDirectory.appending(path: "History/\(identity.router.uuidString.lowercased()).json"))
        let corrupt = CallRecordingLibrary(remote: source, identity: { identity.router }, directory: corruptDirectory)
        precondition(corrupt.items.isEmpty && corrupt.errorMessage != nil, "Corrupt cache data must be reported")
        print("Call history: cold-start/offline cache, failed pagination, router isolation, missed calls, recall, duration, recording deletion, stereo playback and transcripts passed")
    }
}

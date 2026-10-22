import Foundation
import Observation
import UIKit

struct CallRecording: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let number: String?
    let direction: String
    let state: String
    let startedAt: UInt64
    let answeredAt: UInt64?
    let endedAt: UInt64?
    let reason: String?
    var recordingState: String
    var recordingError: String?
    var bytes: UInt64
    var durationMs: UInt64
    var hasTranscript: Bool? = nil
    var phone: CallPhone? = nil
    var line: CellularLine? = nil
    var lineLabel: String { line?.label ?? "Line unknown" }
    var date: Date { Date(timeIntervalSince1970: Double(startedAt)) }
    var isFinished: Bool { state == "ended" && recordingState != "recording" }
    var isMissed: Bool { direction == "incoming" && state == "ended" && answeredAt == nil }
    var hasRecording: Bool { bytes > 44 && ["recording", "complete", "interrupted", "failed"].contains(recordingState) }
    var connectedDuration: Duration? {
        guard let answeredAt, let endedAt else { return nil }
        return .seconds(Double(endedAt) - Double(answeredAt))
    }
    var outcome: String {
        if isMissed { return "Missed" }
        if state != "ended" { return state.capitalized }
        if answeredAt == nil { return "Not connected" }
        return direction == "incoming" ? "Incoming" : "Outgoing"
    }
    var deviceName: String {
        if let phone { return phone.name }
        return direction == "incoming" && answeredAt == nil ? "Not answered" : "Device not recorded"
    }
}
struct CallRecordingPage: Decodable, Sendable { let items: [CallRecording]; let nextOffset: Int?; var error: String? = nil }
struct CallRecordingTranscript: Codable, Equatable, Sendable { let text: String; let locale: String }
private struct RecordingTranscriptResponse: Decodable { let transcript: CallRecordingTranscript? }
struct CallRecordingChunk: Decodable, Sendable {
    let id: UUID
    let offset: UInt64
    let totalBytes: UInt64
    let complete: Bool
    let audio: Data
}
@MainActor protocol CallRecordingRemote: AnyObject {
    func history(offset: Int) async throws -> CallRecordingPage
    func recordingChunk(id: UUID, offset: UInt64) async throws -> CallRecordingChunk
    func deleteRecording(id: UUID) async throws
    func recordingTranscript(id: UUID) async throws -> CallRecordingTranscript?
    func saveRecordingTranscript(id: UUID, transcript: CallRecordingTranscript) async throws
}
extension AgentClient: CallRecordingRemote {
    func history(offset: Int) async throws -> CallRecordingPage {
        try await get(offset == 0 ? "/api/call-history" : "/api/call-history/page/\(offset)")
    }
    func recordingChunk(id: UUID, offset: UInt64) async throws -> CallRecordingChunk {
        try await get("/api/recordings/\(id.uuidString.lowercased())/audio/\(offset)")
    }
    func deleteRecording(id: UUID) async throws { _ = try await deleteJSON("/api/recordings/\(id.uuidString.lowercased())") }
    func recordingTranscript(id: UUID) async throws -> CallRecordingTranscript? {
        let response: RecordingTranscriptResponse = try await get("/api/recordings/\(id.uuidString.lowercased())/transcript")
        return response.transcript
    }
    func saveRecordingTranscript(id: UUID, transcript: CallRecordingTranscript) async throws {
        _ = try await putJSON("/api/recordings/\(id.uuidString.lowercased())/transcript", body: ["text": transcript.text, "locale": transcript.locale])
    }
}
struct DownloadedRecording: Codable, Sendable {
    let routerID: UUID
    var recording: CallRecording
    var complete: Bool
    var bytes: UInt64
    var pendingTranscript: CallRecordingTranscript? = nil
}
struct CallRecordingItem: Identifiable, Equatable {
    let recording: CallRecording
    let remote: Bool
    let local: Bool
    let localComplete: Bool
    var id: UUID { recording.id }
    var remoteAudio: Bool { remote && recording.hasRecording }
    var hasAudio: Bool { local || remoteAudio }
}
enum RecordingError: LocalizedError {
    case historyUnavailable(String)
    case noDevice, deviceChanged, invalidChunk, invalidAudio, noRecording, stillRecording, unsupportedSpeech, unsupportedLanguage, transcriptTooLarge
    var errorDescription: String? {
        switch self {
        case .historyUnavailable(let message): "Call history: \(message)"
        case .noDevice: "Connect to a U60 to load its call history."
        case .deviceChanged: "The selected U60 changed. Reopen call details to continue."
        case .invalidChunk: "The U60 returned an invalid audio chunk."
        case .invalidAudio: "The recording is not a complete supported WAV file."
        case .noRecording: "There is no recording for this call."
        case .stillRecording: "Wait until this call has ended."
        case .unsupportedSpeech: "On-device transcription is unavailable on this device."
        case .unsupportedLanguage: "The selected language has no supported on-device transcription model."
        case .transcriptTooLarge: "This transcript is saved on your iPhone. It is too long to sync to U60."
        }
    }
}

@Observable @MainActor final class CallRecordingLibrary {
    private(set) var items: [CallRecordingItem] = []
    private(set) var loading = false
    private(set) var downloading = Set<UUID>()
    private(set) var errorMessage: String?
    var lastOutgoingNumber: String? {
        items.lazy.filter { $0.recording.direction == "outgoing" }
            .compactMap { $0.recording.number }.first { !$0.isEmpty }
    }
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let remote: any CallRecordingRemote
    @ObservationIgnored private let identity: () -> UUID?
    @ObservationIgnored private var routerID: UUID?
    @ObservationIgnored private var local: [UUID: DownloadedRecording] = [:]
    @ObservationIgnored private var remoteItems: [UUID: CallRecording] = [:]
    @ObservationIgnored private var remoteComplete = false
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private var historyRevision = 0
    @ObservationIgnored private var historyCacheDirty = true
    @ObservationIgnored private var syncTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeCall: UUID?
    @ObservationIgnored private var uploadingTranscripts = Set<UUID>()
    @ObservationIgnored private var background: UIBackgroundTaskIdentifier = .invalid

    init(remote: any CallRecordingRemote, identity: @escaping () -> UUID?, directory: URL = .applicationSupportDirectory.appending(path: "CallRecordings", directoryHint: .isDirectory)) {
        self.remote = remote; self.identity = identity; self.directory = directory
        loadCached()
    }
    private var historyCache: DeviceSnapshotCache<[CallRecording]> {
        DeviceSnapshotCache(directory: directory.appending(path: "History", directoryHint: .isDirectory))
    }
    func loadCached() {
        guard let router = identity() else {
            routerID = nil; local = [:]; remoteItems = [:]; remoteComplete = false
            lastRefresh = nil; refreshID = nil; loading = false; errorMessage = nil; rebuild()
            return
        }
        do { try prepare(router) }
        catch { errorMessage = "Could not load call history on this iPhone: \(error.localizedDescription)" }
    }
    private func folder(_ router: UUID) -> URL { directory.appending(path: router.uuidString.lowercased(), directoryHint: .isDirectory) }
    private func file(_ id: UUID, router: UUID, extension suffix: String) -> URL { folder(router).appending(path: id.uuidString.lowercased()+"."+suffix) }
    private func prepare(_ router: UUID) throws {
        if routerID == router { return }
        routerID = router; local = [:]; remoteItems = [:]; remoteComplete = false
        historyCacheDirty = true
        lastRefresh = nil; refreshID = nil; loading = false; errorMessage = nil; rebuild()
        let folder = folder(router)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var loaded: [UUID: DownloadedRecording] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            let saved = try JSONDecoder().decode(DownloadedRecording.self, from: Data(contentsOf: url))
            guard saved.routerID == router, url.deletingPathExtension().lastPathComponent == saved.recording.id.uuidString.lowercased() else { throw RecordingError.invalidAudio }
            loaded[saved.recording.id] = saved
        }
        local = loaded
        if let cached = try historyCache.load(routerID: router) {
            remoteItems = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            historyCacheDirty = false
        }
        rebuild()
    }
    private func saveHistory(router: UUID) throws {
        historyCacheDirty = true
        try historyCache.save(Array(remoteItems.values), routerID: router)
        historyCacheDirty = false
    }
    private func save(_ value: DownloadedRecording) throws {
        try JSONEncoder().encode(value).write(to: file(value.recording.id, router: value.routerID, extension: "json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        local[value.recording.id] = value; rebuild()
    }
    private func rebuild() {
        let ids = Set(local.keys).union(remoteItems.keys)
        let updated = ids.compactMap { id -> CallRecordingItem? in
            guard let recording = remoteItems[id] ?? local[id]?.recording else { return nil }
            return CallRecordingItem(recording: recording, remote: remoteItems[id] != nil, local: local[id] != nil,
                                     localComplete: local[id]?.complete == true)
        }.sorted { $0.recording.startedAt == $1.recording.startedAt ? $0.id.uuidString > $1.id.uuidString : $0.recording.startedAt > $1.recording.startedAt }
        if items != updated { items.reconcile(with: updated) }
    }
    func refresh(force: Bool = true) async {
        loadCached()
        guard !loading else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 30 { return }
        let requestID = UUID(), revision = historyRevision
        refreshID = requestID; loading = true
        defer { if refreshID == requestID { loading = false; refreshID = nil } }
        do {
            guard let router = identity() else { throw RecordingError.noDevice }
            try prepare(router)
            var offset = 0
            var fetched: [UUID: CallRecording] = [:]
            repeat {
                try Task.checkCancellation()
                let page = try await remote.history(offset: offset)
                try Task.checkCancellation()
                guard identity() == router, routerID == router, refreshID == requestID else { throw RecordingError.deviceChanged }
                if let error = page.error { throw RecordingError.historyUnavailable(error) }
                page.items.forEach { fetched[$0.id] = $0 }
                guard let next = page.nextOffset else { break }
                guard next > offset else { throw RecordingError.invalidChunk }
                offset = next
            } while true
            guard historyRevision == revision else { return }
            let changed = remoteItems != fetched
            if changed { remoteItems = fetched; rebuild() }
            remoteComplete = true; errorMessage = nil
            if changed || historyCacheDirty { try saveHistory(router: router) }
            lastRefresh = Date()
        } catch {
            if identity() != routerID { loadCached() }
            else if refreshID == requestID, !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }
    func localURL(_ id: UUID) -> URL? {
        guard let routerID, local[id] != nil else { return nil }
        let url = file(id, router: routerID, extension: "wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func download(_ recording: CallRecording) async throws -> URL {
        guard let router = identity() else { throw RecordingError.noDevice }
        try prepare(router)
        if let saved = local[recording.id], saved.complete, let url = localURL(recording.id) {
            if saved.recording != recording { try save(DownloadedRecording(routerID: router, recording: recording, complete: true, bytes: saved.bytes, pendingTranscript: saved.pendingTranscript)) }
            return url
        }
        guard recording.hasRecording || recording.recordingState == "recording" else { throw RecordingError.noRecording }
        if downloading.contains(recording.id) {
            while downloading.contains(recording.id) { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() }
            if let saved = local[recording.id], saved.complete, let url = localURL(recording.id) { return url }
        }
        downloading.insert(recording.id); defer { downloading.remove(recording.id) }
        let url = file(recording.id, router: router, extension: "wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        }
        let output = try FileHandle(forUpdating: url); defer { try? output.close() }
        var offset = try output.seekToEnd()
        try save(DownloadedRecording(routerID: router, recording: recording, complete: false, bytes: offset, pendingTranscript: local[recording.id]?.pendingTranscript))
        var completed = false
        // Bound each pass even while the live file is still growing.
        for _ in 0..<64 {
            try Task.checkCancellation()
            let chunk = try await remote.recordingChunk(id: recording.id, offset: offset)
            guard identity() == router else { throw RecordingError.deviceChanged }
            guard chunk.id == recording.id, chunk.offset == offset, chunk.audio.count <= 65536,
                  chunk.totalBytes >= offset + UInt64(chunk.audio.count), !chunk.audio.isEmpty || chunk.totalBytes == offset else { throw RecordingError.invalidChunk }
            try output.seek(toOffset: offset); try output.write(contentsOf: chunk.audio); offset += UInt64(chunk.audio.count)
            if offset == chunk.totalBytes { completed = chunk.complete; break }
        }
        if completed {
            let first = try await remote.recordingChunk(id: recording.id, offset: 0)
            guard identity() == router, first.id == recording.id, first.complete, first.totalBytes == offset, first.audio.count >= 44 else { throw RecordingError.invalidChunk }
            try output.seek(toOffset: 0); try output.write(contentsOf: first.audio.prefix(44))
        }
        if offset >= 44 { try Self.repairHeader(output, bytes: offset) }
        try output.synchronize()
        try save(DownloadedRecording(routerID: router, recording: recording, complete: completed, bytes: offset, pendingTranscript: local[recording.id]?.pendingTranscript))
        return url
    }
    static func repairHeader(_ file: FileHandle, bytes: UInt64) throws {
        guard bytes >= 44, (bytes - 44) % 4 == 0, bytes - 8 <= UInt64(UInt32.max) else { throw RecordingError.invalidAudio }
        try file.seek(toOffset: 0)
        guard let header = try file.read(upToCount: 44), header.count == 44,
              header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8) else { throw RecordingError.invalidAudio }
        for (offset, value) in [(UInt64(4), UInt32(bytes - 8)), (40, UInt32(bytes - 44))] {
            var little = value.littleEndian
            try file.seek(toOffset: offset); try file.write(contentsOf: withUnsafeBytes(of: &little) { Data($0) })
        }
    }
    func removeLocal(_ id: UUID) throws {
        guard let routerID else { throw RecordingError.noDevice }
        for suffix in ["wav", "json", "txt"] {
            let url = file(id, router: routerID, extension: suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        local[id] = nil; rebuild()
    }
    func delete(_ id: UUID) async throws {
        guard !downloading.contains(id), let router = routerID, identity() == router else { throw RecordingError.deviceChanged }
        guard var record = remoteItems[id], record.hasRecording else { throw RecordingError.noRecording }
        try await remote.deleteRecording(id: id)
        guard identity() == router else { throw RecordingError.deviceChanged }
        try removeLocal(id)
        record.recordingState = "deleted"; record.recordingError = nil
        record.bytes = 0; record.durationMs = 0; record.hasTranscript = false
        historyRevision += 1; lastRefresh = nil
        remoteItems[id] = record; rebuild()
        try saveHistory(router: router)
    }
    func transcript(_ id: UUID) throws -> String? {
        guard let routerID else { throw RecordingError.noDevice }
        let url = file(id, router: routerID, extension: "txt")
        return FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
    }
    func loadTranscript(_ id: UUID) async throws -> String? {
        if let saved = try transcript(id) { return saved }
        guard let routerID, identity() == routerID, remoteItems[id]?.hasTranscript == true else { return nil }
        let result = try await remote.recordingTranscript(id: id)
        guard identity() == routerID else { throw RecordingError.deviceChanged }
        if let result { try Data(result.text.utf8).write(to: file(id, router: routerID, extension: "txt"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        return result?.text
    }
    func saveTranscript(_ text: String, locale: String, id: UUID) async throws {
        guard let routerID, var saved = local[id] else { throw RecordingError.noDevice }
        try text.data(using: .utf8)!.write(to: file(id, router: routerID, extension: "txt"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let payload = CallRecordingTranscript(text: text, locale: locale)
        if remoteComplete, remoteItems[id]?.hasRecording != true { saved.pendingTranscript = nil; try save(saved); return }
        guard text.utf8.count <= 48000, try JSONEncoder().encode(payload).count <= 64000 else { throw RecordingError.transcriptTooLarge }
        saved.pendingTranscript = payload; try save(saved)
        try await uploadTranscript(id)
    }
    private func uploadTranscript(_ id: UUID) async throws {
        guard let routerID, identity() == routerID else { throw RecordingError.deviceChanged }
        guard let pending = local[id]?.pendingTranscript, !uploadingTranscripts.contains(id) else { return }
        if remoteComplete, remoteItems[id]?.hasRecording != true, var saved = local[id] { saved.pendingTranscript = nil; try save(saved); return }
        uploadingTranscripts.insert(id); defer { uploadingTranscripts.remove(id) }
        try await remote.saveRecordingTranscript(id: id, transcript: pending)
        guard identity() == routerID, var saved = local[id] else { throw RecordingError.deviceChanged }
        if saved.pendingTranscript == pending { saved.pendingTranscript = nil; try save(saved) }
    }
    func observe(_ call: RemoteCall?) {
        lastRefresh = nil
        activeCall = call?.id
        if let call, call.state == .active, call.mediaReady, syncTasks[call.id] == nil {
            syncTasks[call.id] = Task { [weak self] in await self?.mirror(call: call) }
        }
        if call == nil, !syncTasks.isEmpty, background == .invalid {
            background = UIApplication.shared.beginBackgroundTask(withName: "Finish call recording") { [weak self] in
                Task { @MainActor in self?.syncTasks.values.forEach { $0.cancel() }; self?.endBackground() }
            }
        }
    }
    func resumePending() {
        Task { [self] in
            guard let router = identity() else { return }
            do { try prepare(router) } catch { errorMessage = error.localizedDescription; return }
            await refresh(force: false)
            for value in local.values where !value.complete && syncTasks[value.recording.id] == nil {
                let recording = value.recording
                syncTasks[recording.id] = Task { [weak self] in
                    guard let self else { return }
                    defer { self.syncTasks[recording.id] = nil }
                    do { _ = try await self.download(recording) } catch { self.errorMessage = error.localizedDescription }
                }
            }
            for value in local.values where value.pendingTranscript != nil {
                do { try await uploadTranscript(value.recording.id) } catch { errorMessage = error.localizedDescription }
            }
        }
    }
    private func mirror(call: RemoteCall) async {
        defer { syncTasks[call.id] = nil; if syncTasks.isEmpty { endBackground() } }
        var endDeadline: ContinuousClock.Instant?
        while !Task.isCancelled, identity() == call.routerId {
            if activeCall != call.id { if endDeadline == nil { endDeadline = .now.advanced(by: .seconds(30)) }; if ContinuousClock.now >= endDeadline! { return } }
            do {
                try prepare(call.routerId)
                let page = try await remote.history(offset: 0)
                guard identity() == call.routerId else { return }
                if let recording = page.items.first(where: { $0.id == call.id }) {
                    historyRevision += 1
                    remoteItems[recording.id] = recording; rebuild()
                    try saveHistory(router: call.routerId)
                    _ = try await download(recording)
                    if recording.isFinished, local[recording.id]?.complete == true { return }
                }
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError { return }
            catch { errorMessage = error.localizedDescription; do { try await Task.sleep(for: .seconds(2)) } catch { return } }
        }
    }
    private func endBackground() {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
    }
}

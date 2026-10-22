import AVFoundation
import Foundation
import Speech

enum RecordingTranscriber {
    static func transcribe(_ url: URL, locale: Locale) async throws -> String {
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw RecordingError.unsupportedLanguage }
            let module = SpeechTranscriber(locale: supported, preset: .transcription)
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await install.downloadAndInstall() }
            let analyzer = SpeechAnalyzer(modules: [module])
            let output = Task {
                var parts: [String] = []
                for try await result in module.results { parts.append(String(result.text.characters)) }
                return parts.joined(separator: " ")
            }
            do {
                let input = try AVAudioFile(forReading: url)
                _ = try await analyzer.analyzeSequence(from: input)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await output.value
            } catch {
                await analyzer.cancelAndFinishNow(); output.cancel(); throw error
            }
        }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized, let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.supportsOnDeviceRecognition else { throw RecordingError.unsupportedSpeech }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = false
        return try await legacy(recognizer, request: request)
    }
    private static func legacy(_ recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest) async throws -> String {
        let owner = RecognitionOwner()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                owner.start(recognizer, request: request, continuation: continuation)
            }
        } onCancel: { owner.cancel() }
    }
}
private final class RecognitionOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var cancelled = false
    func start(_ recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest, continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation; lock.unlock()
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error { self?.finish(.failure(error)) }
            else if let result, result.isFinal { self?.finish(.success(result.bestTranscription.formattedString)) }
        }
        lock.lock(); self.task = task; let stop = cancelled || self.continuation == nil; lock.unlock()
        if stop { task.cancel() }
    }
    private func finish(_ result: Result<String, Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; task = nil; lock.unlock()
        continuation?.resume(with: result)
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel(); finish(.failure(CancellationError()))
    }
}

import AVFoundation
import SwiftUI

struct CallHistoryView: View {
    @Environment(CallRecordingLibrary.self) private var library
    var body: some View {
        Group {
            if library.items.isEmpty {
                ContentUnavailableView {
                    Label("No calls yet", systemImage: "clock")
                } description: {
                    Text(library.errorMessage ?? "Incoming, outgoing and missed calls appear here.")
                } actions: {
                    if library.loading { ProgressView() }
                    else { Button("Refresh") { Task { await library.refresh() } } }
                }
            } else {
                List {
                    if let error = library.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                    ForEach(library.items) { item in
                        NavigationLink {
                            CallHistoryDetail(item: item)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.recording.direction == "incoming" ? "phone.arrow.down.left" : "phone.arrow.up.right")
                                    .foregroundStyle(item.recording.isMissed ? Color.red : Color.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.recording.number ?? "Unknown caller").font(.body.weight(.medium))
                                        .foregroundStyle(item.recording.isMissed ? Color.red : Color.primary)
                                    HStack(spacing: 4) {
                                        Text(item.recording.outcome)
                                        if let phone = item.recording.phone { Text("· \(phone.name)") }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                    Text(item.recording.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(item.recording.line.map { "\(item.recording.direction == "incoming" ? "To" : "From") \($0.label)" } ?? "Line unknown")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if item.recording.recordingState == "recording" {
                                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                                } else {
                                    VStack(alignment: .trailing, spacing: 5) {
                                        if let duration = item.recording.connectedDuration {
                                            Text(duration.formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                                        }
                                        if item.hasAudio { Image(systemName: "waveform").accessibilityLabel("Recording available") }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .refreshable { await library.refresh() }
            }
        }
        .task { await library.refresh(force: false) }
        .navigationTitle("History")
        .accessibilityIdentifier("call-history")
    }
}

private struct CallHistoryDetail: View {
    let item: CallRecordingItem
    @Environment(CallRecordingLibrary.self) private var library
    @Environment(RemoteCallingManager.self) private var calling
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVAudioPlayer?
    @State private var url: URL?
    @State private var playing = false
    @State private var seeking = false
    @State private var progress: TimeInterval = 0
    @State private var busy = false
    @State private var error: String?
    @State private var text: String?
    @State private var localeID = Locale.current.identifier
    @State private var confirmDelete = false
    private var current: CallRecordingItem { library.items.first(where: { $0.id == item.id }) ?? item }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(current.recording.number ?? "Unknown caller").font(.title2.weight(.semibold))
                    Text(current.recording.date, format: .dateTime.month().day().year().hour().minute()).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                LabeledContent("Call", value: current.recording.outcome)
                LabeledContent("U60 number", value: current.recording.line?.number ?? "Not recorded")
                if let line = current.recording.line { LabeledContent("SIM", value: line.simLabel) }
                if let duration = current.recording.connectedDuration {
                    LabeledContent("Duration", value: duration.formatted(.time(pattern: .minuteSecond)))
                }
                LabeledContent(current.recording.direction == "incoming" ? "Answering device" : "Calling device",
                               value: current.recording.deviceName)
                if let number = current.recording.number, !number.isEmpty {
                    Button("Call", systemImage: "phone.fill") { perform { try await calling.start(number: number) } }
                        .disabled(busy || calling.call != nil || !calling.isConnected || !calling.routerOnline)
                }
            }
            Section("Recording") {
                if current.hasAudio {
                    LabeledContent("Saved on", value: current.remoteAudio
                        ? (current.local ? "U60 and this iPhone" : "U60") : "This iPhone")
                    if current.local && !current.localComplete {
                        Label("iPhone download incomplete", systemImage: "arrow.down.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = current.recording.recordingError { Text(error).font(.footnote).foregroundStyle(.red) }
                if let url {
                    HStack {
                        Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") { togglePlayback(url) }
                            .disabled(calling.call != nil)
                        Spacer()
                        Text(Duration.seconds(progress).formatted(.time(pattern: .minuteSecond))).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let player {
                        Slider(value: $progress, in: 0...max(player.duration, 0.01)) { editing in
                            seeking = editing
                            if !editing { player.currentTime = progress }
                        }
                    }
                    ShareLink(item: url) { Label("Share audio", systemImage: "square.and.arrow.up") }
                        .disabled(!current.recording.isFinished)
                } else if current.remoteAudio {
                    Button("Download recording", systemImage: "arrow.down.circle") { perform { url = try await library.download(current.recording) } }
                        .disabled(!current.remote || busy || !current.recording.isFinished)
                } else {
                    Text(current.recording.recordingState == "deleted" ? "Recording deleted" : "No recording")
                        .foregroundStyle(.secondary)
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            if current.hasAudio {
                Section("Transcript") {
                    if let text {
                        Text(text).textSelection(.enabled)
                        ShareLink(item: text) { Label("Share transcript", systemImage: "square.and.arrow.up") }
                    }
                    Picker("Language", selection: $localeID) {
                        Text("System language").tag(Locale.current.identifier)
                        ForEach([("English", "en-US"), ("中文", "zh-CN"), ("Nederlands", "nl-NL")], id: \.1) { name, id in
                            if id != Locale.current.identifier { Text(name).tag(id) }
                        }
                    }
                    Button(text == nil ? "Transcribe on this iPhone" : "Transcribe again", systemImage: "text.bubble") {
                        perform {
                            guard current.recording.isFinished else { throw RecordingError.stillRecording }
                            let audio: URL
                            if let url { audio = url } else { audio = try await library.download(current.recording) }
                            url = audio
                            let result = try await RecordingTranscriber.transcribe(audio, locale: Locale(identifier: localeID))
                            text = result
                            try await library.saveTranscript(result, locale: localeID, id: item.id)
                        }
                    }
                    .disabled(busy || calling.call != nil || !current.recording.isFinished)
                }
            }
            if current.local || current.remoteAudio {
                Section {
                    if current.local { Button("Remove iPhone copy", role: .destructive) { perform { player?.stop(); playing = false; try library.removeLocal(item.id); dismiss() } } }
                    if current.remoteAudio {
                        Button("Delete recording", role: .destructive) { confirmDelete = true }.disabled(busy || !current.recording.isFinished)
                    }
                }
            }
        }
        .navigationTitle("Call details")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this recording from U60 and this iPhone?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete recording", role: .destructive) { perform { player?.stop(); try await library.delete(item.id); dismiss() } }
        } message: { Text("Call history and copies already downloaded on other phones are retained.") }
        .task {
            url = library.localURL(item.id)
            do { text = try await library.loadTranscript(item.id) } catch { self.error = error.localizedDescription }
            while !Task.isCancelled {
                if let player { playing = player.isPlaying; if !seeking { progress = player.currentTime } }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        .onDisappear {
            player?.stop()
            if player != nil, calling.call == nil {
                do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
                catch { self.error = error.localizedDescription }
            }
        }
        .onChange(of: calling.call?.id) { _, id in if id != nil { player?.stop(); playing = false } }
    }
    private func togglePlayback(_ url: URL) {
        do {
            if playing { player?.pause(); playing = false; return }
            if player == nil {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                player = try AVAudioPlayer(contentsOf: url)
            }
            guard player?.play() == true else { throw RecordingError.invalidAudio }
            playing = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { do { try await action() } catch { self.error = error.localizedDescription }; busy = false }
    }
}

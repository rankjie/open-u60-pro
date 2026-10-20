#if DEBUG && OPENU60_NATIVE_CALLKIT_PROBE
    import SwiftUI
    import CallKit
    import Observation
    import WebRTC

    struct NativeCallKitProbeView: View {
        @Environment(\.dismiss) private var dismiss
        @State private var probe: NativeCallKitProbe
        init(manager: RemoteCallingManager) { _probe = State(initialValue: NativeCallKitProbe(manager: manager)) }
        var body: some View {
            NavigationStack {
                Form {
                    Section("Native PushKit and media verification") {
                        Text(probe.status)
                        Text("Synthetic router, real APNs and WebRTC. No cellular call.").font(.footnote)
                        Button("Prepare background push") {
                            probe.manager.disconnect()
                            probe.status = "Signaling disconnected; ready for a real push"
                        }
                        .disabled(!probe.ready || probe.manager.call != nil)
                        Button("Answer in app") { probe.perform { try await probe.manager.answer() } }.disabled(
                            probe.manager.call == nil)
                        Button(probe.manager.speaker ? "Use earpiece" : "Use speaker") {
                            probe.perform { try probe.manager.toggleSpeaker() }
                        }.disabled(probe.manager.call == nil)
                        Button("End call") { probe.perform { try await probe.manager.hangup() } }.disabled(
                            probe.manager.call == nil)
                        Button(probe.manager.muted ? "Unmute" : "Mute") {
                            probe.perform { try await probe.manager.toggleMute() }
                        }.disabled(probe.manager.call == nil)
                    }
                    Section("Observed system state") {
                        Text("PushKit receipts: \(probe.manager.nativeProbePushReceipts)")
                        Text("Push received in background: \(probe.manager.nativeProbePushInBackground ? "yes" : "no")")
                        Text("CallKit connected: \(probe.systemConnected ? "yes" : "no")")
                        Text("Audio activated: \(probe.audioActivated ? "yes" : "no")")
                        Text("Muted: \(probe.manager.muted ? "yes" : "no")")
                        Text("Audio output: \(probe.outputRoute)")
                        Text("Native packets received: \(probe.nativeReceived), sent: \(probe.nativeSent)")
                        Text("ICE route: \(probe.mediaRoute)")
                        Text("Completed system calls: \(probe.endedCalls)")
                        if let error = probe.manager.errorMessage { Text(error).foregroundStyle(.red) }
                    }
                }
                .navigationTitle("CallKit test")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back to OpenU60", systemImage: "chevron.left") {
                            Task {
                                await probe.manager.endNativeProbe()
                                dismiss()
                            }
                        }
                    }
                }
                .interactiveDismissDisabled()
                .task { await probe.start() }
            }
        }
    }

    @Observable @MainActor final class NativeCallKitProbe: NSObject, @preconcurrency CXCallObserverDelegate {
        let manager: RemoteCallingManager
        var status = "Preparing isolated verification"
        var ready = false
        var systemConnected = false
        var audioActivated = false
        var outputRoute = "inactive"
        var nativeReceived = 0
        var nativeSent = 0
        var mediaRoute = "checking"
        var endedCalls = 0
        private let observer = CXCallObserver()
        private var closed: Set<UUID> = []
        init(manager: RemoteCallingManager) {
            self.manager = manager
            super.init()
            observer.setDelegate(self, queue: .main)
        }
        func start() async {
            RTCSetMinDebugLogLevel(.none)
            do {
                let url = URL.documentsDirectory.appending(path: "openu60-native-probe.private.json")
                let config = try JSONDecoder().decode(CallingCredentials.self, from: Data(contentsOf: url))
                try await manager.beginNativeProbe(config)
                status = "Real VoIP token registered; ready"
                ready = true
            } catch {
                manager.present(error)
                status = "Verification setup failed"
                return
            }
            while !Task.isCancelled {
                outputRoute = RTCAudioSession.sharedInstance().session.currentRoute.outputs.map { $0.portType.rawValue }
                    .joined(separator: ", ")
                audioActivated =
                    RTCAudioSession.sharedInstance().isAudioEnabled && RTCAudioSession.sharedInstance().isActive
                if manager.call != nil, manager.audioConnected {
                    do {
                        let count = try await manager.nativeProbePacketCounts()
                        nativeReceived = count.received
                        nativeSent = count.sent
                        mediaRoute = count.route
                    } catch { manager.present(error) }
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        func perform(_ action: @escaping @MainActor () async throws -> Void) {
            Task { do { try await action() } catch { manager.present(error) } }
        }
        func callObserver(_ observer: CXCallObserver, callChanged call: CXCall) {
            guard call.uuid == manager.call?.callId || closed.contains(call.uuid) || (systemConnected && call.hasEnded)
            else { return }
            systemConnected = call.hasConnected && !call.hasEnded
            if call.hasEnded, closed.insert(call.uuid).inserted {
                endedCalls += 1
                status = "System call ended"
            } else if call.hasConnected {
                status = "System call connected"
            } else {
                status = call.isOutgoing ? "System outgoing call" : "System incoming call"
            }
        }
    }
#endif

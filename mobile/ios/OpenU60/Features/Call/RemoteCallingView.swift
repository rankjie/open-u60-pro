import SwiftUI

struct RemoteCallingView: View {
    @Environment(RemoteCallingManager.self) private var manager
    let localClient: AgentClient?
    @State private var server = ""
    @State private var pairingCode = ""
    @State private var invitation = ""
    @State private var number = ""
    @State private var busy = false
    @State private var confirmForget = false

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Calling service", value: manager.isConnected ? "Connected" : manager.isPaired ? "Reconnecting…" : "Not paired")
                if manager.isPaired {
                    LabeledContent("Router", value: manager.routerOnline ? "Online" : "Offline")
                    LabeledContent("Incoming call notifications", value: manager.pushConfigured ? "Configured" : "Server setup required")
                }
                if let error = manager.errorMessage { Text(error).foregroundStyle(.orange).font(.callout) }
            }

            if manager.isPaired {
                if let call = manager.call {
                    Section("Current call") {
                        Text(call.number.isEmpty ? "Unknown caller" : call.number).font(.title2)
                        LabeledContent("Status", value: call.state.rawValue.capitalized)
                        if call.state == .active {
                            LabeledContent("Audio", value: manager.audioConnected && call.mediaReady ? "Connected" : "Connecting…")
                            HStack {
                                Button(manager.muted ? "Unmute" : "Mute") { perform { try await manager.toggleMute() } }
                                Spacer()
                                Button(manager.speaker ? "Use earpiece" : "Use speaker") { perform { try manager.toggleSpeaker() } }
                            }
                            DialPadView { digit in perform { try await manager.dtmf(digit) } }
                        }
                        if call.direction == .incoming, call.state == .ringing {
                            Button("Answer", systemImage: "phone.fill") { perform { try await manager.answer() } }
                                .tint(.green)
                        }
                        Button("End call", systemImage: "phone.down.fill", role: .destructive) { perform { try await manager.hangup() } }
                    }
                } else {
                    Section("Make a call") {
                        TextField("Phone number", text: $number)
                            .keyboardType(.phonePad)
                            .accessibilityIdentifier("remote-call-number")
                        Button("Call", systemImage: "phone.fill") { perform { try await manager.start(number: number) } }
                            .disabled(number.isEmpty || !manager.isConnected || !manager.routerOnline)
                            .accessibilityIdentifier("remote-call-dial")
                    }
                }
                Section {
                    Text("Calls use the SIM in your U60 Pro. This iPhone can use mobile data or any Wi-Fi network.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Forget pairing", role: .destructive) { confirmForget = true }
                        .disabled(manager.call != nil)
                }
            } else {
                Section("Calling server") {
                    TextField("HTTPS server address", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let localClient {
                    Section {
                        SecureField("Server invitation", text: $invitation)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Enable remote calling on this router") {
                            perform { try await manager.enableRouter(client: localClient, invitation: invitation, server: server); invitation = "" }
                        }.disabled(invitation.isEmpty)
                    } header: { Text("Set up your router") }
                    footer: { Text("Connect to your router once for setup. Use a one-time invitation from your calling server.") }
                }
                Section {
                    SecureField("Router pairing code", text: $pairingCode).keyboardType(.numberPad)
                    Button("Pair this iPhone") { perform { try await manager.pair(server: server, code: pairingCode); pairingCode = "" } }
                        .disabled(pairingCode.count != 8)
                } header: { Text("Pair with an enabled router") }
                footer: { Text("Enter the 8-digit code created by your router's owner. You do not need to join its Wi-Fi.") }
            }
        }
        .navigationTitle("Remote calling")
        .disabled(busy)
        .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .confirmationDialog("Forget this router's pairing?", isPresented: $confirmForget) {
            Button("Forget pairing", role: .destructive) { perform { try await manager.forgetPairing() } }
        }
        .onAppear { if server.isEmpty { server = manager.serverAddress }; manager.foreground() }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { defer { busy = false }; do { try await action() } catch { manager.present(error) } }
    }
}

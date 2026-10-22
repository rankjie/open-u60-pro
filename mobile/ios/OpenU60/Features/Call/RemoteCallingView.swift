import SwiftUI

enum CallDestination: Hashable { case history }

struct RemoteCallingView: View {
    @Environment(RemoteCallingManager.self) private var manager
    @Environment(CallRecordingLibrary.self) private var recordings
    let localClient: AgentClient?
    var title = "Calls"
    @State private var pairingCode = ""
    @State private var invitation = ""
    @State private var number = ""
    @State private var busy = false
    @State private var confirmForget = false
    @State private var hasTransferredInvitation = false
    @State private var showConnection = false
    @State private var showKeypad = false
    @State private var enteredTones = ""
    @State private var inputError: String?
    private enum Field: Hashable { case invitation, pairingCode }
    @FocusState private var focusedField: Field?
    private var transferredInvitation: URL {
        URL.documentsDirectory.appending(path: "openu60-router-invitation.private")
    }

    var body: some View {
        GeometryReader { geometry in
            let keySize = min(80, max(48, min((geometry.size.width - 64) / 3.55,
                                            (geometry.size.height - (showKeypad && manager.call != nil ? 250 : 142)) / 6.0)))
            ScrollView {
                VStack(spacing: 0) {
                    if let call = manager.call {
                        currentCall(call, keySize: keySize)
                    } else {
                        dialer(keySize: keySize)
                    }
                    if let error = inputError ?? manager.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("calling-error")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(.systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    connectionButton
                    NavigationLink(value: CallDestination.history) {
                        Label("History", systemImage: "clock")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .overlay { Capsule().strokeBorder(.quaternary, lineWidth: 0.5) }
                            .frame(minHeight: 44)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("calling-history")
                }
            }
        }
        .sheet(isPresented: $showConnection) {
            NavigationStack {
                connectionForm
                    .navigationTitle("Calling connection")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showConnection = false }
                                .disabled(busy)
                        }
                    }
            }
            .interactiveDismissDisabled(busy)
        }
        .onAppear {
            hasTransferredInvitation = FileManager.default.fileExists(atPath: transferredInvitation.path)
        }
        .task { await recordings.refresh(force: false) }
        .task(id: manager.call?.id) {
            if manager.call != nil { await recordings.refresh() }
        }
        .onChange(of: manager.call?.id) { _, _ in
            showKeypad = false
            enteredTones = ""
            focusedField = nil
        }
        .onChange(of: manager.callPresentationRequest, initial: true) { _, request in
            guard let request, request.callID == manager.call?.callId else { return }
            showConnection = false
            showKeypad = false
            focusedField = nil
        }
        .onChange(of: manager.serverAddress) { _, _ in
            pairingCode = ""
            invitation = ""
            focusedField = nil
        }
    }

    private var connectionButton: some View {
        Button { showConnection = true } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                Text(connectionText)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.quaternary, lineWidth: 0.5) }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calling connection: \(connectionText)")
        .accessibilityHint("Shows connection details and pairing options")
        .accessibilityIdentifier("calling-connection")
    }

    private var connectionText: String {
        if manager.pairingRejected { return "Pair again" }
        if !manager.isPaired { return "Set up calls" }
        if !manager.isConnected { return "Reconnecting…" }
        if !manager.routerOnline { return "U60 offline" }
        return "U60 connected"
    }

    private var connectionColor: Color {
        if manager.pairingRejected { return .orange }
        if !manager.isPaired { return .secondary }
        if !manager.isConnected || !manager.routerOnline || !manager.pushConfigured { return .orange }
        return .green
    }

    private func dialer(keySize: CGFloat) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Text(localClient?.simState.line.label ?? "Loading SIM line…")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("calling-outgoing-line")
                .accessibilityHint(localClient?.simState.error ?? "The U60 number used for outgoing calls")
            Text(number.isEmpty ? " " : number)
                .font(.system(size: 36, weight: .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(maxWidth: .infinity, minHeight: 56)
                .padding(.horizontal, 24)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Paste", systemImage: "doc.on.clipboard") { pasteNumber() }
                    if !number.isEmpty {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = number }
                    }
                }
                .accessibilityLabel("Phone number")
                .accessibilityValue(number.isEmpty ? "No number entered" : number)
                .accessibilityIdentifier("remote-call-number")

            DialPadView(keySize: keySize, onPlus: {
                if number.isEmpty { number = "+"; inputError = nil }
            }) { digit in
                if number.count < (number.hasPrefix("+") ? 31 : 30) { number.append(digit); inputError = nil }
            }

            ZStack {
                roundCallButton(symbol: "phone.fill", color: .green, size: keySize,
                                label: "Call", identifier: "remote-call-dial") {
                    if number.isEmpty {
                        if let previous = recordings.lastOutgoingNumber { number = previous; inputError = nil }
                    } else {
                        perform { try await manager.start(number: number) }
                    }
                }
                .disabled(busy || (number.isEmpty ? recordings.loading : number == "+" || !manager.isConnected || !manager.routerOnline))
                .accessibilityHint(number.isEmpty ? "Recalls the last outgoing number without placing a call" : "Calls the entered number")
                HStack {
                    Spacer()
                    Button {
                        if !number.isEmpty { number.removeLast(); inputError = nil }
                    } label: {
                        Image(systemName: "delete.backward.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: keySize, height: keySize)
                    }
                    .buttonStyle(.plain)
                    .opacity(number.isEmpty ? 0 : 1)
                    .disabled(number.isEmpty)
                    .accessibilityLabel("Delete last digit")
                    .accessibilityIdentifier("dial-delete")
                }
                .frame(width: keySize * 3.55)
            }
            Spacer(minLength: 0)
        }
    }

    private func currentCall(_ call: RemoteCall, keySize: CGFloat) -> some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text(enteredTones.isEmpty ? (call.number.isEmpty ? "Unknown caller" : call.number) : enteredTones)
                    .font(.system(size: 34, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let connected = call.connectedDate {
                    Text(connected, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Call duration")
                        .accessibilityValue(Text(connected, style: .timer))
                        .accessibilityIdentifier("remote-call-duration")
                }
                if let record = recordings.items.first(where: { $0.id == call.id })?.recording {
                    Text(record.line.map { "\(record.direction == "incoming" ? "To" : "From") \($0.label)" } ?? "Line unknown")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if call.connectedDate == nil || !manager.audioConnected || !call.mediaReady {
                    Text(call.state == .active
                         ? (manager.audioConnected && call.mediaReady ? "Connected" : "Connecting audio…")
                         : call.state.rawValue.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if recordings.items.first(where: { $0.id == call.id })?.recording.recordingState == "recording" {
                    Label("Recording", systemImage: "record.circle.fill").font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
            if call.state != .ended {
                if showKeypad {
                    DialPadView(keySize: keySize) { digit in
                        perform {
                            try await manager.dtmf(digit)
                            enteredTones.append(digit)
                        }
                    }
                    Button("Hide keypad") { showKeypad = false; enteredTones = "" }
                        .font(.subheadline)
                } else {
                    HStack(spacing: 28) {
                        callControl("Mute", symbol: manager.muted ? "mic.slash.fill" : "mic.fill",
                                    active: manager.muted) { perform { try await manager.toggleMute() } }
                        callControl("Keypad", symbol: "number", active: false) { showKeypad = true }
                            .disabled(call.state != .active)
                        callControl("Speaker", symbol: "speaker.wave.3.fill", active: manager.speaker) {
                            perform { try manager.toggleSpeaker() }
                        }
                    }
                    .disabled(busy)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 64) {
                roundCallButton(symbol: "phone.down.fill", color: .red, size: keySize,
                                label: "End call", identifier: "remote-call-hangup") {
                    perform { try await manager.hangup() }
                }
                if call.direction == .incoming && call.state == .ringing {
                    roundCallButton(symbol: "phone.fill", color: .green, size: keySize,
                                    label: "Answer", identifier: "remote-call-answer") {
                        perform { try await manager.answer() }
                    }
                }
            }
            .disabled(busy)
            Spacer(minLength: 0)
        }
    }

    private func roundCallButton(symbol: String, color: Color, size: CGFloat, label: String,
                                 identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(.white) }
                else { Image(systemName: symbol).font(.system(size: size * 0.38, weight: .medium)) }
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func callControl(_ label: String, symbol: String, active: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .background(active ? Color.primary : Color(.tertiarySystemFill), in: Circle())
                    .foregroundStyle(active ? Color(.systemBackground) : Color.primary)
                Text(label).font(.caption)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "On" : "Off")
    }

    private func pasteNumber() {
        guard let text = UIPasteboard.general.string else { return }
        let normalized = text.filter { !$0.isWhitespace && !"()-".contains($0) }
        guard normalized.range(of: "^\\+?[0-9*#]{1,30}$", options: .regularExpression) != nil else {
            inputError = "Paste a phone number with up to 30 digits, * or #."
            return
        }
        number = normalized
        inputError = nil
    }

    private var connectionForm: some View {
        Form {
            Section {
                NavigationLink { CallingServersView() } label: {
                    LabeledContent("Server", value: manager.serverAddress)
                }
            }
            Section("Connection") {
                LabeledContent("Calling service", value: manager.pairingRejected ? "Pair again" : manager.isConnected ? "Connected" : manager.isPaired ? "Reconnecting…" : "Not paired")
                if manager.isPaired {
                    LabeledContent("Router", value: manager.routerOnline ? "Online" : "Offline")
                    LabeledContent("Incoming call notifications", value: manager.pushConfigured ? "Configured" : "Server setup required")
                }
                if let error = manager.errorMessage { Text(error).foregroundStyle(.orange).font(.callout) }
            }

            if manager.isPaired && !manager.pairingRejected {
                Section {
                    Text("All paired phones can manage your U60 over the internet. Incoming calls ring on every phone; the first to answer takes the call.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Forget pairing", role: .destructive) { confirmForget = true }
                        .disabled(manager.call != nil)
                }
            } else {
                Section {
                    NavigationLink { DeviceConnectView() } label: { Label("Connect with device string", systemImage:"wifi.router") }
                }
                Section {
                    DisclosureGroup("Advanced pairing") {
                    if let localClient {
                        Button("Pair with this router", systemImage:"wifi.router") {
                            perform { try await manager.pairLocalRouter(client:localClient); showConnection = false }
                        }
                    }
                    SecureField("Router pairing code", text: $pairingCode).keyboardType(.numberPad)
                        .focused($focusedField, equals: .pairingCode)
                    Button("Pair this iPhone") { perform { try await manager.pair(server: manager.serverAddress, code: pairingCode); pairingCode = ""; showConnection = false } }
                        .disabled(pairingCode.count != 8)
                    if manager.hasPendingPairing {
                        Button("Forget pending pairing", role: .destructive) { confirmForget = true }
                    }
                    }
                }
                if let localClient {
                    Section {
                        DisclosureGroup("Set up a new router") {
                            SecureField("Server invitation", text: $invitation)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focusedField, equals: .invitation)
                            Button("Enable remote calling on this router") {
                                perform { try await manager.enableRouter(client: localClient, invitation: invitation, server: manager.serverAddress); invitation = ""; showConnection = false }
                            }.disabled(invitation.isEmpty)
                            if hasTransferredInvitation {
                                Button("Use transferred server invitation", systemImage: "doc.badge.arrow.up") {
                                    perform {
                                        let status = try await localClient.getJSON("/api/remote-calling/status")
                                        if status["enabled"] as? Bool == true, status["configured"] as? Bool == true {
                                            try await manager.pairLocalRouter(client: localClient)
                                        } else {
                                            try await manager.enableRouter(client: localClient,
                                                invitation: RouterInvitation.read(from: transferredInvitation), server: manager.serverAddress)
                                        }
                                        try FileManager.default.removeItem(at: transferredInvitation)
                                        hasTransferredInvitation = false
                                        showConnection = false
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focusedField != nil {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityIdentifier("remote-calling-dismiss-keyboard")
                }
            }
        }
        .disabled(busy)
        .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .confirmationDialog("Forget pairing on this iPhone?", isPresented: $confirmForget) {
            Button("Forget pairing", role: .destructive) { perform { try await manager.forgetPairing() } }
        }
        .onDisappear { focusedField = nil }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        focusedField = nil
        busy = true
        Task { defer { busy = false }; do { try await action() } catch { manager.present(error) } }
    }
}

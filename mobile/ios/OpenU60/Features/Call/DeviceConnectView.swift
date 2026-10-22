import SwiftUI

struct DeviceConnectView: View {
    @Environment(RemoteCallingManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var busy = false
    @State private var error: String?
    @State private var scanner = false
    @State private var scannedCode: String?
    private enum Field { case code, password }
    @FocusState private var focused: Field?

    var body: some View {
        Form {
            Section {
                Button {
                    focused = nil; error = nil; scanner = true
                } label: {
                    Label("Scan U60 QR code", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("scan-device-qr")
            } footer: { Text("Open Wi-Fi → Connect app on your U60 and scan its QR code.") }
            Section {
                TextField("Connection string", text: $code)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused, equals: .code)
                    .accessibilityIdentifier("device-connection-string")
                SecureField("Router password", text: $password)
                    .focused($focused, equals: .password)
                    .accessibilityIdentifier("device-connection-password")
                Button("Connect") { connect() }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || (password.isEmpty && !hasSavedPassword))
            } header: { Text("Connect to your U60") }
            footer: {
                Text(hasSavedPassword ? "Scanning connects automatically with your saved router password. You can also enter the device string manually." :
                    "Scan the QR code or enter the device string, then enter the router password.")
            }
            NavigationLink { CallingServersView() } label: {
                LabeledContent("Server", value: manager.serverAddress)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .navigationTitle("Connect U60")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissal()
        .disabled(busy)
        .overlay { if busy { ProgressView("Connecting…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius:12)) } }
        .sheet(isPresented: $scanner, onDismiss: acceptScan) {
            NavigationStack {
                QRCodeScanner(kind: .deviceConnection) { value in scannedCode = value; scanner = false }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan U60 QR code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { scanner = false } } }
            }
        }
        .task { hasSavedPassword = await KeychainHelper.loadInBackground(key:"router_password") != nil }
        .onDisappear { password = ""; focused = nil }
    }
    private func acceptScan() {
        guard let scannedCode else { return }
        self.scannedCode = nil
        do {
            let connection = try DeviceConnectionQRCode(scannedCode)
            try manager.selectScannedDevice(connection)
            code = connection.code
            error = nil
            if hasSavedPassword || !password.isEmpty { connect() }
            else { focused = .password }
        } catch { self.error = error.localizedDescription }
    }
    private func connect() {
        focused = nil; busy = true; error = nil
        let entered = password; password = ""
        Task {
            defer { busy = false }
            do {
                let secret: String
                if !entered.isEmpty { secret = entered }
                else if let saved = await KeychainHelper.loadInBackground(key:"router_password") { secret = saved }
                else { throw AgentError.serverError("Enter the router password.") }
                try await manager.connectDevice(code:code, password:secret)
                dismiss()
            } catch { if !error.isCancellation { self.error = error.localizedDescription } }
        }
    }
}

import SwiftUI

struct CallingServersView: View {
    @Environment(RemoteCallingManager.self) private var manager
    @State private var showAdd = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(manager.servers) { server in
                    Button {
                        do { try manager.selectServer(server.address); error = nil }
                        catch { self.error = error.localizedDescription }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.address.host() ?? server.address.absoluteString)
                                    .font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text(server.address.absoluteString)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                Text(server.isPaired ? "Paired" : server.hasPendingPairing ? "Pairing unfinished" : "Not paired")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if server.id == manager.serverAddress {
                                Image(systemName: "checkmark").font(.body.weight(.semibold))
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.call != nil || manager.serverOperationInProgress)
                    .accessibilityValue(server.id == manager.serverAddress ? "Selected" : "Not selected")
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            do { try manager.removeServer(server.address); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                        .disabled(server.id == manager.serverAddress || server.isPaired || server.hasPendingPairing || manager.serverOperationInProgress)
                    }
                }
                Button("Add server", systemImage: "plus") { showAdd = true }
                    .disabled(manager.serverOperationInProgress)
                    .accessibilityIdentifier("calling-add-server")
            } footer: {
                Text("Remote control and calls use the selected server. Each address keeps its own pairing. Adding an address keeps your current server selected; deploy and pair the new server before using it.")
            }
            if manager.call != nil {
                Section { Text("Finish the current call before switching servers.").foregroundStyle(.secondary) }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) { AddCallingServerView() }
    }
}

private struct AddCallingServerView: View {
    @Environment(RemoteCallingManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server address", text: $address,
                              prompt: Text("https://server.example:8443/openu60").foregroundStyle(.secondary))
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($addressFocused)
                        .accessibilityIdentifier("calling-server-address")
                } header: { Text("Server address") }
                footer: { Text("Use an HTTPS address. Include the port and path when required.") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Add server")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissal()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try manager.addServer(address); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { addressFocused = true }
        }
    }
}

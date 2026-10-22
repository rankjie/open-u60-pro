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
            if !manager.paths.options.isEmpty {
                RelayPathsSection()
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

/// The ways to reach the selected server. Doors are regional QUIC entries to the same
/// service; pairing and calls are the same through any of them.
private struct RelayPathsSection: View {
    @Environment(RemoteCallingManager.self) private var manager
    @State private var error: String?

    var body: some View {
        Section {
            row(id: nil, title: "Automatic", detail: automaticDetail, latency: nil)
            ForEach(manager.paths.options) { option in
                row(id: option.id, title: option.label,
                    detail: option.id == RelayPaths.direct ? "HTTPS" : "QUIC door",
                    latency: option.reachable == true ? option.latency : nil, unreachable: option.reachable == false,
                    measuring: option.reachable == nil)
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: {
            Text("Path")
        } footer: {
            Text("Paths are measured before each connection. Automatic uses the fastest that answers; a chosen path is used while it answers.")
        }
    }

    private var automaticDetail: String {
        let current = manager.paths.options.first { $0.id == manager.paths.current }
        return "Using \(current?.label ?? "Direct")"
    }

    private func row(id: String?, title: String, detail: String, latency: TimeInterval?, unreachable: Bool = false,
                     measuring: Bool = false) -> some View {
        Button {
            do { try manager.choosePath(id); error = nil } catch { self.error = error.localizedDescription }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if measuring {
                    ProgressView().controlSize(.small)
                } else if unreachable {
                    Text("Unreachable").font(.caption).foregroundStyle(.red)
                } else if let latency {
                    Text("\(Int((latency * 1000).rounded())) ms").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                if manager.pathPreference == id {
                    Image(systemName: "checkmark").font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.call != nil)
        .accessibilityValue(manager.pathPreference == id ? "Selected" : "")
    }
}

import SwiftUI

struct LANSettingsView: View {
    @Bindable var viewModel: LANSettingsViewModel

    var body: some View {
        List {

            Section("LAN") {
                TextField("IP Address", text: $viewModel.editLanIP)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                TextField("Subnet Mask", text: $viewModel.editNetmask)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
            }

            Section("DHCP Server") {
                Toggle("Enable DHCP", isOn: $viewModel.editDhcpEnabled)

                if viewModel.editDhcpEnabled {
                    TextField("Start Address", text: $viewModel.editDhcpStart)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    TextField("End Address", text: $viewModel.editDhcpEnd)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                    TextField("Lease Time (seconds)", text: $viewModel.editLeaseTime)
                        .keyboardType(.numberPad)
                }
            }

            Section {
                Button {
                    Task { await viewModel.apply() }
                } label: {
                    Text("Apply")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.isLoading)
            }
        }
        .navigationTitle("LAN / DHCP")
        .keyboardDismissal()
        .refreshable { await viewModel.refresh() }
        .operationStatus(message: viewModel.message, isError: viewModel.messageIsError, isLoading: viewModel.isLoading)
        .task { await viewModel.refresh() }
    }
}

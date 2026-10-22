import SwiftUI

struct VPNPassthroughView: View {
    @Bindable var viewModel: VPNPassthroughViewModel

    var body: some View {
        List {

            Section("VPN Passthrough") {
                Toggle("L2TP", isOn: $viewModel.editL2tp)
                Toggle("PPTP", isOn: $viewModel.editPptp)
                Toggle("IPSec", isOn: $viewModel.editIpsec)
            }

            Section {
                Button {
                    Task { await viewModel.apply() }
                } label: {
                    Text("Apply")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.isLoading || !viewModel.isLoaded)
            }
        }
        .navigationTitle("VPN Passthrough")
        .refreshable { await viewModel.refresh() }
        .operationStatus(message: viewModel.message, isError: viewModel.messageIsError, isLoading: viewModel.isLoading)
        .task { await viewModel.refresh() }
    }
}

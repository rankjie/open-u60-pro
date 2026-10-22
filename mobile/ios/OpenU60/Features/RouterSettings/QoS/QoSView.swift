import SwiftUI

struct QoSView: View {
    var viewModel: QoSViewModel

    var body: some View {
        List {

            Section("Quality of Service") {
                Toggle("Enable QoS", isOn: Binding(
                    get: { viewModel.config.enabled },
                    set: { enabled in Task { await viewModel.toggle(enabled: enabled) } }
                ))
                .disabled(viewModel.isLoading)
            }
        }
        .navigationTitle("QoS")
        .refreshable { await viewModel.refresh() }
        .operationStatus(message: viewModel.message, isError: viewModel.messageIsError, isLoading: viewModel.isLoading)
        .task { await viewModel.refresh() }
    }
}

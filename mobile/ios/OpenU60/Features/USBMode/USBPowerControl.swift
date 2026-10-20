import SwiftUI

struct USBPowerControl: View {
    @Bindable var viewModel: USBConnectionViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(
                isOn: Binding(
                    get: { viewModel.usbStatus.powerbankActive },
                    set: { enabled in
                        Task {
                            if enabled { await viewModel.enablePowerbank() } else { await viewModel.disablePowerbank() }
                        }
                    })
            ) {
                HStack(spacing: 8) {
                    Label("Charge phone", systemImage: "bolt.fill").font(.subheadline)
                    if viewModel.isLoading { ProgressView().controlSize(.mini) }
                }
            }
            .disabled(viewModel.isLoading)
            .accessibilityIdentifier("usb-charge-phone")
            if viewModel.messageIsError, let message = viewModel.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

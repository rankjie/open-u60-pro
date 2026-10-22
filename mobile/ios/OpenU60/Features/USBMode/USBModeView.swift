import SwiftUI

struct USBModeView: View {
    @Bindable var viewModel: USBConnectionViewModel

    var body: some View {
        List {

            Section("USB Status") {
                LabeledContent("Cable") {
                    Text(viewModel.usbStatus.cableAttached ? "Connected" : "Disconnected")
                        .foregroundStyle(viewModel.usbStatus.cableAttached ? .green : .secondary)
                }
                LabeledContent("USB-C CC") {
                    Text(viewModel.usbStatus.typecCC)
                }
                LabeledContent("Mode") {
                    Text(viewModel.usbStatus.mode.isEmpty ? "—" : viewModel.usbStatus.mode)
                }
            }

            Section {
                NavigationLink("Power reserve") { USBPowerReserveSettings(viewModel: viewModel) }
                if viewModel.powerStateUnknown {
                    Button("Turn off phone charging") { Task { await viewModel.disablePowerbank() } }
                        .disabled(viewModel.isLoading)
                } else {
                    Toggle(
                        "Fast Charging (Powerbank)",
                        isOn: Binding(
                            get: { viewModel.usbStatus.powerbankActive },
                            set: { newValue in
                                Task {
                                    if newValue {
                                        await viewModel.enablePowerbank()
                                    } else {
                                        await viewModel.disablePowerbank()
                                    }
                                }
                            }
                        )
                    )
                    .disabled(viewModel.isLoading || !viewModel.usbStatus.showsPowerControl)
                }
            } footer: {
                Text(
                    "When enabled, the U60 Pro battery will charge your connected device. This will drain the router's battery faster."
                )
            }
        }
        .task { await viewModel.refresh() }
        .navigationTitle("USB Mode")
        .operationStatus(message: viewModel.message, isError: viewModel.messageIsError, isLoading: viewModel.isLoading)
    }
}

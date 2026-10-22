import SwiftUI

struct USBPowerControl: View {
    @Bindable var viewModel: USBConnectionViewModel
    @State private var showReserve = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label("Charge phone", systemImage: "bolt.fill").font(.subheadline)
                Button { showReserve = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.subheadline).padding(6)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("USB power reserve")
                .accessibilityIdentifier("usb-power-reserve")
                Spacer(minLength: 0)
                if viewModel.isLoading { ProgressView().controlSize(.mini) }
                Toggle("Charge phone",
                isOn: Binding(
                    get: { viewModel.usbStatus.powerbankActive },
                    set: { enabled in
                        Task {
                            if enabled { await viewModel.enablePowerbank() } else { await viewModel.disablePowerbank() }
                        }
                    })
                )
                .labelsHidden()
                .disabled(viewModel.isLoading)
                .accessibilityIdentifier("usb-charge-phone")
            }
            if let stop = viewModel.powerReserve?.stopText {
                Text(stop).font(.caption).foregroundStyle(.secondary)
            }
            if viewModel.messageIsError, let message = viewModel.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showReserve) {
            NavigationStack { USBPowerReserveSettings(viewModel: viewModel, presented: true) }
        }
    }
}

struct USBPowerReserveSettings: View {
    @Bindable var viewModel: USBConnectionViewModel
    var presented = false
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var keepBattery = false
    @State private var batteryPercent = 20
    @State private var keepRuntime = false
    @State private var runtimeMinutes = 120

    private var policy: USBPowerReservePolicy {
        .init(minCapacityPercent: keepBattery ? batteryPercent : nil,
              reserveMinutes: keepRuntime ? runtimeMinutes : nil)
    }

    var body: some View {
        Form {
            if let error = viewModel.reserveError {
                Section { Text(error).foregroundStyle(.red) }
            }
            if loaded {
                Section {
                    Toggle("Keep battery reserve", isOn: $keepBattery)
                    if keepBattery {
                        Stepper(value: $batteryPercent, in: 1...100) {
                            LabeledContent("Minimum battery", value: "\(batteryPercent)%")
                        }
                        .accessibilityIdentifier("usb-reserve-battery")
                    }
                    Toggle("Reserve router runtime", isOn: $keepRuntime)
                    if keepRuntime {
                        Stepper(value: $runtimeMinutes, in: 15...2880, step: 15) {
                            LabeledContent("Keep for router", value: duration(runtimeMinutes))
                        }
                        .accessibilityIdentifier("usb-reserve-runtime")
                    }
                } footer: {
                    Text("USB output stops when either reserve is reached. The router enforces these limits even when this App is closed. Output stays off until you turn it on again.")
                }
                if keepRuntime {
                    Section {
                        LabeledContent("Remaining runtime", value: viewModel.powerReserve?.runtimeText ?? "—")
                        if let load = viewModel.powerReserve?.routerLoadW {
                            LabeledContent("Measured router load", value: String(format: "%.1f W", load))
                        }
                        if viewModel.powerReserve?.baselineReady != true {
                            Text("After saving, leave USB output off for at least 10 seconds to measure the router's own load.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text("Router-only estimate") } footer: {
                        Text("Runtime is estimated from load measured before USB output starts. Network activity can change it. Output cannot start, or stops, if a reliable estimate is unavailable.")
                    }
                }
                if let stop = viewModel.powerReserve?.stopText {
                    Section { Text(stop).foregroundStyle(.secondary) }
                }
            } else if viewModel.reserveError == nil {
                Section { ProgressView("Loading power reserve…") }
            } else {
                Section {
                    Button("Retry") { Task { await load() } }
                    if viewModel.powerReserve != nil {
                        Button("Replace unreadable settings") { loaded = true }
                    }
                }
            }
        }
        .navigationTitle("Power reserve")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presented {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        if await viewModel.savePowerReserve(policy) {
                            await viewModel.refresh()
                            dismiss()
                        }
                    }
                }
                .disabled(!loaded || viewModel.isLoading)
            }
        }
        .task { await load() }
    }

    private func load() async {
        await viewModel.loadPowerReserve()
        guard let stored = viewModel.powerReserve?.policy else { return }
        keepBattery = stored.minCapacityPercent != nil
        batteryPercent = stored.minCapacityPercent ?? 20
        keepRuntime = stored.reserveMinutes != nil
        runtimeMinutes = stored.reserveMinutes ?? 120
        loaded = true
    }

    private func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

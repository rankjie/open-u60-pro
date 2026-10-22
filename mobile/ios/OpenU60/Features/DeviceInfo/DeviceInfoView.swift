import SwiftUI

struct DeviceInfoView: View {
    var viewModel: DeviceInfoViewModel

    var body: some View {
        List {
            Section("Device") {
                infoRow("IMEI", viewModel.identity.imei)
            }

            Section("Network") {
                roamingRow
                signalBarsRow
            }

            Section("WAN") {
                infoRow("IPv4", viewModel.identity.wanIPv4)
                ForEach(viewModel.identity.wanIPv6, id: \.self) { addr in
                    infoRow("IPv6", addr)
                }
                if viewModel.identity.wanIPv6.isEmpty {
                    infoRow("IPv6", "")
                }
            }

            Section("LAN") {
                infoRow("Gateway", viewModel.identity.lanIP)
            }
        }
        .navigationTitle("Device Info")
        .refreshable { await viewModel.refresh() }
        .operationStatus(message: nil, isError: false, isLoading: viewModel.isLoading)
        .task(id: viewModel.identityRevision) { await viewModel.refresh() }
    }

    // MARK: - Rows

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "--" : value)
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private var roamingRow: some View {
        let roaming = viewModel.operatorInfo.roaming
        return HStack {
            Text("Roaming")
                .foregroundStyle(.secondary)
            Spacer()
            Text(roaming ? "Roaming" : "Home")
                .font(.body.monospacedDigit())
                .foregroundStyle(roaming ? .orange : .green)
        }
    }

    private var signalBarsRow: some View {
        // The same RSRP thresholds as Home and the Live Activity.
        let rsrp = viewModel.servingRSRP
        let bars = Color.signalBars(rsrp)
        return HStack {
            Text("Signal")
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "cellularbars", variableValue: Double(bars) / 4)
                .foregroundStyle(rsrp == nil ? .secondary : Color.rsrpColor(rsrp))
                .accessibilityLabel("\(bars) of 4 bars")
            Text(rsrp.map { "\(Int($0.rounded())) dBm" } ?? "—")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }
}

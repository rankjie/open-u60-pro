import SwiftUI

struct OperatorCardView: View, Equatable {
    let operatorInfo: OperatorInfo
    let nrSignal: NRSignal
    let lteSignal: LTESignal
    var padding: CGFloat = 16

    private var displayType: String {
        operatorInfo.networkType.isEmpty
            ? "--"
            : operatorInfo.displayNetworkType(nrConnected: nrSignal.isConnected, lteSignal: lteSignal)
    }

    var body: some View {
        CardView(padding: padding) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(operatorInfo.provider.isEmpty ? "No Operator" : operatorInfo.provider)
                        .font(.headline)
                    Text(displayType)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if operatorInfo.roaming {
                    Label("Roaming", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                NetworkTypeIcon(networkType: displayType)
                // The same RSRP thresholds as Home, so the bar count agrees everywhere.
                let bars = Color.signalBars(nrSignal.isConnected ? nrSignal.rsrp : lteSignal.rsrp)
                Image(systemName: "cellularbars", variableValue: Double(bars) / 4)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(bars > 0 ? .primary : .secondary)
                    .accessibilityLabel(Text("Signal"))
                    .accessibilityValue(Text("\(bars) of 4 bars"))
            }
        }
    }
}

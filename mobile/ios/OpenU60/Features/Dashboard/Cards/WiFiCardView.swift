import SwiftUI

struct WiFiCardView: View {
    let wifiStatus: WifiStatus
    let internetStatus: WiFiInternetStatus?
    let internetStatusError: String?
    @Binding var showWiFiShare: Bool

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Wi-Fi")
                        .font(.headline)
                    if wifiStatus.wifiOn && wifiStatus.wifi6 {
                        Text("WiFi 7")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                    if wifiStatus.wifiOn && wifiStatus.clientsTotal > 0 {
                        HStack(spacing: 2) {
                            AnimatedNumber(value: wifiStatus.clientsTotal,
                                           font: .caption2, textColor: .secondary)
                            Text("client\(wifiStatus.clientsTotal == 1 ? "" : "s")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                if wifiStatus.wifiOn {
                    Button(showWiFiShare ? "Hide sharing code" : "Share Wi-Fi", systemImage: "qrcode") {
                        withAnimation { showWiFiShare.toggle() }
                    }
                    .font(.subheadline)
                    .padding(.vertical, 4)
                }
                wifiBandRow(
                    band: .two,
                    disabled: !wifiStatus.wifiOn || wifiStatus.radio2gDisabled,
                    ssid: wifiStatus.ssid2g,
                    hidden: wifiStatus.hidden2g,
                    encryption: wifiStatus.encryption2g,
                    channel: wifiStatus.channel2g
                )
                Divider()
                wifiBandRow(
                    band: .five,
                    disabled: !wifiStatus.wifiOn || wifiStatus.radio5gDisabled,
                    ssid: wifiStatus.ssid5g,
                    hidden: wifiStatus.hidden5g,
                    encryption: wifiStatus.encryption5g,
                    channel: wifiStatus.channel5g
                )
                if let internetStatusError {
                    Text(internetStatusError).font(.caption).foregroundStyle(.red)
                }
                if wifiStatus.wifiOn && wifiStatus.guestEnabled {
                    HStack {
                        Label("Guest", systemImage: "person.2")
                            .font(.caption)
                        Spacer()
                        Text(wifiStatus.guestSsid)
                            .font(.caption.bold())
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func wifiBandRow(
        band: WiFiInternetBand, disabled: Bool, ssid: String, hidden: Bool,
        encryption: String, channel: String
    ) -> some View {
        let upstream = internetStatus.flatMap { $0.config.mode == .repeater && $0.config.band == band ? $0 : nil }
        // Repeater mode runs the downstream AP outside the saved hotspot radio switches.
        let hotspotDisabled = disabled && internetStatus?.config.mode != .repeater
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(band.label, systemImage: "wifi").font(.caption)
                Spacer()
                if upstream != nil {
                    Text("Upstream").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                } else if hotspotDisabled {
                    Text(internetStatus == nil ? (internetStatusError == nil ? "Checking role…" : "Role unavailable") : "Disabled")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Hotspot").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if let upstream {
                HStack {
                    Text(upstream.config.ssid).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(internetStatusError == nil ? upstream.label : "Status unavailable")
                        .font(.caption)
                        .foregroundStyle(internetStatusError == nil && upstream.label == "Online" ? .green : .secondary)
                }
            } else if !hotspotDisabled {
                HStack {
                    if hidden {
                        Text("(Hidden)").font(.caption2).foregroundStyle(.orange)
                    }
                    if !ssid.isEmpty {
                        Text(ssid).font(.subheadline.weight(.medium)).lineLimit(1)
                    }
                    Spacer()
                    if !encryption.isEmpty {
                        Text(encryption).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !channel.isEmpty {
                        Text("CH \(channel)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

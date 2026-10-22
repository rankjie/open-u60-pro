import SwiftUI

// Home's glanceable layer. Each view reads only the view-model properties it draws, so one
// changing reading re-renders one tile (see the observation-scope note in DashboardView).

/// Internet source and live throughput: the first thing Home answers.
struct InternetHero: View {
    let viewModel: DashboardViewModel
    let internet: WiFiInternetViewModel
    let openInternet: () -> Void
    let openTraffic: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: openInternet) { source.contentShape(.rect) }
                .buttonStyle(TileButtonStyle())
                .accessibilityHint("Opens internet source settings")
                .accessibilityIdentifier("internet-overview")
            Button(action: openTraffic) { HeroTraffic(viewModel: viewModel).contentShape(.rect) }
                .buttonStyle(TileButtonStyle())
                .accessibilityHint("Opens live traffic details")
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: Design.corner))
    }

    private var source: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.semibold)).lineLimit(1)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 8)
            StatusLabel(text: state.text, color: state.color)
        }
        .accessibilityElement(children: .combine)
    }

    /// The live source, or the one restored with the snapshot while the first status loads.
    private var config: WiFiInternetConfig? { internet.status?.config ?? viewModel.restoredInternetConfig }
    private var repeater: Bool { config?.mode == .repeater }

    private var title: String {
        if repeater, let ssid = config?.ssid, !ssid.isEmpty { return ssid }
        // The carrier names the Signal tile; the source here is the cellular link itself.
        return "Cellular"
    }

    private var detail: String? {
        if repeater { return config.map { "Repeater · \($0.band.label)" } }
        let info = viewModel.operatorInfo
        guard !info.networkType.isEmpty else { return nil }
        return info.displayNetworkType(nrConnected: viewModel.nrSignal.isConnected, lteSignal: viewModel.lteSignal)
            + (info.roaming ? " · Roaming" : "")
    }

    private var state: (text: String, color: Color) {
        if internet.refreshError != nil && internet.status == nil { return ("Unknown", .secondary) }
        if let status = internet.status, status.config.mode == .repeater {
            if status.phase == "failed" { return ("Failed", .red) }
            return (status.label, status.connectivity == "online" ? .green : .orange)
        }
        if viewModel.isAirplaneMode { return ("Airplane", .orange) }
        if viewModel.isMobileDataOff { return ("Data off", .orange) }
        if !viewModel.wanIPv4.isEmpty || !viewModel.wanIPv6.isEmpty {
            // A restored or stale reading is not a live claim.
            let current = viewModel.lastUpdated.map { Date().timeIntervalSince($0) < 15 } == true
            return ("Online", current ? .green : .secondary)
        }
        return viewModel.lastUpdated == nil ? ("Checking", .secondary) : ("No data", .secondary)
    }
}

private struct HeroTraffic: View {
    let viewModel: DashboardViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fresh = viewModel.isTrafficAvailable
                && viewModel.trafficUpdatedAt.map { context.date.timeIntervalSince($0) < 5 } == true
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    direction("arrow.down", .blue, fresh ? viewModel.speed.downloadBytesPerSec : nil)
                    direction("arrow.up", .teal, fresh ? viewModel.speed.uploadBytesPerSec : nil)
                }
                TrafficHistoryChart(viewModel: viewModel, fresh: fresh)
                if !fresh {
                    Text(CellularCardView.caption(updatedAt: viewModel.trafficUpdatedAt, available: viewModel.isTrafficAvailable,
                                                  source: viewModel.trafficStats.source, now: context.date))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func direction(_ icon: String, _ tint: Color, _ value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon).font(.subheadline.weight(.bold)).foregroundStyle(tint)
            LiveTrafficValue(bytesPerSecond: value, sampleInterval: viewModel.trafficSampleInterval,
                             font: Design.value(.title))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// The last minute of measured throughput; shows nothing while samples are stale.
struct TrafficHistoryChart: View {
    let viewModel: DashboardViewModel
    let fresh: Bool
    var height: CGFloat = 44
    var showsPeak = false

    var body: some View {
        let history = fresh ? viewModel.speedHistory : []
        let down = history.map(\.downloadBytesPerSec), up = history.map(\.uploadBytesPerSec)
        // At least 1 Mb/s of scale, so an idle link's few bytes draw flat instead of as peaks.
        let ceiling = max(down.max() ?? 0, up.max() ?? 0, 125_000)
        let slots = DashboardViewModel.speedHistoryLimit
        ZStack(alignment: .topLeading) {
            Sparkline(values: down, ceiling: ceiling, area: true, capacity: slots)
                .fill(LinearGradient(colors: [.blue.opacity(0.22), .blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            Sparkline(values: down, ceiling: ceiling, capacity: slots)
                .stroke(.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            Sparkline(values: up, ceiling: ceiling, capacity: slots)
                .stroke(.teal.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            if showsPeak, let top = (down + up).max(), top > 0 {
                let peak = DeviceParser.speedComponents(top)
                Text("Peak \(peak.number, specifier: "%.\(peak.decimalPlaces)f") \(peak.unit.trimmingCharacters(in: .whitespaces)) · last \(history.count)s")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(height: height)
        .background(alignment: .bottom) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5) }
        .accessibilityHidden(true)
    }
}

struct SignalTile: View {
    let viewModel: DashboardViewModel
    let action: () -> Void

    var body: some View {
        let nr = viewModel.nrSignal, lte = viewModel.lteSignal
        let rsrp = nr.isConnected ? nr.rsrp : lte.rsrp
        let sinr = nr.isConnected ? nr.sinr : lte.sinr
        let band = nr.isConnected ? nr.band.bandLabel(prefix: "n") : lte.band.bandLabel(prefix: "B")
        let provider = viewModel.operatorInfo.provider
        Tile(title: provider.isEmpty ? "Signal" : provider, icon: viewModel.isAirplaneMode ? "airplane" : "cellularbars", tint: Color.rsrpColor(rsrp),
             level: viewModel.isAirplaneMode ? nil : Double(Color.signalBars(rsrp)) / 4, action: action) {
            if viewModel.isAirplaneMode {
                Metric(value: "Off")
                Facts("Airplane mode")
            } else {
                Metric(value: rsrp.map { "\(Int($0.rounded()))" }, unit: "dBm")
                Facts(sinr.map { "SINR \(Int($0.rounded()))" }, band, qos)
            }
        }
        .accessibilityIdentifier("home-signal")
    }

    /// 5G SA sessions name their QoS class 5QI; LTE and NSA bearers call it QCI.
    private var qos: String? {
        guard let qci = viewModel.bearer?.qci else { return nil }
        let sa = SignalActivityMode(networkType: viewModel.operatorInfo.networkType, lteCarrierCount: nil) == .sa
        return "\(sa ? "5QI" : "QCI") \(qci)"
    }
}

struct BatteryTile: View {
    let viewModel: DashboardViewModel
    let usb: USBConnectionViewModel
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let battery = viewModel.battery
            let age = viewModel.batteryUpdatedAt.map { context.date.timeIntervalSince($0) }
            let stale = age.map { $0 >= 10 } ?? true
            Tile(title: "Battery", icon: icon(battery), tint: stale ? .secondary : Color.batteryColor(battery.capacity),
                 action: action) {
                Metric(value: battery.capacityPercent.map { "\($0)" }, unit: "%",
                       color: stale ? .secondary : .primary)
                if stale {
                    Facts(age.map { "Updated \(Self.ago($0))" } ?? "No recent data")
                } else {
                    // Power flow: USB input when external power is present, then what the battery
                    // itself takes (+) or gives (draw), then runtime while discharging.
                    let input = battery.usbPower.externalPower == true
                        ? battery.usbPower.inputWatts.map { String(format: "In %.1f W", $0) } : nil
                    let watts = battery.powerWatts.flatMap { abs($0) >= 0.05 ? $0 : nil }
                    let flow = watts.map { $0 > 0 ? String(format: "+%.1f W", $0) : String(format: "Draw %.1f W", -$0) }
                    let discharging = (watts ?? 0) < 0
                    if usb.usbStatus.powerbankActive {
                        Facts("Powering USB", flow)
                    } else if discharging {
                        Facts(flow, battery.runtimeText == "—" ? nil : battery.runtimeText)
                    } else if watts != nil {
                        Facts(input, flow)
                    } else {
                        Facts(battery.statusText == "Unavailable" ? nil : battery.statusText, input)
                    }
                }
            }
        }
        .accessibilityIdentifier("home-battery")
    }

    private func icon(_ battery: BatteryStatus) -> String {
        if battery.charging == "charging" { return "battery.100percent.bolt" }
        switch battery.capacityPercent ?? 0 {
        case 75...: return "battery.100percent"
        case 50..<75: return "battery.75percent"
        case 25..<50: return "battery.50percent"
        case 10..<25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let value = Int(seconds)
        if value < 60 { return "\(value)s ago" }
        if value < 3600 { return "\(value / 60)m ago" }
        return "\(value / 3600)h ago"
    }
}

struct DevicesTile: View {
    let viewModel: DashboardViewModel
    let action: () -> Void

    var body: some View {
        let wifi = viewModel.wifiStatus
        let ssid = wifi.ssid5g.isEmpty ? wifi.ssid2g : wifi.ssid5g
        Tile(title: "Devices", icon: "laptopcomputer.and.iphone", action: action) {
            Metric(value: viewModel.lastUpdated == nil ? nil : "\(viewModel.connectedDevices.count)")
            Facts(wifi.wifiOn ? ssid : (viewModel.lastUpdated == nil ? nil : "Wi-Fi off"))
        }
        .accessibilityIdentifier("home-devices")
    }
}

struct SystemTile: View {
    let viewModel: DashboardViewModel
    let action: () -> Void

    var body: some View {
        let cpu = viewModel.cpuUpdatedAt == nil ? nil : viewModel.systemInfo.cpuUsagePercent
        Tile(title: "CPU", icon: "cpu", tint: cpu.map { $0 >= 80 ? .red : .secondary } ?? .secondary, action: action) {
            Metric(value: cpu.map { String(format: "%.0f", $0) }, unit: "%")
            Facts(viewModel.thermal.cpuTemp.map { String(format: "%.0f °C", $0) })
        }
        .accessibilityIdentifier("home-system")
    }
}

extension String {
    /// "78", "n78" or "NR5G BAND 78" → "n78"; text without a number is left alone.
    func bandLabel(prefix: String) -> String? {
        // Firmware reports "78", "n78" or "LTE BAND 3"; the number is what identifies the band.
        guard let digits = split(whereSeparator: { !$0.isNumber }).last else { return isEmpty ? nil : self }
        return prefix + digits
    }
}

/// The newest unread thread, straight from inbox state; a push delivery
/// shows here without a refresh.
struct LatestMessageTile: View {
    let messages: SMSViewModel
    let open: (String) -> Void

    var body: some View {
        // Home only surfaces messages that still need attention.
        if let conversation = messages.conversations.first(where: { $0.unreadCount > 0 }) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let latest = conversation.messages.last
                let code = latest.flatMap { $0.tag.isIncoming && context.date.timeIntervalSince($0.date) < 86400
                    ? SMSParser.verificationCode(in: $0.content) : nil }
                let unread = messages.unreadCount
                Tile(title: "\(unread) unread", icon: "message.fill", tint: .blue, action: { open(conversation.id) }) {
                    HStack(alignment: .top, spacing: 10) {
                        ContactAvatar(number: conversation.number, name: conversation.brand, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(conversation.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(SMSTimestamp.short(conversation.latestTime, now: context.date))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(conversation.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let code { CodeChip(code: code).padding(.top, 9).padding(.trailing, 12) }
                }
            }
            .accessibilityIdentifier("home-latest-message")
        }
    }
}

/// Regular width (the unfolded Duo, iPad) has room for lists that compact width only links to.
struct HomeWidePanels: View {
    let viewModel: DashboardViewModel
    let messages: SMSViewModel
    let openDevices: () -> Void
    let openConversation: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Design.gap) {
            panel(title: "Devices", icon: "laptopcomputer.and.iphone", action: openDevices) {
                let devices = viewModel.connectedDevices.prefix(6)
                if devices.isEmpty {
                    Text(viewModel.lastUpdated == nil ? "Loading…" : "No devices connected")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { Divider() }
                    HStack {
                        Text(device.displayName).font(.subheadline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(device.ipAddress).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                }
            }
            panel(title: "Recent messages", icon: "message", action: nil) {
                let recent = messages.conversations.prefix(3)
                if recent.isEmpty {
                    Text("No messages").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, conversation in
                    if index > 0 { Divider() }
                    Button { openConversation(conversation.id) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            ContactAvatar(number: conversation.number, name: conversation.brand, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack {
                                    Text(conversation.displayName)
                                        .font(.subheadline.weight(conversation.unreadCount > 0 ? .semibold : .regular))
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(SMSTimestamp.short(conversation.latestTime, now: .now))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(conversation.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 7)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func panel<Content: View>(title: String, icon: String, action: (() -> Void)?,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).imageScale(.small)
                Text(title)
                Spacer()
                if let action {
                    Button("Show all", action: action).font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: Design.corner))
    }
}

/// Where the app reaches U60, and the data age only when it is no longer current.
struct HomeFooter: View {
    let viewModel: DashboardViewModel
    let icon: String
    let label: String
    let color: Color
    let description: String
    let action: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let age = viewModel.lastUpdated.map { context.date.timeIntervalSince($0) }
            Button(action: action) {
                VStack(spacing: 4) {
                    if let error = viewModel.error, (age ?? .infinity) >= 10 {
                        Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                        Text(label)
                        if let age, age >= 10 { Text("· Updated \(BatteryTile.ago(age))") }
                    }
                    .foregroundStyle(color)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Router connection")
            .accessibilityValue(description)
            .accessibilityHint("Opens connection details")
            .accessibilityIdentifier("dashboard-router-connection")
        }
    }
}

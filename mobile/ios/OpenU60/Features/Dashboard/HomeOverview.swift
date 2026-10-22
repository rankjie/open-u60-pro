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
        VStack(alignment: .leading, spacing: 0) {
            Button(action: openInternet) { source.contentShape(.rect) }
                .buttonStyle(TileButtonStyle())
                .accessibilityHint("Opens internet source settings")
                .accessibilityIdentifier("internet-overview")
            Divider().padding(.vertical, 12)
            Button(action: openTraffic) { HeroTraffic(viewModel: viewModel).contentShape(.rect) }
                .buttonStyle(TileButtonStyle())
                .accessibilityHint("Opens live traffic details")
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: Design.corner))
    }

    private var source: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: repeater ? "wifi" : "antenna.radiowaves.left.and.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Facts(internet.status?.sourceLabel ?? "Internet", detail)
            }
            Spacer(minLength: 8)
            StatusLabel(text: state.text, color: state.color)
        }
        .accessibilityElement(children: .combine)
    }

    private var repeater: Bool { internet.status?.config.mode == .repeater }

    private var title: String {
        if repeater, let ssid = internet.status?.config.ssid, !ssid.isEmpty { return ssid }
        let provider = viewModel.operatorInfo.provider
        return provider.isEmpty ? "U60" : provider
    }

    private var detail: String? {
        if repeater { return internet.status.map { "\($0.config.band.label) upstream" } }
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
        if !viewModel.wanIPv4.isEmpty || !viewModel.wanIPv6.isEmpty { return ("Online", .green) }
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
                chart(fresh: fresh)
                Text(CellularCardView.caption(updatedAt: viewModel.trafficUpdatedAt, available: viewModel.isTrafficAvailable,
                                              source: viewModel.trafficStats.source, now: context.date))
                    .font(.caption2).foregroundStyle(.secondary)
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

    @ViewBuilder private func chart(fresh: Bool) -> some View {
        let history = fresh ? viewModel.speedHistory : []
        let down = history.map(\.downloadBytesPerSec), up = history.map(\.uploadBytesPerSec)
        let ceiling = max(down.max() ?? 0, up.max() ?? 0)
        let slots = DashboardViewModel.speedHistoryLimit
        ZStack {
            Sparkline(values: down, ceiling: ceiling, area: true, capacity: slots)
                .fill(LinearGradient(colors: [.blue.opacity(0.22), .blue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            Sparkline(values: down, ceiling: ceiling, capacity: slots)
                .stroke(.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            Sparkline(values: up, ceiling: ceiling, capacity: slots)
                .stroke(.teal.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 44)
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
        Tile(title: "Signal", icon: "antenna.radiowaves.left.and.right", tint: Color.rsrpColor(rsrp), action: action) {
            if viewModel.isAirplaneMode {
                Metric(value: "Off")
                Facts("Airplane mode")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Metric(value: rsrp.map { "\(Int($0.rounded()))" }, unit: "dBm")
                    Spacer(minLength: 4)
                    LevelBars(level: Color.signalBars(rsrp), color: Color.rsrpColor(rsrp))
                }
                Facts(rsrp.map { _ in Color.rsrpQuality(rsrp) }, sinr.map { "SINR \(Int($0.rounded()))" }, band)
            }
        }
        .accessibilityIdentifier("home-signal")
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
                HStack(alignment: .firstTextBaseline) {
                    Metric(value: battery.capacityPercent.map { "\($0)" }, unit: "%",
                           color: stale ? .secondary : .primary)
                    Spacer(minLength: 4)
                    if !stale, battery.powerWatts != nil {
                        Text(battery.powerText).font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle((battery.powerWatts ?? 0) > 0.05 ? .green : .secondary)
                    }
                }
                if stale {
                    Facts(age.map { "Updated \(Self.ago($0))" } ?? "No recent data")
                } else {
                    Facts(usb.usbStatus.powerbankActive ? "Powering USB" : battery.statusText,
                          battery.usbPower.externalPower == true ? nil : battery.runtimeText == "—" ? nil : battery.runtimeText)
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
        Tile(title: "Devices", icon: "laptopcomputer.and.iphone", tint: .blue, action: action) {
            Metric(value: viewModel.lastUpdated == nil ? nil : "\(viewModel.connectedDevices.count)",
                   unit: viewModel.connectedDevices.count == 1 ? "device" : "devices")
            Facts(wifi.wifiOn ? ssid : (viewModel.lastUpdated == nil ? nil : "Wi-Fi off"),
                  wifi.guestEnabled ? "Guest on" : nil)
        }
        .accessibilityIdentifier("home-devices")
    }
}

struct SystemTile: View {
    let viewModel: DashboardViewModel
    let action: () -> Void

    var body: some View {
        let system = viewModel.systemInfo
        let cpu = viewModel.cpuUpdatedAt == nil ? nil : system.cpuUsagePercent
        Tile(title: "System", icon: "cpu", tint: cpu.map(Color.cpuUsageColor) ?? .secondary, action: action) {
            Metric(value: cpu.map { String(format: "%.0f", $0) }, unit: "% CPU")
            Facts(viewModel.thermal.cpuTemp.map { String(format: "%.0f °C", $0) },
                  system.uptime > 0 ? "up \(Self.uptime(system.uptime))" : nil)
        }
        .accessibilityIdentifier("home-system")
    }

    static func uptime(_ seconds: Int) -> String {
        let days = seconds / 86400, hours = seconds % 86400 / 3600
        if days > 0 { return "\(days)d \(hours)h" }
        return hours > 0 ? "\(hours)h \(seconds % 3600 / 60)m" : "\(seconds / 60)m"
    }
}

extension String {
    /// "78" → "n78"; an already-labelled or empty band is left alone.
    func bandLabel(prefix: String) -> String? {
        guard !isEmpty else { return nil }
        return allSatisfy(\.isNumber) ? prefix + self : self
    }
}

/// The newest unread thread, or the newest thread, straight from inbox state; a push delivery
/// shows here without a refresh.
struct LatestMessageTile: View {
    let messages: SMSViewModel
    let open: (String) -> Void

    var body: some View {
        let conversations = messages.conversations
        if let conversation = conversations.first(where: { $0.unreadCount > 0 }) ?? conversations.first {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let latest = conversation.messages.last
                let code = latest.flatMap { $0.tag.isIncoming && context.date.timeIntervalSince($0.date) < 86400
                    ? SMSParser.verificationCode(in: $0.content) : nil }
                let unread = messages.unreadCount
                Tile(title: unread > 0 ? "\(unread) unread" : "Messages", icon: "message.fill",
                     tint: unread > 0 ? .blue : .secondary, action: { open(conversation.id) }) {
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
                    if let code { CodeChip(code: code).padding(.top, 9).padding(.trailing, 36) }
                }
            }
            .accessibilityIdentifier("home-latest-message")
        }
    }
}

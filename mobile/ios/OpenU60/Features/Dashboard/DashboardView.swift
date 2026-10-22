import SwiftUI

struct DashboardView: View {
    var viewModel: DashboardViewModel
    let isAuthenticated: Bool
    let client: AgentClient
    let authManager: AuthManager
    let usbViewModel: USBConnectionViewModel

    @State private var signalMonitorVM: SignalMonitorViewModel?
    @State private var networkModeVM: NetworkModeViewModel?
    @State private var detail: DashboardDetail?
    @State private var showCPUDetails = false
    @State private var showAllDevices = true
    @State private var showWiFiShare = false
    @Environment(AppModel.self) private var app
    private var internetModel: WiFiInternetViewModel { app.device.internet }

    init(viewModel: DashboardViewModel, isAuthenticated: Bool, client: AgentClient, authManager: AuthManager, usbViewModel: USBConnectionViewModel) {
        self.viewModel = viewModel
        self.isAuthenticated = isAuthenticated
        self.client = client
        self.authManager = authManager
        self.usbViewModel = usbViewModel
    }

    var body: some View {
        let banners = bannerConfigs
        NavigationStack {
            ScrollView {
                // Keep summary view identities stable while samples update and sheets open.
                VStack(spacing: 12) {
                    if usbViewModel.usbStatus.showsPowerControl { USBPowerControl(viewModel: usbViewModel) }
                    ForEach(banners) { config in
                        SIMAlertBanner(config: config)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Button { detail = .internet } label: {
                        InternetOverview(model: internetModel)
                    }
                    .buttonStyle(.plain)
                    Button { detail = .traffic } label: {
                        CellularCardScope(viewModel: viewModel, compact: true)
                    }
                    .buttonStyle(.plain)
                    CardView(padding: 0) {
                        VStack(spacing: 0) {
                            Button { detail = .wifi } label: {
                                WiFiOverview(viewModel: viewModel)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 52)
                            Button { detail = .health } label: {
                                HealthOverview(viewModel: viewModel)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { detail = .battery } label: {
                        BatteryOverviewScope(viewModel: viewModel, usbViewModel: usbViewModel)
                    }
                    .buttonStyle(.plain)
                    DashboardUpdateStatus(viewModel: viewModel)
                }
                .padding()
                .animation(.easeInOut, value: banners)
            }
            .background(Color(.systemGroupedBackground))
            .task {
                if signalMonitorVM == nil {
                    signalMonitorVM = SignalMonitorViewModel(client: client, authManager: authManager)
                }
                if networkModeVM == nil {
                    networkModeVM = NetworkModeViewModel(client: client, authManager: authManager)
                }
            }
            .sheet(item: $detail) { selected in
                dashboardDetail(selected)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await viewModel.refresh() }
            .onChange(of: client.connectionRoute) { _, route in
                guard route == .local || route == .p2p || route == .relay else { return }
                Task {
                    async let dashboard: Void = viewModel.refresh()
                    async let usb = usbViewModel.refresh()
                    _ = await (dashboard, usb)
                }
            }
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) { connectionIndicator }
                        .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .topBarTrailing) {
                        CellularStatusButton(viewModel: viewModel) { detail = .connection }
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .topBarTrailing) {
                        BatteryStatusButton(viewModel: viewModel) { detail = .battery }
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { connectionIndicator }
                    ToolbarItem(placement: .topBarTrailing) {
                        CellularStatusButton(viewModel: viewModel) { detail = .connection }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        BatteryStatusButton(viewModel: viewModel) { detail = .battery }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dashboardDetail(_ selected: DashboardDetail) -> some View {
        switch selected {
        case .routerConnection:
            NavigationStack {
                RouterConnectionDetail(client: client, internetModel: internetModel,
                    connectionLabel: connectionLabel, connectionDescription: connectionDescription)
            }
        case .internet:
            NavigationStack {
                WiFiInternetView(client: client, authManager: authManager)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } }
            }
        case .battery:
            BatteryDetailScope(viewModel: viewModel)
        case .health:
            NavigationStack {
                ScrollView {
                    VStack(spacing: 12) {
                        CPUCardScope(viewModel: viewModel)
                        Button("CPU, memory & processes") { showCPUDetails = true }
                        TemperatureCardScope(viewModel: viewModel)
                    }.padding()
                }
                .background(Color(.systemGroupedBackground))
                .sheet(isPresented: $showCPUDetails) {
                    CPUDetailScope(viewModel: viewModel, client: client)
                        .presentationDragIndicator(.visible)
                }
                .navigationTitle("CPU & temperatures")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } }
            }
        case .connection:
            NavigationStack {
                if let signalMonitorVM {
                    ConnectionSignalDetail(dashboard: viewModel, viewModel: signalMonitorVM,
                                           networkModeViewModel: networkModeVM)
                } else {
                    ProgressView("Loading connection details…")
                }
            }
        case .traffic, .wifi:
            NavigationStack {
                ScrollView {
                    VStack(spacing: 12) {
                        if selected == .traffic {
                            CellularCardScope(viewModel: viewModel)
                            Text("These speeds show current cellular traffic across all connected devices. A speed test reports throughput over its test period; the live numbers change throughout that period.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            WiFiCardScope(viewModel: viewModel, internetModel: internetModel,
                                          showWiFiShare: $showWiFiShare)
                            if showWiFiShare {
                                WiFiShareCardScope(viewModel: viewModel, client: client,
                                    authManager: authManager, isExpanded: $showWiFiShare)
                            }
                            DevicesCardScope(viewModel: viewModel, showAllDevices: $showAllDevices)
                        }
                    }.padding()
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle(selected.rawValue)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detail = nil } } }
                .task { if selected == .wifi { await viewModel.refresh() } }
            }
        }
    }

    private var bannerConfigs: [SIMAlertBanner.Config] {
        var configs: [SIMAlertBanner.Config] = []
        if viewModel.simPukRequired {
            configs.append(SIMAlertBanner.Config(
                id: "puk",
                icon: "exclamationmark.lock.fill",
                title: "SIM PUK Required",
                message: "Too many wrong PIN attempts. Open Settings → Cellular & SIM → SIM card to enter your PUK.",
                color: .red
            ))
        }
        if viewModel.simPinRequired {
            configs.append(SIMAlertBanner.Config(
                id: "pin",
                icon: "lock.fill",
                title: "SIM PIN Required",
                message: "Your SIM card is locked. Open Settings → Cellular & SIM → SIM card to enter your PIN.",
                color: .orange
            ))
        }
        if viewModel.isAirplaneMode {
            configs.append(SIMAlertBanner.Config(
                id: "airplane",
                icon: "airplane",
                title: "Airplane Mode",
                message: "Cellular radio is off. The modem is powered down — no signal or data.",
                color: .blue
            ))
        }
        if viewModel.isMobileDataOff && !viewModel.isAirplaneMode {
            configs.append(SIMAlertBanner.Config(
                id: "data",
                icon: "antenna.radiowaves.left.and.right.slash",
                title: "Mobile Data Off",
                message: "Cellular radio is on but data is disabled. Open Settings → Cellular & SIM → Mobile data to enable it.",
                color: .orange
            ))
        }
        return configs
    }

    private var connectionIndicator: some View {
        Button { detail = .routerConnection } label: {
            HStack(spacing: 6) {
                if isAuthenticated && client.connectionRoute == .connecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: connectionIcon)
                }
                Text(connectionLabel)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(connectionColor)
            .fixedSize()
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Router connection")
        .accessibilityValue(connectionDescription)
        .accessibilityHint("Opens connection details")
        .accessibilityIdentifier("dashboard-router-connection")
    }

    private var connectionIcon: String {
        guard isAuthenticated else { return "wifi.exclamationmark" }
        switch client.connectionRoute {
        case .local: return "wifi"
        case .p2p: return "point.3.connected.trianglepath.dotted"
        case .relay: return "globe"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .unavailable: return "wifi.exclamationmark"
        }
    }

    private var connectionDescription: String {
        guard isAuthenticated else { return "U60 is offline" }
        switch client.connectionRoute {
        case .local: return "Connected directly to U60 on the local network"
        case .p2p: return "Connected directly to U60 over an encrypted P2P connection"
        case .relay: return "Connected to U60 remotely through your server"
        case .connecting: return "Connecting to U60"
        case .unavailable: return "U60 is offline"
        }
    }

    private var connectionColor: Color {
        guard isAuthenticated else { return .red }
        switch client.connectionRoute {
        case .local, .p2p, .relay: return .secondary
        case .connecting: return .orange
        case .unavailable: return .red
        }
    }
    private var connectionLabel: String {
        guard isAuthenticated else { return "Offline" }
        switch client.connectionRoute {
        case .local: return "Local"
        case .p2p: return "P2P"
        case .relay: return "Relay"
        case .connecting: return "Connecting"
        case .unavailable: return "Offline"
        }
    }
}

// MARK: - Observation scopes

// Each wrapper below reads the DashboardViewModel properties for exactly one card inside its own
// body. @Observation installs tracking per body evaluation, not per property, so
// `let battery = viewModel.battery` in DashboardView.body would still subscribe the whole
// dashboard to `battery`. Only a separate View type moves the read into its own invalidation
// unit; passing the view model itself down reads nothing and so tracks nothing.

private struct CellularCardScope: View {
    let viewModel: DashboardViewModel
    var compact = false

    var body: some View {
        CellularCardView(
            wanIPv4: viewModel.wanIPv4,
            wanIPv6: viewModel.wanIPv6,
            speed: viewModel.speed,
            trafficStats: viewModel.trafficStats,
            isTrafficAvailable: viewModel.isTrafficAvailable,
            trafficUpdatedAt: viewModel.trafficUpdatedAt,
            trafficSampleInterval: viewModel.trafficSampleInterval,
            compact: compact
        )
    }
}

private struct CPUCardScope: View {
    let viewModel: DashboardViewModel

    var body: some View {
        CPUCardView(systemInfo: viewModel.systemInfo, thermal: viewModel.thermal, cpuAvailable: viewModel.cpuUpdatedAt != nil)
    }
}

private struct WiFiCardScope: View {
    let viewModel: DashboardViewModel
    let internetModel: WiFiInternetViewModel
    @Binding var showWiFiShare: Bool

    var body: some View {
        WiFiCardView(wifiStatus: viewModel.wifiStatus, internetStatus: internetModel.status,
                     internetStatusError: internetModel.refreshError, showWiFiShare: $showWiFiShare)
    }
}

private struct WiFiShareCardScope: View {
    let viewModel: DashboardViewModel
    let client: AgentClient
    let authManager: AuthManager
    @Binding var isExpanded: Bool

    var body: some View {
        WiFiShareCardView(
            wifiStatus: viewModel.wifiStatus,
            client: client,
            authManager: authManager,
            isExpanded: $isExpanded
        )
    }
}

private struct DevicesCardScope: View {
    let viewModel: DashboardViewModel
    @Binding var showAllDevices: Bool

    var body: some View {
        DevicesCardView(connectedDevices: viewModel.connectedDevices, showAllDevices: $showAllDevices)
    }
}

private struct DashboardUpdateStatus: View {
    let viewModel: DashboardViewModel

    var body: some View {
        VStack(spacing: 6) {
            if let error = viewModel.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 4) {
                if viewModel.isLoading { ProgressView().controlSize(.mini) }
                Text("Updated").font(.caption2).foregroundStyle(.secondary)
                LastUpdatedView(date: viewModel.lastUpdated)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

private struct BatteryDetailScope: View {
    let viewModel: DashboardViewModel

    var body: some View {
        BatteryDetailSheet(battery: viewModel.battery, updatedAt: viewModel.batteryUpdatedAt)
    }
}

private struct BatteryOverviewScope: View {
    let viewModel: DashboardViewModel
    let usbViewModel: USBConnectionViewModel

    var body: some View {
        BatteryOverviewCard(battery: viewModel.battery, updatedAt: viewModel.batteryUpdatedAt,
                            powerbankActive: usbViewModel.usbStatus.powerbankActive)
    }
}

private struct CPUDetailScope: View {
    let viewModel: DashboardViewModel
    let client: AgentClient

    var body: some View {
        CPUDetailSheet(cpuAvailable: viewModel.cpuUpdatedAt != nil, systemInfo: viewModel.systemInfo, thermal: viewModel.thermal, client: client)
            // Killing bloat frees ~225 MB at once, and system info only reloads on the 60s tier.
            // Nothing inside a sheet can reach pull-to-refresh, so the sheet stack asks for one.
            .environment(\.processKillRefresh, { await viewModel.refresh() })
    }
}

// MARK: - Connection & signal detail

/// The combined sheet owns signal polling while visible. Keep the dashboard's fetch suspended
/// for the same lifetime, balancing appearances when navigating to network mode or another tab.
private struct ConnectionSignalDetail: View {
    let dashboard: DashboardViewModel
    let viewModel: SignalMonitorViewModel
    let networkModeViewModel: NetworkModeViewModel?

    @Environment(\.dismiss) private var dismiss
    @State private var isSuspended = false

    var body: some View {
        SignalMonitorView(viewModel: viewModel) {
            SignalActivityControl()
            ConnectionAddresses(viewModel: dashboard)
            if let networkModeViewModel {
                NavigationLink("Network mode") { NetworkModeView(viewModel: networkModeViewModel) }
            }
        }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                guard !isSuspended else { return }
                isSuspended = true
                dashboard.suspendSignalFetch()
            }
            .onDisappear {
                guard isSuspended else { return }
                isSuspended = false
                dashboard.resumeSignalFetch()
            }
    }
}

// MARK: - Banner

private struct SIMAlertBanner: View {
    struct Config: Identifiable, Equatable {
        let id: String
        let icon: String
        let title: String
        let message: String
        let color: Color
    }

    let config: Config

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: config.icon)
                .font(.title2)
                .foregroundStyle(config.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.title).font(.subheadline.bold()).textSelection(.enabled)
                Text(config.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .padding(12)
        .background(config.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(config.color.opacity(0.3), lineWidth: 1))
    }
}


private struct TemperatureCardScope: View {
    let viewModel: DashboardViewModel

    var body: some View {
        TemperatureCardView(thermal: viewModel.thermal, battery: viewModel.battery,
            thermalUpdatedAt: viewModel.thermalUpdatedAt, batteryUpdatedAt: viewModel.batteryUpdatedAt)
    }
}

private enum DashboardDetail: String, Identifiable {
    case routerConnection = "Connection details"
    case internet = "Internet"
    case connection = "Connection & signal"
    case traffic = "Live traffic"
    case battery = "Battery"
    case health = "CPU & temperatures"
    case wifi = "Wi-Fi & devices"
    var id: String { rawValue }
}

private struct OverviewHeading: View {
    let title: String
    let icon: String
    var body: some View {
        HStack {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }
}

private struct InternetOverview: View {
    let model: WiFiInternetViewModel
    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("Internet", systemImage: "globe").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if let status = model.status {
                        Text(status.config.mode == .repeater ? "Wi-Fi Repeater" : "SIM Hotspot")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                if let status = model.status {
                    HStack(alignment: .firstTextBaseline) {
                        Text(status.config.mode == .repeater ? status.config.ssid : status.sourceLabel)
                            .font(.title3.bold())
                        Spacer()
                        Text(model.refreshError == nil ? status.label : "Status unavailable")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(model.refreshError != nil || status.phase == "failed" ? .red : (status.connectivity == "online" ? .green : .secondary))
                    }
                    if status.config.mode == .repeater {
                        Text("\(status.config.band.label) upstream → \(status.config.band.hotspotLabel) hotspot")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.refreshError == nil {
                    ProgressView("Checking internet source…")
                }
                if let error = model.refreshError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("internet-overview")
    }
}

private struct RouterConnectionDetail: View {
    let client: AgentClient
    let internetModel: WiFiInternetViewModel
    let connectionLabel: String
    let connectionDescription: String
    @Environment(RemoteCallingManager.self) private var remoteCalling
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("App to U60") {
                LabeledContent("Connection", value: connectionLabel)
                Text(connectionDescription).font(.subheadline).foregroundStyle(.secondary)
                LabeledContent("Local address") {
                    Text(client.baseURL).textSelection(.enabled)
                }
            }
            Section("Remote access") {
                NavigationLink("Connect with device string") { DeviceConnectView() }
                LabeledContent("Pairing", value: remoteCalling.pairingRejected ? "Pair again" :
                    remoteCalling.isPaired ? "Paired" : "Not paired")
                if remoteCalling.isPaired {
                    if let router = remoteCalling.managementAccess?.routerID {
                        LabeledContent("Device ID", value:"U60-\(router.uuidString.lowercased())")
                    }
                    LabeledContent("Server connection", value: remoteCalling.pairingRejected ? "Pairing rejected" :
                        remoteCalling.isConnected ? "Connected" : "Reconnecting…")
                    LabeledContent("U60 at server", value: remoteCalling.isConnected ?
                        (remoteCalling.routerOnline ? "Online" : "Offline") : "Unknown")
                    LabeledContent("P2P", value: remoteCalling.managementPeerStatus)
                }
                NavigationLink { CallingServersView() } label: {
                    LabeledContent("Server", value: remoteCalling.serverAddress)
                }
            }
            Section("U60 internet") {
                if let status = internetModel.status {
                    LabeledContent("Source", value: status.sourceLabel)
                    if status.config.mode == .repeater {
                        LabeledContent("Upstream", value: status.upstreamLabel)
                    }
                    LabeledContent("Status", value: internetModel.refreshError == nil ? status.label : "Status unavailable")
                } else if internetModel.refreshError == nil {
                    ProgressView("Checking internet source…")
                }
                if let error = internetModel.refreshError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            Section {
                Text("The app prefers the local network, then an encrypted P2P connection. If direct connectivity is unavailable, it automatically uses your server relay.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Connection details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

private struct CellularStatusButton: View {
    let viewModel: DashboardViewModel
    let action: () -> Void

    var body: some View {
        let info = viewModel.operatorInfo
        let nr = viewModel.nrSignal
        let lte = viewModel.lteSignal
        let rsrp = nr.isConnected ? nr.rsrp : lte.rsrp
        let network = info.networkType.isEmpty ? "—" : info.displayNetworkType(nrConnected: nr.isConnected, lteSignal: lte)
        Button(action: action) {
            HStack(spacing: 5) {
                if viewModel.isAirplaneMode {
                    Image(systemName: "airplane")
                } else {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(0..<4) { bar in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(bar < Color.signalBars(rsrp) ? Color.primary : Color(.quaternaryLabel))
                                .frame(width: 3, height: CGFloat(5 + bar * 3))
                        }
                    }
                    Text(network).font(.caption.weight(.semibold)).lineLimit(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cellular signal")
        .accessibilityValue(viewModel.isAirplaneMode ? "Airplane mode" :
            "\(info.provider.isEmpty ? "No operator" : info.provider), \(network), \(rsrp.map { "\(Int($0)) dBm" } ?? "No signal data")\(info.roaming ? ", roaming" : "")")
        .accessibilityHint("Opens connection and signal details")
        .accessibilityIdentifier("dashboard-cellular-status")
    }
}

private struct BatteryStatusButton: View {
    let viewModel: DashboardViewModel
    let action: () -> Void

    var body: some View {
        let battery = viewModel.battery
        Button(action: action) {
            HStack(spacing: 6) {
                BatteryStatusIcon(capacity: battery.capacityPercent)
                Text(battery.powerText)
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                    .foregroundStyle(battery.powerWatts.map { $0 > 0 ? Color.green : Color.secondary } ?? .secondary)
                    .transaction { $0.animation = nil }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Router battery")
        .accessibilityValue("\(battery.capacityPercent == nil ? "Unavailable" : battery.capacityText)\(battery.charging.isEmpty ? "" : ", \(battery.charging)"), \(battery.powerText)")
        .accessibilityHint("Opens battery details")
        .accessibilityIdentifier("dashboard-battery-status")
    }

}

private struct BatteryStatusIcon: View {
    let capacity: Int?

    private var fillWidth: CGFloat { CGFloat(capacity ?? 0) / 100 * 30 }
    private var percentage: some View {
        Text(capacity.map(String.init) ?? "—")
            .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
            .frame(width: 34, height: 18)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.primary, lineWidth: 1.5)
                .frame(width: 34, height: 18)
            RoundedRectangle(cornerRadius: 2)
                .fill(.primary)
                .frame(width: fillWidth, height: 14)
                .offset(x: 2)
            percentage.foregroundStyle(.primary)
            percentage.foregroundStyle(Color(.systemBackground))
                .mask(alignment: .leading) {
                    Rectangle().frame(width: fillWidth, height: 14).offset(x: 2)
                }
            RoundedRectangle(cornerRadius: 1)
                .fill(.primary)
                .frame(width: 2.5, height: 7)
                .offset(x: 35.5)
        }
        .frame(width: 38, height: 18)
        .accessibilityHidden(true)
        .transaction { $0.animation = nil }
    }
}

private struct HealthOverview: View {
    let viewModel: DashboardViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu").foregroundStyle(.secondary).frame(width: 24)
            Text("System").font(.subheadline.weight(.medium))
            Spacer(minLength: 4)
            if viewModel.cpuUpdatedAt != nil {
                Text("\(viewModel.systemInfo.cpuUsagePercent, specifier: "%.0f")% CPU")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            } else { Text("Unavailable").font(.subheadline).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens CPU, memory, processes and temperatures")
    }
}

private struct WiFiOverview: View {
    let viewModel: DashboardViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi").foregroundStyle(.blue).frame(width: 24)
            Text("Hotspot & devices").font(.subheadline.weight(.medium))
            Spacer(minLength: 4)
            Text(viewModel.wifiStatus.wifiOn ? "\(viewModel.connectedDevices.count) connected" : "Wi-Fi off")
                .font(.subheadline).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens hotspot sharing and connected devices")
    }
}

private struct ConnectionAddresses: View {
    let viewModel: DashboardViewModel
    var body: some View {
        CardView(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("WAN addresses").font(.headline)
                LabeledContent("IPv4", value: viewModel.wanIPv4.isEmpty ? "—" : viewModel.wanIPv4)
                LabeledContent("IPv6", value: viewModel.wanIPv6.isEmpty ? "—" : viewModel.wanIPv6)
            }.font(.caption).textSelection(.enabled)
        }
    }
}

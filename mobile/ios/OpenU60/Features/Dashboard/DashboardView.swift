import SwiftUI

struct DashboardView: View {
    var viewModel: DashboardViewModel
    let isAuthenticated: Bool
    let client: AgentClient
    let authManager: AuthManager
    let usbViewModel: USBConnectionViewModel
    let messages: SMSViewModel
    let openConversation: (String) -> Void

    @State private var signalMonitorVM: SignalMonitorViewModel?
    @State private var networkModeVM: NetworkModeViewModel?
    @State private var detail: DashboardDetail? = DashboardDetail.debugInitial
    @State private var showCPUDetails = false
    @State private var showAllDevices = true
    @State private var showWiFiShare = false
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var internetModel: WiFiInternetViewModel { app.device.internet }

    init(viewModel: DashboardViewModel, isAuthenticated: Bool, client: AgentClient, authManager: AuthManager,
         usbViewModel: USBConnectionViewModel, messages: SMSViewModel, openConversation: @escaping (String) -> Void) {
        self.viewModel = viewModel
        self.isAuthenticated = isAuthenticated
        self.client = client
        self.authManager = authManager
        self.usbViewModel = usbViewModel
        self.messages = messages
        self.openConversation = openConversation
    }

    var body: some View {
        let banners = bannerConfigs
        NavigationStack {
            ScrollView {
                // Keep summary view identities stable while samples update and sheets open.
                VStack(spacing: Design.gap) {
                    if usbViewModel.usbStatus.showsPowerControl { USBPowerControl(viewModel: usbViewModel) }
                    ForEach(banners) { config in
                        SIMAlertBanner(config: config)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    InternetHero(viewModel: viewModel, internet: internetModel,
                                 openInternet: { detail = .internet }, openTraffic: { detail = .traffic })
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Design.tileMinWidth), spacing: Design.gap)],
                              spacing: Design.gap) {
                        SignalTile(viewModel: viewModel) { detail = .connection }
                        BatteryTile(viewModel: viewModel, usb: usbViewModel) { detail = .battery }
                        DevicesTile(viewModel: viewModel) { detail = .wifi }
                        SystemTile(viewModel: viewModel) { detail = .health }
                    }
                    if horizontalSizeClass == .regular {
                        HomeWidePanels(viewModel: viewModel, messages: messages,
                                       openDevices: { detail = .wifi }, openConversation: openConversation)
                    } else {
                        LatestMessageTile(messages: messages, open: openConversation)
                    }
                    HomeFooter(viewModel: viewModel, icon: connectionIcon, label: connectionLabel,
                               color: connectionColor, description: connectionDescription) { detail = .routerConnection }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
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
            .toolbar(.hidden, for: .navigationBar)
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
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                TrafficHistoryChart(viewModel: viewModel, fresh: viewModel.isTrafficAvailable
                                    && viewModel.trafficUpdatedAt.map { context.date.timeIntervalSince($0) < 5 } == true,
                                    height: 140, showsPeak: true)
                                    .padding(16)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: Design.corner))
                            }
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

private struct BatteryDetailScope: View {
    let viewModel: DashboardViewModel

    var body: some View {
        BatteryDetailSheet(battery: viewModel.battery, updatedAt: viewModel.batteryUpdatedAt)
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

private enum DashboardDetail: String, Identifiable, CaseIterable {
    case routerConnection = "Connection details"
    case internet = "Internet"
    case connection = "Connection & signal"
    case traffic = "Live traffic"
    case battery = "Battery"
    case health = "CPU & temperatures"
    case wifi = "Wi-Fi & devices"
    var id: String { rawValue }

    static var debugInitial: DashboardDetail? {
#if DEBUG
        // Simulator screenshots: `-debug_detail connection`.
        if let name = UserDefaults.standard.string(forKey: "debug_detail") {
            return allCases.first { "\($0)" == name }
        }
#endif
        return nil
    }
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

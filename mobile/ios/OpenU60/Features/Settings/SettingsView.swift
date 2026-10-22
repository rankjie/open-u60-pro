import SwiftUI

struct SettingsView: View {
    private let client: AgentClient
    private let authManager: AuthManager
    @State private var viewModel: SettingsViewModel
    @FocusState private var gatewayFieldFocused: Bool
    @Environment(AppModel.self) private var app

    init(client: AgentClient, authManager: AuthManager) {
        self.client = client
        self.authManager = authManager
        _viewModel = State(initialValue: SettingsViewModel(client: client))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    NavigationLink {
                        RouterSettingsListView(client: client, authManager: authManager, category: .connectivity)
                    } label: {
                        SettingsRow(title: "Wi-Fi & network", icon: "wifi", value: summary.wifi)
                    }.listRowInsets(SettingsRow.insets)
                    NavigationLink {
                        RouterSettingsListView(client: client, authManager: authManager, category: .cellular)
                    } label: {
                        SettingsRow(title: "Cellular & SIM", icon: "simcard.fill", color: .green, value: summary.cellular)
                    }.listRowInsets(SettingsRow.insets)
                    NavigationLink {
                        RouterSettingsListView(client: client, authManager: authManager, category: .security)
                    } label: {
                        SettingsRow(title: "Security & traffic", icon: "shield.lefthalf.filled", color: .indigo)
                    }.listRowInsets(SettingsRow.insets)
                    NavigationLink {
                        RouterSettingsListView(client: client, authManager: authManager, category: .system)
                    } label: {
                        SettingsRow(title: "Power & system", icon: "power", color: .gray, value: summary.battery)
                    }.listRowInsets(SettingsRow.insets)
                }
                Section("Services") {
                    NavigationLink {
                        MessageSettingsView(client: client, authManager: authManager)
                    } label: {
                        SettingsRow(title: "Messages", icon: "message.fill", color: .green, value: summary.messages)
                    }.listRowInsets(SettingsRow.insets)
                    NavigationLink {
                        PushedModelHost(SchedulerViewModel(client: client, authManager: authManager)) {
                            SchedulerView(viewModel: $0)
                        }
                    } label: {
                        SettingsRow(title: "Schedules", icon: "clock.fill", color: .orange)
                    }.listRowInsets(SettingsRow.insets)
                    NavigationLink {
                        ToolsListView(client: client, authManager: authManager, category: .diagnostics)
                    } label: {
                        SettingsRow(title: "Diagnostics", icon: "waveform.path.ecg")
                    }.listRowInsets(SettingsRow.insets)
                    NavigationLink {
                        ToolsListView(client: client, authManager: authManager, category: .advanced)
                    } label: {
                        SettingsRow(title: "Advanced", icon: "wrench.and.screwdriver.fill", color: .gray)
                    }.listRowInsets(SettingsRow.insets)
                }
                Section("App") {
                    NavigationLink { connectionSettings } label: {
                        SettingsRow(title: "Connection", icon: "point.3.connected.trianglepath.dotted", value: summary.route)
                    }.listRowInsets(SettingsRow.insets)
                    NavigationLink { preferences } label: {
                        SettingsRow(title: "Appearance & refresh", icon: "paintbrush.fill", color: .indigo)
                    }.listRowInsets(SettingsRow.insets)
                    NavigationLink { about } label: {
                        SettingsRow(title: "About OpenU60", icon: "info.circle.fill", color: .gray)
                    }.listRowInsets(SettingsRow.insets)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            // Opened before Home has polled: one batched read fills the row values.
            .task { if app.device.dashboard.lastUpdated == nil { await app.device.dashboard.refresh() } }
        }
    }

    /// Last known device state for the hub rows; nothing here issues a request.
    private var summary: (wifi: String?, cellular: String?, battery: String?, messages: String?, route: String?) {
        let dashboard = app.device.dashboard
        let wifi = dashboard.wifiStatus
        let devices = dashboard.connectedDevices.count
        let info = dashboard.operatorInfo
        let network = info.networkType.isEmpty ? nil
            : info.displayNetworkType(nrConnected: dashboard.nrSignal.isConnected, lteSignal: dashboard.lteSignal)
        let cellular = dashboard.isAirplaneMode ? "Airplane mode" : network
        let unread = app.device.messages.unreadCount
        let route: String? = switch client.connectionRoute {
        case .local: "Local"
        case .p2p: "P2P"
        case .relay: "Relay"
        case .connecting: "Connecting"
        case .unavailable: "Offline"
        }
        return (dashboard.lastUpdated == nil ? nil : wifi.wifiOn ? "\(devices) device\(devices == 1 ? "" : "s")" : "Off",
                cellular,
                dashboard.battery.capacityPercent.map { "\($0)%" },
                unread > 0 ? "\(unread) unread" : nil,
                authManager.isAuthenticated ? route : "Offline")
    }

    private var connectionSettings: some View {
        @Bindable var vm = viewModel
        return Form {
            Section {
                HStack {
                    TextField("Gateway IP", text: $vm.gatewayIP)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        .focused($gatewayFieldFocused)
                        .onSubmit { viewModel.commitGatewayIP() }
                        .onChange(of: gatewayFieldFocused) { _, isFocused in
                            if !isFocused { viewModel.commitGatewayIP() }
                        }
                        // Detection walks the client's base URL across candidates; an edit
                        // committed mid-probe would fight it for the same property.
                        .disabled(viewModel.isDetectingGateway)
                    Button("Detect") {
                        gatewayFieldFocused = false
                        Task { await viewModel.autoDetectGateway() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(viewModel.isDetectingGateway)
                    if viewModel.isDetectingGateway {
                        ProgressView()
                    }
                }
            } header: {
                Text("Gateway")
            } footer: {
                if viewModel.detectionFailed {
                    Text("No agent answered on the common gateway addresses. The previous address is still in use.")
                }
            }

            Section("Authentication") {
                if viewModel.hasStoredPassword {
                    HStack {
                        Text("Password stored in Keychain")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear", role: .destructive) {
                            viewModel.clearPassword()
                        }
                        .font(.caption)
                    }
                }
                SecureField("New Password", text: $vm.passwordInput)
                Button("Save to Keychain") {
                    withAnimation { viewModel.savePassword() }
                }
                .disabled(viewModel.passwordInput.isEmpty)
            }
        }
        .navigationTitle("App connection")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissal()
        .overlay(alignment: .top) {
            if viewModel.showSavedConfirmation { savedToast }
        }
        .task { await viewModel.refreshStoredPasswordState() }
    }

    private var preferences: some View {
        @Bindable var vm = viewModel
        return Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Refresh interval: \(viewModel.pollInterval, specifier: "%.1f")s")
                    Slider(value: $vm.pollInterval, in: 1...10, step: 0.5)
                        .accessibilityLabel("Refresh interval")
                        .accessibilityValue(String(format: "%.1f seconds", viewModel.pollInterval))
                }
            } header: {
                Text("Polling")
            } footer: {
                Text("Live upload and download use a separate 1-second refresh, matching the modem’s update rate.")
            }

            Section("Appearance") {
                Picker("Theme", selection: $vm.darkModeOverride) {
                    Text("System").tag(0)
                    Text("Light").tag(1)
                    Text("Dark").tag(2)
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Appearance & refresh")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var about: some View {
        Form {
            Section("About") {
                LabeledContent("App", value: "OpenU60")
                LabeledContent("Device", value: "ZTE U60 Pro (MU5250)")
            }

            Section("Legal") {
                Text("This app is not affiliated with, endorsed by, or sponsored by ZTE Corporation. ZTE and U60 Pro are trademarks of ZTE Corporation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Privacy Policy", destination: URL(string: "https://open-u60-pro.vercel.app/privacy")!)
            }
        }
        .navigationTitle("About OpenU60")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var savedToast: some View {
        Text("Password saved")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .transition(.move(edge: .top).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { viewModel.showSavedConfirmation = false }
            }
    }
}

struct MessageSettingsView: View {
    let client: AgentClient
    let authManager: AuthManager

    var body: some View {
        List {
            Section {
                NavigationLink { SMSNotificationSettingsView(client: client) } label: {
                    SettingsRow(title: "Notifications", icon: "bell.badge.fill", color: .red)
                }.listRowInsets(SettingsRow.insets)
                NavigationLink {
                    PushedModelHost(SMSForwardViewModel(client: client, authManager: authManager)) {
                        SMSForwardConfigView(viewModel: $0)
                    }
                } label: {
                    SettingsRow(title: "Forwarding", icon: "arrowshape.turn.up.right.fill", color: .green)
                }.listRowInsets(SettingsRow.insets)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Message settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

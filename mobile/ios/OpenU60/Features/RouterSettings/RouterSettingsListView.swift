import SwiftUI

struct RouterSettingsListView: View {
    @Environment(AppModel.self) private var app
    let client: AgentClient
    let authManager: AuthManager

    enum Category { case cellular, connectivity, security, system }
    let category: Category
    private var title: String {
        switch category {
        case .cellular: "Cellular & SIM"
        case .connectivity: "Wi-Fi & network"
        case .security: "Security & traffic"
        case .system: "Power & system"
        }
    }

    // MARK: - Routes

    private enum Route: Hashable {
        case mobileNetwork
        case networkMode
        case cellLock
        case smartTowerConnect
        case signalDetection
        case sim
        case routerESim
        case simServices
        case wifi
        case guestWiFi
        case apn
        case lan
        case dns
        case firewall
        case telemetryBlocker
        case vpnPassthrough
        case qos
        case deviceControls
        case usbMode
        case deviceInfo
        case clients
        case bandLock
    }

    // MARK: - Body

    var body: some View {
        Group {
            List {
                if category == .cellular {
                    Section("Mobile data") {
                        NavigationLink { destination(for: .mobileNetwork) } label: {
                            SettingsRow(title: "Mobile data", icon: "cellularbars", color: .green)
                        }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .networkMode) } label: {
                            SettingsRow(title: "Network mode", icon: "antenna.radiowaves.left.and.right", color: .green)
                        }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .apn) } label: {
                            SettingsRow(title: "APN", icon: "network", color: .green)
                        }.listRowInsets(SettingsRow.insets)
                    }
                    Section("SIM") {
                        NavigationLink { destination(for: .sim) } label: {
                            SettingsRow(title: "SIM card", icon: "simcard.fill", color: .green)
                        }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .routerESim) } label: {
                            SettingsRow(title: "eSIM profiles", icon: "simcard.2.fill", color: .green)
                        }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .simServices) } label: {
                            SettingsRow(title: "SIM services", icon: "phone.badge.waveform.fill", color: .green)
                        }.listRowInsets(SettingsRow.insets)
                    }
                    Section("Advanced radio") {
                        NavigationLink { destination(for: .bandLock) } label: {
                            SettingsRow(title: "Band lock", icon: "lock.fill", color: .gray)
                        }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .cellLock) } label: {
                            SettingsRow(title: "Cell lock", icon: "lock.fill", color: .gray)
                        }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .smartTowerConnect) } label: {
                            SettingsRow(title: "Smart tower connect", icon: "antenna.radiowaves.left.and.right", color: .gray)
                        }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .signalDetection) } label: {
                            SettingsRow(title: "Signal scan", icon: "waveform.badge.magnifyingglass", color: .gray)
                        }.listRowInsets(SettingsRow.insets)
                    }
                }
                if category == .connectivity {
                    Section("Wi-Fi") {
                        NavigationLink { destination(for: .clients) } label: {
                            SettingsRow(title: "Connected devices", icon: "laptopcomputer.and.iphone")
                        }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .wifi) } label: {
                            SettingsRow(title: "Internet & hotspot", icon: "wifi")
                        }.listRowInsets(SettingsRow.insets)

                        NavigationLink { destination(for: .guestWiFi) } label: {
                            SettingsRow(title: "Guest hotspot", icon: "person.2")
                        }.listRowInsets(SettingsRow.insets)

                    }
                    Section("Local network") {
                        NavigationLink { destination(for: .lan) } label: {
                            SettingsRow(title: "LAN & DHCP", icon: "network")
                        }.listRowInsets(SettingsRow.insets)

                        NavigationLink { destination(for: .dns) } label: {
                            SettingsRow(title: "DNS", icon: "globe")
                        }.listRowInsets(SettingsRow.insets)
                    }

                }
                if category == .security {
                    Section("Security") {
                        NavigationLink { destination(for: .firewall) } label: {
                            SettingsRow(title: "Firewall", icon: "shield.lefthalf.filled")
                        }.listRowInsets(SettingsRow.insets)

                        NavigationLink { destination(for: .telemetryBlocker) } label: {
                            SettingsRow(title: "Telemetry blocking", icon: "eye.slash")
                        }.listRowInsets(SettingsRow.insets)

                        NavigationLink { destination(for: .vpnPassthrough) } label: {
                            SettingsRow(title: "VPN passthrough", icon: "lock.shield")
                        }.listRowInsets(SettingsRow.insets)
                    }

                    Section("Traffic") {
                        NavigationLink { destination(for: .qos) } label: {
                            SettingsRow(title: "Traffic priority (QoS)", icon: "speedometer")
                        }.listRowInsets(SettingsRow.insets)
                    }

                }
                if category == .system {
                    Section("System") {
                        NavigationLink { destination(for: .deviceInfo) } label: { SettingsRow(title: "Device information", icon: "info.circle") }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .usbMode) } label: { SettingsRow(title: "USB mode", icon: "cable.connector") }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .deviceControls) } label: {
                            SettingsRow(title: "Restart & power", icon: "power")
                        }.listRowInsets(SettingsRow.insets)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .mobileNetwork:
            MobileNetworkView(viewModel: app.device.mobile)
        case .networkMode:
            PushedModelHost(NetworkModeViewModel(client: client, authManager: authManager)) {
                NetworkModeView(viewModel: $0)
            }
        case .cellLock:
            PushedModelHost(CellLockViewModel(client: client, authManager: authManager)) {
                CellLockView(viewModel: $0)
            }
        case .smartTowerConnect:
            PushedModelHost(STCViewModel(client: client, authManager: authManager)) {
                STCView(viewModel: $0)
            }
        case .signalDetection:
            PushedModelHost(SignalDetectViewModel(client: client, authManager: authManager)) {
                SignalDetectView(viewModel: $0)
            }
        case .sim:
            SIMView(viewModel: app.device.sim)
        case .routerESim:
            PushedModelHost(RouterESimViewModel(client: client, authManager: authManager)) {
                RouterESimView(viewModel: $0)
            }
        case .simServices:
            PushedModelHost(STKViewModel(client: client, authManager: authManager)) {
                STKMenuView(viewModel: $0)
            }
        case .wifi:
            WiFiInternetView(client: client, authManager: authManager)
        case .guestWiFi:
            PushedModelHost(GuestWiFiSettingsViewModel(client: client, authManager: authManager)) {
                GuestWiFiSettingsView(viewModel: $0)
            }
        case .apn:
            PushedModelHost(APNViewModel(client: client, authManager: authManager)) {
                APNView(viewModel: $0)
            }
        case .lan:
            PushedModelHost(LANSettingsViewModel(client: client, authManager: authManager)) {
                LANSettingsView(viewModel: $0)
            }
        case .dns:
            PushedModelHost(DNSSettingsViewModel(client: client, authManager: authManager)) {
                DNSSettingsView(viewModel: $0)
            }
        case .firewall:
            PushedModelHost(FirewallSettingsViewModel(client: client, authManager: authManager)) {
                FirewallSettingsView(viewModel: $0)
            }
        case .telemetryBlocker:
            PushedModelHost(TelemetryBlockerViewModel(client: client, authManager: authManager)) {
                TelemetryBlockerView(viewModel: $0)
            }
        case .vpnPassthrough:
            PushedModelHost(VPNPassthroughViewModel(client: client, authManager: authManager)) {
                VPNPassthroughView(viewModel: $0)
            }
        case .qos:
            PushedModelHost(QoSViewModel(client: client, authManager: authManager)) {
                QoSView(viewModel: $0)
            }
        case .bandLock:
            PushedModelHost(BandLockViewModel(client:client,authManager:authManager)) {BandLockView(viewModel:$0)}
        case .clients:
            PushedModelHost(ClientsViewModel(client:client,authManager:authManager)) {ClientsView(viewModel:$0)}
        case .deviceInfo:
            PushedModelHost(DeviceInfoViewModel(client:client,authManager:authManager)) {DeviceInfoView(viewModel:$0)}
        case .usbMode:
            USBModeView(viewModel: app.device.usb)
        case .deviceControls:
            PushedModelHost(DeviceControlViewModel(client: client, authManager: authManager)) {
                DeviceControlView(viewModel: $0)
            }
        }
    }
}

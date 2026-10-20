import SwiftUI

struct RouterSettingsListView: View {
    let client: AgentClient
    let authManager: AuthManager

    enum Category { case cellular, connectivity, security, system }
    let category: Category
    private var title: String {
        switch category {
        case .cellular: "Cellular & SIM"
        case .connectivity: "Wi-Fi & LAN"
        case .security: "Security & QoS"
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
                    Section("Cellular") {
                        NavigationLink { destination(for: .apn) } label: {
                            Label("APN", systemImage: "simcard")
                        }

                        NavigationLink { destination(for: .bandLock) } label: { Label("Band Lock", systemImage: "lock.fill") }
                        NavigationLink { destination(for: .mobileNetwork) } label: {
                            Label("Mobile Network", systemImage: "cellularbars")
                        }

                        NavigationLink { destination(for: .networkMode) } label: {
                            Label("Network Mode", systemImage: "antenna.radiowaves.left.and.right")
                        }

                        NavigationLink { destination(for: .cellLock) } label: {
                            Label("Cell Lock", systemImage: "lock.fill")
                        }

                        NavigationLink { destination(for: .smartTowerConnect) } label: {
                            Label("Smart Tower Connect", systemImage: "antenna.radiowaves.left.and.right")
                        }

                        NavigationLink { destination(for: .signalDetection) } label: {
                            Label("Signal Detection", systemImage: "waveform.badge.magnifyingglass")
                        }

                        NavigationLink { destination(for: .sim) } label: {
                            Label("SIM Card", systemImage: "simcard")
                        }

                        NavigationLink { destination(for: .routerESim) } label: {
                            Label("eSIM Profiles", systemImage: "simcard.2")
                        }

                        NavigationLink { destination(for: .simServices) } label: {
                            Label("SIM Services", systemImage: "phone.badge.waveform")
                        }
                    }

                }
                if category == .connectivity {
                    Section("Connectivity") {
                        NavigationLink { destination(for: .clients) } label: {
                            Label("Connected Devices", systemImage: "laptopcomputer.and.iphone")
                        }
                        NavigationLink { destination(for: .wifi) } label: {
                            Label("WiFi", systemImage: "wifi")
                        }

                        NavigationLink { destination(for: .guestWiFi) } label: {
                            Label("Guest WiFi", systemImage: "person.2")
                        }

                        NavigationLink { destination(for: .lan) } label: {
                            Label("LAN / DHCP", systemImage: "network")
                        }

                        NavigationLink { destination(for: .dns) } label: {
                            Label("DNS", systemImage: "globe")
                        }
                    }

                }
                if category == .security {
                    Section("Security") {
                        NavigationLink { destination(for: .firewall) } label: {
                            Label("Firewall", systemImage: "shield.lefthalf.filled")
                        }

                        NavigationLink { destination(for: .telemetryBlocker) } label: {
                            Label("Telemetry Blocker", systemImage: "eye.slash")
                        }

                        NavigationLink { destination(for: .vpnPassthrough) } label: {
                            Label("VPN Passthrough", systemImage: "lock.shield")
                        }
                    }

                    Section("Quality") {
                        NavigationLink { destination(for: .qos) } label: {
                            Label("QoS", systemImage: "speedometer")
                        }
                    }

                }
                if category == .system {
                    Section("System") {
                        NavigationLink { destination(for: .deviceInfo) } label: { Label("Device Info", systemImage: "info.circle") }
                        NavigationLink { destination(for: .usbMode) } label: { Label("USB Mode", systemImage: "cable.connector") }
                        NavigationLink { destination(for: .deviceControls) } label: {
                            Label("Device Controls", systemImage: "power")
                        }
                    }
                }
            }
            .navigationTitle(title)
        }
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .mobileNetwork:
            PushedModelHost(MobileNetworkViewModel(client: client, authManager: authManager)) {
                MobileNetworkView(viewModel: $0)
            }
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
            PushedModelHost(SIMViewModel(client: client, authManager: authManager)) {
                SIMView(viewModel: $0)
            }
        case .routerESim:
            PushedModelHost(RouterESimViewModel(client: client, authManager: authManager)) {
                RouterESimView(viewModel: $0)
            }
        case .simServices:
            PushedModelHost(STKViewModel(client: client, authManager: authManager)) {
                STKMenuView(viewModel: $0)
            }
        case .wifi:
            PushedModelHost(WiFiSettingsViewModel(client: client, authManager: authManager)) {
                WiFiSettingsView(viewModel: $0)
            }
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
            PushedModelHost(USBConnectionViewModel(client:client,authManager:authManager)) {USBModeView(viewModel:$0)}
        case .deviceControls:
            PushedModelHost(DeviceControlViewModel(client: client, authManager: authManager)) {
                DeviceControlView(viewModel: $0)
            }
        }
    }
}

// MARK: - Pushed model host

/// Holds a pushed screen's view model in `@State` so the model is built once, when the
/// route is actually pushed, and survives re-evaluation of the navigation destination.
///
/// Construction has to happen inside the box: `State.init(wrappedValue:)` is not itself an
/// autoclosure, so building the model in `init` would build and discard one on every
/// re-evaluation of the `.navigationDestination` closure.
private struct PushedModelHost<Model, Content: View>: View {
    @State private var box: LazyModelBox<Model>
    private let content: (Model) -> Content

    init(_ model: @autoclosure @escaping () -> Model, @ViewBuilder content: @escaping (Model) -> Content) {
        _box = State(wrappedValue: LazyModelBox(model))
        self.content = content
    }

    var body: some View {
        content(box.model)
    }
}

/// Defers building a pushed screen's view model until the first time it is read, which only
/// happens for the box `@State` actually keeps.
@MainActor
private final class LazyModelBox<Model> {
    lazy var model: Model = build()

    private let build: () -> Model

    init(_ build: @escaping () -> Model) {
        self.build = build
    }
}

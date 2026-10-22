import SwiftUI

struct ToolsListView: View {
    let client: AgentClient
    let authManager: AuthManager

    enum Category { case diagnostics, advanced }
    let category: Category
    private var title: String {
        switch category {
        case .diagnostics: "Network diagnostics"
        case .advanced: "Advanced"
        }
    }

    // MARK: - Routes

    private enum Route: Hashable {
        case speedTest
        case lanSpeedTest
        case enableADB
        case atTerminal
        case modemCalls
        case config
    }

    // MARK: - Body

    var body: some View {
        Group {
            List {
                if category == .diagnostics {
                    Section("Network tests") {
                        NavigationLink { destination(for: .speedTest) } label: {
                            SettingsRow(title: "Internet speed test", icon: "gauge.with.needle")
                        }.listRowInsets(SettingsRow.insets)

                        NavigationLink { destination(for: .lanSpeedTest) } label: {
                            SettingsRow(title: "Local Wi-Fi speed test", icon: "wifi")
                        }.listRowInsets(SettingsRow.insets)
                    }
                }
                if category == .advanced {
                    Section("Device access") {
                        NavigationLink { destination(for: .enableADB) } label: {
                            SettingsRow(title: "USB debugging", icon: "cable.connector.horizontal", color: .gray)
                        }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .atTerminal) } label: {
                            SettingsRow(title: "AT terminal", icon: "terminal.fill", color: .gray)
                        }.listRowInsets(SettingsRow.insets)
                        NavigationLink { destination(for: .modemCalls) } label: {
                            SettingsRow(title: "Modem diagnostics", icon: "phone.connection.fill", color: .gray)
                        }.listRowInsets(SettingsRow.insets)
                    }
                    Section("Configuration") {
                        NavigationLink { destination(for: .config) } label: {
                            SettingsRow(title: "Configuration files", icon: "doc.badge.gearshape", color: .gray)
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
        case .speedTest:
            PushedModelHost(SpeedTestViewModel(client: client, authManager: authManager)) {
                SpeedTestView(viewModel: $0)
            }
        case .lanSpeedTest:
            PushedModelHost(LANSpeedTestViewModel(client: client)) {
                LANSpeedTestView(viewModel: $0)
            }
        case .enableADB:
            EnableADBView(client: client, authManager: authManager)
        case .atTerminal:
            PushedModelHost(ATTerminalViewModel(client: client, authManager: authManager)) {
                ATTerminalView(viewModel: $0)
            }
        case .config:
            ConfigToolView()
        case .modemCalls:
            PushedModelHost(CallViewModel(client: client, authManager: authManager)) {
                CallView(viewModel: $0).navigationTitle("Modem controls")
            }
        }
    }
}

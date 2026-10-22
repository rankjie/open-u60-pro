import SwiftUI

struct TabBarView: View {
    let model: AppModel
    private var client: AgentClient { model.client }
    private var authManager: AuthManager { model.auth }
    @AppStorage("poll_interval") private var pollInterval: Double = 2.0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SMSNotificationManager.self) private var notifications
    @Environment(RemoteCallingManager.self) private var calling

    private enum Tab: String, Hashable { case dashboard, calls, sms, settings }
    @State private var selectedTab: Tab = Self.initialTab
    @State private var callPath: [CallDestination] = []
    @State private var messagePath: [String] = []

    private var dashboardVM: DashboardViewModel { model.device.dashboard }
    private var smsVM: SMSViewModel { model.device.messages }
    private var usbVM: USBConnectionViewModel { model.device.usb }

    private struct DashboardPollKey: Equatable {
        let interval: Double
        let active: Bool
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(viewModel: dashboardVM, isAuthenticated: authManager.isAuthenticated,
                         client: client, authManager: authManager, usbViewModel: usbVM,
                         messages: smsVM, openConversation: { id in
                             messagePath = [id]
                             selectedTab = .sms
                         })
                .tabItem {
                    Label("Home", systemImage: "gauge.with.needle")
                }
                .tag(Tab.dashboard)

            NavigationStack(path: $callPath) {
                RemoteCallingView(localClient: client, title: "Calls")
                    .navigationDestination(for: CallDestination.self) { destination in
                        switch destination {
                        case .history: CallHistoryView()
                        }
                    }
            }
                .tabItem { Label("Calls", systemImage: "phone.fill") }
                .tag(Tab.calls)

            SMSListView(viewModel: smsVM, client: client, authManager: authManager, messagePath: $messagePath)
                .tabItem {
                    Label("Messages", systemImage: "message")
                }
                .badge(smsVM.unreadCount)
                .tag(Tab.sms)

            SettingsView(client: client, authManager: authManager)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
        .onChange(of: dashboardPollKey, initial: true) { _, key in
            if key.active {
                dashboardVM.startPolling(interval: key.interval)
            } else {
                dashboardVM.stopPolling()
            }
        }
        .onChange(of: notifications.openRevision, initial: true) { _, revision in
            if revision > 0 { selectedTab = .sms }
        }
        .onChange(of: calling.callPresentationRequest, initial: true) { _, request in
            guard let request, request.callID == calling.call?.callId else { return }
            callPath.removeAll()
            selectedTab = .calls
        }
        .onChange(of: isForeground, initial: true) { _, foreground in
            if foreground {
                usbVM.startPolling()
            } else {
                usbVM.stopPolling()
            }
        }
        .onAppear {
            // Reappearing with an unchanged poll key must resume loops stopped on disappear.
            if dashboardPollKey.active { dashboardVM.startPolling(interval: pollInterval) }
            if isForeground { usbVM.startPolling() }
        }
        .onDisappear {
            dashboardVM.stopPolling()
            usbVM.stopPolling()
        }
    }

    private static var initialTab: Tab {
#if DEBUG
        // Simulator screenshots: `-debug_tab sms`.
        if let raw = UserDefaults.standard.string(forKey: "debug_tab"), let tab = Tab(rawValue: raw) { return tab }
#endif
        return .dashboard
    }

    // MARK: - Polling gates

    /// Polling only runs in `.active`. Pausing on `.inactive` as well covers the app switcher,
    /// iPad multitasking and the lock transition, where the scene stays alive but nothing the
    /// user can read is on screen; the cost is one extra immediate refresh when a short Control
    /// Centre pull ends, which is what a returning user wants anyway.
    private var isForeground: Bool { scenePhase == .active }

    /// Restarting on any change of this key preserves the previous behaviour: the loop restarts
    /// when the configured interval changes and stops when the dashboard is not on screen.
    private var dashboardPollKey: DashboardPollKey {
        DashboardPollKey(interval: pollInterval, active: isForeground && selectedTab == .dashboard)
    }
}

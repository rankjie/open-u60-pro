import Foundation
import Observation

/// One graph for the app lifetime. Views own navigation and edits, not device sessions.
@Observable @MainActor
final class AppModel {
    let client: AgentClient
    let auth: AuthManager
    let calling: RemoteCallingManager
    let notifications: SMSNotificationManager
    let signalActivity: SignalActivityManager
    private(set) var device: RouterSession
    private var deviceKey: String

    init() {
        let gateway = UserDefaults.standard.string(forKey: "gateway_ip") ?? "192.168.0.1"
        let client = AgentClient(baseURL: "http://\(gateway):9090")
        let calling = RemoteCallingManager()
        let auth = AuthManager(client: client)
        self.client = client; self.calling = calling; self.auth = auth
        notifications = .shared
        signalActivity = SignalActivityManager(client: client)
        client.relayAccess = { [weak calling] in calling?.managementAccess }
        client.peerRequest = { [weak calling] data, id, timeout, access in
            guard let calling, let current = calling.managementAccess,
                  current.server == access.server, current.routerID == access.routerID,
                  current.token == access.token else { throw AgentError.remoteUnauthorized }
            return try await calling.peerManagementRequest(data, id: id, timeout: timeout)
        }
        calling.localCommandDelivery = { [weak client] command, routerID in
            guard let client else { throw CallingError.disconnected }
            return try await client.deliverLocalCall(command, routerID: routerID)
        }
        auth.hasRemoteAccess = { [weak calling] in calling?.hasSavedPairing == true }
        deviceKey = calling.managementAccess?.routerID.uuidString ?? client.baseURL
        device = RouterSession(client: client, auth: auth)
        notifications.access = { [weak calling] in calling?.managementAccess }
        calling.onCallChanged = { [weak self] call in self?.device.recordings.observe(call) }
        calling.onSMSReceived = { [weak self] eventID, routerID, messageID, payload in
            self?.notifications.receive(eventID: eventID, routerID: routerID, messageID: messageID, payload: payload)
        }
        notifications.onDelivery = { [weak self] payload in
            guard let inbox = self?.device.messages else { return }
            inbox.receive(payload)
            if inbox.needsReconciliation { Task { await inbox.refresh(force: false) } }
        }
    }

    func selectDevice() {
        let key = calling.managementAccess?.routerID.uuidString ?? client.baseURL
        guard deviceKey != key else { return }
        deviceKey = key
        device.stop()
        device = RouterSession(client: client, auth: auth)
    }

    /// Cancellation is the foreground boundary. A tab change never restarts these workers.
    func run() async {
        selectDevice()
        await notifications.restoreDelivered()
        guard !Task.isCancelled, auth.isAuthenticated else { return }
        let device = device
        async let sim: Void = client.watchSIMState()
        async let internet: Void = device.internet.monitor()
        async let reconcile: Void = device.reconcile()
        _ = await (sim, internet, reconcile)
    }
}

@Observable @MainActor
final class RouterSession {
    let id = UUID()
    let dashboard: DashboardViewModel
    let messages: SMSViewModel
    let usb: USBConnectionViewModel
    let internet: WiFiInternetViewModel
    let sim: SIMViewModel
    let mobile: MobileNetworkViewModel
    let recordings: CallRecordingLibrary

    init(client: AgentClient, auth: AuthManager) {
        dashboard = DashboardViewModel(client: client, authManager: auth, identity: { [weak client] in client?.relayAccess?()?.routerID })
        messages = SMSViewModel(client: client, identity: { [weak client] in client?.relayAccess?()?.routerID })
        usb = USBConnectionViewModel(client: client, authManager: auth)
        internet = WiFiInternetViewModel(client: client)
        sim = SIMViewModel(client: client, authManager: auth)
        mobile = MobileNetworkViewModel(client: client, authManager: auth)
        recordings = CallRecordingLibrary(remote: client, identity: { [weak client] in client?.relayAccess?()?.routerID })
    }

    func reconcile() async {
        recordings.resumePending()
        await messages.refresh(force: false)
    }

    func stop() {
        dashboard.stopPolling()
        usb.stopPolling()
    }
}

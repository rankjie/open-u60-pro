import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor final class OpenU60Delegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        SMSNotificationManager.shared.register(token)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SMSNotificationManager.shared.registrationFailed(error)
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let payload = Dictionary(uniqueKeysWithValues: userInfo.compactMap { key, value in (key as? String).map { ($0, value) } })
        completionHandler(SMSNotificationManager.shared.receive(payload, open: false) ? .newData : .noData)
    }
}

@Observable @MainActor
final class SMSNotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = SMSNotificationManager()
    private(set) var enabled = false
    private(set) var message = "Pair this iPhone to receive SMS notifications."
    private(set) var errorMessage: String?
    private(set) var revision = 0
    private(set) var openRevision = 0
    private(set) var openMessageID: String?
    @ObservationIgnored var access: (@MainActor () -> AgentRelayAccess?)?
    @ObservationIgnored var onDelivery: (@MainActor ([String: Any]) -> Void)?
    @ObservationIgnored private let http = CallingHTTPClient()
    @ObservationIgnored private var deviceToken: String?
    @ObservationIgnored private var registering: Task<Void, Never>?
    @ObservationIgnored private var seen: [UUID] = []

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    func refresh(requestPermission: Bool = false) async {
        guard access?() != nil else { enabled = false; message = "Pair this iPhone to receive SMS notifications."; return }
        do {
            let center = UNUserNotificationCenter.current()
            if requestPermission, await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            let status = await center.notificationSettings().authorizationStatus
            enabled = status == .authorized || status == .provisional || status == .ephemeral
            if enabled {
                message = "Registering SMS notifications…"
                UIApplication.shared.registerForRemoteNotifications()
            } else {
                message = "Allow notifications for OpenU60 in iPhone Settings."
                if let access = access?() {
                    _ = try await http.request("v1/notification-token", server: access.server, token: access.token, method: "DELETE")
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func register(_ bytes: Data) {
        deviceToken = bytes.map { String(format:"%02x",$0) }.joined()
        registering?.cancel()
        registering = Task { [weak self] in
            guard let self, let access = self.access?(), let token = self.deviceToken else { return }
            do {
                guard let environment = Bundle.main.object(forInfoDictionaryKey:"OpenU60PushEnvironment") as? String,
                      ["sandbox","production"].contains(environment) else { throw CallingError.invalidResponse }
                _ = try await self.http.request("v1/notification-token", server: access.server, token: access.token, method: "PUT",
                                               body: ["token":token,"environment":environment])
                guard self.access?()?.token == access.token else { return }
                self.message = "SMS notifications enabled"
                self.errorMessage = nil
            } catch { if !error.isCancellation { self.errorMessage = error.localizedDescription } }
        }
    }
    func registrationFailed(_ error: Error) { errorMessage = error.localizedDescription }
    func takeOpenMessageID() -> String? {
        let id = openMessageID
        openMessageID = nil
        return id
    }
    func receive(eventID: UUID, routerID: UUID, messageID: String?, payload: [String: Any] = [:], open: Bool = false) {
        guard routerID == access?()?.routerID else { return }
        var delivery = payload
        delivery["eventId"] = eventID.uuidString; delivery["routerId"] = routerID.uuidString
        if let messageID { delivery["messageId"] = messageID }
        // Parts and retries reach the inbox owner, which deduplicates only after durable merge.
        onDelivery?(delivery)
        if !seen.contains(eventID) {
            seen.append(eventID); if seen.count > 128 { seen.removeFirst() }
            revision += 1
        }
        if open { openMessageID = messageID; openRevision += 1; revision += 1 }
    }
    private func receive(_ notification: UNNotification, open: Bool) -> Bool {
        let value = Dictionary(uniqueKeysWithValues: notification.request.content.userInfo.compactMap { key, value in (key as? String).map { ($0, value) } })
        return receive(value, open: open)
    }
    @discardableResult func receive(_ value: [String: Any], open: Bool) -> Bool {
        guard value["kind"] as? String == "sms", let raw = value["eventId"] as? String, let event = UUID(uuidString:raw),
              let rawRouter = value["routerId"] as? String, let router = UUID(uuidString:rawRouter), router == access?()?.routerID else { return false }
        receive(eventID:event,routerID:router,messageID:value["messageId"] as? String,payload:value,open:open)
        return true
    }
    /// Alert delivery may happen while iOS keeps the app suspended. Replay retained payloads
    /// on foreground before reconciliation; opening Messages never owns this recovery work.
    func restoreDelivered() async {
        let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
        for notification in notifications { _ = receive(notification, open: false) }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion(receive(notification,open:false) ? [.banner,.sound,.list] : [])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void) {
        _ = receive(response.notification,open:true)
        completion()
    }
}

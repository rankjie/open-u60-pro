import SwiftUI

struct SMSNotificationSettingsView: View {
    @Environment(SMSNotificationManager.self) private var notifications
    @Environment(\.openURL) private var openURL
    let client: AgentClient
    @State private var deviceStatus = "Checking the router…"

    var body: some View {
        Form {
            Section("iPhone") {
                Label(notifications.message, systemImage:notifications.enabled ? "bell.badge.fill" : "bell.slash")
                if let error = notifications.errorMessage { Text(error).foregroundStyle(.red) }
                Button("Enable notifications") { Task { await notifications.refresh(requestPermission:true) } }
                Button("Open iPhone Settings") {
                    if let url = URL(string:UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Section("Router") { Text(deviceStatus) }
            Section {
                Text("Notifications show the sender and complete SMS text. Long messages are split when they exceed Apple's notification size limit.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("SMS notifications")
        .task {
            await notifications.refresh()
            do {
                let status = try await client.getJSON("/api/sms/notifications/status")
                if let error = status["lastError"] as? String { deviceStatus = error }
                else if let pending = status["pending"] as? Int, let ready = status["initialized"] as? Bool {
                    deviceStatus = ready ? "Monitoring new SMS · \(pending) awaiting delivery" : "Waiting for the SMS database"
                } else { throw CallingError.invalidResponse }
            } catch { deviceStatus = error.localizedDescription }
        }
    }
}

import SwiftUI

@Observable
@MainActor
final class WiFiSettingsViewModel {
    var config: WiFiConfig = .empty
    var isLoading: Bool = false
    /// Saving stays off until a load succeeded: a failed load leaves defaults (empty SSIDs and
    /// keys) that must never be written.
    private(set) var isLoaded = false
    var message: String?
    var messageIsError: Bool = false

    // Editable fields
    var editSSID2g: String = ""
    var editSSID5g: String = ""
    var editKey2g: String = ""
    var editKey5g: String = ""
    var editChannel2g: String = "auto"
    var editChannel5g: String = "auto"
    var editTxpower2g: String = "100"
    var editTxpower5g: String = "100"
    var editEncryption2g: String = "psk2+ccmp"
    var editEncryption5g: String = "psk2+ccmp"
    var editHidden2g: Bool = false
    var editHidden5g: Bool = false
    var editWifiOnOff: Bool = true
    var editRadio2gDisabled: Bool = false
    var editRadio5gDisabled: Bool = false
    var editWifi7Enabled: Bool = false
    var editBandwidth2g: String = "auto"
    var editBandwidth5g: String = "auto"

    private let client: AgentClient
    private let authManager: AuthManager

    init(client: AgentClient, authManager: AuthManager) {
        self.client = client
        self.authManager = authManager
    }

    func refresh() async {
        isLoading = true
        message = nil

        // Try native /api/wifi/status first (single call, all fields)
        if let wifiData = try? await client.getJSON("/api/wifi/status"),
           wifiData["htmode_2g"] != nil {
            config = WiFiParser.parse(wifiData)
            syncEditFields()
            isLoaded = true
            isLoading = false
            return
        }

        showMessage("Failed to load WiFi settings", isError: true)
        isLoading = false
    }

    var hasChanges: Bool { isLoaded && !changedFields(editedParams, from: loadedParams).isEmpty }

    func apply() async {
        guard isLoaded else { return }
        // Only what the user edited; the agent keeps every other field as the router has it.
        let params = changedFields(editedParams, from: loadedParams)
        guard !params.isEmpty else { return }
        isLoading = true

        do {
            let _ = try await client.putJSON("/api/wifi/settings", body: params)
            showMessage("WiFi settings applied — WiFi will restart briefly", isError: false)
            updateConfigFromEdits()
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    private var loadedParams: [String: Any] { Self.params(config) }
    private var editedParams: [String: Any] {
        Self.params(WiFiConfig(ssid2g: editSSID2g, ssid5g: editSSID5g, key2g: editKey2g, key5g: editKey5g,
                               channel2g: editChannel2g, channel5g: editChannel5g,
                               txpower2g: editTxpower2g, txpower5g: editTxpower5g,
                               encryption2g: editEncryption2g, encryption5g: editEncryption5g,
                               wifiOnOff: editWifiOnOff, hidden2g: editHidden2g, hidden5g: editHidden5g,
                               radio2gDisabled: editRadio2gDisabled, radio5gDisabled: editRadio5gDisabled,
                               wifi7Enabled: editWifi7Enabled, bandwidth2g: editBandwidth2g, bandwidth5g: editBandwidth5g))
    }

    private static func params(_ config: WiFiConfig) -> [String: Any] {
        [
            "ssid_2g": config.ssid2g,
            "ssid_5g": config.ssid5g,
            "key_2g": config.key2g,
            "key_5g": config.key5g,
            "channel_2g": config.channel2g,
            "channel_5g": config.channel5g,
            "txpower_2g": config.txpower2g,
            "txpower_5g": config.txpower5g,
            "encryption_2g": config.encryption2g,
            "encryption_5g": config.encryption5g,
            "hidden_2g": config.hidden2g ? "1" : "0",
            "hidden_5g": config.hidden5g ? "1" : "0",
            "wifi_onoff": config.wifiOnOff ? "1" : "0",
            "radio2_disabled": config.radio2gDisabled ? "1" : "0",
            "radio5_disabled": config.radio5gDisabled ? "1" : "0",
            "wifi6_switch": config.wifi7Enabled ? "1" : "0",
            "htmode_2g": config.bandwidth2g,
            "htmode_5g": config.bandwidth5g
        ]
    }

    private func updateConfigFromEdits() {
        config = WiFiConfig(ssid2g: editSSID2g, ssid5g: editSSID5g, key2g: editKey2g, key5g: editKey5g,
                            channel2g: editChannel2g, channel5g: editChannel5g,
                            txpower2g: editTxpower2g, txpower5g: editTxpower5g,
                            encryption2g: editEncryption2g, encryption5g: editEncryption5g,
                            wifiOnOff: editWifiOnOff, hidden2g: editHidden2g, hidden5g: editHidden5g,
                            radio2gDisabled: editRadio2gDisabled, radio5gDisabled: editRadio5gDisabled,
                            wifi7Enabled: editWifi7Enabled, bandwidth2g: editBandwidth2g, bandwidth5g: editBandwidth5g)
    }

    private func syncEditFields() {
        editSSID2g = config.ssid2g
        editSSID5g = config.ssid5g
        editKey2g = config.key2g
        editKey5g = config.key5g
        editChannel2g = config.channel2g
        editChannel5g = config.channel5g
        editTxpower2g = config.txpower2g
        editTxpower5g = config.txpower5g
        editEncryption2g = config.encryption2g
        editEncryption5g = config.encryption5g
        editHidden2g = config.hidden2g
        editHidden5g = config.hidden5g
        editWifiOnOff = config.wifiOnOff
        editRadio2gDisabled = config.radio2gDisabled
        editRadio5gDisabled = config.radio5gDisabled
        editWifi7Enabled = config.wifi7Enabled
        editBandwidth2g = config.bandwidth2g
        editBandwidth5g = config.bandwidth5g
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}

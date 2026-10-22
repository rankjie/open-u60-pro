import SwiftUI

@Observable
@MainActor
final class USBConnectionViewModel {
    var usbStatus: USBStatus = .empty
    var isLoading: Bool = false
    var message: String?
    var messageIsError: Bool = false
    var powerStateUnknown = false
    var powerReserve: USBPowerReserveStatus?
    var reserveError: String?

    /// Refresh the compact dashboard control while the app is active.
    nonisolated static let defaultPollInterval: TimeInterval = 10

    private let client: AgentClient
    private let authManager: AuthManager
    private let poller: PollingLoop
    private var revision = 0
    private var pollError = false

    init(client: AgentClient, authManager: AuthManager) {
        self.client = client
        self.authManager = authManager
        self.poller = PollingLoop()
    }

    func startPolling(interval: TimeInterval = USBConnectionViewModel.defaultPollInterval) {
        poller.start(interval: .seconds(interval)) { [weak self] in
            guard let self else { return .failure }
            let reachedAgent = await self.refresh()
            return reachedAgent ? .success : .failure
        }
    }

    func stopPolling() {
        poller.stop()
    }

    /// - Returns: true when the agent answered, so the poll loop can back off when it does not.
    @discardableResult
    func refresh() async -> Bool {
        let started = revision
        let changing = isLoading
        do {
            let usb = try await client.getJSON("/api/usb/status")
            guard !changing, !isLoading, started == revision else { return true }
            let status = try DeviceParser.parseUSBStatus(usb)
            if let reserve = usb["power_reserve"] as? [String: Any] {
                powerReserve = try JSONDecoder().decode(USBPowerReserveStatus.self, from: JSONSerialization.data(withJSONObject: reserve))
                reserveError = powerReserve?.error
            } else {
                powerReserve = nil
            }
            powerStateUnknown = false
            if pollError { message = nil; messageIsError = false; pollError = false }
            if status != usbStatus { usbStatus = status }
            return true
        } catch {
            guard !error.isCancellation else { return false }
            guard !changing, !isLoading, started == revision else { return false }
            if error is USBStatusError { powerStateUnknown = true }
            pollError = true
            message = error.localizedDescription
            messageIsError = true
            return false
        }
    }

    func enablePowerbank() async {
        await setPowerbank(true)
    }

    func disablePowerbank() async {
        await setPowerbank(false)
    }

    func loadPowerReserve() async {
        let started = revision
        do {
            let status: USBPowerReserveStatus = try await client.get("/api/usb/power-reserve")
            guard !isLoading, started == revision else { return }
            powerReserve = status
            reserveError = status.error
        } catch {
            guard !error.isCancellation, started == revision else { return }
            reserveError = error.localizedDescription
        }
    }

    func savePowerReserve(_ policy: USBPowerReservePolicy) async -> Bool {
        guard !isLoading else { return false }
        revision += 1
        isLoading = true
        reserveError = nil
        defer { isLoading = false; revision += 1 }
        do {
            let status: USBPowerReserveStatus = try await client.put("/api/usb/power-reserve", body: policy)
            powerReserve = status
            reserveError = status.error
            return true
        } catch {
            reserveError = error.localizedDescription
            return false
        }
    }

    private func setPowerbank(_ enabled: Bool) async {
        guard !isLoading, !enabled || usbStatus.cableAttached else { return }
        revision += 1
        isLoading = true
        message = nil
        pollError = false
        defer {
            isLoading = false
            revision += 1
        }
        do {
            let data = try await client.putJSON("/api/usb/powerbank", body: ["state": enabled ? 1 : 0])
            guard (data["state"] as? Int) == (enabled ? 1 : 0) else {
                throw AgentError.serverError(
                    "The router did not confirm the USB charging state. Update the device agent and retry.")
            }
            usbStatus.powerbankActive = enabled
            message = enabled ? "Phone charging enabled" : "Phone charging disabled"
            messageIsError = false
        } catch {
            message = "Failed: \(error.localizedDescription)"
            messageIsError = true
        }
    }

}

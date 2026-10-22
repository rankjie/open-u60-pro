import SwiftUI

@Observable
@MainActor
final class BandLockViewModel {
    var config: BandConfig = .empty
    var isLoading: Bool = false
    var message: String?
    var messageIsError: Bool = false

    private let client: AgentClient
    private let authManager: AuthManager

    init(client: AgentClient, authManager: AuthManager) {
        self.client = client
        self.authManager = authManager
    }

    /// The modem's current selection, so the grids start from what is applied.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await client.getJSON("/api/network/signal")
            guard let current = BandConfig.current(data) else {
                showMessage("The modem did not report its band selection", isError: true)
                return
            }
            config = current
        } catch {
            guard !error.isCancellation else { return }
            showMessage("Could not read the band selection: \(error.localizedDescription)", isError: true)
        }
    }

    func toggleNRBand(_ band: String) {
        if config.nrBands.contains(band) {
            config.nrBands.remove(band)
        } else {
            config.nrBands.insert(band)
        }
    }

    func toggleLTEBand(_ band: String) {
        if config.lteBands.contains(band) {
            config.lteBands.remove(band)
        } else {
            config.lteBands.insert(band)
        }
    }

    func applyNRLock() async {
        guard !config.nrBands.isEmpty else {
            showMessage("Select at least one NR band", isError: true)
            return
        }
        isLoading = true
        let bandStr = config.nrBandString

        do {
            // Lock NSA bands
            let _ = try await client.postJSON("/api/cell/band/nr", body: ["nr5g_type": "nsa", "nr5g_band": bandStr])
            // Lock SA bands
            let _ = try await client.postJSON("/api/cell/band/nr", body: ["nr5g_type": "sa", "nr5g_band": bandStr])
            showMessage("NR bands locked: \(bandStr)", isError: false)
            await load()
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
        }
        isLoading = false
    }

    func applyLTELock() async {
        guard !config.lteBands.isEmpty else {
            showMessage("Select at least one LTE band", isError: true)
            return
        }
        isLoading = true

        do {
            let _ = try await client.postJSON("/api/cell/band/lte", body: [
                "is_lte_band": "1",
                "lte_band_mask": config.lteBandString,
                "is_gw_band": "0",
                "gw_band_mask": ""
            ])
            showMessage("LTE bands locked: \(config.lteBandString)", isError: false)
            await load()
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
        }
        isLoading = false
    }

    func unlockAll() async {
        isLoading = true

        do {
            let _ = try await client.postJSON("/api/cell/band/reset")
            showMessage("All bands unlocked", isError: false)
            await load()
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
        }
        isLoading = false
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}

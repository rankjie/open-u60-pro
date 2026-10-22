import SwiftUI

enum DNSMode: Int, CaseIterable, Identifiable {
    case auto, custom, doh

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .custom: "Custom"
        case .doh: "DoH"
        }
    }
}

@Observable
@MainActor
final class DNSSettingsViewModel {
    var config: DNSConfig = .empty
    var isLoading: Bool = false
    var message: String?
    var messageIsError: Bool = false

    // Mode
    var selectedMode: DNSMode = .auto

    // Editable fields
    var editPrimary: String = ""
    var editSecondary: String = ""

    // DoH
    var doh: DoHStatus = .empty
    var editUpstream: String = ""
    var cacheEntries: [DoHCacheEntry] = []
    var showCacheInspector: Bool = false

    private let client: AgentClient
    private let authManager: AuthManager

    init(client: AgentClient, authManager: AuthManager) {
        self.client = client
        self.authManager = authManager
    }

    /// Both the DNS record and the DoH status must load before anything can be applied: the
    /// mode is derived from both, and a guess would wipe custom DNS or DoH.
    private(set) var isLoaded = false

    func refresh() async {
        isLoading = true
        message = nil
        do {
            async let dnsCall = client.getJSON("/api/router/dns")
            async let dohCall = client.getJSON("/api/doh/status")
            let (dnsData, dohData) = try await (dnsCall, dohCall)
            config = DNSParser.parse(dnsData)
            doh = DoHParser.parse(dohData)
            // Every successful load shows the router's current state, never an older visit's.
            editPrimary = config.primaryDns
            editSecondary = config.secondaryDns
            editUpstream = doh.upstreamUrl
            selectedMode = doh.enabled ? .doh : config.isManual ? .custom : .auto
            isLoaded = true
            if doh.enabled { await refreshCache() }
        } catch {
            isLoaded = false
            showMessage("Failed to load DNS settings: \(error.localizedDescription)", isError: true)
        }
        isLoading = false
    }

    func apply() async {
        guard isLoaded else { return }
        switch selectedMode {
        case .auto:
            await applyAuto()
        case .custom:
            await applyCustom()
        case .doh:
            await applyDoH()
        }
    }

    private func applyAuto() async {
        isLoading = true
        do {
            let _ = try await client.putJSON("/api/router/dns", body: [
                "dns_mode": "auto",
                "prefer_dns_manual": "",
                "standby_dns_manual": ""
            ])
            // Always disable DoH (idempotent, prevents orphaned dnsmasq forwarding)
            let _ = try await client.postJSON("/api/doh/disable")
            showMessage("DNS set to Auto", isError: false)
            await refresh()
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
            isLoading = false
        }
    }

    private func isValidIPv4(_ str: String) -> Bool {
        let parts = str.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let n = UInt16(part) else { return false }
            return n <= 255
        }
    }

    private func applyCustom() async {
        guard !editPrimary.isEmpty else {
            showMessage("Primary DNS cannot be empty", isError: true)
            return
        }
        guard isValidIPv4(editPrimary) else {
            showMessage("Invalid primary DNS address", isError: true)
            return
        }
        if !editSecondary.isEmpty {
            guard isValidIPv4(editSecondary) else {
                showMessage("Invalid secondary DNS address", isError: true)
                return
            }
        }
        isLoading = true
        do {
            let _ = try await client.putJSON("/api/router/dns", body: [
                "dns_mode": "manual",
                "prefer_dns_manual": editPrimary,
                "standby_dns_manual": editSecondary
            ])
            // Always disable DoH (idempotent, prevents orphaned dnsmasq forwarding)
            let _ = try await client.postJSON("/api/doh/disable")
            showMessage("DNS set to Custom (\(editPrimary))", isError: false)
            await refresh()
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
            isLoading = false
        }
    }

    private func applyDoH() async {
        guard !editPrimary.isEmpty else {
            showMessage("Primary DNS cannot be empty", isError: true)
            return
        }
        guard isValidIPv4(editPrimary) else {
            showMessage("Invalid primary DNS address", isError: true)
            return
        }
        if !editSecondary.isEmpty {
            guard isValidIPv4(editSecondary) else {
                showMessage("Invalid secondary DNS address", isError: true)
                return
            }
        }
        guard !editUpstream.isEmpty else {
            showMessage("DoH upstream URL cannot be empty", isError: true)
            return
        }
        isLoading = true
        do {
            // Set manual DNS (DoH local resolver)
            let _ = try await client.putJSON("/api/router/dns", body: [
                "dns_mode": "manual",
                "prefer_dns_manual": editPrimary,
                "standby_dns_manual": editSecondary
            ])
            // Update DoH upstream
            let _ = try await client.putJSON("/api/doh/config", body: [
                "upstream_url": editUpstream
            ])
            // Enable DoH if not running
            if !doh.enabled {
                let _ = try await client.postJSON("/api/doh/enable")
            }
            showMessage("DoH enabled with \(editUpstream)", isError: false)
            await refresh()
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
            isLoading = false
        }
    }

    func clearCache() async {
        isLoading = true
        do {
            let _ = try await client.postJSON("/api/doh/cache/clear")
            showMessage("DNS cache cleared", isError: false)
            await refresh()
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
            isLoading = false
        }
    }

    func refreshCache() async {
        do {
            let list = try await client.getJSONArray("/api/doh/cache")
            cacheEntries = DoHParser.parseCacheEntries(list)
        } catch {
            // cache fetch is best-effort
        }
    }

    func applyPreset(primary: String, secondary: String, upstream: String) {
        if selectedMode == .auto {
            selectedMode = .custom
        }
        editPrimary = primary
        editSecondary = secondary
        editUpstream = upstream
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}

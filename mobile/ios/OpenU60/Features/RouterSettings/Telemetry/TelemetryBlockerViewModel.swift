import SwiftUI

@Observable
@MainActor
final class TelemetryBlockerViewModel {
    var filterConfig: DomainFilterConfig = .empty
    var isLoading: Bool = false
    var message: String?
    var messageIsError: Bool = false
    var newDomain: String = ""

    private let client: AgentClient
    private let authManager: AuthManager

    init(client: AgentClient, authManager: AuthManager) {
        self.client = client
        self.authManager = authManager
    }

    /// The router's rule list. Ids come only from here: rules added in this app are re-read
    /// rather than given local ids the router would not recognise when deleting.
    private func reload() async throws {
        let data = try await client.getJSON("/api/router/domain-filter")
        filterConfig = TelemetryParser.parseDomainFilter(data)
    }

    func refresh() async {
        isLoading = true
        message = nil

        do {
            try await reload()
        } catch {
            showMessage("Failed to load filters: \(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    func toggleFilter(enabled: Bool) async {
        isLoading = true

        do {
            let _ = try await client.putJSON("/api/router/domain-filter", body: ["enable": enabled ? "1" : "0"])
            showMessage("Domain filter \(enabled ? "enabled" : "disabled")", isError: false)
            filterConfig.enabled = enabled
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    func addDomain(_ domain: String) async {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showMessage("Enter a domain name", isError: true)
            return
        }

        isLoading = true

        do {
            let _ = try await client.putJSON("/api/router/domain-filter", body: [
                "action": "add",
                "domain": trimmed,
                "enabled": "1"
            ])
            newDomain = ""
            showMessage("Added \(trimmed)", isError: false)
            try? await reload()
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    func removeDomain(_ rule: DomainFilterRule) async {
        isLoading = true

        do {
            // Ids may be list positions; re-read so the delete names the rule as it is now,
            // not where it sat when this screen loaded (another client may have changed it).
            try await reload()
            guard let current = filterConfig.rules.first(where: { $0.domain == rule.domain }) else {
                showMessage("\(rule.domain) is no longer blocked", isError: false)
                isLoading = false
                return
            }
            let _ = try await client.putJSON("/api/router/domain-filter", body: [
                "action": "delete",
                "id": current.id
            ])
            showMessage("Removed \(rule.domain)", isError: false)
            try? await reload()
        } catch {
            showMessage("Failed: \(error.localizedDescription)", isError: true)
        }

        isLoading = false
    }

    func blockAllTelemetry() async {
        isLoading = true
        let existingDomains = Set(filterConfig.rules.map(\.domain))

        var added = 0
        for domain in TelemetryParser.knownTelemetryDomains {
            guard !existingDomains.contains(domain) else { continue }
            do {
                let _ = try await client.putJSON("/api/router/domain-filter", body: [
                    "action": "add",
                    "domain": domain,
                    "enabled": "1"
                ])
                added += 1
            } catch {
                // Continue with remaining domains
            }
        }

        try? await reload()
        if added > 0 {
            showMessage("Blocked \(added) telemetry domain\(added == 1 ? "" : "s")", isError: false)
        } else {
            showMessage("All telemetry domains already blocked", isError: false)
        }

        isLoading = false
    }

    private func showMessage(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}

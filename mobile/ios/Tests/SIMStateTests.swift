import Foundation

private enum FixtureError: Error { case offline }

@MainActor
private final class PendingRead {
    var started = false
    private var continuation: CheckedContinuation<[String: Any], Error>?
    func fetch() async throws -> [String: Any] {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ data: [String: Any]) { continuation!.resume(returning: data); continuation = nil }
}

@main
struct SIMStateTests {
    static let first = "8988307000000000001"
    static let second = "8988307000000000002"
    static func stamp(_ epoch: Int, phase: String = "online") -> [String: Any] {
        ["agent_instance": NSNumber(value: 10), "sim_epoch": NSNumber(value: epoch), "sim_phase": phase]
    }
    static func info(_ iccid: String = first, number: String = "0612345678", epoch: Int = 1, phase: String = "online") -> [String: Any] {
        stamp(epoch, phase: phase).merging(["sim_states": "modem_sim_ready", "sim_iccid": iccid,
                                          "msisdn": number, "msisdn_source": "manual"]) { _, new in new }
    }

    @MainActor private static func started(_ pending: PendingRead) async {
        for _ in 0..<1000 {
            if pending.started { return }
            await Task.yield()
        }
        preconditionFailure("Shared request never started")
    }

    @MainActor static func main() async throws {
        var time = Date(timeIntervalSince1970: 100)
        let state = SIMState(now: { time })
        state.selectDevice("router-one")
        precondition(state.line == .loading, "Never-loaded state must not claim the SIM is unavailable")
        let pending = PendingRead()
        let home = Task { try await state.read { try await pending.fetch() } }
        await started(pending)
        precondition(state.line == .loading)
        let settings = Task { try await state.read { preconditionFailure("Concurrent screens issued duplicate SIM requests") } }
        await Task.yield()
        home.cancel()
        state.observeIdentity(stamp(1))
        pending.finish(info())
        _ = try await (home.value, settings.value)
        let known = state.line
        precondition(known == .available(CellularLine(iccid: first, number: "0612345678", source: "manual")))

        for _ in 0..<5 {
            state.selectDevice("router-one")
            _ = try await state.read(force: false) { preconditionFailure("Tab entry refetched a fresh SIM state") }
            precondition(state.line == known)
        }
        time += 29.9
        _ = try await state.read(force: false) { preconditionFailure("Premature freshness expiry") }
        time += 0.1
        var refreshes = 0
        _ = try await state.read(force: false) { refreshes += 1; return info() }
        precondition(refreshes == 1)

        let offline = Task { try await state.read { throw FixtureError.offline } }
        do { _ = try await offline.value; preconditionFailure("Offline read reported success") }
        catch FixtureError.offline {}
        precondition(state.line == known && state.error != nil, "Refresh failure discarded a confirmed number")

        state.observeIdentity(stamp(1, phase: "stalled"))
        precondition(state.line == known, "A WAN phase alone changed the known SIM")
        state.observeIdentity(stamp(1, phase: "leaving"))
        precondition(state.line == .loading, "A card transition kept showing the outgoing card")
        do {
            _ = try await state.read { info(phase: "leaving") }
            preconditionFailure("Leaving phase restored the previous card")
        } catch is CancellationError {}
        state.observeIdentity(stamp(2, phase: "changed"))
        do {
            _ = try await state.read { info() }
            preconditionFailure("Late old-SIM response was accepted")
        } catch is CancellationError {}
        precondition(state.line == .loading)
        _ = try await state.read { info(second, number: "0623456789", epoch: 2, phase: "changed") }
        precondition(state.line == .available(CellularLine(iccid: second, number: "0623456789", source: "manual")))

        let oldNumber = PendingRead()
        let refresh = Task { try await state.read { try await oldNumber.fetch() } }
        await started(oldNumber)
        try state.updateNumber(info(second, number: "0634567890", epoch: 2, phase: "changed"))
        oldNumber.finish(info(second, number: "0623456789", epoch: 2, phase: "changed"))
        do { _ = try await refresh.value; preconditionFailure("Superseded number read succeeded") }
        catch is CancellationError {}
        precondition(state.line == .available(CellularLine(iccid: second, number: "0634567890", source: "manual")))

        let oldRouter = PendingRead()
        let stale = Task { try await state.read { try await oldRouter.fetch() } }
        await started(oldRouter)
        state.selectDevice("router-two")
        precondition(state.line == .loading && state.error == nil)
        state.observeIdentity(stamp(1))
        _ = try await state.read { info() }
        oldRouter.finish(info(second, number: "0623456789", epoch: 2))
        do { _ = try await stale.value; preconditionFailure("Old router response succeeded") }
        catch is CancellationError {}
        precondition(state.line == known, "Old router response replaced the selected router")

        _ = try await state.read { ["sim_states": "modem_no_sim"] }
        precondition(state.line == .unavailable, "Confirmed no-SIM must remain distinct from loading")
        state.selectDevice("router-three")
        do { _ = try await state.read { throw FixtureError.offline }; preconditionFailure() }
        catch FixtureError.offline {}
        precondition(state.line == .failed, "A network failure must not claim there is no SIM")
        _ = try await state.read { info(number: "") }
        precondition(state.line == .available(CellularLine(iccid: first, number: nil, source: "manual")))
        do { _ = try await state.read { ["sim_states": "modem_sim_ready"] }; preconditionFailure("Malformed SIM accepted") }
        catch LineError.invalid {}
        precondition(state.error != nil && state.line != .unavailable)
        try await sharedAgentClient()
        print("SIM state: shared reads, tab reentry, freshness, offline retention, card/router changes, stale replies, number edits and explicit unavailable/error states passed")
    }

    @MainActor private static func sharedAgentClient() async throws {
        let router = UUID()
        let client = AgentClient(baseURL: "http://[")
        client.relayAccess = {
            AgentRelayAccess(server: URL(string: "https://relay.invalid")!, token: "synthetic", routerID: router,
                             serverTime: Date().timeIntervalSince1970)
        }
        var requests: [String] = []
        let pending = PendingRead()
        client.peerRequest = { bytes, _, _, _ in
            let request = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let path = request["path"] as! String
            requests.append(path)
            let data = path == "/api/sim/info" ? try await pending.fetch() : stamp(1)
            return AgentHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: ["ok": true, "data": data]))
        }
        let home = Task { try await client.getJSON("/api/sim/info") }
        await started(pending)
        let settings = Task { try await client.getJSON("/api/sim/info") }
        await Task.yield()
        pending.finish(info())
        _ = try await (home.value, settings.value)
        precondition(requests == ["/api/sim/info"] && client.connectionRoute == .p2p,
                     "Shared SIM reads did not use the existing management transport")
        let monitor = Task { await client.watchSIMState() }
        for _ in 0..<100 {
            if requests.contains("/api/esim/switch") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        monitor.cancel()
        await monitor.value
        precondition(requests == ["/api/sim/info", "/api/esim/switch"], "Foreground monitor refetched a fresh SIM")
        precondition(client.simState.line == .available(CellularLine(iccid: first, number: "0612345678", source: "manual")))

        let stale = Task { try await client.getJSON("/api/sim/info") }
        // The fixture's fetch is reusable once the first read has completed.
        while requests.filter({ $0 == "/api/sim/info" }).count < 2 { await Task.yield() }
        let otherRouter = UUID()
        client.relayAccess = {
            AgentRelayAccess(server: URL(string: "https://relay.invalid")!, token: "synthetic", routerID: otherRouter,
                             serverTime: Date().timeIntervalSince1970)
        }
        pending.finish(info())
        do { _ = try await stale.value; preconditionFailure("A reply from the previous router was accepted") }
        catch is CancellationError {}
        precondition(client.simState.line == .loading, "Router selection did not clear the old current line")
    }
}

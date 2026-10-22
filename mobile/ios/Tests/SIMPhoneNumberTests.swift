import Foundation

enum DeviceParser { static func decodeSpn(_ value: String) -> String { value } }
@MainActor final class AuthManager {}
@MainActor final class AgentClient {
    var identityRevision = 0
    var writes: [(String, [String: Any])] = []
    var response: [String: Any] = [:]
    var failure: Error?
    var hold = false
    var gate: CheckedContinuation<Void, Never>?
    func watchSimIdentity() async {}
    func getJSON(_ path: String) async throws -> [String: Any] { response }
    func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] { [:] }
    func putJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        writes.append((path, body))
        if hold { await withCheckedContinuation { gate = $0 } }
        if let failure { throw failure }
        return response
    }
}

@main struct SIMPhoneNumberTests {
    @MainActor static func main() async throws {
        let iccid = "8901000000000000001F"
        let other = "8901000000000000002F"
        for (input, normalized) in [("0612345678", "0612345678"), ("+31 (6) 1234-5678", "+31612345678"),
                                    ("123", "123"), ("123456789012345", "123456789012345"), ("", "")] {
            precondition(SIMPhoneNumber.normalized(input) == normalized)
        }
        for input in ["+", "12", "1234567890123456", "１２３", "123\n456", "1+234"] {
            precondition(SIMPhoneNumber.normalized(input) == nil)
        }
        func data(_ iccid: String, _ number: String, manual: Bool) -> [String: Any] {
            ["sim_iccid": iccid, "sim_states": "sim ready", "msisdn": number,
             "msisdn_source": manual ? "manual" : "unavailable"]
        }
        let client = AgentClient()
        let model = SIMViewModel(client: client, authManager: AuthManager())
        model.simInfo = SIMParser.parseSIMInfo(data(iccid, "", manual: false))
        client.response = data(iccid, "0612345678", manual: true)
        try await model.savePhoneNumber("06 1234-5678", for: iccid)
        precondition(client.writes.last?.0 == "/api/sim/phone-number")
        precondition(client.writes.last?.1["iccid"] as? String == iccid)
        precondition(client.writes.last?.1["number"] as? String == "0612345678")
        precondition(model.simInfo.msisdn == "0612345678" && model.simInfo.phoneNumberIsManual)

        client.failure = AgentError.serverError("SIM changed")
        do { try await model.savePhoneNumber("0623456789", for: iccid); preconditionFailure("Failed writes must propagate") }
        catch { precondition(model.simInfo.msisdn == "0612345678") }
        client.failure = nil
        client.response = data(iccid, "", manual: false)
        try await model.savePhoneNumber("", for: iccid)
        precondition(client.writes.last?.1["number"] as? String == "")
        precondition(model.simInfo.msisdn.isEmpty && !model.simInfo.phoneNumberIsManual)

        client.hold = true
        client.response = data(iccid, "0612345678", manual: true)
        let pending = Task { try await model.savePhoneNumber("0612345678", for: iccid) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while client.gate == nil && ContinuousClock.now < deadline { await Task.yield() }
        precondition(client.gate != nil)
        model.simInfo = SIMParser.parseSIMInfo(data(other, "0623456789", manual: true))
        client.gate?.resume()
        do { try await pending.value; preconditionFailure("A response for the old SIM must not replace the current SIM") }
        catch { precondition(model.simInfo.iccid == other && model.simInfo.msisdn == "0623456789") }
        let writes = client.writes.count
        do { try await model.savePhoneNumber("0612345678", for: iccid); preconditionFailure("A stale editor must not write") }
        catch { precondition(client.writes.count == writes) }
        print("SIM phone number validation, shared save, reset and SIM-change handling passed")
    }
}

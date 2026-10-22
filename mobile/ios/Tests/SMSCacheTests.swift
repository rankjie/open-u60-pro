import Foundation

@MainActor private final class Identity { var router: UUID? = UUID() }
@MainActor private final class Gate {
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation!.resume(); continuation = nil }
}
private func message(_ id: Int, tag: Int = 1, text: String = "Synthetic SMS 🐼") -> [String: Any] {
    ["id": id, "number": id == 3 ? "PROVIDER" : "+12025550123", "content": text,
     "date": "26,10,22,12,00,00,+0", "tag": String(tag), "mem_store": "nv"]
}
@MainActor final class AgentClient {
    var messages = [message(3), message(2), message(1, tag: 0)]
    var offline = false
    var malformed = false
    var requests = 0
    fileprivate var gate: Gate?
    func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        switch path {
        case "/api/sms/list":
            requests += 1
            if offline { throw URLError(.notConnectedToInternet) }
            let snapshot = messages
            if let gate { self.gate = nil; await gate.wait() }
            return malformed ? [:] : ["messages": snapshot]
        case "/api/sms/read":
            let ids = (body["id"] as! String).split(separator: ";").compactMap { Int($0) }
            for index in messages.indices where ids.contains(messages[index]["id"] as! Int) { messages[index]["tag"] = "0" }
            return [:]
        case "/api/sms/delete":
            let ids = (body["id"] as! String).split(separator: ";").compactMap { Int($0) }
            messages.removeAll { ids.contains($0["id"] as! Int) }
            return [:]
        default: preconditionFailure("Unexpected SMS request")
        }
    }
    func getJSON(_ path: String, retryOnUnauthorized: Bool) async throws -> [String: Any] {
        if offline { throw URLError(.notConnectedToInternet) }
        return ["sms_nv_total": 500, "sms_nvused_total": messages.count, "sms_dev_unread_num": 2]
    }
}

@main private struct SMSCacheTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sms-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = Identity(), client = AgentClient()
        func make() -> SMSViewModel { SMSViewModel(client: client, identity: { identity.router }, directory: directory) }
        let inbox = make()
        precondition(inbox.allMessages.isEmpty && inbox.error == nil)
        await inbox.refresh(force: false)
        precondition(inbox.allMessages.count == 3 && inbox.conversations.count == 2)
        let cold = make()
        precondition(cold.allMessages == inbox.allMessages && cold.capacity.nvUsed == 3,
                     "A cold start must display complete cached SMS before any request")
        client.offline = true; await cold.refresh()
        precondition(cold.allMessages == inbox.allMessages && cold.error != nil, "Offline refresh must keep cached SMS")
        client.offline = false
        let requestCount = client.requests
        await inbox.refresh(force: false)
        precondition(client.requests == requestCount, "Reentering a fresh list must not reload it")

        client.messages = [message(4, text: "New synthetic message"), message(3, tag: 0), message(1, tag: 0)]
        await inbox.refresh()
        precondition(inbox.allMessages.map(\.id) == [4, 3, 1] && inbox.allMessages[1].tag == .read,
                     "Reconciliation must insert new SMS, update read state and remove deleted SMS")
        precondition(make().allMessages == inbox.allMessages)
        client.malformed = true; await inbox.refresh()
        precondition(inbox.allMessages.count == 3 && inbox.error != nil, "A malformed response must not erase the inbox")
        client.malformed = false

        await inbox.markAsRead(ids: [4])
        precondition(make().allMessages.first?.tag == .read, "Read state must survive relaunch")
        client.offline = true
        await inbox.deleteMessages(ids: [3])
        precondition(inbox.allMessages.map(\.id) == [4, 1] && make().allMessages == inbox.allMessages,
                     "An acknowledged delete must persist even if the following refresh fails")
        client.offline = false

        client.messages = [message(7)]
        await inbox.refresh()
        let readGate = Gate(); client.gate = readGate
        let staleRead = Task { await inbox.refresh() }
        while !readGate.waiting { await Task.yield() }
        await inbox.markAsRead(ids: [7]); readGate.release(); await staleRead.value
        precondition(inbox.allMessages[0].tag == .read && make().allMessages[0].tag == .read,
                     "An older refresh must not undo an acknowledged read")

        let notificationGate = Gate(); client.gate = notificationGate
        let navigatingAway = Task { await inbox.refresh() }
        while !notificationGate.waiting { await Task.yield() }
        navigatingAway.cancel()
        client.messages.insert(message(8), at: 0)
        inbox.receive(["eventId": UUID().uuidString, "routerId": identity.router!.uuidString, "messageId": "8"])
        let notified = Task { await inbox.refresh() }
        await Task.yield(); notificationGate.release()
        await navigatingAway.value; await notified.value
        precondition(inbox.allMessages.map(\.id) == [8, 7] && make().allMessages == inbox.allMessages,
                     "A notification during refresh must catch up even if its original view disappears")

        let originalRouter = identity.router
        let lineA: [String: Any] = ["iccid": "890000000000000001", "number": "+12025550101", "source": "manual"]
        let lineB: [String: Any] = ["iccid": "890000000000000002", "number": "+12025550102", "source": "sim"]
        client.messages[0]["line"] = lineB; client.messages[1]["line"] = lineA
        await inbox.refresh()
        precondition(inbox.allMessages.map { $0.line?.number } == ["+12025550102", "+12025550101"])
        await inbox.markAsRead(ids: [7, 8])
        precondition(make().allMessages.map { $0.line?.number } == ["+12025550102", "+12025550101"],
                     "Read updates and relaunch must retain each message's original line")
        precondition(inbox.conversations.first?.messages.last?.line?.number == "+12025550102")
        let switchGate = Gate(); client.gate = switchGate
        let staleRouter = Task { await inbox.refresh() }
        while !switchGate.waiting { await Task.yield() }
        identity.router = UUID(); inbox.loadCached()
        precondition(inbox.allMessages.isEmpty && inbox.conversations.isEmpty, "A new router cannot show another router's SMS")
        client.messages = [message(9)]; await inbox.refresh()
        switchGate.release(); await staleRouter.value
        precondition(inbox.allMessages.map(\.id) == [9], "A previous router's late response must be ignored")
        identity.router = originalRouter; inbox.loadCached()
        precondition(inbox.allMessages.map(\.id) == [8, 7], "Returning to a router must restore its own cached SMS")

        let cacheURL = directory.appending(path: "\(identity.router!.uuidString.lowercased()).json")
        try Data("invalid".utf8).write(to: cacheURL)
        let corrupt = make()
        precondition(corrupt.allMessages.isEmpty && corrupt.error != nil, "Corrupt cache data must be reported")
        await corrupt.refresh()
        precondition(make().allMessages.map(\.id) == [9], "A successful refresh must repair a corrupt cache")
        identity.router = nil
        let unpaired = make(); await unpaired.refresh()
        precondition(unpaired.allMessages.map(\.id) == [9], "Local-only SMS must keep working before remote pairing")
        print("SMS cache: immediate cold start, offline retention, ID reconciliation, freshness, notifications, read/delete persistence, stale requests and router isolation passed")
    }
}

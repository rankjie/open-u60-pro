import Foundation

private actor RouterFixture {
    enum Mode { case local, offline, wrongRouter, lostWrite, explicitFailure, unauthorized, malformed }
    let router: UUID
    let mode: Mode
    var requests: [URLRequest] = []
    var inFlight = 0
    var maximum = 0
    init(router: UUID, mode: Mode) { self.router = router; self.mode = mode }
    func load(_ request: URLRequest) async throws -> AgentHTTPResponse {
        requests.append(request)
        if request.url!.path == "/api/identity" {
            if mode == .offline { throw URLError(.cannotConnectToHost) }
            let id = mode == .wrongRouter ? UUID() : router
            return try response(200, ["ok":true, "data":["protocol":1,"routerId":id.uuidString,"agentTime":1_700_000_000]])
        }
        if request.url!.path == "/api/management" {
            if mode == .lostWrite { throw URLError(.networkConnectionLost) }
            if mode == .explicitFailure { return try response(503,["ok":false,"error":"modem_unavailable"]) }
            return try response(200,["ok":true,"data":["source":"local"]])
        }
        precondition(request.url!.path == "/openu60/v1/agent")
        inFlight += 1; maximum = max(maximum, inFlight)
        defer { inFlight -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        if mode == .unauthorized { return try response(401,["error":"unauthorized"]) }
        if mode == .malformed { return try response(200,["requestId":UUID().uuidString,"status":200,"body":"e30="]) }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String:Any]
        let status = mode == .lostWrite ? 409 : 200
        let data = try JSONSerialization.data(withJSONObject: mode == .lostWrite
            ? ["ok":false,"error":"agent_request_completed"] : ["ok":true,"data":["source":"relay"]])
        return try response(200,["requestId":body["requestId"]!,"status":status,"body":data.base64EncodedString()])
    }
    private func response(_ status: Int, _ body: [String:Any]) throws -> AgentHTTPResponse {
        AgentHTTPResponse(status: status, data: try JSONSerialization.data(withJSONObject: body))
    }
}

@main struct AgentTransportTests {
    @MainActor static func main() async throws {
        let router = UUID()
        let access = AgentRelayAccess(server: URL(string:"https://relay.invalid/openu60")!, token:"synthetic-phone", routerID:router,
                                      serverTime:Date().timeIntervalSince1970)
        let message = Data(#"{"number":"12345","message_body":"synthetic"}"#.utf8)
        for mode: RouterFixture.Mode in [.local,.wrongRouter,.offline,.lostWrite,.explicitFailure] {
            let fixture = RouterFixture(router:router,mode:mode)
            let transport = AgentTransport(load: { request, _ in try await fixture.load(request) })
            var logins = 0
            let response = try await transport.send(method:"POST",path:"/api/sms/send",body:message,baseURL:"http://192.168.0.1:9090",
                access:access,token:{"synthetic-admin"},reauthenticate:{logins += 1; return false})
            let requests = await fixture.requests
            precondition(logins == 0)
            let local = requests.filter { $0.url!.path == "/api/management" }
            let relay = requests.filter { $0.url!.path == "/openu60/v1/agent" }
            switch mode {
            case .local:
                precondition(local.count == 1 && relay.isEmpty && transport.route == .local)
                precondition(local[0].value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-admin")
                let payload = try JSONSerialization.jsonObject(with:local[0].httpBody!) as! [String:Any]
                precondition((1_700_000_001...1_700_000_020).contains(payload["expiresAt"] as! Int), "Device expiry follows its clock")
            case .wrongRouter,.offline:
                precondition(local.isEmpty && relay.count == 1 && transport.route == .relay)
                precondition(relay[0].value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-phone")
            case .lostWrite:
                precondition(local.count == 1 && relay.count == 1 && response.status == 409)
                let left = try JSONSerialization.jsonObject(with:local[0].httpBody!) as! [String:Any]
                let right = try JSONSerialization.jsonObject(with:relay[0].httpBody!) as! [String:Any]
                for key in ["requestId","method","path","body"] { precondition(left[key] as? String == right[key] as? String) }
                precondition(Data(base64Encoded:right["body"] as! String) == message)
            case .explicitFailure:
                precondition(response.status == 503 && relay.isEmpty, "A modem failure must not replay a write")
            default: preconditionFailure()
            }
        }
        // A mismatch must never trigger a saved-password login to the unrelated local host.
        let mismatch = RouterFixture(router:router,mode:.wrongRouter)
        let mismatchTransport = AgentTransport(load:{ request, _ in try await mismatch.load(request) })
        _ = try await mismatchTransport.send(method:"GET",path:"/api/battery",body:nil,baseURL:"http://foreign.invalid",access:access,
                                             token:{nil},reauthenticate:{preconditionFailure("Credential sent to unverified router")})
        let invalidLocal = RouterFixture(router:router,mode:.local)
        let invalidLocalTransport = AgentTransport(load:{ request, _ in try await invalidLocal.load(request) })
        let relayed = try await invalidLocalTransport.send(method:"GET",path:"/api/battery",body:nil,baseURL:"http://[",access:access,
            token:{nil},reauthenticate:{preconditionFailure("Invalid local URL must not trigger login")})
        let invalidLocalRequests = await invalidLocal.requests
        precondition(relayed.status == 200 && invalidLocalTransport.route == .relay)
        precondition(invalidLocalRequests.count == 1 && invalidLocalRequests[0].url!.path == "/openu60/v1/agent",
                     "An invalid saved LAN URL must still allow the paired server route")
        // Concurrent dashboard reads share one probe and stay below the router/server limit.
        let fixture = RouterFixture(router:router,mode:.offline)
        let transport = AgentTransport(load:{ request, _ in try await fixture.load(request) })
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<16 { group.addTask { @MainActor in
                let result = try await transport.send(method:"GET",path:"/api/battery",body:nil,baseURL:"http://192.168.0.1:9090",
                    access:access,token:{nil},reauthenticate:{false})
                precondition(result.status == 200)
            } }
            try await group.waitForAll()
        }
        let requests = await fixture.requests
        precondition(requests.filter{$0.url!.path == "/api/identity"}.count == 1)
        let maximum = await fixture.maximum
        precondition(maximum <= 6)
        for mode: RouterFixture.Mode in [.unauthorized,.malformed] {
            let fixture = RouterFixture(router:router,mode:mode)
            let transport = AgentTransport(load:{ request, limit in
                if request.url!.path == "/api/identity" { throw URLError(.cannotConnectToHost) }
                return try await fixture.load(request)
            })
            do {
                _ = try await transport.send(method:"GET",path:"/api/battery",body:nil,baseURL:"http://192.168.0.1:9090",access:access,
                    token:{nil},reauthenticate:{preconditionFailure("Remote revocation must not relogin locally")})
                preconditionFailure("Invalid relay response accepted")
            } catch AgentError.remoteUnauthorized { precondition(mode == .unauthorized) }
              catch AgentError.decodingError { precondition(mode == .malformed) }
        }
        print("Agent transport: verified LAN preference, clock domains, relay fallback, stable write IDs, explicit failures, revocation and concurrency passed")
    }
}

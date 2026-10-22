import Foundation

// Compile with DeviceModels.swift and RouterSettingsModels.swift.
@main struct USBStatusTests {
    static func main() throws {
        for (cc, active, visible) in [("no_cc", 0, false), ("cc1", 0, true), ("no_cc", 1, true), ("cc1", 1, true)] {
            let status = try DeviceParser.parseUSBStatus([
                "mode": "debug", "typec_cc": cc, "connect": 0, "powerbank_state": active,
            ])
            precondition(status.powerbankActive == (active == 1))
            precondition(
                status.showsPowerControl == visible,
                "An active power source must retain its off switch even when firmware clears CC")
        }
        for value: [String: Any] in [[:], ["powerbank_state": 2], ["powerbank_state": -1]] {
            do {
                _ = try DeviceParser.parseUSBStatus(value)
                preconditionFailure("Missing or invalid power state must be explicit")
            } catch USBStatusError.missingPowerState {}
        }
        for (minimum, minutes) in [(nil, nil), (20, nil), (nil, 120), (30, 60)] as [(Int?, Int?)] {
            let policy = USBPowerReservePolicy(minCapacityPercent: minimum, reserveMinutes: minutes)
            let encoded = try JSONEncoder().encode(policy)
            let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            precondition(object.count == 2)
            precondition(minimum == nil ? object["min_capacity_percent"] is NSNull : object["min_capacity_percent"] as? Int == minimum)
            precondition(minutes == nil ? object["reserve_minutes"] is NSNull : object["reserve_minutes"] as? Int == minutes)
            let decoded = try JSONDecoder().decode(USBPowerReservePolicy.self, from: encoded)
            precondition(decoded == policy)
        }
        let status = try JSONDecoder().decode(USBPowerReserveStatus.self, from: Data(#"{"policy":{"min_capacity_percent":20,"reserve_minutes":120},"baseline_ready":true,"router_load_w":2.5,"router_runtime_minutes":245,"pending_stop":"reserved_runtime","last_stop":{"reason":"minimum_battery","at":123},"error":"BSP stop pending"}"#.utf8))
        precondition(status.policy?.reserveMinutes == 120 && status.routerLoadW == 2.5)
        precondition(status.runtimeText == "≈ 4h 5m")
        precondition(status.stopText == "Stopping USB output: router runtime reserve reached")
        let unknown = try JSONDecoder().decode(USBPowerReserveStatus.self, from: Data(#"{"policy":null,"baseline_ready":false,"error":"Invalid power reserve settings"}"#.utf8))
        precondition(unknown.policy == nil && unknown.runtimeText == "—" && unknown.error != nil)
        print("USB reserve JSON, explicit disabled limits, pending stop and runtime display checks passed")
        print("USB status and source-mode control checks passed")
    }
}

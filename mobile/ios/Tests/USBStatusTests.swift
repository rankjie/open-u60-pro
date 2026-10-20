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
        print("USB status and source-mode control checks passed")
    }
}

import Foundation

// Run from the repository root: sh scripts/test-router-esim.sh
@main
struct MobileNetworkTests {
    static func main() {
        var connection = MobileNetworkConfig.empty
        for state in ["connected", "ipv4_connected", "ipv6_connected", "ipv4_ipv6_connected"] {
            connection.connectStatus = state
            precondition(connection.isConnected, "An established cellular connection must be shown as connected")
        }
        for state in ["", "disconnected", "disconnecting", "not_connected"] {
            connection.connectStatus = state
            precondition(!connection.isConnected, "Disconnected must not match the connected substring")
        }
        // A roaming eSIM profile with roaming off: the router reports mobile data off.
        var blocked = MobileNetworkConfig.empty
        blocked.roamEnable = 0
        blocked.dataEnabled = 0
        let on = blocked.connectionBody(connectMode: 1, roaming: true)
        precondition(on["roam_enable"] as? Int == 1)
        precondition(on["enable"] as? Int == 1, "turning roaming on also turns mobile data on")

        // Other changes never send the data switch: the agent keeps the modem's current value,
        // so a stale copy here cannot turn data off (roaming off did on 2026-10-22).
        let modeOnly = blocked.connectionBody(connectMode: 0, roaming: false)
        precondition(modeOnly["enable"] == nil && modeOnly["roam_enable"] == nil && modeOnly["connect_mode"] as? Int == 0)
        var roaming = blocked
        roaming.roamEnable = 1
        roaming.dataEnabled = 0  // stale: the modem's data is on
        let roamingOff = roaming.connectionBody(connectMode: 1, roaming: false)
        precondition(roamingOff["enable"] == nil, "turning roaming off must not send the data switch")
        precondition(roamingOff["roam_enable"] as? Int == 0 && roamingOff["connect_mode"] == nil)
        print("MobileNetworkTests: cellular connection states, roaming and mobile data settings passed")
    }
}

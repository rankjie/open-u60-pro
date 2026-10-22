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

        // Other changes keep the user's mobile data choice.
        let modeOnly = blocked.connectionBody(connectMode: 0, roaming: false)
        precondition(modeOnly["enable"] as? Int == 0, "data the user turned off stays off")
        var roaming = blocked
        roaming.roamEnable = 1
        roaming.dataEnabled = 1
        precondition(roaming.connectionBody(connectMode: 1, roaming: false)["enable"] as? Int == 1)
        precondition(roaming.connectionBody(connectMode: 1, roaming: false)["roam_enable"] as? Int == 0)
        print("MobileNetworkTests: cellular connection states, roaming and mobile data settings passed")
    }
}

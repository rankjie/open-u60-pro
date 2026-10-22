import Foundation

@main
struct NetworkTypeTests {
    static func main() {
        let cases: [(String, OperatorInfo.NetworkMode)] = [
            ("SA", .sa), ("5G SA", .sa), ("NR SA", .sa), ("NR-SA", .sa),
            ("NR5G-SA", .sa), ("NR5G_SA", .sa), ("nr5g-sa", .sa), ("NR5G SA", .sa),
            ("NSA", .nsa), ("NR5G-NSA", .nsa), ("NR5G_NSA", .nsa), ("ENDC", .nsa), ("5G NSA", .nsa),
            ("LTE", .lte), ("4G", .lte), ("LTE-CA", .lte),
            ("WCDMA", .legacy), ("GSM", .legacy),
            ("", .unknown), ("NO_SERVICE", .unknown), ("SAMSUNG", .unknown),
        ]
        for (raw, expected) in cases {
            var info = OperatorInfo()
            info.networkType = raw
            precondition(info.networkMode == expected, "\(raw) → \(info.networkMode), expected \(expected)")
        }
        print("Network type: SA/NSA/LTE/legacy spellings passed")
    }
}

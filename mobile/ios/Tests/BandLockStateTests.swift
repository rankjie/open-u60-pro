import Foundation

@main
struct BandLockStateTests {
    static func main() {
        // Values as read from a U60 (nwinfo_get_netinfo) on 2026-10-22.
        let device: [String: Any] = [
            "lte_band": "1,3,7,8,20,28,32,38,40,41,42,43",
            "lte_band_lock": "0x7a0880800c5",
            "nr5g_sa_band_lock": "1,3,7,8,20,28,38,40,41,75,77,78",
            "nr5g_nsa_band_lock": "1,3,7,8,20,28,38,40,41,75,77,78",
        ]
        let config = BandConfig.current(device)
        precondition(config?.lteBands == ["1", "3", "7", "8", "20", "28", "32", "38", "40", "41", "42", "43"])
        precondition(config?.nrBands == ["1", "3", "7", "8", "20", "28", "38", "40", "41", "75", "77", "78"])
        // The mask is the authority when the list is missing.
        let maskOnly = BandConfig.current(["lte_band_lock": "0x5", "nr5g_sa_band_lock": "78"])
        precondition(maskOnly?.lteBands == ["1", "3"] && maskOnly?.nrBands == ["78"])
        // Older agents or a modem without the fields: unknown, not "no bands".
        precondition(BandConfig.current([:]) == nil)
        precondition(BandConfig.current(["lte_band": "", "nr5g_sa_band_lock": ""]) == nil)
        precondition(BandConfig.current(["lte_band_lock": "zz"]) == nil)
        print("Band lock state: list, mask and missing-field parsing passed")
    }
}

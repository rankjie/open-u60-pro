import Foundation

struct BandConfig: Equatable {
    var nrBands: Set<String> = []
    var lteBands: Set<String> = []

    static let empty = BandConfig()

    /// The modem's current band selection from nwinfo_get_netinfo (/api/network/signal):
    /// `lte_band` lists the allowed LTE bands (`lte_band_lock` is the same set as a bit mask)
    /// and `nr5g_sa_band_lock` the allowed NR bands. Nil when the modem reports neither.
    static func current(_ data: [String: Any]) -> BandConfig? {
        func list(_ key: String) -> Set<String> {
            Set((data[key] as? String ?? "").split(separator: ",").compactMap {
                let band = $0.trimmingCharacters(in: .whitespaces)
                return Int(band).map(String.init)
            })
        }
        var lte = list("lte_band")
        if lte.isEmpty, let raw = data["lte_band_lock"] as? String, raw.hasPrefix("0x"),
           let mask = UInt64(raw.dropFirst(2), radix: 16) {
            lte = Set((0..<64).filter { mask >> $0 & 1 == 1 }.map { String($0 + 1) })
        }
        let nr = list("nr5g_sa_band_lock")
        guard !lte.isEmpty || !nr.isEmpty else { return nil }
        return BandConfig(nrBands: nr, lteBands: lte)
    }

    static let commonNRBands = ["1", "2", "3", "5", "7", "8", "12", "20", "25", "28", "38", "40", "41", "48", "66", "71", "77", "78", "79"]
    static let commonLTEBands = ["1", "2", "3", "4", "5", "7", "8", "12", "13", "14", "17", "20", "25", "26", "28", "29", "30", "32", "38", "39", "40", "41", "42", "43", "46", "48", "66", "71"]

    var nrBandString: String {
        nrBands.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.joined(separator: ",")
    }

    var lteBandString: String {
        lteBands.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }.joined(separator: ",")
    }

    // MARK: - Frequency Lookup

    static func lteFrequency(band: String) -> String? {
        BandSpecDatabase.lte(band)?.commonName
    }

    static func nrFrequency(band: String) -> String? {
        BandSpecDatabase.nr(band)?.commonName
    }
}

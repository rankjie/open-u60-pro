import Foundation

struct CellularLine: Codable, Equatable, Sendable {
    let iccid: String
    let number: String?
    let source: String

    var label: String { number ?? "SIM ····\(iccid.suffix(4)) · Number not set" }
    var simLabel: String { "SIM ····\(iccid.suffix(4))" }

    static func decode(_ value: Any?) throws -> CellularLine? {
        guard let value, !(value is NSNull) else { return nil }
        let line = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
        guard (18...22).contains(line.iccid.count), line.iccid.allSatisfy({ $0.isNumber || $0 == "F" || $0 == "f" }),
              ["sim", "manual", "unavailable"].contains(line.source),
              line.number.map({ !$0.isEmpty && (3...15).contains($0.filter(\.isNumber).count)
                  && $0.enumerated().allSatisfy({ $0.element.isNumber || ($0.offset == 0 && $0.element == "+") }) }) ?? true
        else { throw LineError.invalid }
        return line
    }

    static func current(_ data: [String: Any]) throws -> CellularLine? {
        guard let state = data["sim_states"] as? String else { throw LineError.invalid }
        guard state.lowercased().contains("ready"), !state.lowercased().contains("not") else { return nil }
        guard let iccid = data["sim_iccid"] as? String, let number = data["msisdn"] as? String,
              let source = data["msisdn_source"] as? String else { throw LineError.invalid }
        return try decode(["iccid": iccid, "number": number.isEmpty ? NSNull() : number as Any, "source": source])
    }
}
enum LineError: LocalizedError {
    case invalid
    var errorDescription: String? { "The U60 returned invalid SIM line information." }
}

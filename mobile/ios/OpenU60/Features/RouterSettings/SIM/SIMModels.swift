import Foundation

struct SIMInfo: Equatable {
    var iccid: String = ""
    var imsi: String = ""
    var msisdn: String = ""
    var phoneNumberIsManual: Bool = false
    var spn: String = ""
    var mcc: String = ""
    var mnc: String = ""
    var simStatus: String = ""
    var operatorName: String = ""
    var currentSlot: String = ""
    var pinStatus: String = ""
    var pinAttempts: Int = 0
    var pukAttempts: Int = 0
    var provisionState: String = ""
    var modemMainState: String = ""

    static let empty = SIMInfo()

    var canEditPhoneNumber: Bool {
        let state = simStatus.lowercased()
        return !iccid.isEmpty && state.contains("ready") && !state.contains("not")
    }
}

enum SIMPhoneNumber {
    static func normalized(_ input: String) -> String? {
        var number = ""
        for character in input {
            switch character {
            case "0"..."9": number.append(character)
            case "+" where number.isEmpty: number.append(character)
            case " ", "-", "(", ")": break
            default: return nil
            }
        }
        let digits = number.hasPrefix("+") ? number.dropFirst() : number[...]
        return number.isEmpty || (3...15).contains(digits.count) ? number : nil
    }
}

enum SIMPhoneNumberError: LocalizedError {
    case invalidNumber
    case simChanged

    var errorDescription: String? {
        switch self {
        case .invalidNumber: return "Enter a phone number with 3 to 15 digits, optionally starting with +."
        case .simChanged: return "SIM changed or is not ready. Refresh and try again."
        }
    }
}

struct SIMLockInfo: Equatable {
    var availableTrials: Int = 0

    static let empty = SIMLockInfo()
}

enum SIMParser {
    static func parseSIMInfo(_ data: [String: Any]) -> SIMInfo {
        var info = SIMInfo()
        info.iccid = data["sim_iccid"] as? String ?? ""
        info.imsi = data["sim_imsi"] as? String ?? ""
        info.msisdn = data["msisdn"] as? String ?? ""
        info.phoneNumberIsManual = data["msisdn_source"] as? String == "manual"
        info.mcc = data["mdm_mcc"] as? String ?? ""
        info.mnc = data["mdm_mnc"] as? String ?? ""
        info.simStatus = data["sim_states"] as? String ?? ""
        info.operatorName = data["Operator"] as? String ?? ""
        info.currentSlot = data["current_sim_slot"] as? String ?? ""
        info.pinStatus = data["pin_status"] as? String ?? ""
        info.pinAttempts = asInt(data["pinnumber"]) ?? 0
        info.pukAttempts = asInt(data["puknumber"]) ?? 0
        info.provisionState = data["sim1_provision_state"] as? String ?? ""
        info.modemMainState = data["modem_main_state"] as? String ?? ""
        if let spnHex = data["spn_name_data"] as? String {
            info.spn = DeviceParser.decodeSpn(spnHex)
        }
        return info
    }

    static func parseSIMLock(_ data: [String: Any]) -> SIMLockInfo {
        SIMLockInfo(availableTrials: asInt(data["available_trials"]) ?? 0)
    }

    private static func asInt(_ val: Any?) -> Int? {
        if let i = val as? Int { return i }
        if let s = val as? String { return Int(s) }
        if let d = val as? Double { return Int(d) }
        return nil
    }
}

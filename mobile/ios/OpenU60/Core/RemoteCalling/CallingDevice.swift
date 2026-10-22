import Darwin
import Foundation
import UIKit

struct CallPhone: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let model: String
}

struct CallingDeviceInfo: Codable, Equatable, Sendable {
    let name: String
    let model: String

    @MainActor static func current() throws -> CallingDeviceInfo {
        var system = utsname()
        guard uname(&system) == 0 else { throw DeviceInfoError.unavailable }
        let capacity = MemoryLayout.size(ofValue: system.machine)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        return CallingDeviceInfo(name: displayName(assigned: UIDevice.current.name, model: model,
                                                   category: UIDevice.current.model), model: model)
    }

    static func displayName(assigned: String, model: String, category: String = "iPhone") -> String {
        let assigned = assigned.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !assigned.isEmpty, !["iphone", "ipad", "ipod touch"].contains(assigned.lowercased()) {
            return String(assigned.prefix(80))
        }
        // iOS may return only "iPhone" without the user-assigned device-name entitlement.
        switch model {
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone18,1": return "iPhone 17 Pro"
        default: return "\(category) (\(model))"
        }
    }
}

private enum DeviceInfoError: LocalizedError {
    case unavailable
    var errorDescription: String? { "This iPhone could not identify its device model." }
}

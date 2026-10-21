import Foundation

enum RouterInvitation {
    enum ImportError: LocalizedError {
        case invalidFile
        var errorDescription: String? { "The transferred server invitation is invalid. Request a new invitation file." }
    }

    static func read(from file: URL) throws -> String {
        let metadata = try FileManager.default.attributesOfItem(atPath: file.path)
        guard metadata[.type] as? FileAttributeType == .typeRegular,
              let size = metadata[.size] as? Int, (43...64).contains(size) else { throw ImportError.invalidFile }
        let value = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count == 43,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
        else { throw ImportError.invalidFile }
        return value
    }
}

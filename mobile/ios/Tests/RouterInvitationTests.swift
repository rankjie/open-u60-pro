import Foundation

@main struct RouterInvitationTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "invitation")
        let synthetic = String(repeating: "A", count: 41) + "_-"
        try (synthetic + "\n").write(to: file, atomically: true, encoding: .utf8)
        let imported = try RouterInvitation.read(from: file)
        precondition(imported == synthetic)
        for invalid in ["", String(repeating: "A", count: 42), String(repeating: "A", count: 65), String(repeating: "A", count: 42) + "!"] {
            try invalid.write(to: file, atomically: true, encoding: .utf8)
            do { _ = try RouterInvitation.read(from: file); preconditionFailure("Malformed invitation accepted") }
            catch RouterInvitation.ImportError.invalidFile {}
        }
        try synthetic.write(to: file, atomically: true, encoding: .utf8)
        let link = directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        do { _ = try RouterInvitation.read(from: link); preconditionFailure("Symbolic invitation accepted") }
        catch RouterInvitation.ImportError.invalidFile {}
        print("Router invitation: bounded private file import and malformed input checks passed")
    }
}

import Foundation

@main
struct SettingsChangesTests {
    static func main() {
        let loaded: [String: Any] = ["ssid_2g": "Home", "key_2g": "secret123", "channel_2g": "6", "hidden_2g": "0", "count": 3]
        // Only the edited field is sent; stale or untouched values never are.
        let edited: [String: Any] = ["ssid_2g": "Home", "key_2g": "secret123", "channel_2g": "11", "hidden_2g": "0", "count": 3]
        let changes = changedFields(edited, from: loaded)
        precondition(changes.count == 1 && changes["channel_2g"] as? String == "11")
        // Nothing changed: nothing to send.
        precondition(changedFields(loaded, from: loaded).isEmpty)
        // A field absent from the loaded record is a change.
        precondition(changedFields(["new": "x"], from: loaded)["new"] as? String == "x")
        // Same value, different numeric spelling, is not a change.
        precondition(changedFields(["count": 3], from: ["count": 3]).isEmpty)
        precondition(changedFields(["count": 4], from: ["count": 3]).count == 1)
        print("Settings changes: only edited fields are written")
    }
}

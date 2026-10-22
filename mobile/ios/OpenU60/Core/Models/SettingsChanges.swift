import Foundation

/// Fields whose edited value differs from the value last loaded from the router. Settings
/// screens send only these: a field the user did not change is never written from a copy that
/// may be stale (another phone, the router's screen) or a default left by a failed load.
func changedFields(_ edited: [String: Any], from loaded: [String: Any]) -> [String: Any] {
    edited.filter { key, value in
        guard let previous = loaded[key] else { return true }
        return !(String(describing: previous) == String(describing: value))
    }
}

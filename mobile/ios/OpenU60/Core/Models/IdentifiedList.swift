import Foundation

extension Array where Element: Identifiable & Equatable {
    /// Keep unchanged records in place while applying an authoritative list by identity.
    @discardableResult mutating func reconcile(with incoming: [Element]) -> Bool {
        let ids = Set(incoming.map(\.id))
        var changed = false
        let previousCount = count
        removeAll { !ids.contains($0.id) }
        changed = count != previousCount
        for (index, value) in incoming.enumerated() {
            if index < count, self[index].id == value.id {
                if self[index] != value { self[index] = value; changed = true }
            } else {
                if let existing = self[index...].firstIndex(where: { $0.id == value.id }) {
                    remove(at: existing)
                }
                insert(value, at: index)
                changed = true
            }
        }
        return changed
    }
}

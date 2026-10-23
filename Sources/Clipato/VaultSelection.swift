import AppKit

struct VaultSelection {
    var anchor: UUID?

    static func previewID(in orderedIDs: [UUID], selected: Set<UUID>, preferredID: UUID?) -> UUID? {
        if let preferredID, selected.contains(preferredID), orderedIDs.contains(preferredID) { return preferredID }
        return orderedIDs.first { selected.contains($0) }
    }

    static func draggedIDs(startingWith id: UUID, visibleIDs: Set<UUID>, selected: Set<UUID>) -> Set<UUID> {
        selected.contains(id) ? selected.intersection(visibleIDs) : [id]
    }

    mutating func select(_ id: UUID, in orderedIDs: [UUID], modifiers: NSEvent.ModifierFlags, selected: Set<UUID>) -> Set<UUID> {
        Self.select(id, in: orderedIDs, modifiers: modifiers, anchor: &anchor, selected: selected)
    }

    static func select<ID: Hashable>(_ id: ID, in orderedIDs: [ID], modifiers: NSEvent.ModifierFlags,
                                    anchor: inout ID?, selected: Set<ID>) -> Set<ID> {
        var result = selected
        if modifiers.contains(.shift) {
            if let anchor, let start = orderedIDs.firstIndex(of: anchor), let end = orderedIDs.firstIndex(of: id) {
                result.formUnion(orderedIDs[min(start, end)...max(start, end)])
            } else {
                anchor = id
                result.insert(id)
            }
        } else if modifiers.contains(.command) {
            anchor = id
            if result.contains(id) { result.remove(id) }
            else { result.insert(id) }
        } else {
            anchor = id
            result = [id]
        }
        return result
    }
}

/// Source presence and stable identity only; video frames and input sockets stay outside this policy.
public struct DisplaySceneItem: Equatable, Sendable {
    public let id: String
    public let isMain: Bool
    public let isActive: Bool

    public init(id: String, isMain: Bool, isActive: Bool) {
        self.id = id; self.isMain = isMain; self.isActive = isActive
    }
}

/// Separates active viewing from explicitly opened history without changing any Android display.
public struct DisplayScenePolicy: Sendable {
    private var hiddenInactiveIDs: Set<String> = []
    public private(set) var inspectedHistoryID: String?

    public init() {}

    /// Cleared OFF displays may still be enumerated by Android. Keep them hidden until
    /// that exact identity becomes active again; absence alone does not clear the tombstone.
    public mutating func accept(_ item: DisplaySceneItem) -> Bool {
        if item.isMain || item.isActive {
            hiddenInactiveIDs.remove(item.id)
            if inspectedHistoryID == item.id { inspectedHistoryID = nil }
            return true
        }
        return !hiddenInactiveIDs.contains(item.id)
    }

    public mutating func select(_ item: DisplaySceneItem) {
        inspectedHistoryID = !item.isMain && !item.isActive && !hiddenInactiveIDs.contains(item.id) ? item.id : nil
    }

    /// Only local history is cleared. Callers drop the corresponding cached frames.
    @discardableResult
    public mutating func clearHistory(_ items: [DisplaySceneItem]) -> Set<String> {
        let ids = Set(items.filter { !$0.isMain && !$0.isActive }.map(\.id))
        hiddenInactiveIDs.formUnion(ids)
        if let inspectedHistoryID, ids.contains(inspectedHistoryID) { self.inspectedHistoryID = nil }
        return ids
    }

    /// Changing devices ends history inspection, but remembered cleared IDs stay scoped by full identity.
    public mutating func resetSelection() { inspectedHistoryID = nil }

    public func visibleIDs(in items: [DisplaySceneItem]) -> [String] {
        items.filter {
            $0.isMain || $0.isActive || ($0.id == inspectedHistoryID && !hiddenInactiveIDs.contains($0.id))
        }.map(\.id)
    }

    /// A newly active secondary can follow automatically only while main input is not focused.
    /// Ignored arrival events are not queued to steal selection after typing ends.
    public func selection(afterUpdating items: [DisplaySceneItem], previous: String?,
                          newlyActive: [String], followNew: Bool, mainInputFocused: Bool) -> String? {
        let visible = visibleIDs(in: items)
        let mainID = items.first(where: \.isMain)?.id
        if mainInputFocused, let mainID { return mainID }
        if followNew, let newID = newlyActive.last(where: { id in
            items.contains { $0.id == id && !$0.isMain && $0.isActive }
        }) { return newID }
        if let previous, visible.contains(previous) { return previous }
        return mainID ?? visible.first
    }
}

/// Serializes replacement of one display's owned session without delaying other
/// displays. Cleanup may take seconds on an offline device; repeated retries
/// coalesce into one start after the old session has released its resources.
public struct StreamRestartGate {
    private var retiring = Set<String>()
    private var pending = Set<String>()

    public init() {}

    public mutating func requestStart(for id: String) -> Bool {
        guard retiring.contains(id) else { return true }
        pending.insert(id)
        return false
    }

    public mutating func beginRetirement(for id: String) {
        pending.remove(id)
        retiring.insert(id)
    }

    public mutating func cancelStart(for id: String) { pending.remove(id) }
    public mutating func cancelPendingStarts() { pending.removeAll() }

    public mutating func didRetire(_ id: String) -> Bool {
        retiring.remove(id)
        return pending.remove(id) != nil
    }
}

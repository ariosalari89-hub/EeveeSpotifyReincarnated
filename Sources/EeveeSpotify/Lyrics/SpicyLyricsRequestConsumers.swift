import Foundation

/// One network operation can serve several visible lyric surfaces. Leaving
/// one surface must not cancel the others. Once cancellation is observed the
/// group is sealed, so a late subscriber starts a fresh operation instead of
/// joining one that is already unwinding.
final class SpicyLyricsRequestConsumers {
    private let lock = NSLock()
    private var consumers = [UUID: () -> Bool]()
    private var sealed = false

    func add(_ isActive: @escaping () -> Bool) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed else { return nil }
        let id = UUID()
        consumers[id] = isActive
        return id
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        consumers.removeValue(forKey: id)
    }

    var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !sealed else { return false }
        // These callbacks only read their own cancellation flag; they must
        // not mutate/reenter this group or perform network/UI work.
        if consumers.values.contains(where: { $0() }) { return true }
        sealed = true
        return false
    }
}

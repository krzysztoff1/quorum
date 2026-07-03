import Foundation

/// Production clock — real wall time.
public struct SystemClock: RunClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(until deadline: Date) async throws {
        let interval = deadline.timeIntervalSinceNow
        if interval <= 0 { return }
        // Cap to avoid UInt64 overflow on absurd deadlines; a run's timeout never approaches this.
        let ns = UInt64(min(interval, 60 * 60 * 24 * 30) * 1_000_000_000)
        try await Task.sleep(nanoseconds: ns)
    }
}

/// Test clock — virtual time the test drives with `advance(by:)`. No real waiting.
/// A `class` (not actor) so `now()` stays synchronous for the runner's deadline comparison.
public final class TestClock: RunClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var nextID = 0
    private struct Sleeper { let deadline: Date; let cont: CheckedContinuation<Void, Error> }
    private var sleepers: [Int: Sleeper] = [:]

    public init(now: Date) { current = now }

    public func now() -> Date { lock.withLock { current } }

    public func sleep(until deadline: Date) async throws {
        let id = lock.withLock { () -> Int in nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); cont.resume(throwing: CancellationError()); return }
                if current >= deadline { lock.unlock(); cont.resume(); return }
                sleepers[id] = Sleeper(deadline: deadline, cont: cont)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let s = sleepers.removeValue(forKey: id)
            lock.unlock()
            s?.cont.resume(throwing: CancellationError())
        }
    }

    /// Advance virtual time; resume every sleeper whose deadline has now passed.
    public func advance(by duration: Duration) {
        lock.lock()
        current = current.addingTimeInterval(duration.seconds)
        let due = sleepers.filter { $0.value.deadline <= current }
        for id in due.keys { sleepers.removeValue(forKey: id) }
        lock.unlock()
        for s in due.values { s.cont.resume() }
    }
}

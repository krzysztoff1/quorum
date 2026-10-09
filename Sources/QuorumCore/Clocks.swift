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

import Foundation

public enum Selection: Hashable, Sendable {
    case new
    case question(String)
}

public struct RunStartGate: Equatable, Sendable {
    private var pending: Set<String> = []

    public init() {}

    private static let freshKey = "\u{0}new"

    private static func key(_ start: RunStart) -> String { start.questionID ?? freshKey }

    public func isPending(question: String) -> Bool { pending.contains(question) }

    public mutating func begin(_ start: RunStart, runningQuestions: Set<String>) -> Bool {
        let key = Self.key(start)
        if let question = start.questionID, runningQuestions.contains(question) { return false }
        return pending.insert(key).inserted
    }

    public mutating func finish(_ start: RunStart) { pending.remove(Self.key(start)) }
}

public enum RunOrigin: Equatable, Sendable {
    case composer
    case thread(String)
}

public enum AttachPlan {
    public struct Decision: Equatable, Sendable {
        public let resetComposer: Bool
        public let select: Bool
    }

    public static func decide(origin: RunOrigin, selectionAtStart: Selection, selectionNow: Selection) -> Decision {
        Decision(resetComposer: origin == .composer, select: selectionNow == selectionAtStart)
    }
}

public struct FollowUpRequests: Equatable, Sendable {
    private var seeds: [String: String] = [:]
    private var counts: [String: Int] = [:]

    public init() {}

    public mutating func request(question: String, seed: String? = nil) {
        if let seed { seeds[question] = seed }
        counts[question, default: 0] += 1
    }

    public func count(for question: String) -> Int { counts[question] ?? 0 }

    public mutating func takeSeed(for question: String) -> String? { seeds.removeValue(forKey: question) }
}

public struct Expiring<Value: Sendable>: Sendable {
    private let ttl: TimeInterval
    private var stored: (value: Value, at: Date)?

    public init(ttl: TimeInterval) { self.ttl = ttl }

    public func value(at now: Date) -> Value? {
        guard let stored, now.timeIntervalSince(stored.at) < ttl else { return nil }
        return stored.value
    }

    public mutating func store(_ value: Value, at now: Date) { stored = (value, now) }

    public mutating func invalidate() { stored = nil }
}

public enum ThreadTrash {
    public enum Outcome: Equatable, Sendable { case trashed, stillRunning, failed }

    public static func perform(thread: QuestionThread, brain: URL,
                               stop: (String) async -> Void,
                               isStillRunning: (String) async -> Bool,
                               trash: (URL) throws -> Void,
                               pause: () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) },
                               attempts: Int = 40) async -> Outcome {
        let running = thread.runs.filter(\.isRunning).map(\.id)
        for runID in running {
            await stop(runID)
            var settled = false
            for _ in 0..<attempts {
                if !(await isStillRunning(runID)) { settled = true; break }
                await pause()
            }
            if !settled { return .stillRunning }
        }
        guard let first = thread.runs.first else { return .failed }
        let questionDir = first.runDir.deletingLastPathComponent().deletingLastPathComponent()
        do { try trash(questionDir) } catch { return .failed }
        for export in AnswerExport.urls(forQuestion: thread.id, in: brain) { try? FileManager.default.removeItem(at: export) }
        return .trashed
    }
}

public final class RecentlyUsed<Key: Hashable, Value> {
    private let capacity: Int
    private var order: [Key] = []
    private var values: [Key: Value] = [:]

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    public func set(_ value: Value, for key: Key) {
        values[key] = value
        touch(key)
        while order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }

    public func value(for key: Key, build: () -> Value) -> Value {
        if let cached = value(for: key) { return cached }
        let built = build()
        set(built, for: key)
        return built
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

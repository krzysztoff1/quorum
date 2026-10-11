import Foundation

public struct UIState: Codable, Equatable, Sendable {
    public static let file = "ui-state.json"
    public static let schema = "quorum.ui/1"

    public var schema = UIState.schema
    public private(set) var readAt: [String: Date] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schema
        case readAt = "read_at"
    }

    public func isUnread(question: String, latestFinish: Date?) -> Bool {
        guard let latestFinish else { return false }
        guard let read = readAt[question] else { return true }
        return latestFinish > read
    }

    public mutating func markRead(question: String, at date: Date) {
        if let read = readAt[question], read >= date { return }
        readAt[question] = date
    }

    public static func load(in brain: URL) -> UIState { loadIfValid(in: brain) ?? UIState() }

    private static func loadIfValid(in brain: URL) -> UIState? {
        guard let data = try? Data(contentsOf: brain.appendingPathComponent(file)),
              let state = try? decoder.decode(UIState.self, from: data), state.schema == Self.schema else { return nil }
        return state
    }

    public func save(in brain: URL) throws {
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: brain.appendingPathComponent(Self.file), options: .atomic)
    }

    public static func loadOrSeed(in brain: URL, threads: [QuestionThread]) -> UIState {
        if let state = loadIfValid(in: brain) { return state }
        var state = UIState()
        for thread in threads {
            if let finish = thread.latestFinish { state.markRead(question: thread.id, at: finish) }
        }
        try? state.save(in: brain)
        return state
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

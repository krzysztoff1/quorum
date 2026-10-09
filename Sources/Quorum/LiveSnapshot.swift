import Foundation

struct LiveSource: Identifiable, Hashable, Sendable {
    var id: String { "\(kind)·\(value)·\(at.timeIntervalSince1970)" }
    let kind: String
    let value: String
    var at = Date()
    var isURL: Bool { value.hasPrefix("http") }
}

struct LiveSnapshot: Sendable {
    var topicID = ""
    var question = ""
    var thinking = ""
    var output = ""
    var sources: [LiveSource] = []
    var costUSD: Decimal = 0
    var writingStartedAt: Date?

    var thinkingTail: String {
        let source = thinking.isEmpty ? output : thinking
        let flat = source.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flat.suffix(180))
    }
}

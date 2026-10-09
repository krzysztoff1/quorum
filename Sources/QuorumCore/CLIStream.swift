import Foundation

public enum CLIStream {

    public struct ToolUse: Equatable, Sendable {
        public let name: String
        public let detail: String
    }

    public struct Line: Equatable, Sendable {
        public let type: String?
        public let totalCostUSD: Decimal?
        public let assistantText: String?
        public let thinking: String?
        public let deltaText: String?
        public let deltaThinking: String?
        public let toolUses: [ToolUse]
        public let result: String?
        public let sessionID: String?
    }

    public static func parse(_ line: String) -> Line? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(RawEvent.self, from: data) else { return nil }
        let content = event.message?.content ?? []
        let text = content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        let thinking = content.compactMap { $0.type == "thinking" ? $0.thinking : nil }.joined()
        let tools: [ToolUse] = content.compactMap { item in
            guard item.type == "tool_use", let name = item.name else { return nil }
            return ToolUse(name: name, detail: item.input?.display ?? "")
        }
        let delta = event.delta ?? event.event?.delta
        return Line(
            type: event.type,
            totalCostUSD: event.total_cost_usd.map { Decimal($0) },
            assistantText: text.isEmpty ? nil : text,
            thinking: thinking.isEmpty ? nil : thinking,
            deltaText: delta?.type == "text_delta" ? delta?.text : nil,
            deltaThinking: delta?.type == "thinking_delta" ? delta?.thinking : nil,
            toolUses: tools,
            result: event.result,
            sessionID: event.session_id)
    }

    private struct RawEvent: Decodable {
        let type: String?
        let result: String?
        let total_cost_usd: Double?
        let session_id: String?
        let message: Message?
        let delta: Delta?
        let event: Inner?
        struct Message: Decodable { let content: [Content]? }
        struct Content: Decodable {
            let type: String?
            let text: String?
            let thinking: String?
            let name: String?
            let input: ToolInput?
        }
        struct ToolInput: Decodable {
            let query: String?; let url: String?; let prompt: String?; let file_path: String?; let pattern: String?
            var display: String { query ?? url ?? prompt ?? file_path ?? pattern ?? "" }
        }
        struct Delta: Decodable { let type: String?; let text: String?; let thinking: String? }
        struct Inner: Decodable { let delta: Delta? }
    }
}

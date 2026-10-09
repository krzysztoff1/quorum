import Foundation

public final class EventLogTail {
    private let url: URL
    private var offset: UInt64 = 0
    private var carry = Data()

    public init(url: URL) {
        self.url = url
    }

    public func newLines() -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        carry.append(data)
        var lines: [String] = []
        while let newline = carry.firstIndex(of: 0x0A) {
            let line = carry[carry.startIndex..<newline]
            carry = Data(carry[(newline + 1)...])
            if !line.isEmpty, let text = String(data: line, encoding: .utf8) { lines.append(text) }
        }
        return lines
    }
}

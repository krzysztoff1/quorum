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
        if let end = try? handle.seekToEnd(), end < offset {
            offset = 0
            carry = Data()
        }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        carry.append(data)
        var lines: [String] = []
        var start = carry.startIndex
        while let newline = carry[start...].firstIndex(of: 0x0A) {
            if newline > start, let text = String(data: carry[start..<newline], encoding: .utf8) { lines.append(text) }
            start = newline + 1
        }
        carry = Data(carry[start...])
        return lines
    }
}

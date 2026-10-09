import Foundation

/// Drains a subprocess's stderr as it arrives, keeping only the last few KB. Without a reader the
/// child blocks once the pipe fills (~64KB) and its crash output is lost; with one, diagnostics
/// survive without unbounded memory. The handler runs on its own queue, hence the lock.
final class StderrTail: @unchecked Sendable {
    static let capBytes = 8192
    private let lock = NSLock()
    private var buffer = Data()

    func drain(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(chunk)
            if self.buffer.count > Self.capBytes { self.buffer.removeFirst(self.buffer.count - Self.capBytes) }
            self.lock.unlock()
        }
    }

    func finish(_ pipe: Pipe) -> String {
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
            lock.lock()
            buffer.append(rest)
            if buffer.count > Self.capBytes { buffer.removeFirst(buffer.count - Self.capBytes) }
            lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

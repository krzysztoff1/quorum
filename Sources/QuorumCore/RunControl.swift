import Foundation

/// One thing the canvas says to a run that is already in flight. The run reads these off the same stdin the
/// config went down, so every one of them has to be a single line the engine can parse on its own.
public enum RunControl: Sendable, Hashable {
    case approve(id: String)
    case reject(id: String)
    case prune(id: String)
    case retry(id: String)

    public var id: String {
        switch self {
        case let .approve(id), let .reject(id), let .prune(id), let .retry(id): return id
        }
    }

    public var wireLine: String {
        switch self {
        case let .approve(id): return #"{"type":"approve","id":"\#(id)","verdict":"approved"}"#
        case let .reject(id):  return #"{"type":"approve","id":"\#(id)","verdict":"rejected"}"#
        case let .prune(id):   return #"{"type":"prune","id":"\#(id)"}"#
        case let .retry(id):   return #"{"type":"retry","id":"\#(id)"}"#
        }
    }

    public static func parse(_ line: String) -> RunControl? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else { return nil }
        switch object["type"] as? String {
        case "approve":
            switch object["verdict"] as? String {
            case "approved": return .approve(id: id)
            case "rejected": return .reject(id: id)
            default:         return nil
            }
        case "prune": return .prune(id: id)
        case "retry": return .retry(id: id)
        default:      return nil
        }
    }
}

/// The way back into a running engine, held open for the whole run. Everything the canvas can do to a run
/// in flight goes through here, so there is one channel to close when the run ends rather than several.
public final class RunControlChannel: @unchecked Sendable {
    private let writeLine: (String) -> Void
    private let onClose: () -> Void
    private let lock = NSLock()
    private var closed = false

    public init(onClose: @escaping () -> Void = {}, writeLine: @escaping (String) -> Void) {
        self.writeLine = writeLine
        self.onClose = onClose
    }

    public func send(_ control: RunControl) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        writeLine(control.wireLine)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        onClose()
    }
}

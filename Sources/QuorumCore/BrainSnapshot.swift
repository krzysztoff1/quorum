import Foundation

public struct BrainSnapshot: Sendable {
    public let runs: [StoredRun]
    public let unreadable: [UnreadableRun]
    public let threads: [QuestionThread]
    public let ui: UIState
    public let exports: [String: URL]

    public static func load(brain: URL) -> BrainSnapshot {
        let inventory = BrainFolder.inventory(in: brain)
        let threads = ThreadIndex.build(runs: inventory.runs)
        let ui = UIState.loadOrSeed(in: brain, threads: threads)
        return BrainSnapshot(runs: inventory.runs, unreadable: inventory.unreadable, threads: threads, ui: ui,
                             exports: exports(for: threads, in: brain))
    }

    private static func exports(for threads: [QuestionThread], in brain: URL) -> [String: URL] {
        let answers = brain.appendingPathComponent("answers", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: answers, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
        var found: [String: URL] = [:]
        for thread in threads {
            let tail = "-" + thread.id.suffix(5).lowercased()
            if let file = files.first(where: { $0.deletingPathExtension().lastPathComponent.hasSuffix(tail) }) { found[thread.id] = file }
        }
        return found
    }
}

public struct UnreadableRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let reason: String
    public let explanation: String
}

public extension Inbox {
    static func unreadableRows(_ runs: [UnreadableRun]) -> [UnreadableRow] {
        runs.map { run in
            let reason: String
            switch run.reason {
            case .needsUpgrade: reason = "Waiting for an upgrade"
            case .newerThanThisApp: reason = "Needs a newer Quorum"
            case .undecodable: reason = "Couldn't open"
            }
            let title = run.runDir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            return UnreadableRow(id: run.id, title: title, reason: reason, explanation: run.explanation)
        }
    }
}

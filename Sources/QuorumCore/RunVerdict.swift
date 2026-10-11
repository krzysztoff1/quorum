import Foundation

public enum RunVerdict {
    public static func title(for run: StoredRun) -> String { run.title }

    public static func isRateLimited(_ run: StoredRun) -> Bool { run.record.refusal?.kind == "rate_limited" }

    public static func sentence(for run: StoredRun) -> String {
        let stats = run.record.stats
        switch run.record.status {
        case .failed, .crashed: return "Couldn't finish."
        case .halted, .cancelled:
            if isRateLimited(run), let reason = run.record.refusal?.reason { return reason }
            return "Stopped before it finished."
        case .partial, .unknown:
            switch run.record.limits.wallHit {
            case .hard: return "Stopped at the time limit. This answer uses the research that had finished."
            case .windDown: return "Ran short of time, so some checks were skipped."
            default: return "Partial answer, not fully checked."
            }
        case .running: return "Still researching."
        case .complete, .inconclusive: break
        }
        if stats.trustLevel == .unchecked { return "Quotes not checked. \(stats.sourcesRead) source\(stats.sourcesRead == 1 ? "" : "s") read." }
        let trust = "\(stats.trustLevel.rawValue.capitalized) confidence."
        if stats.conflictsOpen > 0 {
            let topic = run.record.conflicts.first { run.record.openItems.conflicts.contains($0.id) }?.statement
            let named = topic.map { ": " + $0.prefix(80) } ?? ""
            return "\(trust) \(stats.conflictsOpen) open conflict\(stats.conflictsOpen == 1 ? "" : "s")\(named)."
        }
        return "\(trust) \(stats.sourcesCited) source\(stats.sourcesCited == 1 ? "" : "s") cited."
    }
}

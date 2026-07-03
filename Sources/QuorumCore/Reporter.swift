import Foundation

/// Folds findings into the run-digest markdown. The digest is the hero surface: per topic the
/// headline, how well-sourced/confident, cost, wall status, effort preset, sources consulted, whether
/// the note was created or extended, and a link to the note — plus the run totals.
public enum Reporter {

    public static func confidenceSummary(_ findings: [Finding]) -> String {
        guard !findings.isEmpty else { return "no verified findings" }
        var counts: [Confidence: Int] = [:]
        for f in findings { counts[f.confidence, default: 0] += 1 }
        let order: [Confidence] = [.high, .medium, .low, .unverified]
        return order.compactMap { c in counts[c].map { "\($0) \(c.rawValue)" } }.joined(separator: " · ")
    }

    public static func renderDigest(_ r: RunReport) -> String {
        var s = "# Quorum — Run Digest\n\n"
        let df = ISO8601DateFormatter()
        s += "- **Run:** \(df.string(from: r.startedAt)) → \(df.string(from: r.finishedAt))\n"
        s += "- **Total time:** \(fmtDuration(r.totalDurationSeconds))\n"
        s += "- **Total spend:** \(money(r.totalCostUSD)) / \(money(r.runSpendCapUSD)) cap"
        s += r.stayedUnderCap ? " ✅\n\n" : " ⚠️ over cap\n\n"

        for e in r.entries {
            s += "## \(e.question)\n\n"
            s += "- **Status:** \(e.status.label)  ·  **Effort:** \(e.preset.displayName)\n"

            if e.status == .skipped {
                if let n = e.note { s += "- \(n)\n" }
                s += "\n"
                continue
            }

            s += "- **Headline:** \(e.headline)\n"
            s += "- **Confidence:** \(e.confidenceSummary)  ·  **Sources consulted:** \(e.sourcesConsulted)\n"
            s += "- **Cost:** \(money(e.costUSD))  ·  **Time:** \(fmtDuration(e.durationSeconds))\n"
            if let a = e.noteAction { s += "- **Brain:** \(a.digestLabel)\n" }
            if let n = e.note { s += "- **Caveat:** \(n)\n" }
            if let cs = e.conflicts, !cs.isEmpty {
                // Surface disagreement up front — the fan-out's whole point is not to dissolve it.
                s += "- **⚠️ Open conflicts (\(cs.count)):**\n"
                for c in cs {
                    s += "  - \(c.claim)\n"
                    for p in c.positions { s += "    - \(p)\n" }
                }
            }
            if let p = e.notePath {
                s += "- **Note:** [\(URL(fileURLWithPath: p).lastPathComponent)](\(p))\n"
            }
            s += "\n"
        }
        return s
    }

    // MARK: display helpers

    public static func money(_ d: Decimal) -> String {
        String(format: "$%.2f", (d as NSDecimalNumber).doubleValue)
    }

    public static func fmtDuration(_ secs: Double) -> String {
        let total = Int(secs.rounded())
        let m = total / 60, s = total % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}

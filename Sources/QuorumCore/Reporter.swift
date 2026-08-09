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
        s += r.stayedUnderCap ? " ✅\n" : " ⚠️ over cap\n"
        if let profile = r.profile {
            s += "- **Profile:** \(profile.displayName)"
            if r.engineCostUSD > 0 {
                s += "  ·  **Engine spend:** \(money(r.engineCostUSD)) of \(money(r.totalCostUSD))"
            }
            s += "\n"
        }
        s += "\n"

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
        s += costLedger(r)
        return s
    }

    /// Per-run token/cost ledger — one row per topic (its role's model + tokens + searches), plus a
    /// total. Rendered only when at least one topic carries usage, so pre-ledger runs stay clean.
    public static func costLedger(_ r: RunReport) -> String {
        let rows = r.entries.filter { $0.usage != nil }
        guard !rows.isEmpty || r.validationCostUSD != nil else { return "" }
        var s = "## Cost ledger\n\n"
        s += "| Topic | Model | Tokens (in/out) | Cache read | Search/fetch | Cost |\n"
        s += "|---|---|---|---|---|---|\n"
        var tIn = 0, tOut = 0, tCache = 0, tSearch = 0, tFetch = 0, tCost = Decimal(0)
        for e in rows {
            guard let u = e.usage else { continue }
            let role = e.isSynthesis == true ? "synthesis" : "angle"
            let label = "\(shortLabel(e.question)) · \(role)"
            let model = u.model.isEmpty ? u.provider : "\(u.provider)/\(u.model)"
            s += "| \(label) | \(model) | \(u.inputTokens) / \(u.outputTokens) | \(u.cacheReadTokens)"
            s += " | \(u.searchCalls) / \(u.fetchCalls) | \(money(u.costUSD)) |\n"
            tIn += u.inputTokens; tOut += u.outputTokens; tCache += u.cacheReadTokens
            tSearch += u.searchCalls; tFetch += u.fetchCalls; tCost += u.costUSD
        }
        if let validationCost = r.validationCostUSD {
            s += "| validation · claim sweep + critics |  |  |  |  | \(money(validationCost)) |\n"
            tCost += validationCost
        }
        s += "| **Total** |  | \(tIn) / \(tOut) | \(tCache) | \(tSearch) / \(tFetch) | \(money(tCost)) |\n\n"
        return s
    }

    private static func shortLabel(_ q: String) -> String {
        let one = q.replacingOccurrences(of: "\n", with: " ")
        return one.count > 40 ? String(one.prefix(40)) + "…" : one
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

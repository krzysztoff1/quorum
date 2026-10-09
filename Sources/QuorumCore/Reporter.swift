import Foundation

/// Folds findings into the run-digest markdown. The digest is the hero surface: per topic the
/// headline, how well-sourced/confident, cost, wall status, effort preset, sources consulted, whether
/// the note was created or extended, and a link to the note — plus the run totals.
public enum Reporter {

    /// "Sources consulted" means exactly one thing: the distinct URLs the work actually cited. A model's
    /// own `sourcesConsulted` is a claim about its reading, and the same page arrives spelled four ways —
    /// so the number every surface shows is computed here, once, and never re-derived per view.
    public static func distinctSources(_ findings: [Finding]) -> Int {
        distinctSourceURLs(findings).count
    }

    /// The same URLs, deduped, in first-cited order — what History lists under the count.
    public static func distinctSourceURLs(_ findings: [Finding]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for url in findings.flatMap(\.sources) {
            let key = canonicalSource(url)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(url)
        }
        return out
    }

    /// Every distinct URL a whole run cited. A report written before findings were stored falls back to the
    /// URL list it kept, so an old run still counts rather than reading as zero.
    public static func distinctSources(_ entries: [RunReport.TopicEntry]) -> Int {
        let cited = entries.flatMap { entry -> [Finding] in
            if let findings = entry.findings, !findings.isEmpty { return findings }
            return [Finding(claim: "", sources: entry.sources ?? [], confidence: .unverified)]
        }
        return distinctSources(cited)
    }

    /// One spelling per page: scheme, `www.`, case and a trailing slash are not different sources.
    static func canonicalSource(_ url: String) -> String {
        var t = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where t.hasPrefix(scheme) { t.removeFirst(scheme.count) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

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
        if let pipeline = r.pipeline {
            s += "- **Pipeline:** \(pipeline.label)"
            s += pipeline.badge.map { "  ·  ⚠️ \($0)\n" } ?? "\n"
            if let why = pipeline.fallbackReason, !why.isEmpty { s += "- **Why no engine:** \(why)\n" }
        }
        if let why = r.windDownNote, !why.isEmpty { s += "- **Why it stopped:** \(why)\n" }
        if let open = leftOpen(r) { s += "- ⚠️ **Left open:** \(open)\n" }
        s += "\n"

        for e in r.entries {
            s += "## \(e.question)\n\n"
            s += "- **Status:** \(e.status.label)  ·  **Effort:** \(e.preset.displayName)\n"
            if let badge = r.pipeline?.badge { s += "- **⚠️ \(badge)**\n" }

            if e.status == .skipped {
                if let n = e.note { s += "- \(n)\n" }
                s += "\n"
                continue
            }

            s += "- **Headline:** \(e.headline)\n"
            s += "- **Confidence:** \(e.confidenceSummary)  ·  **Sources consulted:** \(sourcesLabel(e, in: r))\n"
            s += "- **Cost:** \(money(e.costUSD))  ·  **Time:** \(fmtDuration(e.durationSeconds))\n"
            if let a = e.noteAction { s += "- **Brain:** \(a.digestLabel)\n" }
            if let n = e.note { s += "- **Caveat:** \(n)\n" }
            if let cs = e.conflicts, !cs.isEmpty {
                // Surface disagreement up front — the fan-out's whole point is not to dissolve it.
                s += "- **⚠️ Open conflicts (\(cs.count)):**\n"
                for c in cs {
                    s += "  - \(c.claim) — \(conflictAttribution(c))\n"
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

    /// Who is actually at odds in a conflict. "The angles disagreed" is the fan-out's own story about
    /// itself, and it is often wrong: two sources one angle found can contradict each other with no other
    /// angle involved. The positions say which angle raised them, so the copy follows them rather than the
    /// shape of the run.
    public static func conflictAttribution(_ conflict: Conflict) -> String {
        let angles = conflict.positions.map(angleNumber)
        guard !angles.contains(nil), let first = angles.first ?? nil else { return "sources disagree" }
        let named = Set(angles.compactMap { $0 })
        return named.count == 1 ? "sources within Angle \(first) disagree" : "the angles disagree"
    }

    private static func angleNumber(_ position: String) -> Int? {
        guard let range = position.range(of: #"^\s*angle\s+(\d+)"#,
                                         options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(position[range].filter(\.isNumber))
    }

    /// What the run ends up still not knowing, and why nothing chased it. An answer that carries an open
    /// conflict is honest research; a digest that lists the conflict and says nothing about whether anything
    /// was going to be done about it reads as an oversight. A one-round run says so — a single targeted
    /// re-run is often all that stands between the conflict and a primary source.
    public static func leftOpen(_ r: RunReport) -> String? {
        let answer = r.entries.last { $0.isSynthesis == true }
        let counts = [
            plural(answer?.conflicts?.count ?? 0, "conflict"),
            plural(answer?.gaps?.count ?? 0, "gap"),
            plural(r.validation?.objectionsOutstanding.count ?? 0, "objection", suffix: " standing"),
        ].compactMap { $0 }
        guard !counts.isEmpty else { return nil }
        let rounds = r.entries.compactMap(\.round).max() ?? 1
        let why = rounds > 1
            ? "the run made \(rounds) rounds and could not settle them."
            : "the run made 1 round, so none were sent back as research. Re-run to chase them."
        return counts.joined(separator: " · ") + " — " + why
    }

    private static func plural(_ count: Int, _ noun: String, suffix: String = "") -> String? {
        count > 0 ? "\(count) \(noun)\(count == 1 ? "" : "s")\(suffix)" : nil
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

    /// An angle reports what it cited; the answer reports what the whole run stood on, because the reader
    /// asking "how well sourced is this?" means the run, not the summariser's own reference list.
    private static func sourcesLabel(_ e: RunReport.TopicEntry, in r: RunReport) -> String {
        guard e.isSynthesis == true else { return "\(e.sourcesConsulted)" }
        let angles = r.entries.filter { $0.isSynthesis != true && $0.status != .skipped }
            .filter { e.round == nil || $0.round == e.round }
        guard !angles.isEmpty else { return "\(e.sourcesConsulted) distinct sources" }
        return "\(angles.count) angle\(angles.count == 1 ? "" : "s") · \(e.sourcesConsulted) distinct sources"
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

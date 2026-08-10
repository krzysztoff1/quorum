import Foundation

/// A run folder is named `<title> <yyyy-MM-dd-HHmmss>` — a human title (from the cheapest model) with
/// the timestamp kept last. Legacy runs are the bare stamp. These pull the two apart: the trailing
/// stamp stays the stable sort key + selection identity (unchanged when a run is later titled/renamed),
/// while the title is free-form and shown in History. Pure string ops — the single source of truth for
/// both the app and the store, so naming and parsing can never drift apart.
public enum RunFolder {
    static let stampLen = 17   // "yyyy-MM-dd-HHmmss"

    /// The trailing timestamp — the whole name for a legacy bare-stamp dir. Stable across a title rename.
    public static func stamp(_ name: String) -> String {
        name.count >= stampLen ? String(name.suffix(stampLen)) : name
    }

    /// The title prefixed before the stamp, or nil for a legacy bare-stamp dir (nothing before the stamp).
    public static func title(_ name: String) -> String? {
        guard name.count > stampLen + 1 else { return nil }   // + the separating space
        let trimmed = name.dropLast(stampLen + 1).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Folder name for a titled run: `<sanitized title> <stamp>`. Path-illegal chars become spaces;
    /// an empty title falls back to the bare stamp.
    public static func name(title: String, stamp: String) -> String {
        let clean = title
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? stamp : "\(clean) \(stamp)"
    }
}

/// One node in the notes folder tree: a directory (with `children`) or a markdown file (leaf). `id` is
/// the full path, stable for SwiftUI selection/`OutlineGroup`; `childrenOrNil` returns `nil` for a leaf
/// so files get no disclosure triangle.
public struct NoteTreeNode: Identifiable, Equatable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let children: [NoteTreeNode]

    public var id: String { url.path }
    public var childrenOrNil: [NoteTreeNode]? { children.isEmpty ? nil : children }

    public init(url: URL, name: String, isDirectory: Bool, children: [NoteTreeNode]) {
        self.url = url; self.name = name; self.isDirectory = isDirectory; self.children = children
    }
}

/// The second-brain core. Notes live in a stable `Quorum/notes/<slug>.md` in the brain — one note
/// per topic, *extended* over time rather than duplicated — while each run's transcripts and digest
/// live in `Quorum/runs/<timestamp>/`. Before a topic runs, the orchestrator asks for related prior
/// notes (read-only context); after, `write` files the findings by extending the best-matching note or
/// creating a new one. Plain portable markdown (YAML frontmatter + `[[wikilinks]]`) — greppable,
/// git-able, drops straight into Obsidian/Logseq. The research run never writes; every write is here.
public struct DiskFindingsStore: FindingsStore {
    public init() {}

    // MARK: layout

    static func brainRoot(_ brain: URL) -> URL { brain.appendingPathComponent("Quorum", isDirectory: true) }
    static func notesDir(_ brain: URL) -> URL { brainRoot(brain).appendingPathComponent("notes", isDirectory: true) }
    static func runsDir(_ brain: URL) -> URL { brainRoot(brain).appendingPathComponent("runs", isDirectory: true) }

    public func makeRunDirectory(projectURL: URL, startedAt: Date) throws -> URL {
        try makeRunDirectory(projectURL: projectURL, startedAt: startedAt, title: nil)
    }

    public func makeRunDirectory(projectURL: URL, startedAt: Date, title: String?) throws -> URL {
        let name = RunFolder.name(title: title ?? "", stamp: Self.stamp(startedAt))
        let dir = Self.runsDir(projectURL).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func listRuns(projectURL: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Self.runsDir(projectURL), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { RunFolder.stamp($0.lastPathComponent) > RunFolder.stamp($1.lastPathComponent) }   // newest first, by the trailing stamp (survives a title rename)
    }

    /// Every `.md` file under `root`, recursively, path-sorted — the source list for the notes browser.
    /// Skips hidden files/dirs and dependency dumps so a project's real notes aren't buried under vendored
    /// ones, and skips `*.transcript.md` (raw per-run logs, not notes).
    /// ponytail: node_modules/Pods are the known noise dirs; add more names here if a project needs it.
    public static func markdownFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            if url.lastPathComponent == "node_modules" || url.lastPathComponent == "Pods" {
                en.skipDescendants(); continue
            }
            if url.pathExtension.lowercased() == "md",
               url.deletingPathExtension().pathExtension.lowercased() != "transcript" {
                out.append(url)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The markdown files under `root` as a folder tree mirroring the on-disk structure — directories
    /// first then files, each alphabetical (Finder-style). Only folders that actually contain a note
    /// appear (empty/transcript-only dirs are pruned, since they hold no listable file). Drives the
    /// sidebar's `OutlineGroup`.
    public static func noteTree(under root: URL) -> [NoteTreeNode] {
        let entries = markdownFiles(under: root).map {
            (comps: relativeComponents(of: $0, under: root), url: $0)
        }
        return assemble(entries, prefix: root)
    }

    private static func relativeComponents(of url: URL, under root: URL) -> [String] {
        // Resolve symlinks on both so the prefix matches (temp dirs hang off /var → /private/var).
        let rc = root.resolvingSymlinksInPath().pathComponents
        let uc = url.resolvingSymlinksInPath().pathComponents
        guard uc.count > rc.count, Array(uc.prefix(rc.count)) == rc else { return [url.lastPathComponent] }
        return Array(uc.dropFirst(rc.count))
    }

    private static func assemble(_ entries: [(comps: [String], url: URL)], prefix: URL) -> [NoteTreeNode] {
        var dirs: [NoteTreeNode] = [], files: [NoteTreeNode] = []
        for (name, group) in Dictionary(grouping: entries.filter { !$0.comps.isEmpty }, by: { $0.comps[0] }) {
            let leaves = group.filter { $0.comps.count == 1 }
            if leaves.count == group.count, let leaf = leaves.first {
                files.append(NoteTreeNode(url: leaf.url, name: name, isDirectory: false, children: []))
            } else {
                let dirURL = prefix.appendingPathComponent(name, isDirectory: true)
                let deeper = group.map { (comps: Array($0.comps.dropFirst()), url: $0.url) }
                dirs.append(NoteTreeNode(url: dirURL, name: name, isDirectory: true,
                                         children: assemble(deeper, prefix: dirURL)))
            }
        }
        func byName(_ a: NoteTreeNode, _ b: NoteTreeNode) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return dirs.sorted(by: byName) + files.sorted(by: byName)
    }

    // MARK: the moat — finding related notes & extending vs. creating (stories 30–32)

    /// Related prior notes, most-related first. Read-only context so a run builds on what's known.
    public func relatedNotes(to question: String, in brain: URL) -> [URL] {
        let q = Self.keywords(question)
        guard !q.isEmpty else { return [] }
        return allNotes(in: brain)
            .map { (url: $0, score: Self.score(q, Self.keywords(noteQuestion(at: $0)))) }
            .filter { $0.score >= Self.relatedMin }
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map(\.url)
    }

    /// The single note that already covers this question (for the "already researched" warning and the
    /// extend decision), or nil. ponytail: naive keyword Jaccard with fixed thresholds — the calibration
    /// knob for clustering. Swap for embeddings if it mis-groups; the thresholds are the tuning surface.
    public func existingNote(matching question: String, in brain: URL) -> URL? {
        let q = Self.keywords(question)
        guard !q.isEmpty else { return nil }
        return allNotes(in: brain)
            .map { (url: $0, score: Self.score(q, Self.keywords(noteQuestion(at: $0)))) }
            .filter { $0.score >= Self.extendMin }
            .max { $0.score < $1.score }?
            .url
    }

    public func write(_ f: TopicFindings, question: String, brain: URL, priorNotes: [URL],
                      runDir: URL, at date: Date) throws -> WriteResult {
        // Transcript: raw logs for this run, kept out of the skimmable note.
        let transcriptURL = runDir.appendingPathComponent("\(Self.fileSlug(question))-\(f.id.prefix(6)).transcript.md")
        let transcript = f.transcript.isEmpty ? "_no transcript captured_\n" : f.transcript
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: Self.notesDir(brain), withIntermediateDirectories: true)

        if let match = existingNote(matching: question, in: brain) {
            try extendNote(at: match, with: f, question: question, priorNotes: priorNotes, date: date)
            return WriteResult(note: match, transcript: transcriptURL, action: .extended)
        }
        let note = try createNote(f, question: question, brain: brain, priorNotes: priorNotes, date: date)
        return WriteResult(note: note, transcript: transcriptURL, action: .created)
    }

    /// File a fan-out run: each angle's writeup becomes a run artifact (kept out of the brain — the
    /// summary IS the note), and the summariser's reconciled findings create/extend the one durable
    /// note for the question, `[[wikilinked]]` to the angle artifacts + prior notes for provenance.
    /// New note → `.created`; an existing note this reconciles into → `.merged` (the reserved case).
    public func writeSynthesis(_ summary: TopicFindings, question: String, angles: [TopicFindings],
                               angleTitles: [String], brain: URL, priorNotes: [URL], runDir: URL, at date: Date) throws -> WriteResult {
        // Angle writeups as run artifacts (provenance for the synthesis; not durable brain notes).
        // Lead the filename with the angle's own short title (the run folder already carries the question),
        // so files read as `technical-feasibility-angle-1.md` — not N copies of the same question slug.
        var artifacts: [URL] = []
        for (i, a) in angles.enumerated() {
            let label = i < angleTitles.count && !angleTitles[i].isEmpty ? angleTitles[i] : a.headline
            let url = runDir.appendingPathComponent("\(Self.fileSlug(label))-angle-\(i + 1).md")
            let head = "# Angle \(i + 1): \(a.headline)\n\n_\(a.sourcesConsulted) source(s) · \(Reporter.money(a.costUSD)) · \(a.status.label)_\n\n"
            let body = a.writeupMarkdown.isEmpty
                     ? "_No findings gathered._"
                     : Self.withFootnotes(a.writeupMarkdown, evidence: a.evidence)
            try (head + body).write(to: url, atomically: true, encoding: .utf8)
            artifacts.append(url)
        }
        // The summariser's own transcript, like `write` keeps for a topic.
        let transcriptURL = runDir.appendingPathComponent("\(Self.fileSlug(question))-synthesis-\(summary.id.prefix(6)).transcript.md")
        try (summary.transcript.isEmpty ? "_no transcript captured_\n" : summary.transcript)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: Self.notesDir(brain), withIntermediateDirectories: true)
        // ponytail: [[wikilinks]] to artifacts resolve in Obsidian when the project folder is the vault
        // (the runs/ tree lives under it). If you keep the vault narrower, point these at notes/ instead.
        let related = priorNotes + artifacts
        if let match = existingNote(matching: question, in: brain) {
            try extendNote(at: match, with: summary, question: question, priorNotes: related, date: date)
            return WriteResult(note: match, transcript: transcriptURL, action: .merged, angleArtifacts: artifacts)
        }
        let note = try createNote(summary, question: question, brain: brain, priorNotes: related, date: date)
        return WriteResult(note: note, transcript: transcriptURL, action: .created, angleArtifacts: artifacts)
    }

    /// The current body (after frontmatter) of the note covering this question — the pre-dive snapshot
    /// reconciliation appends its one fused section to. nil if no note yet exists for the question.
    public func noteBody(matching question: String, in brain: URL) -> String? {
        guard let note = existingNote(matching: question, in: brain),
              let text = try? String(contentsOf: note, encoding: .utf8) else { return nil }
        return Self.splitFrontmatter(text).body
    }

    /// Collapse a completed multi-round dive into ONE current answer: rewrite the note as `preDiveBody`
    /// (everything before this dive — prior dives stay intact) + one reconciled dated section. The dive's
    /// per-round sections (written live during the rounds) are superseded. Frontmatter lineage — created
    /// date, run count, title, original question — is carried from the note the rounds wrote, exactly as
    /// `extend` does; only the summary stats (updated, sources, confidence, cost) refresh to the reconciled
    /// answer. Emits `.reconciled` so History can label a fused multi-round note.
    public func writeReconciliation(_ summary: TopicFindings, question: String, relatedLinks: [URL],
                                    brain: URL, runDir: URL, preDiveBody: String?, at date: Date) throws -> WriteResult {
        let transcriptURL = runDir.appendingPathComponent("\(Self.fileSlug(question))-reconciliation-\(summary.id.prefix(6)).transcript.md")
        try (summary.transcript.isEmpty ? "_no transcript captured_\n" : summary.transcript)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: Self.notesDir(brain), withIntermediateDirectories: true)
        let note = existingNote(matching: question, in: brain)
                 ?? Self.uniqueNoteURL(for: question, in: Self.notesDir(brain))
        let (fm, _) = Self.splitFrontmatter((try? String(contentsOf: note, encoding: .utf8)) ?? "")
        let header = Self.frontmatter(title: fm["title"] ?? summary.headline,
                                      question: fm["question"] ?? question,
                                      created: fm["created"] ?? Self.dayStamp(date), updated: Self.dayStamp(date),
                                      runs: Int(fm["runs"] ?? "") ?? 1, preset: summary.preset.displayName,
                                      sources: summary.sourcesConsulted, confidence: Reporter.confidenceSummary(summary.findings),
                                      cost: Reporter.money(summary.costUSD))
        let section = Self.renderReconciledSection(summary, date: date,
                                                   relatedLinks: Self.wikilinks(relatedLinks, excluding: note))
        let prior = (preDiveBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = prior.isEmpty ? section : prior + "\n\n" + section
        try (header + "\n" + body).write(to: note, atomically: true, encoding: .utf8)
        return WriteResult(note: note, transcript: transcriptURL, action: .reconciled)
    }

    // MARK: note writing

    private func createNote(_ f: TopicFindings, question: String, brain: URL,
                            priorNotes: [URL], date: Date) throws -> URL {
        let url = Self.uniqueNoteURL(for: question, in: Self.notesDir(brain))
        let day = Self.dayStamp(date)
        var text = Self.frontmatter(title: f.headline, question: question, created: day, updated: day,
                                    runs: 1, preset: f.preset.displayName, sources: f.sourcesConsulted,
                                    confidence: Reporter.confidenceSummary(f.findings), cost: Reporter.money(f.costUSD))
        text += "\n"
        text += Self.renderSection(f, date: date, relatedLinks: Self.wikilinks(priorNotes, excluding: url))
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func extendNote(at url: URL, with f: TopicFindings, question: String,
                            priorNotes: [URL], date: Date) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let (fm, body) = Self.splitFrontmatter(existing)
        let runs = (Int(fm["runs"] ?? "") ?? 1) + 1
        let created = fm["created"] ?? Self.dayStamp(date)
        let title = fm["title"] ?? f.headline
        let originalQuestion = fm["question"] ?? question

        let header = Self.frontmatter(title: title, question: originalQuestion, created: created,
                                      updated: Self.dayStamp(date), runs: runs, preset: f.preset.displayName,
                                      sources: f.sourcesConsulted, confidence: Reporter.confidenceSummary(f.findings),
                                      cost: Reporter.money(f.costUSD))
        let section = Self.renderSection(f, date: date, relatedLinks: Self.wikilinks(priorNotes, excluding: url))
        let newBody = body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + section
        try (header + "\n" + newBody).write(to: url, atomically: true, encoding: .utf8)
    }

    /// One dated section — reused by create and extend, so the note reads as one topic deepening.
    static func renderSection(_ f: TopicFindings, date: Date, relatedLinks: [String]) -> String {
        var s = "## \(dayStamp(date)) — \(f.headline)\n\n"
        s += "_Effort: \(f.preset.displayName) · \(f.findings.count) finding(s) · "
        s += "\(f.sourcesConsulted) source(s) · \(Reporter.money(f.costUSD))_\n\n"
        if f.status == .inconclusive {
            s += "> ℹ️ **Inconclusive** — \(f.note ?? "couldn't find a solid answer.")\n\n"
        }
        if !f.conflicts.isEmpty {
            s += "> ⚠️ **Open conflicts (\(f.conflicts.count))** — the angles disagreed:\n"
            for c in f.conflicts {
                s += ">\n> - **\(c.claim)**\n"
                for p in c.positions { s += ">   - \(p)\n" }
            }
            s += "\n"
        }
        s += exportedWriteup(f) + "\n\n"
        if !f.gaps.isEmpty {
            s += "### Gaps & open questions\n\n"
            for g in f.gaps { s += "- \(g)\n" }
            s += "\n"
        }
        if !relatedLinks.isEmpty {
            s += "_Related: " + relatedLinks.map { "[[\($0)]]" }.joined(separator: ", ") + "_\n"
        }
        return s
    }

    /// Reconciled notes are the current answer, not a run log. Keep the section to the fused body plus
    /// provenance links; the model's own writeup should carry any unresolved nuance.
    static func renderReconciledSection(_ f: TopicFindings, date: Date, relatedLinks: [String]) -> String {
        var s = "## \(dayStamp(date)) — \(f.headline)\n\n"
        s += exportedWriteup(f) + "\n\n"
        if !relatedLinks.isEmpty {
            s += "_Related: " + relatedLinks.map { "[[\($0)]]" }.joined(separator: ", ") + "_\n"
        }
        return s
    }

    /// The answer as the export renders it: the prose, what the run's own validators made of it, and the
    /// footnote definitions for every marker below both — a portable document that says the same thing the
    /// graph does about the same answer (PRD 09 R4).
    static func exportedWriteup(_ f: TopicFindings) -> String {
        let body = f.writeupMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "_No findings were gathered._" }
        return withGroundingNotice(withFootnotes(withValidation(body, f.validation), evidence: f.evidence),
                                   evidence: f.evidence)
    }

    static func withGroundingNotice(_ writeup: String, evidence: EvidenceIndex) -> String {
        guard let notice = evidence.unvalidatedNotice else { return writeup }
        return "> ⚠️ \(notice)\n\n" + writeup
    }

    /// An answer the loop already wrote its verdict into keeps that one: the rewritten-in-loop section is
    /// the last round's own account, and a second summary under the same heading would only argue with it.
    static func withValidation(_ writeup: String, _ validation: RunValidation?) -> String {
        guard let validation,
              writeup.range(of: #"(?m)^#{1,6} +Validation\b"#,
                            options: [.regularExpression, .caseInsensitive]) == nil else { return writeup }
        return writeup + "\n\n" + validationSection(validation)
    }

    /// What the validators filed, in the export. A verdict never edited the answer, so it stands beside it:
    /// whether it held, the ledger of objections, and — the part nothing is allowed to hide — the ones
    /// still standing, each with the task that would settle it.
    static func validationSection(_ v: RunValidation) -> String {
        var s = "## Validation\n\n"
        if v.status == "validated" {
            s += v.holds ? "✓ The answer held" : "⚠️ The answer did not hold"
            s += " — judged by agents that did not write it, over "
            s += "\(v.rounds) round\(v.rounds == 1 ? "" : "s") · \(Reporter.money(v.spendUSD)).\n\n"
        } else {
            s += "⚠️ Not fully validated — some of the loop could not run on this answer.\n\n"
        }
        s += "_\(v.objectionsAdmitted) filed · \(v.objectionsResolved) settled by research · "
        s += "\(v.objectionsOutstanding.count) still standing_\n"
        if !v.objectionsOutstanding.isEmpty {
            s += "\nThese were filed against the answer, not fixed in it — only further research settles them:\n\n"
            for o in v.objectionsOutstanding {
                s += "- \(o.lens.replacingOccurrences(of: "_", with: " ")) · \(o.severity) — "
                s += "\(o.statement) → \(o.followup)\n"
            }
        }
        if !v.unsupportedCitationIDs.isEmpty {
            s += "\n\(v.unsupportedCitationIDs.count) quote(s) were located but do not support the claim "
            s += "they were cited for: " + v.unsupportedCitationIDs.joined(separator: ", ") + ".\n"
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A writeup plus the markdown footnote definitions for the markers it uses (PRD 03), under a
    /// `## Sources` heading unless the writeup already wrote one — so the note stays a portable document
    /// whose citations render in Obsidian or on GitHub. A writeup with no markers, or none the run
    /// resolved, comes back untouched: no heading, no fabricated footnote.
    static func withFootnotes(_ writeup: String, evidence: EvidenceIndex) -> String {
        let definitions = CitationMarkers.footnoteDefinitions(for: writeup, evidence: evidence)
        guard !definitions.isEmpty else { return writeup }
        let hasHeading = writeup.range(of: #"(?m)^#{1,6} +Sources\b"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil
        return writeup + (hasHeading ? "\n\n" : "\n\n## Sources\n\n") + definitions
    }

    // MARK: digest (per-run)

    public func writeDigest(_ report: RunReport, inRunDirectory dir: URL) throws -> URL {
        let digestURL = dir.appendingPathComponent("digest.md")
        try Reporter.renderDigest(report).write(to: digestURL, atomically: true, encoding: .utf8)
        // Persist the structured report so the app reloads history without re-parsing markdown.
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: dir.appendingPathComponent("report.json"))
        }
        // The run's captured sources + resolved quotes, so a marker still opens its source months later.
        // Paths inside stay relative to `<runDir>/evidence` — the store never moves or rewrites a snapshot.
        let evidence = Self.runEvidence(report)
        if !evidence.isEmpty, let data = try? JSONEncoder().encode(evidence) {
            try? data.write(to: dir.appendingPathComponent("sources.json"))
        }
        return digestURL
    }

    /// One deduped evidence index for a whole run — every topic's captured documents and resolved quotes,
    /// earlier entries winning so a resolved citation is never replaced by a later unresolved twin.
    public static func runEvidence(_ report: RunReport) -> EvidenceIndex {
        report.entries.compactMap(\.evidence).reduce(EvidenceIndex()) { $0.merging($1) }
    }

    // MARK: helpers — notes on disk

    public func allNotes(in brain: URL) -> [URL] {
        Self.markdownFiles(under: Self.notesDir(brain))
    }

    /// The note's original question from frontmatter (best match signal); falls back to the de-slugged filename.
    private func noteQuestion(at url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let (fm, _) = Self.splitFrontmatter(text)
        if let q = fm["question"], !q.isEmpty { return q }
        return url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
    }

    // MARK: helpers — matching (naive keyword Jaccard; see `existingNote` ponytail note)

    static let relatedMin = 0.001   // any shared significant keyword → "related" (context)
    static let extendMin  = 0.4     // strong overlap → same topic (extend / already-researched)

    static let stopwords: Set<String> = [
        "the","and","for","are","was","how","what","why","does","did","with","from","this","that",
        "your","you","its","into","than","then","over","more","most","can","will","about","versus",
        "vs","should","would","could","when","where","which","who","whom","been","have","has","not",
        "but","use","using","get","got","new","best"
    ]

    static func keywords(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let tokens = lowered.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return Set(tokens.filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    /// Jaccard overlap of significant keywords.
    static func score(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        guard inter > 0 else { return 0 }
        return Double(inter) / Double(a.union(b).count)
    }

    // MARK: helpers — frontmatter (minimal `key: value`, not a YAML lib — ponytail)

    static func frontmatter(title: String, question: String, created: String, updated: String,
                            runs: Int, preset: String, sources: Int, confidence: String, cost: String) -> String {
        func q(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "'"))\"" }
        return """
        ---
        title: \(q(title))
        question: \(q(question))
        created: \(created)
        updated: \(updated)
        runs: \(runs)
        preset: \(preset)
        sources: \(sources)
        confidence: \(q(confidence))
        cost: \(cost)
        ---
        """
    }

    /// Split a `---`-fenced frontmatter block into a flat dict + the body after it. Forgiving: a note
    /// with no frontmatter returns an empty dict and the whole text as body.
    static func splitFrontmatter(_ text: String) -> (fields: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closeIdx = lines.dropFirst().firstIndex(of: "---") else {
            return ([:], text)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<closeIdx] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            fields[key] = val
        }
        let body = lines[(closeIdx + 1)...].joined(separator: "\n")
        return (fields, body)
    }

    // MARK: helpers — wikilinks & slugs

    /// The `[[slug]]` targets a note's body references, in order, deduped — the alias (`[[slug|text]]`)
    /// and heading (`[[slug#section]]`) suffixes stripped down to the bare filename stem.
    public static func wikilinkSlugs(in body: String) -> [String] {
        var slugs: [String] = []
        var seen = Set<String>()
        var rest = Substring(body)
        while let open = rest.range(of: "[[") {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "]]") else { break }
            let inner = rest[..<close.lowerBound]
            rest = rest[close.upperBound...]
            let slug = inner.prefix { $0 != "|" && $0 != "#" }.trimmingCharacters(in: .whitespaces)
            if !slug.isEmpty, seen.insert(slug).inserted { slugs.append(slug) }
        }
        return slugs
    }

    /// `[[slug]]` targets for related notes (their filenames), excluding the note being written.
    static func wikilinks(_ priorNotes: [URL], excluding self_: URL) -> [String] {
        let selfSlug = self_.deletingPathExtension().lastPathComponent
        var seen = Set<String>()
        return priorNotes
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != selfSlug && seen.insert($0).inserted }
    }

    static func uniqueNoteURL(for question: String, in notesDir: URL) -> URL {
        let base = fileSlug(question)
        var candidate = notesDir.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = notesDir.appendingPathComponent("\(base)-\(n).md"); n += 1
        }
        return candidate
    }

    static func stamp(_ d: Date) -> String { formatted(d, "yyyy-MM-dd-HHmmss") }
    static func dayStamp(_ d: Date) -> String { formatted(d, "yyyy-MM-dd") }

    private static func formatted(_ d: Date, _ fmt: String) -> String {
        let f = DateFormatter()
        f.dateFormat = fmt
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: d)
    }

    static func fileSlug(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        let mapped = text.lowercased().map { allowed.contains($0) ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        let trimmed = String(collapsed.prefix(60))
        return trimmed.isEmpty ? "topic" : trimmed
    }
}

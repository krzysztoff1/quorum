import Foundation

/// Whole-brain audit: the per-question conflict/gap logic of `runIterativeFanOut`, lifted to run across
/// EVERY note instead of within one run. Reads all notes off disk (via the store), embeds bounded
/// frontmatter summaries + excerpts under a char budget, and assembles a single prompt that asks the
/// agent to report contradictions, gaps, and worth-researching questions across the set. Missing
/// `[[wikilink]]` connections are found deterministically here (free, and the model can't be trusted to
/// return slugs correctly). Pure and testable; the app supplies the store and streams the answer through
/// the same Claude Code subprocess the chat uses. ponytail: single audit call; if quality drops on huge
/// brains, map-reduce the lint over note clusters — not v1.
public struct BrainLint: Sendable {
    /// One note, enough for the UI (title/path) and the prompt (frontmatter summary + bounded excerpt).
    public struct NoteSummary: Sendable, Equatable, Identifiable {
        public let slug: String
        public let title: String
        public let question: String
        public let path: String
        public let excerpt: String
        public var id: String { slug }
    }

    /// Two related notes that should `[[wikilink]]` each other but don't — surfaced for the user to act on.
    public struct ConnectionCandidate: Sendable, Equatable, Identifiable {
        public let fromSlug: String
        public let toSlug: String
        public let fromTitle: String
        public let toTitle: String
        public let score: Double
        public var id: String { "\(fromSlug)→\(toSlug)" }
    }

    /// All notes, listed once (embedded oldest-slug first for a stable prompt).
    public let notes: [NoteSummary]
    /// Missing-connection candidates — deterministic + free, not from the model.
    public let unlinkedCandidates: [ConnectionCandidate]
    /// The prompt to send the agent: audit the whole set, return a ```json block of findings.
    public let prompt: String

    /// A stable phrase in the prompt so the dev dry-run executor can recognise a lint prompt.
    public static let auditMarker = "auditing your entire knowledge base"

    /// Build the summaries, missing-connection candidates, and prompt for the whole brain. `budget` bounds
    /// the total embedded note text (frontmatter is always embedded — it's cheap and it's what
    /// inconsistency-detection needs); once spent, a note is still listed but its excerpt is dropped and the
    /// prompt tells the agent the full note is on disk to read. ponytail: char-count budget, not tokens.
    public static func build(brain: URL, store: any FindingsStore, budget: Int = 40_000) -> BrainLint {
        let urls = store.allNotes(in: brain).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var notes: [NoteSummary] = []
        var bodies: [String] = []
        var used = 0
        for url in urls {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (fm, body) = DiskFindingsStore.splitFrontmatter(raw)
            let slug = url.deletingPathExtension().lastPathComponent
            let deslugged = slug.replacingOccurrences(of: "-", with: " ")
            let title = fm["title"].flatMap { $0.isEmpty ? nil : $0 } ?? deslugged
            let question = fm["question"].flatMap { $0.isEmpty ? nil : $0 } ?? deslugged
            let room = max(0, budget - used)
            let excerpt = room >= 200 ? String(body.prefix(room)) : ""   // still listed; body read from disk
            used += excerpt.count
            notes.append(NoteSummary(slug: slug, title: title, question: question, path: url.path, excerpt: excerpt))
            bodies.append(body)
        }
        return BrainLint(notes: notes,
                         unlinkedCandidates: connectionCandidates(notes: notes, bodies: bodies),
                         prompt: makePrompt(notes: notes))
    }

    /// For each unordered pair, score their questions by the same keyword-Jaccard the store uses; emit a
    /// candidate when they're related AND neither already `[[wikilinks]]` the other. Sorted by score,
    /// capped. ponytail: O(n²) pairwise scan — fine for hundreds of notes; batch/index if the brain outgrows it.
    static func connectionCandidates(notes: [NoteSummary], bodies: [String]) -> [ConnectionCandidate] {
        var out: [ConnectionCandidate] = []
        for i in notes.indices {
            for j in (i + 1)..<notes.count {
                let a = notes[i], b = notes[j]
                let score = DiskFindingsStore.score(DiskFindingsStore.keywords(a.question),
                                                    DiskFindingsStore.keywords(b.question))
                guard score >= DiskFindingsStore.relatedMin else { continue }
                guard !bodies[i].contains("[[\(b.slug)]]"), !bodies[j].contains("[[\(a.slug)]]") else { continue }
                out.append(ConnectionCandidate(fromSlug: a.slug, toSlug: b.slug,
                                               fromTitle: a.title, toTitle: b.title, score: score))
            }
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(20))
    }

    static func makePrompt(notes: [NoteSummary]) -> String {
        var p = "You are \(auditMarker) — every research note you've saved. Audit the whole set for problems.\n\n"
        if notes.isEmpty {
            p += """
            There are NO notes yet — there's nothing to audit.
            Return a ```json block with empty arrays: {"inconsistencies": [], "gaps": [], "questions": []}.
            """
            return p
        }
        p += "ALL NOTES (frontmatter summary always; excerpts may be truncated — the full note is on disk at the path shown, read it with your file tools if a summary is too thin to judge):\n\n"
        for n in notes {
            p += "=== \(n.title) — \(n.path) ===\n"
            p += "Question: \(n.question)\n"
            p += n.excerpt.isEmpty ? "(excerpt omitted for length — read the file at the path above)\n" : n.excerpt + "\n"
            p += "\n"
        }
        p += """
        Audit ACROSS notes and return your findings as a ```json block with exactly these keys:
        - "inconsistencies": claims that CONTRADICT between notes — each {"claim": short label, "notes": [the note titles involved], "detail": why they conflict}.
        - "gaps": questions these notes raise but never answer (array of strings).
        - "questions": new research worth doing to deepen or connect this brain (array of strings).
        Read full notes from the given paths when a summary is too thin. Report only real findings — an empty array is the right answer when there's nothing to report.
        """
        return p
    }
}

/// The model's audit output. Connections stay deterministic (from `BrainLint`) — the model is only asked
/// for the reasoning-shaped findings. Forgiving: any parse failure degrades to an empty report, never a throw.
public struct BrainLintReport: Sendable, Equatable {
    public struct Inconsistency: Sendable, Equatable {
        public let claim: String
        public let notes: [String]
        public let detail: String
    }
    public let inconsistencies: [Inconsistency]
    public let gaps: [String]
    public let questions: [String]

    public static func parse(_ text: String) -> BrainLintReport {
        guard let (json, _) = ResearchOutputParser.lastJSONBlock(in: text),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return BrainLintReport(inconsistencies: [], gaps: [], questions: [])
        }
        let inconsistencies = (raw.inconsistencies ?? []).compactMap { r -> Inconsistency? in
            let claim = (r.claim ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !claim.isEmpty else { return nil }
            return Inconsistency(claim: claim,
                                 notes: clean(r.notes),
                                 detail: (r.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return BrainLintReport(inconsistencies: inconsistencies, gaps: clean(raw.gaps), questions: clean(raw.questions))
    }

    private static func clean(_ items: [String]?) -> [String] {
        (items ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private struct Raw: Decodable {
        let inconsistencies: [RawInconsistency]?
        let gaps: [String]?
        let questions: [String]?
        struct RawInconsistency: Decodable { let claim: String?; let notes: [String]?; let detail: String? }
    }
}

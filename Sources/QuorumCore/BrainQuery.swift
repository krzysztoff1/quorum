import Foundation

/// "Ask your brain" (story 40): answer a question from the user's OWN notes first, and the web only for
/// the gap. Reuses the existing keyword matcher (`FindingsStore.relatedNotes`) to pre-select the notes
/// most related to the question, reads bounded excerpts, and assembles the prompt that tells the agent to
/// answer from those notes first. Pure and testable; the app supplies the store and streams the answer
/// (through the same Claude Code subprocess the chat uses).
public struct BrainQuery: Sendable {
    /// A matched note — enough for the UI to show it (title + path, tap to open) and for the prompt to
    /// embed it (the bounded excerpt).
    public struct Note: Identifiable, Sendable, Equatable {
        public let path: String
        public let title: String
        public let excerpt: String
        public var id: String { path }
    }

    /// The notes the matcher picked, most-related first (may be empty — an unknown topic).
    public let notes: [Note]
    /// The prompt to send the agent: notes-first, web-only-for-the-gap, provenance kept separate.
    public let prompt: String

    /// Build the matched notes + prompt for a question. `budget` bounds the total embedded note text so a
    /// big brain can't blow up the prompt; the full note stays on disk (its path is in the prompt) for the
    /// agent to read if an excerpt was truncated. ponytail: char-count budget, not tokens — good enough;
    /// the agent re-reads from disk when it needs more.
    public static func build(question: String, brain: URL, store: any FindingsStore,
                             budget: Int = 24_000) -> BrainQuery {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = q.isEmpty ? [] : store.relatedNotes(to: q, in: brain)
        var notes: [Note] = []
        var used = 0
        for url in urls {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let title = DiskFindingsStore.splitFrontmatter(raw).fields["title"].flatMap { $0.isEmpty ? nil : $0 }
                ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
            let room = max(0, budget - used)
            let excerpt = room >= 200 ? String(raw.prefix(room)) : ""   // still listed; body read from disk
            used += excerpt.count
            notes.append(Note(path: url.path, title: title, excerpt: excerpt))
        }
        return BrainQuery(notes: notes, prompt: makePrompt(question: q, notes: notes))
    }

    static func makePrompt(question: String, notes: [Note]) -> String {
        var p = "You are the user's second brain. Answer their question from their OWN research notes first, and use the web only to fill what the notes don't cover.\n\n"
        p += "QUESTION:\n\(question)\n\n"
        if notes.isEmpty {
            p += """
            Their brain has NO notes matching this question yet.
            - Say that plainly in one sentence.
            - Then answer from the web (search as needed), clearly marked as web-sourced.
            - End by suggesting they run an "Explore every angle" research to capture this in their brain.
            """
        } else {
            p += "RELEVANT NOTES FROM THEIR BRAIN (pre-selected as most related; excerpts may be truncated — the full note is on disk at the path shown, read it if you need more):\n\n"
            for n in notes {
                p += "=== \(n.title) — \(n.path) ===\n"
                p += n.excerpt.isEmpty ? "(excerpt omitted for length — read the file at the path above)" : n.excerpt
                p += "\n\n"
            }
            p += """
            INSTRUCTIONS:
            - Answer PRIMARILY from these notes, and cite the note titles you draw on.
            - Search the web ONLY to fill a genuine gap the notes don't cover, or to check something time-sensitive. If the notes already answer the question, do NOT search — just answer.
            - Keep anything you add from the web in a short, clearly-labelled "From the web" section, so the user can trust which parts came from their brain.
            - Be concise and directly useful — answer the question, don't summarize the whole notes.
            """
        }
        return p
    }
}

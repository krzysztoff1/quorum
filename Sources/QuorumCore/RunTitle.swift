import Foundation

/// The name a run's folder carries. A cheap model is asked for a short label and usually gives one — but
/// it is a chat model, and an ambiguous, mistyped or non-English question just as often gets back a
/// clarifying question, a "did you mean…", or a refusal. Those are replies TO the question, not names FOR
/// it, and a run folder called "Zanim zacznę deep research, chciałbym sprecyzować…" says nothing about
/// what was researched. So the shape is checked before the reply is trusted, and anything that isn't a
/// title falls back to the question itself — the one string that is always about the topic.
public enum RunTitle {
    static let maxLength = 60
    static let maxWords = 8

    /// The folder title for a run: the model's label when it wrote one, else a short cut of the question.
    public static func from(reply: String?, question: String) -> String {
        modelTitle(reply) ?? fromQuestion(question)
    }

    /// The reply when it names the question, or nil when it answers it: a title is one short line of a few
    /// words with nothing conversational in it. Deliberately language-agnostic — the tells that a Polish
    /// clarifier shares with an English one are its length and its punctuation, not its vocabulary.
    public static func modelTitle(_ reply: String?) -> String? {
        guard let reply, isOneShortLine(reply) else { return nil }
        let candidate = ResearchOutputParser.titleFrom(reply)
        guard !candidate.isEmpty,
              candidate.split(whereSeparator: \.isWhitespace).count <= maxWords,
              candidate.rangeOfCharacter(from: Self.conversational) == nil else { return nil }
        return candidate
    }

    /// The question as a folder title: one line, cut to length on a word boundary, with the punctuation a
    /// question trails stripped off its ends.
    public static func fromQuestion(_ question: String) -> String {
        trimmingEdgePunctuation(cut(question.split(whereSeparator: \.isWhitespace).joined(separator: " ")))
    }

    private static let conversational = CharacterSet(charactersIn: "?!")

    private static func isOneShortLine(_ reply: String) -> Bool {
        let lines = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, let only = lines.first else { return false }
        return only.count <= maxLength
    }

    private static func cut(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let window = text.prefix(maxLength)
        guard let lastSpace = window.lastIndex(of: " ") else { return String(window) }
        return String(window[..<lastSpace])
    }

    private static func trimmingEdgePunctuation(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters).union(.symbols))
    }
}

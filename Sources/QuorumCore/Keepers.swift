import Foundation

/// One saved snippet — a link, sentence, or name the user wanted to keep from a research writeup.
public struct Keeper: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let source: String
    public let date: Date

    public init(id: String, text: String, source: String, date: Date) {
        self.id = id; self.text = text; self.source = source; self.date = date
    }
}

/// Keepers live in one portable markdown file, `Quorum/keepers.md`, so they drop straight into Obsidian
/// like every other note. Each clip is a blockquote fronted by an HTML-comment marker that carries its
/// id/date/source — invisible when rendered, but a robust delimiter that survives clip bodies containing
/// `---`, `>`, or `|`. Runs never write here; only the Keepers flow does.
public enum Keepers {
    public static func url(in brain: URL) -> URL {
        brain.appendingPathComponent("Quorum", isDirectory: true).appendingPathComponent("keepers.md")
    }

    static let marker = "<!--keeper|"
    static let header = "---\ntitle: Keepers\nkind: keepers\n---\n\n# Keepers\n"

    public static func parse(_ markdown: String) -> [Keeper] {
        markdown.components(separatedBy: marker).dropFirst().compactMap { chunk in
            guard let close = chunk.range(of: "-->") else { return nil }
            let fields = chunk[..<close.lowerBound].components(separatedBy: "|")
            guard fields.count >= 3, let date = isoParse(fields[1]) else { return nil }
            return Keeper(id: fields[0], text: extractText(String(chunk[close.upperBound...])),
                          source: fields[2...].joined(separator: "|"), date: date)
        }
    }

    public static func appending(text: String, source: String, id: String, date: Date,
                                 to markdown: String) -> String {
        let base = markdown.isEmpty ? header : markdown
        return base.trimmingCharacters(in: .newlines) + "\n\n"
             + block(Keeper(id: id, text: text, source: source, date: date)) + "\n"
    }

    public static func removing(id: String, from markdown: String) -> String {
        render(parse(markdown).filter { $0.id != id })
    }

    public static func render(_ keepers: [Keeper]) -> String {
        keepers.reduce(header) { $0.trimmingCharacters(in: .newlines) + "\n\n" + block($1) + "\n" }
    }

    static func block(_ k: Keeper) -> String {
        let quoted = k.text.components(separatedBy: "\n")
            .map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
        let clean = sanitize(k.source)
        // A `[[wikilink]]` back to the research note — visible + clickable in Obsidian; the marker keeps
        // the full path so the app can reopen it. Excluded from the clip text by `extractText`.
        let attribution = clean.isEmpty ? "" : "\n— from [[\(slug(clean))]]"
        return "\(marker)\(k.id)|\(iso(k.date))|\(clean)-->\n\(quoted)\(attribution)"
    }

    static func slug(_ source: String) -> String {
        let base = (source as NSString).lastPathComponent
        return base.hasSuffix(".md") ? String(base.dropLast(3)) : base
    }

    // ponytail: a clip whose body literally contains "<!--keeper|" would split wrong — a research snippet
    // never does; guard the marker only if that ever bites.
    static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "|", with: "/")
         .replacingOccurrences(of: "-->", with: "->")
         .trimmingCharacters(in: .whitespaces)
    }

    /// The clip text is the leading run of `>`-quoted lines; the first non-quoted line (the `— from`
    /// attribution) ends it. Every text line is quoted by `block`, so mid-clip blanks (rendered `>`) are
    /// kept while the trailing attribution is dropped.
    static func extractText(_ body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        while lines.first?.isEmpty == true { lines.removeFirst() }
        var out: [String] = []
        for line in lines {
            guard line.hasPrefix(">") else { break }
            out.append(line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line.dropFirst()))
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
    static func isoParse(_ s: String) -> Date? { isoFormatter.date(from: s) }
}

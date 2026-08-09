import Foundation

/// What kind of markdown block a piece of a writeup is. The reader renders prose blocks itself (so it can
/// put a tappable chip where each `[^c3]` marker stood) and hands the rest to the markdown view unchanged.
public enum CitedBlockKind: String, Sendable, Equatable {
    case paragraph, heading, listItem, table, code, quote
}

/// One markdown block of a writeup plus the citation markers found inside it. `text` keeps its markdown
/// AND its markers, so the reader can place chips at the right offsets; `citationIDs` is the same markers
/// flattened, in reading order, for a per-block summary.
public struct CitedBlock: Identifiable, Sendable, Equatable {
    public let id: Int
    public let kind: CitedBlockKind
    public let text: String
    public let citationIDs: [String]

    public init(id: Int, kind: CitedBlockKind, text: String, citationIDs: [String]) {
        self.id = id
        self.kind = kind
        self.text = text
        self.citationIDs = citationIDs
    }

    public var strippedText: String { CitationMarkers.stripping(text) }
}

/// One `[^id]` marker and where it sits in the text it came from.
public struct CitationMarker: Sendable, Equatable {
    public let id: String
    public let range: Range<String.Index>

    public init(id: String, range: Range<String.Index>) {
        self.id = id
        self.range = range
    }
}

/// Parsing of the `[^c3]` footnote markers the research prompts contract for. Markdown footnote syntax is
/// deliberate: the brain's notes stay portable, so a note with generated definitions renders correct
/// footnotes in Obsidian or on GitHub with no Quorum involved.
public enum CitationMarkers {

    static let markerPattern = #"\[\^([A-Za-z0-9_-]{1,32})\]"#

    /// Every marker with its position, in reading order.
    public static func markers(in text: String) -> [CitationMarker] {
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1,
                  let full = Range(match.range, in: text),
                  let idRange = Range(match.range(at: 1), in: text) else { return nil }
            return CitationMarker(id: String(text[idRange]), range: full)
        }
    }

    /// Marker ids in reading order, duplicates preserved (a sentence may cite the same source twice).
    public static func ids(in text: String) -> [String] {
        markers(in: text).map(\.id)
    }

    /// The text with every marker removed, tidying the space a removed marker leaves behind. Used for
    /// plain views, the benchmark's baseline comparison, and search.
    public static func stripping(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return text }
        let ns = NSMutableString(string: text)
        regex.replaceMatches(in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return (ns as String)
            .replacingOccurrences(of: #" +([.,;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+$"#, with: "", options: [.regularExpression])
    }

    /// Does this writeup carry per-sentence provenance at all? False for a legacy run — the reader falls
    /// back to the plain markdown view instead of showing an empty citation rail.
    public static func hasMarkers(in text: String) -> Bool { !markers(in: text).isEmpty }

    /// Split a writeup into renderable markdown blocks. Fenced code is opaque (markers inside it are part
    /// of the sample, not citations); consecutive table rows group into one block; every other run of
    /// non-blank lines becomes a paragraph, with headings and list items standing alone.
    public static func blocks(in writeup: String) -> [CitedBlock] {
        var blocks: [CitedBlock] = []
        var paragraph: [String] = []
        var table: [String] = []
        var fence: [String] = []
        var inFence = false
        var next = 0

        func emit(_ kind: CitedBlockKind, _ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            blocks.append(CitedBlock(id: next, kind: kind, text: trimmed,
                                     citationIDs: kind == .code ? [] : ids(in: trimmed)))
            next += 1
        }
        func flushParagraph() {
            defer { paragraph = [] }
            emit(.paragraph, paragraph.joined(separator: "\n"))
        }
        func flushTable() {
            defer { table = [] }
            emit(.table, table.joined(separator: "\n"))
        }

        for line in writeup.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFence {
                fence.append(line)
                if trimmed.hasPrefix("```") {
                    inFence = false
                    emit(.code, fence.joined(separator: "\n"))
                    fence = []
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph(); flushTable()
                inFence = true
                fence = [line]
                continue
            }
            if trimmed.isEmpty {
                flushParagraph(); flushTable()
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                table.append(line)
                continue
            }
            flushTable()
            if trimmed.hasPrefix("#") {
                flushParagraph()
                emit(.heading, trimmed)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                emit(.quote, trimmed)
                continue
            }
            if isListItem(trimmed) {
                flushParagraph()
                emit(.listItem, trimmed)
                continue
            }
            paragraph.append(line)
        }
        if inFence { emit(.code, fence.joined(separator: "\n")) }
        flushParagraph()
        flushTable()
        return blocks
    }

    private static func isListItem(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        return trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
    }

    /// The markdown footnote definitions for a writeup's markers, appended to a note so the citation
    /// survives outside the app. Emits only markers the writeup actually uses, in first-use order, so a
    /// note never carries definitions for citations it doesn't reference.
    public static func footnoteDefinitions(for writeup: String, evidence: EvidenceIndex) -> String {
        var seen = Set<String>()
        let used = ids(in: writeup).filter { seen.insert($0).inserted }
        let lines: [String] = used.compactMap { id in
            guard let citation = evidence.citation(id) else { return nil }
            let document = evidence.document(for: citation)
            return "[^\(id)]: " + definitionBody(citation, document)
        }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n")
    }

    private static func definitionBody(_ citation: Citation, _ document: SourceDocument?) -> String {
        var parts: [String] = []
        if let document {
            let title = document.displayTitle.replacingOccurrences(of: "]", with: "")
            parts.append(document.url.isEmpty ? title : "[\(title)](\(document.url))")
        }
        if let page = citation.page { parts.append("p. \(page)") }
        let quote = citation.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !quote.isEmpty { parts.append("“\(singleLine(quote))”") }
        if !citation.isVerified { parts.append("(quote not verifiable against a stored snapshot)") }
        return parts.isEmpty ? citation.id : parts.joined(separator: " — ")
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

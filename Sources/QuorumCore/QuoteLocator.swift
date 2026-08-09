import Foundation

/// Where a quote sits in a stored snapshot. The recorded offsets are written by whichever process captured
/// the source, so they are checked against the text before they are trusted: a highlight the reader can see
/// beats an offset nobody verified, and no highlight at all beats a wrong one.
public enum QuoteLocator {

    /// The passages worth offering for this citation, in document order, and which one it pinned. Empty for
    /// an unresolved citation — the run could not find the quote, and the reader is told that instead of
    /// being shown a guess.
    public static func passages(for citation: Citation, in text: String) -> (ranges: [Range<String.Index>], index: Int) {
        guard citation.isVerified else { return ([], 0) }
        var ranges = occurrences(of: citation.quote, in: text)
        guard let recorded = recordedRange(citation, in: text) else { return (ranges, 0) }
        if let overlapping = ranges.firstIndex(where: { $0.overlaps(recorded) }) { return (ranges, overlapping) }
        guard ranges.isEmpty || holdsQuote(citation.quote, at: recorded, in: text) else { return (ranges, 0) }
        ranges.append(recorded)
        ranges.sort { $0.lowerBound < $1.lowerBound }
        return (ranges, ranges.firstIndex(of: recorded) ?? 0)
    }

    /// Every place the quote occurs, verbatim first and whitespace-tolerantly only if that finds nothing —
    /// so "the quote appears twice" means what it says and prev/next has something real to walk.
    public static func occurrences(of quote: String, in text: String, limit: Int = 60) -> [Range<String.Index>] {
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 4, !text.isEmpty else { return [] }
        let verbatim = ranges(of: needle, in: text)
        let found = verbatim.isEmpty ? ranges(matching: whitespaceTolerantPattern(needle), in: text) : verbatim
        return Array(found.prefix(limit))
    }

    /// The recorded offsets as a range in this text. Offsets are counted in UTF-16 units, the unit every
    /// capture path shares.
    public static func recordedRange(_ citation: Citation, in text: String) -> Range<String.Index>? {
        guard let offsets = citation.snapshotRange else { return nil }
        let units = text.utf16
        guard let lower = units.index(units.startIndex, offsetBy: offsets.lowerBound, limitedBy: units.endIndex),
              let upper = units.index(units.startIndex, offsetBy: offsets.upperBound, limitedBy: units.endIndex),
              let start = String.Index(lower, within: text), let end = String.Index(upper, within: text),
              start < end else { return nil }
        return start..<end
    }

    public static func holdsQuote(_ quote: String, at range: Range<String.Index>, in text: String) -> Bool {
        folded(String(text[range])) == folded(quote)
    }

    /// The match ladder's `normalized` rung: whitespace, case, smart quotes and dashes folded away.
    public static func folded(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[\u{2018}\u{2019}\u{201B}]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[\u{201C}\u{201D}]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func whitespaceTolerantPattern(_ needle: String) -> String {
        NSRegularExpression.escapedPattern(for: needle)
            .replacingOccurrences(of: #"\s+"#,
                                  with: NSRegularExpression.escapedTemplate(for: #"\s+"#),
                                  options: .regularExpression)
    }

    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let hit = text.range(of: needle, range: searchStart..<text.endIndex) {
            found.append(hit)
            searchStart = hit.upperBound > hit.lowerBound ? hit.upperBound : text.index(after: hit.lowerBound)
            if searchStart >= text.endIndex { break }
        }
        return found
    }

    private static func ranges(matching pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: whole).compactMap { Range($0.range, in: text) }
    }

    // MARK: the ladder, shared with the engine (PRD 07 R6)

    /// Where a quote sits in a snapshot and how well it sits there. The engine's `evidence.ts` derives the
    /// same tier from the same text; `Fixtures/quote-match-contract.json` is the shared proof, because a
    /// chip coloured "verified" over a highlight this side would not have found is a lie the reader cannot
    /// see through.
    public struct QuoteResolution: Equatable, Sendable {
        public let match: QuoteMatch
        public let range: Range<String.Index>?
    }

    /// How the best-overlapping window scores: `dice` is word-set overlap, `order` is how much of that
    /// window reads in the quote's own order. Both bars must fall for a quote to be a close match — set
    /// overlap alone scores a scrambled quote a perfect 1.0.
    public struct WindowScores: Equatable, Sendable {
        public let dice: Double
        public let order: Double
    }

    public static let fuzzyDiceThreshold = 0.82
    public static let fuzzyOrderThreshold = 0.6

    public static func resolve(quote: String, in text: String) -> QuoteResolution {
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return QuoteResolution(match: .unresolved, range: nil) }
        if let verbatim = text.range(of: needle) { return QuoteResolution(match: .exact, range: verbatim) }

        let haystack = foldedIndex(text)
        let wanted = foldedIndex(needle)
        guard !wanted.chars.isEmpty else { return QuoteResolution(match: .unresolved, range: nil) }
        if let hit = firstIndex(of: wanted.chars, in: haystack.chars) {
            return QuoteResolution(match: .normalized,
                                   range: haystack.span(from: hit, through: hit + wanted.chars.count - 1, in: text))
        }
        guard let window = scoredWindow(tokens(haystack, in: text), tokens(wanted, in: needle)),
              window.scores.dice >= fuzzyDiceThreshold, window.scores.order >= fuzzyOrderThreshold
        else { return QuoteResolution(match: .unresolved, range: nil) }
        return QuoteResolution(match: .fuzzy, range: window.range)
    }

    public static func windowScores(quote: String, in text: String) -> WindowScores? {
        scoredWindow(tokens(foldedIndex(text), in: text), tokens(foldedIndex(quote), in: quote))?.scores
    }

    private struct FoldedText {
        let chars: [Character]
        let sources: [String.Index]

        func span(from first: Int, through last: Int, in text: String) -> Range<String.Index> {
            sources[first]..<text.index(after: sources[last])
        }
    }

    private struct Token {
        let text: String
        let range: Range<String.Index>
    }

    private struct ScoredWindow {
        let range: Range<String.Index>
        let scores: WindowScores
    }

    private static let foldedCharacters: [Character: Character] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201B}": "'", "\u{2032}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201F}": "\"", "\u{2033}": "\"",
        "\u{2013}": "-", "\u{2014}": "-", "\u{2015}": "-", "\u{2212}": "-",
    ]

    /// `folded` again, but keeping the source index every folded character came from — so a hit in the
    /// folded text maps back to a range in the ORIGINAL snapshot, which is the text the reader highlights.
    private static func foldedIndex(_ text: String) -> FoldedText {
        var chars: [Character] = []
        var sources: [String.Index] = []
        var spaceAt: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            defer { index = text.index(after: index) }
            if character.isWhitespace {
                if spaceAt == nil { spaceAt = index }
                continue
            }
            if let pending = spaceAt {
                if !chars.isEmpty {
                    chars.append(" ")
                    sources.append(pending)
                }
                spaceAt = nil
            }
            for lowered in (foldedCharacters[character] ?? character).lowercased() {
                chars.append(lowered)
                sources.append(index)
            }
        }
        return FoldedText(chars: chars, sources: sources)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func tokens(_ folded: FoldedText, in text: String) -> [Token] {
        var found: [Token] = []
        var cursor = 0
        while cursor < folded.chars.count {
            if folded.chars[cursor] == " " {
                cursor += 1
                continue
            }
            var end = cursor
            while end < folded.chars.count && folded.chars[end] != " " { end += 1 }
            var head = cursor
            var tail = end - 1
            while head <= tail && !isWordCharacter(folded.chars[head]) { head += 1 }
            while tail >= head && !isWordCharacter(folded.chars[tail]) && folded.chars[tail] != "%" { tail -= 1 }
            if head <= tail {
                found.append(Token(text: String(folded.chars[head...tail]),
                                   range: folded.span(from: cursor, through: end - 1, in: text)))
            }
            cursor = end
        }
        return found
    }

    private static func scoredWindow(_ words: [Token], _ target: [Token]) -> ScoredWindow? {
        let wanted = target.map(\.text)
        let size = wanted.count
        guard size > 0, words.count >= size else { return nil }

        let unique = Set(wanted)
        var best: ScoredWindow?
        for start in 0...(words.count - size) {
            let window = words[start..<(start + size)].map(\.text)
            let seen = Set(window)
            let shared = seen.filter(unique.contains).count
            let dice = (2 * Double(shared)) / Double(seen.count + unique.count)
            if let best, dice <= best.scores.dice { continue }
            best = ScoredWindow(range: words[start].range.lowerBound..<words[start + size - 1].range.upperBound,
                                scores: WindowScores(dice: dice, order: orderRatio(window, wanted)))
        }
        return best
    }

    /// Longest common subsequence over the quote's length: 1.0 when the window reads the quote's words in
    /// the quote's order, near zero when it merely contains them.
    private static func orderRatio(_ window: [String], _ wanted: [String]) -> Double {
        guard !wanted.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: wanted.count + 1)
        var current = [Int](repeating: 0, count: wanted.count + 1)
        for row in 1...window.count {
            for column in 1...wanted.count {
                current[column] = window[row - 1] == wanted[column - 1]
                    ? previous[column - 1] + 1
                    : max(previous[column], current[column - 1])
            }
            swap(&previous, &current)
        }
        return Double(previous[wanted.count]) / Double(wanted.count)
    }

    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var offset = 0
            while offset < needle.count && haystack[start + offset] == needle[offset] { offset += 1 }
            if offset == needle.count { return start }
        }
        return nil
    }

    /// Search strings to try in a PDF's real page layout, longest first. Extraction folds away the
    /// hyphenation and line breaks the page itself carries, so the whole quote often misses where its
    /// opening clause lands. Pure so it can be tested without a PDF.
    public static func pdfSearchCandidates(for quote: String) -> [String] {
        let single = quote.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = single.components(separatedBy: " ")
        var tried: [String] = []
        for candidate in [single, words.prefix(12).joined(separator: " "), words.prefix(6).joined(separator: " ")]
        where candidate.count >= 12 && !tried.contains(candidate) {
            tried.append(candidate)
        }
        return tried
    }
}

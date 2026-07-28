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

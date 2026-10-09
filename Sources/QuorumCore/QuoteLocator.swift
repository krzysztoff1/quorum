import Foundation

public enum QuoteLocator {

    public static func passages(for citation: Citation, in text: String) -> (ranges: [Range<String.Index>], index: Int) {
        guard citation.isVerified, let recorded = recordedRange(citation, in: text) else { return ([], 0) }
        return ([recorded], 0)
    }

    public static func recordedRange(_ citation: Citation, in text: String) -> Range<String.Index>? {
        guard let offsets = citation.snapshotRange else { return nil }
        let units = text.utf16
        guard let lower = units.index(units.startIndex, offsetBy: offsets.lowerBound, limitedBy: units.endIndex),
              let upper = units.index(units.startIndex, offsetBy: offsets.upperBound, limitedBy: units.endIndex),
              let start = String.Index(lower, within: text), let end = String.Index(upper, within: text),
              start < end else { return nil }
        return start..<end
    }

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

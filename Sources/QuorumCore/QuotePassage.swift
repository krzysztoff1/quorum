import Foundation

public struct QuotePassage: Sendable, Equatable {
    public let before: String
    public let quote: String
    public let after: String

    public init(before: String, quote: String, after: String) {
        self.before = before
        self.quote = quote
        self.after = after
    }

    public init(text: String, quote: String, start: Int?, end: Int?, radius: Int = 280) {
        let source = text as NSString
        let located: NSRange
        if let start, let end, start >= 0, end <= source.length, start < end {
            located = NSRange(location: start, length: end - start)
        } else {
            located = source.range(of: quote, options: [.caseInsensitive, .diacriticInsensitive])
        }
        guard located.location != NSNotFound else {
            self.init(before: "", quote: quote, after: "")
            return
        }
        let lower = max(0, located.location - radius)
        let upper = min(source.length, located.upperBound + radius)
        var before = source.substring(with: NSRange(location: lower, length: located.location - lower))
        var after = source.substring(with: NSRange(location: located.upperBound, length: upper - located.upperBound))
        if lower > 0 {
            let cutMidWord = !Self.isSpace(source.character(at: lower - 1))
            if cutMidWord, let space = before.firstIndex(where: \.isWhitespace) { before = String(before[before.index(after: space)...]) }
            before = "…" + before
        }
        if upper < source.length {
            let cutMidWord = !Self.isSpace(source.character(at: upper))
            if cutMidWord, let space = after.lastIndex(where: \.isWhitespace) { after = String(after[..<space]) }
            after += "…"
        }
        self.init(before: Self.flatten(before), quote: Self.flatten(source.substring(with: located)), after: Self.flatten(after))
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 32 || unit == 10 || unit == 9 || unit == 13
    }

    private static func flatten(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

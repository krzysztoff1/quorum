import Foundation

public enum RestatedOpenQuestions {
    static let minimumOverlap = 0.35
    static let minimumSharedWords = 3

    public static func stripped(_ writeup: String, conflicts: [Conflict], gaps: [String]) -> String {
        let known = (conflicts.map { ([$0.claim] + $0.positions).joined(separator: " ") } + gaps)
            .map(significantWords)
            .filter { !$0.isEmpty }
        guard !known.isEmpty else { return writeup }
        let lines = writeup.components(separatedBy: "\n")
        var kept: [String] = []
        var dropped = false
        var index = 0
        while index < lines.count {
            let end = sectionEnd(after: index, in: lines)
            if isSubheading(lines[index]), restatesOnly(lines[(index + 1)..<end], known) {
                dropped = true
                index = end
                continue
            }
            kept.append(lines[index])
            index += 1
        }
        guard dropped else { return writeup }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSubheading(_ line: String) -> Bool {
        line.hasPrefix("## ") || line.hasPrefix("### ")
    }

    private static func sectionEnd(after heading: Int, in lines: [String]) -> Int {
        var next = heading + 1
        while next < lines.count, !lines[next].hasPrefix("#") { next += 1 }
        return next
    }

    private static func restatesOnly(_ body: ArraySlice<String>, _ known: [Set<String>]) -> Bool {
        let content = body.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return !content.isEmpty && content.allSatisfy { isBullet($0) && isCovered($0, by: known) }
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
    }

    private static func isCovered(_ bullet: String, by known: [Set<String>]) -> Bool {
        let words = significantWords(bullet)
        guard !words.isEmpty else { return false }
        return known.contains { statement in
            let shared = words.intersection(statement).count
            return shared >= minimumSharedWords
                && Double(shared) / Double(min(words.count, statement.count)) >= minimumOverlap
        }
    }

    static func significantWords(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 })
    }
}

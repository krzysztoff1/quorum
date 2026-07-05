import Foundation

/// Ranking for the global quick switcher. Pure string logic (no UI) so it's unit-tested: a match is
/// scored by where the query lands in the title — a title prefix beats a word-boundary hit beats a
/// bare substring — and results are ordered by that score, ties broken by original position (stable).
public enum QuickSwitch {
    private static let boundary: Set<Character> = [" ", "-", "_", "/", ".", ":"]

    /// nil = no match. Lower is better: 0 title prefix, 1 word-boundary, 2 anywhere. Empty query matches
    /// everything at 0 so the switcher shows the full list in its given order before you type.
    public static func score(_ query: String, _ title: String) -> Int? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let t = title.lowercased()
        guard let r = t.range(of: q) else { return nil }
        if r.lowerBound == t.startIndex { return 0 }
        return boundary.contains(t[t.index(before: r.lowerBound)]) ? 1 : 2
    }

    /// Indices of `titles` that match `query`, best first, stable within a score.
    public static func rankedIndices(_ query: String, _ titles: [String]) -> [Int] {
        titles.enumerated()
            .compactMap { i, t in score(query, t).map { (i, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map(\.0)
    }
}

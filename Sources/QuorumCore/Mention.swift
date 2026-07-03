import Foundation

/// Pure logic for @-mention autocomplete in the chat composer. Lives in Core so the fiddly parsing
/// and ranking are unit-tested; the app owns the disk scan (which files exist), the file picker, and
/// the UI. Substring matching, not fuzzy-subsequence — predictable for file paths.
public enum Mention {
    /// The active "@query" the user is typing, or nil. The `@` must open a token (start of string or
    /// after whitespace) and have no whitespace after it.
    /// ponytail: keyed off the LAST `@` and the text after it — SwiftUI's TextField doesn't expose the
    /// caret, so this tracks typing at the end (the common case); editing mid-string won't re-trigger.
    public static func activeQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let q = text[text.index(after: at)...]
        if q.contains(where: \.isWhitespace) { return nil }
        return String(q)
    }

    /// Replace the active `@query` with `@path ` (trailing space closes the token).
    public static func complete(_ text: String, with path: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + "@\(path) "
    }

    /// Files matching `query`, ranked: filename prefix > filename contains > path contains, then
    /// shorter paths first. Empty query returns the first `limit` (already-sorted) files.
    public static func rank(_ query: String, in files: [String], limit: Int = 8) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(files.prefix(limit)) }
        func name(_ p: String) -> Substring { p[(p.lastIndex(of: "/").map { p.index(after: $0) } ?? p.startIndex)...] }
        let scored: [(String, Int)] = files.compactMap { f in
            let lf = f.lowercased(), ln = name(lf)
            if ln.hasPrefix(q) { return (f, 0) }
            if ln.contains(q)  { return (f, 1) }
            if lf.contains(q)  { return (f, 2) }
            return nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.count < $1.0.count }
                     .prefix(limit).map(\.0)
    }

    /// The path of `file` relative to `root`, or nil if `file` isn't inside `root`.
    public static func relativePath(of file: URL, under root: URL) -> String? {
        let f = file.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        let prefix = r.hasSuffix("/") ? r : r + "/"
        guard f.hasPrefix(prefix) else { return nil }
        return String(f.dropFirst(prefix.count))
    }
}

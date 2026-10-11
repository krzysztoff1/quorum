import Foundation

public enum NotesFolder {
    public static func wikilinkSlugs(in body: String) -> [String] {
        var slugs: [String] = []
        var seen = Set<String>()
        var rest = Substring(body)
        while let open = rest.range(of: "[[") {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "]]") else { break }
            let inner = rest[..<close.lowerBound]
            rest = rest[close.upperBound...]
            let slug = inner.prefix { $0 != "|" && $0 != "#" }.trimmingCharacters(in: .whitespaces)
            if !slug.isEmpty, seen.insert(slug).inserted { slugs.append(slug) }
        }
        return slugs
    }
}

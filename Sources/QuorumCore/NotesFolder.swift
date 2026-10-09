import Foundation

public struct NoteTreeNode: Identifiable, Equatable, Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let children: [NoteTreeNode]

    public var id: String { url.path }
    public var childrenOrNil: [NoteTreeNode]? { children.isEmpty ? nil : children }

    public init(url: URL, name: String, isDirectory: Bool, children: [NoteTreeNode]) {
        self.url = url; self.name = name; self.isDirectory = isDirectory; self.children = children
    }
}

public enum NotesFolder {
    public static func markdownFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            if url.lastPathComponent == "node_modules" || url.lastPathComponent == "Pods" {
                en.skipDescendants(); continue
            }
            if url.pathExtension.lowercased() == "md",
               url.deletingPathExtension().pathExtension.lowercased() != "transcript" {
                out.append(url)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func noteTree(under root: URL) -> [NoteTreeNode] {
        let entries = markdownFiles(under: root).map {
            (comps: relativeComponents(of: $0, under: root), url: $0)
        }
        return assemble(entries, prefix: root)
    }

    private static func relativeComponents(of url: URL, under root: URL) -> [String] {
        let rc = root.resolvingSymlinksInPath().pathComponents
        let uc = url.resolvingSymlinksInPath().pathComponents
        guard uc.count > rc.count, Array(uc.prefix(rc.count)) == rc else { return [url.lastPathComponent] }
        return Array(uc.dropFirst(rc.count))
    }

    private static func assemble(_ entries: [(comps: [String], url: URL)], prefix: URL) -> [NoteTreeNode] {
        var dirs: [NoteTreeNode] = [], files: [NoteTreeNode] = []
        for (name, group) in Dictionary(grouping: entries.filter { !$0.comps.isEmpty }, by: { $0.comps[0] }) {
            let leaves = group.filter { $0.comps.count == 1 }
            if leaves.count == group.count, let leaf = leaves.first {
                files.append(NoteTreeNode(url: leaf.url, name: name, isDirectory: false, children: []))
            } else {
                let dirURL = prefix.appendingPathComponent(name, isDirectory: true)
                let deeper = group.map { (comps: Array($0.comps.dropFirst()), url: $0.url) }
                dirs.append(NoteTreeNode(url: dirURL, name: name, isDirectory: true,
                                         children: assemble(deeper, prefix: dirURL)))
            }
        }
        func byName(_ a: NoteTreeNode, _ b: NoteTreeNode) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return dirs.sorted(by: byName) + files.sorted(by: byName)
    }

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

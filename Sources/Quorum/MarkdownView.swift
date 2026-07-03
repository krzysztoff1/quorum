import SwiftUI

/// A lightweight native markdown renderer — headings, paragraphs, bullet/ordered lists, fenced code,
/// blockquotes, pipe tables, and horizontal rules, with inline bold/italic/code and **clickable
/// links** (they open in the browser). No dependency; `AttributedString(markdown:)` does the inline
/// spans, this just handles block structure the writeups actually use.
/// ponytail: covers the constructs our research writeups emit; not a spec-complete CommonMark parser.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parseMarkdown(markdown).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    @ViewBuilder
    private func render(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text)).font(headingFont(level)).bold().padding(.top, level <= 2 ? 8 : 2)
        case .paragraph(let text):
            Text(inline(text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(items[i])).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(items[i])).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 3)
                Text(inline(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) { tableGrid(header, rows) }
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func tableGrid(_ header: [String], _ rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            GridRow { ForEach(header.indices, id: \.self) { Text(inline(header[$0])).bold() } }
            Divider()
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(header.indices, id: \.self) { c in
                        Text(inline(c < rows[r].count ? rows[r][c] : ""))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level { case 1: return .title; case 2: return .title2; case 3: return .title3; default: return .headline }
    }
}

// MARK: - Block model + parser

enum MDBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case orderedList([String])
    case code(String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
}

func parseMarkdown(_ md: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    let lines = md.components(separatedBy: "\n")
    var i = 0

    func trimmed(_ n: Int) -> String { lines[n].trimmingCharacters(in: .whitespaces) }
    func isBullet(_ s: String) -> Bool { s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") }
    func isOrdered(_ s: String) -> Bool {
        guard let dot = s.firstIndex(of: ".") else { return false }
        let num = s[s.startIndex..<dot]
        return !num.isEmpty && num.allSatisfy(\.isNumber) && s.index(after: dot) < s.endIndex && s[s.index(after: dot)] == " "
    }
    func isTableSep(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }
    func cells(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    while i < lines.count {
        let t = trimmed(i)
        if t.isEmpty { i += 1; continue }

        if t.hasPrefix("```") {
            var code = ""; i += 1
            while i < lines.count && !trimmed(i).hasPrefix("```") { code += lines[i] + "\n"; i += 1 }
            if i < lines.count { i += 1 }
            blocks.append(.code(code.trimmingCharacters(in: .newlines))); continue
        }
        if t.first == "#" {
            let hashes = t.prefix { $0 == "#" }.count
            if hashes <= 6, t.count > hashes, t[t.index(t.startIndex, offsetBy: hashes)] == " " {
                blocks.append(.heading(level: hashes, text: String(t.dropFirst(hashes + 1)))); i += 1; continue
            }
        }
        if t == "---" || t == "***" || t == "___" { blocks.append(.rule); i += 1; continue }

        if t.hasPrefix("|"), i + 1 < lines.count, isTableSep(lines[i + 1]) {
            let header = cells(t); i += 2
            var rows: [[String]] = []
            while i < lines.count && trimmed(i).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
            blocks.append(.table(header: header, rows: rows)); continue
        }
        if t.hasPrefix(">") {
            var q: [String] = []
            while i < lines.count && trimmed(i).hasPrefix(">") {
                q.append(String(trimmed(i).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
            }
            blocks.append(.quote(q.joined(separator: " "))); continue
        }
        if isBullet(t) {
            var items: [String] = []
            while i < lines.count && isBullet(trimmed(i)) { items.append(String(trimmed(i).dropFirst(2))); i += 1 }
            blocks.append(.bulletList(items)); continue
        }
        if isOrdered(t) {
            var items: [String] = []
            while i < lines.count && isOrdered(trimmed(i)) {
                let s = trimmed(i)
                if let dot = s.firstIndex(of: ".") { items.append(String(s[s.index(after: dot)...]).trimmingCharacters(in: .whitespaces)) }
                i += 1
            }
            blocks.append(.orderedList(items)); continue
        }

        var para: [String] = []
        while i < lines.count {
            let l = trimmed(i)
            if l.isEmpty || l.hasPrefix("#") || l.hasPrefix("```") || l.hasPrefix(">")
                || isBullet(l) || isOrdered(l) || l.hasPrefix("|") || l == "---" { break }
            para.append(l); i += 1
        }
        if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))) }
    }
    return blocks
}

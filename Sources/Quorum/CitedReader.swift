import SwiftUI
import AppKit
import QuorumCore

/// The `quorum-cite:` link a chip carries. A citation id round-trips through a URL so a tap on a run of
/// `Text` can be caught by `OpenURLAction` — SwiftUI has no other way to make part of a paragraph tappable.
enum CitationLink {
    static let scheme = "quorum-cite"

    static func url(_ id: String) -> URL? { URL(string: "\(scheme):///\(id)") }

    static func citationID(in url: URL) -> String? {
        guard url.scheme == CitationLink.scheme else { return nil }
        let id = url.lastPathComponent
        return id.isEmpty ? nil : id
    }
}

/// Reader-facing citation numbers. `[^a2c1]` is an engine-internal id and means nothing to a person, so
/// chips are numbered by first appearance — ⟦1⟧, ⟦2⟧ — and the rail lists the sources in that same order.
struct CitationNumbering {
    let order: [String]
    private let numbers: [String: Int]

    init(writeup: String) {
        var numbers: [String: Int] = [:]
        var order: [String] = []
        for id in CitationMarkers.ids(in: writeup) where numbers[id] == nil {
            order.append(id)
            numbers[id] = order.count
        }
        self.order = order
        self.numbers = numbers
    }

    func number(_ id: String) -> Int? { numbers[id] }
}

/// Turns one markdown block into an `AttributedString` whose `[^c3]` markers have become superscript
/// citation chips. Inline markdown around a marker is parsed per segment, so bold, links and code spans
/// still read as themselves.
struct CitedProse {
    let numbering: CitationNumbering
    let evidence: EvidenceIndex
    var selectedID: String?

    func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        var cursor = text.startIndex
        for marker in CitationMarkers.markers(in: text) {
            out += inline(String(text[cursor..<marker.range.lowerBound]))
            out += chip(marker.id)
            cursor = marker.range.upperBound
        }
        out += inline(String(text[cursor...]))
        return out
    }

    private func inline(_ markdown: String) -> AttributedString {
        guard !markdown.isEmpty else { return AttributedString() }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    private func chip(_ id: String) -> AttributedString {
        guard let number = numbering.number(id) else { return AttributedString() }
        let citation = evidence.citation(id)
        let tier = evidence.tier(id)
        let style = CitationChipStyle(tier)
        var attributes = AttributeContainer()
        attributes.swiftUI.font = Font.caption.weight(.semibold)
        attributes.swiftUI.baselineOffset = 4
        attributes.swiftUI.foregroundColor = style.tint
        attributes.swiftUI.backgroundColor = selectedID == id ? style.tint.opacity(0.30) : style.fill
        if citation != nil { attributes.link = CitationLink.url(id) }
        return AttributedString("⟦\(number)\(tier.mark)⟧", attributes: attributes)
    }
}

/// How a chip is painted for a given rung of the ladder — the paint itself comes from `NodeStyle.citation`,
/// so the ⚠ of a quote that does not carry its claim is decided once, beside the tier it belongs to, and not
/// again in here. A rung with nothing behind it is drawn hollow: an unverifiable citation must never pass
/// for a verified one.
struct CitationChipStyle {
    let tint: Color
    let fill: Color

    init(_ tier: CitationTier) {
        let style = NodeStyle.citation(tier)
        tint = style.color
        fill = style.isMuted ? .clear : style.color.opacity(0.14)
    }
}

/// A writeup read with its provenance one click away: every `[^c3]` marker becomes a numbered chip, and
/// picking one hands the citation up so the source can be opened beside the prose. Tables and fenced code
/// go to `MarkdownView` (markers stripped) — nothing is gained by re-implementing those. A writeup with no
/// markers is a legacy run: it falls back to the plain markdown view rather than showing an empty rail.
struct CitedReader: View {
    let writeup: String
    let evidence: EvidenceIndex
    @Binding var selected: Citation?
    let documentID: String?

    private let numbering: CitationNumbering
    private let blocks: [CitedBlock]

    init(writeup: String, evidence: EvidenceIndex, selected: Binding<Citation?>, documentID: String? = nil) {
        self.writeup = writeup
        self.evidence = evidence
        self._selected = selected
        self.documentID = documentID
        numbering = CitationNumbering(writeup: writeup)
        blocks = CitationMarkers.blocks(in: writeup).filter { !Self.isFootnoteDefinition($0) }
    }

    /// A generated `[^c1]: source — “quote”` definition line. It exists so the note reads correctly in
    /// Obsidian; in here the rail says the same thing, openable, so showing both is noise.
    static func isFootnoteDefinition(_ block: CitedBlock) -> Bool {
        let first = block.text.components(separatedBy: "\n").first ?? ""
        return first.range(of: #"^\[\^[A-Za-z0-9_-]{1,32}\]:"#, options: .regularExpression) != nil
    }

    var body: some View {
        if numbering.order.isEmpty {
            MarkdownView(markdown: writeup, documentId: documentID)
        } else {
            reader
        }
    }

    private var reader: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(blocks) { block in blockView(block) }
                rail
            }
            .textSelection(.enabled)
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let id = CitationLink.citationID(in: url) else { return .systemAction }
            select(id)
            return .handled
        })
    }

    @ViewBuilder private func blockView(_ block: CitedBlock) -> some View {
        switch block.kind {
        case .table, .code:
            MarkdownView(markdown: block.strippedText, documentId: "\(documentID ?? "cited")-\(block.id)")
        case .heading:
            Text(prose(Self.headingText(block.text)))
                .font(Self.headingFont(block.text))
                .padding(.top, 8)
        case .listItem:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.listMarker(block.text)).foregroundStyle(.secondary).monospacedDigit()
                Text(prose(Self.listItemText(block.text)))
            }
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.35)).frame(width: 3)
                Text(prose(Self.quoteText(block.text))).foregroundStyle(.secondary).italic()
            }
        case .paragraph:
            Text(prose(block.text))
        }
    }

    /// A newline inside a markdown paragraph is a soft break — a space, not a line break. The inline parser
    /// is told to preserve whitespace (so a marker's spacing survives), so the folding happens here.
    private static func foldingSoftBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: " ", options: .regularExpression)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 6)
            Label("Sources", systemImage: "link").font(.headline).foregroundStyle(.secondary)
            ForEach(Array(numbering.order.enumerated()), id: \.element) { index, id in
                railRow(number: index + 1, id: id)
            }
        }
        .padding(.top, 10)
    }

    @ViewBuilder private func railRow(number: Int, id: String) -> some View {
        let citation = evidence.citation(id)
        let document = citation.flatMap { evidence.document(for: $0) }
        let shown = evidence.tier(id)
        let style = CitationChipStyle(shown)
        Button { select(id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("⟦\(number)\(shown.mark)⟧")
                    .font(.caption.weight(.semibold)).foregroundStyle(style.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document?.displayTitle ?? "source not captured")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 8) {
                        if let document, document.displayTitle != document.host {
                            Text(document.host)
                        }
                        if let page = citation?.page { Text("p. \(page)") }
                        let rung = NodeStyle.citation(shown)
                        Label(evidence.unvalidatedNotice ?? rung.label, systemImage: rung.icon)
                            .foregroundStyle(rung.color)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(selected?.id == id ? Color.accentColor.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(citation?.quote ?? "This citation has no stored quote.")
    }

    private func prose(_ text: String) -> AttributedString {
        CitedProse(numbering: numbering, evidence: evidence, selectedID: selected?.id)
            .attributed(Self.foldingSoftBreaks(text))
    }

    private func select(_ id: String) {
        guard let citation = evidence.citation(id) else { return }
        selected = selected?.id == citation.id ? nil : citation
    }

    private static func headingText(_ text: String) -> String {
        String(text.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
    }

    private static func headingFont(_ text: String) -> Font {
        switch text.prefix(while: { $0 == "#" }).count {
        case 1:  return .title.weight(.bold)
        case 2:  return .title2.weight(.semibold)
        case 3:  return .title3.weight(.semibold)
        default: return .headline
        }
    }

    private static func listMarker(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let ordered = trimmed.range(of: #"^\d+[.)]"#, options: .regularExpression) {
            return String(trimmed[ordered])
        }
        return "•"
    }

    private static func listItemText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let ordered = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return String(trimmed[ordered.upperBound...])
        }
        return String(trimmed.dropFirst(2))
    }

    private static func quoteText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix(">") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            }
            .joined(separator: "\n")
    }
}

/// A run's evidence plus the directory its snapshots live in — everything the reader needs to turn a marker
/// into an openable source. A live run folds it off the stream, a finished one is read out of its report,
/// and both arrive here as the same thing.
typealias EvidenceContext = NodeEvidence

extension EvidenceContext {
    /// One entry of a finished run, read on its own. The rail keeps a `ReportEvidence` and reads through
    /// that; this is for the places that hold a single entry and no run.
    static func make(_ entry: RunReport.TopicEntry, report: RunReport) -> EvidenceContext? {
        ReportEvidence(report: report).reading(for: entry.id)
    }
}

/// A note on disk read with its citations live: loads the file, drops the frontmatter the editor also
/// hides, and hands the body to `CitedReader`.
struct CitedNoteReader: View {
    let path: String
    let evidence: EvidenceIndex
    @Binding var selected: Citation?
    @State private var noteBody: String?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Couldn’t open this note", systemImage: "doc.questionmark",
                                       description: Text(loadError))
            } else if let noteBody {
                CitedReader(writeup: noteBody, evidence: evidence, selected: $selected, documentID: path)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) { load() }
    }

    private func load() {
        do {
            let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            noteBody = MarkdownFileEditor.splitFrontmatter(text).body
        } catch { loadError = error.localizedDescription }
    }
}

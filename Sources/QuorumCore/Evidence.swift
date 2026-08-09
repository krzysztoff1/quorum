import Foundation

/// What a captured source turned out to be. Decoding is forgiving: an unknown kind reads as `.text`
/// rather than failing the whole document, so one odd content type never costs a run its evidence.
public enum SourceContentType: String, Codable, Sendable {
    case html, pdf, text

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SourceContentType(rawValue: raw.lowercased()) ?? .text
    }
}

/// How well a quote could be located in its source's stored snapshot. `unresolved` means the quote was
/// not found, or the source has no snapshot at all (built-in search captured no text) — the reader shows
/// that plainly instead of implying a verification that never happened.
public enum QuoteMatch: String, Codable, Sendable {
    case exact, normalized, fuzzy, unresolved

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = QuoteMatch(rawValue: raw.lowercased()) ?? .unresolved
    }

    public var isVerified: Bool { self != .unresolved }

    public var label: String {
        switch self {
        case .exact:      return "verified"
        case .normalized: return "verified"
        case .fuzzy:      return "close match"
        case .unresolved: return "not verifiable"
        }
    }
}

/// One source captured at research time. `snapshotPath` is the extracted text that `Citation.start/end`
/// index into; `originalPath` is the bytes as fetched (a PDF the reader can open in PDFKit). Both are
/// relative to the run's evidence directory (`<runDir>/evidence`), so a reader joins against that, not
/// against the run directory. Paths are nil when the fetch produced no text to keep — a URL seen only in
/// search results still registers, so a citation against it resolves honestly to `.unresolved`.
public struct SourceDocument: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let sourceID: String
    public let url: String
    public let title: String
    public let contentType: SourceContentType
    public let fetchedAt: String?
    public let snapshotPath: String?
    public let originalPath: String?
    public let textLength: Int
    public let byteSize: Int
    public let pageOffsets: [Int]

    public var id: String { sourceID }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case url, title
        case contentType = "content_type"
        case fetchedAt = "fetched_at"
        case snapshotPath = "snapshot_path"
        case originalPath = "original_path"
        case textLength = "text_length"
        case byteSize = "byte_size"
        case pageOffsets = "page_offsets"
    }

    public init(sourceID: String, url: String, title: String, contentType: SourceContentType,
                fetchedAt: String? = nil, snapshotPath: String? = nil, originalPath: String? = nil,
                textLength: Int = 0, byteSize: Int = 0, pageOffsets: [Int] = []) {
        self.sourceID = sourceID
        self.url = url
        self.title = title
        self.contentType = contentType
        self.fetchedAt = fetchedAt
        self.snapshotPath = snapshotPath
        self.originalPath = originalPath
        self.textLength = textLength
        self.byteSize = byteSize
        self.pageOffsets = pageOffsets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        contentType = try c.decodeIfPresent(SourceContentType.self, forKey: .contentType) ?? .text
        fetchedAt = try c.decodeIfPresent(String.self, forKey: .fetchedAt)
        snapshotPath = try c.decodeIfPresent(String.self, forKey: .snapshotPath)
        originalPath = try c.decodeIfPresent(String.self, forKey: .originalPath)
        textLength = try c.decodeIfPresent(Int.self, forKey: .textLength) ?? 0
        byteSize = try c.decodeIfPresent(Int.self, forKey: .byteSize) ?? 0
        pageOffsets = try c.decodeIfPresent([Int].self, forKey: .pageOffsets) ?? []
    }

    public var hasSnapshot: Bool { snapshotPath?.isEmpty == false }

    /// The host, for a compact "nature.com" label in the reader. Falls back to the raw URL.
    public var host: String {
        guard let h = URL(string: url)?.host else { return url }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// A human label: the source's own title, else its host.
    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? host : t
    }

    /// 1-based page holding a snapshot offset, from the capture-time page table. Nil when the source
    /// isn't paginated or the table is missing.
    public func page(containing offset: Int) -> Int? {
        guard !pageOffsets.isEmpty else { return nil }
        var page = 1
        for (index, start) in pageOffsets.enumerated() where offset >= start { page = index + 1 }
        return page
    }
}

/// A quote pinned to a source document. `start`/`end` are character offsets into that document's stored
/// snapshot; they are nil when `match` is `.unresolved`. `page` is filled at capture time for paginated
/// sources so the reader can label the citation before it opens anything.
public struct Citation: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let sourceID: String
    public let quote: String
    public let start: Int?
    public let end: Int?
    public let match: QuoteMatch
    public let page: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceID = "source_id"
        case quote, start, end, match, page
    }

    public init(id: String, sourceID: String, quote: String, start: Int? = nil, end: Int? = nil,
                match: QuoteMatch = .unresolved, page: Int? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.quote = quote
        self.start = start
        self.end = end
        self.match = match
        self.page = page
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        start = try c.decodeIfPresent(Int.self, forKey: .start)
        end = try c.decodeIfPresent(Int.self, forKey: .end)
        match = try c.decodeIfPresent(QuoteMatch.self, forKey: .match) ?? .unresolved
        page = try c.decodeIfPresent(Int.self, forKey: .page)
    }

    public var isVerified: Bool { match.isVerified }

    /// The snapshot range to highlight, when the quote resolved to one.
    public var snapshotRange: Range<Int>? {
        guard let start, let end, end > start else { return nil }
        return start..<end
    }
}

/// One run's deduped source registry plus every citation across its topics — what the reader needs to
/// turn a `[^c3]` marker into an openable, highlightable source.
public struct EvidenceIndex: Codable, Sendable, Equatable {
    public let documents: [SourceDocument]
    public let citations: [Citation]

    public init(documents: [SourceDocument] = [], citations: [Citation] = []) {
        self.documents = documents
        self.citations = citations
    }

    private var documentsBySourceID: [String: SourceDocument] {
        Dictionary(documents.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var citationsByID: [String: Citation] {
        Dictionary(citations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func citation(_ id: String) -> Citation? { citationsByID[id] }

    public func document(_ sourceID: String) -> SourceDocument? { documentsBySourceID[sourceID] }

    public func document(for citation: Citation) -> SourceDocument? { documentsBySourceID[citation.sourceID] }

    /// Citations for a marker list, in marker order, silently dropping ids the run never resolved.
    public func resolve(_ ids: [String]) -> [Citation] {
        ids.compactMap { citationsByID[$0] }
    }

    /// Merge another index in, preferring already-present entries so an angle's resolved citation isn't
    /// overwritten by a later unresolved duplicate of the same id.
    public func merging(_ other: EvidenceIndex) -> EvidenceIndex {
        var docs = documents
        let knownSources = Set(documents.map(\.sourceID))
        docs.append(contentsOf: other.documents.filter { !knownSources.contains($0.sourceID) })
        var cites = citations
        let knownCitations = Set(citations.map(\.id))
        cites.append(contentsOf: other.citations.filter { !knownCitations.contains($0.id) })
        return EvidenceIndex(documents: docs, citations: cites)
    }

    public var isEmpty: Bool { documents.isEmpty && citations.isEmpty }
}

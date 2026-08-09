import Foundation

/// What a live run has written and what it wrote it from, folded out of the same stream the graph is folded
/// from. A finished run keeps this in its report; a running one has nothing on disk yet, so without this
/// the rail beside the canvas could only ever show unresolved markers.
public struct RunEvidence: Sendable, Equatable {
    private var documents: [String: SourceDocument] = [:]
    private var citationsByNode: [String: [Citation]] = [:]
    private var writeups: [String: String] = [:]
    private var grounding: RunGrounding = .captured

    public init() {}

    /// Whether the rail has anything new to read. Most of a run's stream is activity the reader never sees,
    /// and a live view redrawn on every delta of it is a view redrawn for nothing.
    @discardableResult
    public mutating func apply(_ event: RunStreamParser.Event) -> Bool {
        switch event {
        case let .runStart(_, _, tier):
            grounding = tier
        case let .document(_, document):
            absorb(document)
        case let .topicResult(result):
            absorb(result)
        case let .runResult(result):
            grounding = result.grounding
            for document in result.evidence.documents { absorb(document) }
            for topic in result.topics { absorb(topic) }
        default:
            return false
        }
        return true
    }

    private mutating func absorb(_ document: SourceDocument) {
        guard !document.sourceID.isEmpty, documents[document.sourceID] == nil else { return }
        documents[document.sourceID] = document
    }

    /// The writeup as a reader sees it — the trailing machine block the parser eats is not prose. The
    /// stream's resolved offsets win over the ones the writeup declared for itself, because only the run
    /// checked its quotes against anything.
    private mutating func absorb(_ result: RunStreamParser.TopicResultEvent) {
        guard !result.angleID.isEmpty else { return }
        let parsed = ResearchOutputParser.parseFinal(result.result)
        writeups[result.angleID] = parsed.writeup
        citationsByNode[result.angleID] = result.evidence.merging(parsed.evidence).citations
    }

    public func writeup(for nodeID: String) -> String? { writeups[nodeID] }

    /// A node's evidence, scoped the way the run scoped it: an angle's `c1` means something different next
    /// door, so an angle reads only its own citations, while the answer and the validators reading that
    /// answer are backed by every angle's registry. Documents are content-addressed and shared by all of
    /// them — the same page fetched twice is one source.
    public func index(for node: GraphNode) -> EvidenceIndex {
        EvidenceIndex(documents: Array(documents.values).sorted { $0.sourceID < $1.sourceID },
                      citations: citations(for: node), grounding: grounding)
    }

    private func citations(for node: GraphNode) -> [Citation] {
        guard readsTheWholeRun(node) else { return citationsByNode[node.id] ?? [] }
        var seen: Set<String> = []
        return citationsByNode.keys.sorted().flatMap { key in
            (citationsByNode[key] ?? []).filter { seen.insert($0.id).inserted }
        }
    }

    /// The answer, and anything whose job is to read the answer. They quote what the angles found rather
    /// than researching anything of their own.
    private func readsTheWholeRun(_ node: GraphNode) -> Bool {
        node.kind == .synthesis || node.kind == .verdict || node.kind == .verification
    }
}

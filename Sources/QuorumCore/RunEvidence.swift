import Foundation

public struct RunEvidence: Sendable, Equatable {
    private var documents: [String: SourceDocument] = [:]
    private var stored: StoredRun?
    private var grounding: RunGrounding = .captured

    public init() {}

    @discardableResult
    public mutating func apply(_ event: RunStreamParser.Event) -> Bool {
        switch event {
        case let .runStart(_, _, tier, _):
            grounding = tier
        case let .document(_, document):
            absorb(document)
        default:
            return false
        }
        return true
    }

    public mutating func absorb(_ run: StoredRun) {
        stored = run
        grounding = run.grounding
        for source in run.record.sources { absorb(SourceDocument(record: source)) }
    }

    private mutating func absorb(_ document: SourceDocument) {
        guard !document.sourceID.isEmpty, documents[document.sourceID] == nil else { return }
        documents[document.sourceID] = document
    }

    public func writeup(for nodeID: String) -> String? { stored?.writeup(forNode: nodeID) }

    public func index(for node: GraphNode) -> EvidenceIndex {
        EvidenceIndex(documents: Array(documents.values).sorted { $0.sourceID < $1.sourceID },
                      citations: (stored?.citations(forNode: node.id) ?? []).map(Citation.init(record:)),
                      grounding: grounding)
    }
}

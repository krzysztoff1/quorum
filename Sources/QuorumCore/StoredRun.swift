import Foundation

public struct StoredRun: Sendable, Equatable, Identifiable {
    public static let recordFile = "run.json"
    public static let questionFile = "question.json"
    public static let readableSchema = "quorum.run/1"

    public let runDir: URL
    public let record: RunRecord
    public let question: QuestionRecord?

    public init(runDir: URL, record: RunRecord, question: QuestionRecord? = nil) {
        self.runDir = runDir
        self.record = record
        self.question = question
    }

    public static func load(_ runDir: URL) -> StoredRun? {
        guard let data = try? Data(contentsOf: runDir.appendingPathComponent(recordFile)),
              let record = try? JSONDecoder().decode(RunRecord.self, from: data),
              record.schema == readableSchema else { return nil }
        let questionURL = runDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(questionFile)
        let question = (try? Data(contentsOf: questionURL)).flatMap { try? JSONDecoder().decode(QuestionRecord.self, from: $0) }
        return StoredRun(runDir: runDir, record: record, question: question)
    }

    public var id: String { record.id }
    public var title: String { question?.title ?? record.brief.question }
    public var isRunning: Bool { record.status == .running }
    public var createdAt: Date { Self.date(record.createdAt) ?? .distantPast }
    public var evidenceDirectory: URL { runDir.appendingPathComponent("evidence", isDirectory: true) }
    public var grounding: RunGrounding { record.pipeline.grounding == .none ? .none : .captured }

    public var answerTask: RecordTask? {
        record.answer.flatMap { answer in record.tasks.first { $0.id == answer.taskID } }
    }

    public func task(forNode nodeID: String) -> RecordTask? {
        if nodeID == answerTask?.nodeID { return answerTask }
        return record.tasks.last { $0.nodeID == nodeID }
    }

    public func writeup(forNode nodeID: String) -> String? {
        if let answer = record.answer, nodeID == answerTask?.nodeID { return answer.markdown }
        return task(forNode: nodeID)?.writeup
    }

    public var evidenceIndex: EvidenceIndex {
        EvidenceIndex(documents: record.sources.map(SourceDocument.init(record:)),
                      citations: record.citations.map(Citation.init(record:)),
                      grounding: grounding)
    }

    public func evidence(forNode nodeID: String) -> NodeEvidence? {
        let index = EvidenceIndex(documents: record.sources.map(SourceDocument.init(record:)),
                                  citations: citations(forNode: nodeID).map(Citation.init(record:)),
                                  grounding: grounding)
        guard !index.hasNothingToSay else { return nil }
        let judged = readsTheAnswer(nodeID)
            ? index.marking(unsupported: record.validation?.unsupportedCitations ?? [])
            : index
        return NodeEvidence(index: judged, directory: evidenceDirectory)
    }

    public func citations(forNode nodeID: String) -> [RecordCitation] {
        guard !readsTheAnswer(nodeID), let task = task(forNode: nodeID) else { return record.citations }
        let own = Set(task.citationIDs)
        return record.citations.filter { own.contains($0.id) }
    }

    private func readsTheAnswer(_ nodeID: String) -> Bool {
        if nodeID == answerTask?.nodeID { return true }
        let kind = record.graph.nodes.first { $0.id == nodeID }?.kind
        return kind == "verdict" || kind == "synthesis" || kind == "verification"
    }

    public var graph: ResearchGraph {
        var graph = ResearchGraph()
        graph.apply(.runStart(sessionID: record.id, protocolVersion: record.pipeline.protocol, grounding: grounding, record: nil))
        for node in record.graph.nodes { graph.apply(.graphNode(RunStreamParser.GraphNodeEvent(record: node))) }
        for edge in record.graph.edges {
            graph.apply(.graphEdge(RunStreamParser.GraphEdgeEvent(from: edge.from, to: edge.to, kind: edge.kind,
                                                                 label: edge.label)))
        }
        for source in record.sources {
            for reader in source.readBy { graph.apply(.document(angleID: reader, SourceDocument(record: source))) }
        }
        return graph
    }

    public var validation: RunValidation? {
        guard let validation = record.validation else { return nil }
        let verdicts = record.graph.nodes.filter { $0.kind == "verdict" }.map { node in
            RunValidation.Verdict(id: node.id, lens: node.lens ?? "", title: node.title, round: node.round,
                                  status: node.status, objections: (node.objections ?? []).map(RunStreamParser.ObjectionEvent.init(record:)))
        }
        return RunValidation(
            status: validation.status.rawValue, holds: validation.holds, blocking: validation.blocking,
            spendUSD: Decimal(validation.spendUSD), rounds: validation.rounds.count,
            objectionsAdmitted: validation.objectionsAdmitted, objectionsResolved: validation.objectionsResolved,
            objectionsOutstanding: validation.objectionsOpen.map {
                RunStreamParser.ObjectionEvent(lens: $0.lens, statement: $0.statement, severity: $0.severity.rawValue,
                                               followup: $0.followup)
            },
            verdicts: verdicts, unsupportedCitationIDs: validation.unsupportedCitations)
    }

    public var claimsSummary: String {
        let stats = record.stats
        guard stats.claims > 0 else { return "" }
        let parts = [(stats.claimsSolid, "solid"), (stats.claimsShaky - stats.claimsUnverified, "shaky"),
                     (stats.claimsUnverified, "unchecked")]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    public var sourcesSummary: String {
        "\(record.stats.sourcesCited) cited · \(record.stats.sourcesRead) read"
    }

    static func date(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }
}

public enum BrainFolder {
    public static let defaultsKey = "brainFolder"

    public static func defaultLocation(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Quorum", isDirectory: true)
    }

    public static func location(stored: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty else { return defaultLocation(home: home) }
        return URL(fileURLWithPath: (stored as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static func runs(in brain: URL) -> [StoredRun] {
        let fm = FileManager.default
        let questions = brain.appendingPathComponent("questions", isDirectory: true)
        let questionDirs = (try? fm.contentsOfDirectory(at: questions, includingPropertiesForKeys: nil)) ?? []
        let runDirs = questionDirs.flatMap { question in
            (try? fm.contentsOfDirectory(at: question.appendingPathComponent("runs", isDirectory: true),
                                         includingPropertiesForKeys: nil)) ?? []
        }
        return runDirs.compactMap(StoredRun.load).sorted { $0.record.createdAt > $1.record.createdAt }
    }
}

public extension SourceDocument {
    init(record source: RecordSource) {
        self.init(sourceID: source.id, url: source.url, title: source.title,
                  contentType: SourceContentType(rawValue: source.contentType.rawValue) ?? .text,
                  fetchedAt: source.fetchedAt, snapshotPath: source.snapshotPath, originalPath: source.originalPath,
                  textLength: source.textLength, byteSize: source.byteSize, pageOffsets: source.pageOffsets,
                  capture: SourceCapture(rawValue: source.capture.rawValue) ?? .failed)
    }
}

public extension Citation {
    init(record citation: RecordCitation) {
        self.init(id: citation.id, sourceID: citation.sourceID, quote: citation.quote, start: citation.start,
                  end: citation.end, match: QuoteMatch(rawValue: citation.match.rawValue) ?? .unresolved,
                  page: citation.page)
    }
}

public extension RunStreamParser.ObjectionEvent {
    init(record objection: RecordObjection) {
        self.init(lens: objection.lens, statement: objection.statement, severity: objection.severity.rawValue,
                  followup: objection.followup)
    }
}

public extension RunStreamParser.GraphNodeEvent {
    init(record node: RecordGraphNode) {
        self.init(id: node.id, kind: node.kind, title: node.title, parentIDs: node.parentIDs, depth: node.depth,
                  round: node.round, status: node.status, origin: node.origin,
                  why: node.why ?? node.statement, provokedBy: node.provokedBy, rejectedReason: node.rejectedReason,
                  estimatedCostUSD: node.estCostUSD.map { Decimal($0) }, costUSD: node.costUSD.map { Decimal($0) },
                  lens: node.lens, objections: (node.objections ?? []).map(RunStreamParser.ObjectionEvent.init(record:)))
    }
}

public extension TopicStatus {
    init(record status: RecordTaskStatus) {
        switch status {
        case .queued: self = .queued
        case .running: self = .running
        case .complete: self = .complete
        case .inconclusive: self = .inconclusive
        case .halted: self = .haltedManual
        case .error, .unknown: self = .error
        }
    }

    init(record status: RunRecordStatus) {
        switch status {
        case .running: self = .running
        case .complete: self = .complete
        case .inconclusive: self = .inconclusive
        case .halted, .cancelled: self = .haltedManual
        case .failed, .crashed, .unknown: self = .error
        }
    }
}

import Foundation

public enum RunStreamParser {

    public static let supportedProtocolVersion = 5

    public static func accepts(protocolVersion: Int?) -> Bool { protocolVersion == supportedProtocolVersion }

    /// What a validator filed against the answer, exactly as it filed it: never a fix, always a task that
    /// would settle it (PRD 06).
    public struct ObjectionEvent: Equatable, Sendable, Codable {
        public let lens: String
        public let statement: String
        public let severity: String
        public let followup: String

        public init(lens: String, statement: String, severity: String, followup: String) {
            self.lens = lens; self.statement = statement; self.severity = severity; self.followup = followup
        }
    }

    /// One node the orchestrator added to the run's graph. Only the orchestrator emits these — a model may
    /// ask for a node, never declare one — so what the app draws is what actually happened.
    public struct GraphNodeEvent: Equatable, Sendable {
        public let id: String
        public let kind: String
        public let title: String
        public let parentIDs: [String]
        public let depth: Int
        public let round: Int
        public let status: String
        public let origin: String
        public let why: String?
        public let provokedBy: String?
        public let rejectedReason: String?
        public let estimatedCostUSD: Decimal?
        public let costUSD: Decimal?
        /// Which validator task this is, or which one raised the question — the one field that tells a
        /// coverage verdict from a sources one once both have passed and neither is carrying anything.
        public let lens: String?
        public let objections: [ObjectionEvent]
    }

    /// What the run's own validators made of its answer (PRD 06). Absent on any transcript recorded before v4.
    public struct ValidationEvent: Equatable, Sendable {
        public let status: String
        public let holds: Bool
        public let blocking: Int
        public let spendUSD: Decimal
        public let rounds: Int
        public let objectionsAdmitted: Int
        public let objectionsResolved: Int
        public let objectionsOutstanding: [ObjectionEvent]
        /// The located quotes the last round's sweep could not stand their claim up on — what the reader
        /// badges ⚠ rather than verified (PRD 09 R3).
        public let unsupportedCitationIDs: [String]
    }

    public struct GraphEdgeEvent: Equatable, Sendable {
        public let from: String
        public let to: String
        public let kind: String
        public let label: String?
    }

    public struct PlannedAngle: Equatable, Sendable {
        public let angleID: String
        public let title: String
        public let prompt: String
        public init(angleID: String, title: String, prompt: String) {
            self.angleID = angleID; self.title = title; self.prompt = prompt
        }
    }

    /// One finished topic (an angle or the synthesis) reported by the engine.
    public struct TopicResultEvent: Equatable, Sendable {
        public let angleID: String
        public let role: String        // research / synthesis / verify
        public let backend: String     // "cli" (claude subscription) / "engine" (BYOK)
        public let provider: String
        public let model: String
        public let sessionID: String?
        public let status: String
        public let result: String      // the full writeup incl. the trailing fenced json
        public let usage: TopicUsage?
        public let note: String?
        public let evidence: EvidenceIndex   // quotes the run resolved for this topic's markers (PRD 03)
        public let reconciled: Bool

        /// Whether chat must reopen fresh-and-seeded rather than `--resume`: only CLI (subscription)
        /// sessions are resumable; BYOK engine sessions are synthetic. Explicit from the engine, so an
        /// early-failed engine topic is never mistaken for a resumable one.
        public var isResumable: Bool { backend == "cli" }
    }

    public struct RecordLocation: Equatable, Sendable {
        public let runID: String
        public let questionID: String
        public let runDir: URL

        public init(runID: String, questionID: String, runDir: URL) {
            self.runID = runID
            self.questionID = questionID
            self.runDir = runDir
        }
    }

    public struct Refusal: Equatable, Sendable {
        public let kind: String
        public let reason: String
        public init(kind: String, reason: String) { self.kind = kind; self.reason = reason }
    }

    public struct RunResultEvent: Equatable, Sendable {
        public let status: String
        public let totalCostUSD: Decimal
        public let topics: [TopicResultEvent]
        public let evidence: EvidenceIndex   // the run-wide deduped source registry (PRD 03)
        /// What this run could check its quotes against at all (PRD 07). Carried here as well as on
        /// `run_start` so a report read back from disk knows it, not just a live stream.
        public let grounding: RunGrounding
        public let validation: ValidationEvent?
        /// Why the orchestrator stopped where it did — round cap, budget, deadline. Nil when it just finished.
        public let note: String?
        /// Set when the run stopped because the engine would not go on (the Claude CLI is logged out), not
        /// because the research ran out of road.
        public let refusal: Refusal?
        public init(status: String, totalCostUSD: Decimal, topics: [TopicResultEvent],
                    evidence: EvidenceIndex = EvidenceIndex(), grounding: RunGrounding = .captured,
                    validation: ValidationEvent? = nil, note: String? = nil, refusal: Refusal? = nil) {
            self.refusal = refusal
            self.status = status; self.totalCostUSD = totalCostUSD; self.topics = topics
            self.evidence = evidence.withGrounding(grounding)
            self.grounding = grounding
            self.validation = validation
            self.note = note
        }
    }

    public enum Event: Equatable, Sendable {
        case runStart(sessionID: String, protocolVersion: Int?, grounding: RunGrounding, record: RecordLocation?)
        case phase(String)
        case plan([PlannedAngle])
        case round(Int, [PlannedAngle])
        case angleStatus(angleID: String, status: String)
        case document(angleID: String, SourceDocument)                          // a source captured to disk
        case activity(angleID: String, line: CLIStream.Line)
        case graphNode(GraphNodeEvent)                                          // the run's shape, as it grows
        case graphEdge(GraphEdgeEvent)
        case graphNodeUpdate(id: String, status: String, costUSD: Decimal?)
        case topicResult(TopicResultEvent)
        case progress(RunProgress)
        case heartbeat
        case runResult(RunResultEvent)
        case other
    }

    public static func parse(_ line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let ev = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        switch ev.type {
        case "run_start":
            return .runStart(sessionID: ev.session_id ?? "", protocolVersion: ev.protocol_version,
                             grounding: ev.grounding ?? .captured, record: recordLocation(ev))
        case "phase":
            return ev.phase.map { .phase($0) } ?? .other
        case "plan":
            return .plan((ev.angles ?? []).map(planned))
        case "round":
            return .round(ev.round ?? 0, (ev.angles ?? []).map(planned))
        case "angle_status":
            return .angleStatus(angleID: ev.angle_id ?? "", status: ev.status ?? "")
        case "document":
            guard let doc = ev.document, !doc.sourceID.isEmpty else { return .other }
            return .document(angleID: ev.angle_id ?? "", doc)
        case "graph_node":
            guard let node = ev.node, !node.id.isEmpty else { return .other }
            return .graphNode(graphNode(node))
        case "graph_edge":
            guard let edge = ev.edge, !edge.from.isEmpty, !edge.to.isEmpty else { return .other }
            return .graphEdge(GraphEdgeEvent(from: edge.from, to: edge.to,
                                             kind: edge.kind ?? "", label: edge.label))
        case "graph_node_update":
            guard let id = ev.id, !id.isEmpty else { return .other }
            return .graphNodeUpdate(id: id, status: ev.status ?? "",
                                    costUSD: ev.meta?.cost_usd.map { Decimal($0) })
        case "stream_event", "assistant", "usage":
            guard let inner = CLIStream.parse(line) else { return .other }
            return .activity(angleID: ev.angle_id ?? "", line: inner)
        case "topic_result":
            return .topicResult(topicResult(ev))
        case "run.progress":
            return .progress(RunProgress(
                stage: ev.stage ?? "", stageIndex: ev.stage_index ?? 0, stageCount: ev.stage_count ?? 5,
                tasksDone: ev.tasks_done ?? 0, tasksTotal: ev.tasks_total ?? 0, sourcesRead: ev.sources_read ?? 0,
                etaSeconds: ev.eta_s))
        case "heartbeat":
            return .heartbeat
        case "run_result":
            return .runResult(RunResultEvent(
                status: ev.status ?? "complete",
                totalCostUSD: ev.total_cost_usd.map { Decimal($0) } ?? 0,
                topics: (ev.topics ?? []).map(topicResult),
                evidence: EvidenceIndex(documents: knownDocuments(ev.documents)),
                grounding: ev.grounding ?? .captured,
                validation: ev.validation.map(validation),
                note: ev.note,
                refusal: ev.refusal.flatMap { raw in
                    guard let kind = raw.kind, let reason = raw.reason else { return nil }
                    return Refusal(kind: kind, reason: reason)
                }))
        default:
            return .other
        }
    }

    private static func recordLocation(_ ev: Raw) -> RecordLocation? {
        guard let runID = ev.run_id, let runDir = ev.run_dir, !runID.isEmpty, !runDir.isEmpty else { return nil }
        return RecordLocation(runID: runID, questionID: ev.question_id ?? "", runDir: URL(fileURLWithPath: runDir, isDirectory: true))
    }

    private static func planned(_ a: Raw.Angle) -> PlannedAngle {
        PlannedAngle(angleID: a.angle_id ?? "", title: a.title ?? "", prompt: a.prompt ?? "")
    }

    private static func graphNode(_ n: Raw.Node) -> GraphNodeEvent {
        GraphNodeEvent(
            id: n.id, kind: n.kind ?? "", title: n.title ?? "", parentIDs: n.parent_ids ?? [],
            depth: n.depth ?? 0, round: n.round ?? 1, status: n.status ?? "", origin: n.origin ?? "",
            why: n.meta?.why ?? n.meta?.statement, provokedBy: n.meta?.provoked_by,
            rejectedReason: n.meta?.rejected_reason,
            estimatedCostUSD: n.meta?.est_cost_usd.map { Decimal($0) },
            costUSD: n.meta?.cost_usd.map { Decimal($0) },
            lens: n.meta?.lens, objections: n.meta?.objections ?? [])
    }

    private static func validation(_ v: Raw.Validation) -> ValidationEvent {
        ValidationEvent(
            status: v.status ?? "unvalidated", holds: v.holds ?? true, blocking: v.blocking ?? 0,
            spendUSD: v.spend_usd.map { Decimal($0) } ?? 0, rounds: v.rounds?.count ?? 0,
            objectionsAdmitted: v.objections_admitted ?? 0, objectionsResolved: v.objections_resolved ?? 0,
            objectionsOutstanding: v.objections_outstanding ?? [],
            unsupportedCitationIDs: v.unsupported_citations ?? [])
    }

    private static func topicResult(_ r: RawTopic) -> TopicResultEvent {
        TopicResultEvent(
            angleID: r.angle_id ?? "", role: r.role ?? "research", backend: r.backend ?? "engine",
            provider: r.provider ?? "", model: r.model ?? "", sessionID: r.session_id,
            status: r.status ?? "complete", result: r.result ?? "", usage: r.usage?.topicUsage,
            note: r.note, evidence: EvidenceIndex(citations: knownCitations(r.citations)),
            reconciled: r.reconciled ?? false)
    }

    /// A citation no marker can name, or a document no citation can name, is unreachable — drop it rather
    /// than carry a blank entry the reader would render as a dead footnote.
    private static func knownCitations(_ citations: [Citation]?) -> [Citation] {
        (citations ?? []).filter { !$0.id.isEmpty }
    }

    private static func knownDocuments(_ documents: [SourceDocument]?) -> [SourceDocument] {
        (documents ?? []).filter { !$0.sourceID.isEmpty }
    }

    // Defensive decodables — the top-level `topic_result` shares its fields with the `run_result.topics`
    // elements, so both decode through `RawTopic`.
    private struct Raw: Decodable {
        let type: String?
        let phase: String?
        let session_id: String?
        let protocol_version: Int?
        let run_id: String?
        let question_id: String?
        let run_dir: String?
        let grounding: RunGrounding?
        let round: Int?
        let angle_id: String?
        let status: String?
        let angles: [Angle]?
        let total_cost_usd: Double?
        let topics: [RawTopic]?
        let role: String?; let backend: String?; let provider: String?
        let model: String?; let result: String?; let note: String?
        let reconciled: Bool?
        let usage: RawUsage?
        let document: SourceDocument?      // a captured source (type "document")
        let citations: [Citation]?         // resolved quotes on a bare topic_result
        let documents: [SourceDocument]?   // the run-wide registry on run_result
        let node: Node?                    // graph_node
        let edge: Edge?                    // graph_edge
        let id: String?                    // graph_node_update
        let meta: Meta?                    // graph_node_update
        let validation: Validation?        // run_result (PRD 06)
        let refusal: RawRefusal?           // run_result
        let stage: String?; let stage_index: Int?; let stage_count: Int?   // run.progress
        let tasks_done: Int?; let tasks_total: Int?; let sources_read: Int?; let eta_s: Int?
        struct Angle: Decodable { let angle_id: String?; let title: String?; let prompt: String? }

        struct Validation: Decodable {
            let status: String?; let holds: Bool?; let blocking: Int?
            let spend_usd: Double?
            let objections_admitted: Int?; let objections_resolved: Int?
            let objections_outstanding: [ObjectionEvent]?
            let unsupported_citations: [String]?
            let rounds: [Round]?
            struct Round: Decodable { let round: Int? }
        }

        struct Node: Decodable {
            let id: String
            let kind: String?; let title: String?
            let parent_ids: [String]?
            let depth: Int?; let round: Int?
            let status: String?; let origin: String?
            let meta: Meta?
        }

        struct Edge: Decodable {
            let from: String; let to: String
            let kind: String?; let label: String?
        }

        struct Meta: Decodable {
            let why: String?
            let statement: String?
            let lens: String?
            let provoked_by: String?
            let rejected_reason: String?
            let est_cost_usd: Double?
            let cost_usd: Double?
            let objections: [ObjectionEvent]?
        }
    }

    private struct RawRefusal: Decodable { let kind: String?; let reason: String? }

    private struct RawTopic: Decodable {
        let angle_id: String?; let role: String?; let backend: String?
        let provider: String?; let model: String?; let session_id: String?
        let status: String?; let result: String?; let note: String?
        let reconciled: Bool?
        let usage: RawUsage?
        let citations: [Citation]?
    }

    private struct RawUsage: Decodable {
        let provider: String?; let model: String?
        let input_tokens: Int?; let output_tokens: Int?
        let cache_read_tokens: Int?; let cache_write_tokens: Int?
        let cost_usd: Double?; let search_calls: Int?; let fetch_calls: Int?
        var topicUsage: TopicUsage {
            TopicUsage(provider: provider ?? "", model: model ?? "",
                       inputTokens: input_tokens ?? 0, outputTokens: output_tokens ?? 0,
                       cacheReadTokens: cache_read_tokens ?? 0, cacheWriteTokens: cache_write_tokens ?? 0,
                       searchCalls: search_calls ?? 0, fetchCalls: fetch_calls ?? 0,
                       costUSD: cost_usd.map { Decimal($0) } ?? 0)
        }
    }

    // `Raw` also needs the topic fields when a bare topic_result decodes at the top level.
    private static func topicResult(_ ev: Raw) -> TopicResultEvent {
        TopicResultEvent(
            angleID: ev.angle_id ?? "", role: ev.role ?? "research", backend: ev.backend ?? "engine",
            provider: ev.provider ?? "", model: ev.model ?? "", sessionID: ev.session_id,
            status: ev.status ?? "complete", result: ev.result ?? "", usage: ev.usage?.topicUsage,
            note: ev.note, evidence: EvidenceIndex(citations: knownCitations(ev.citations)),
            reconciled: ev.reconciled ?? false)
    }
}

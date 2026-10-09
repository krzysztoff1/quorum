import Foundation

public struct RunRecord: Codable, Sendable, Equatable {
    public let schema: String
    public let id: String
    public let questionID: String
    public let kind: RunRecordKind
    public let createdAt: String
    public let updatedAt: String
    public let finishedAt: String?
    public let status: RunRecordStatus
    public let statusNote: String?
    public let refusal: RecordRefusal?
    public let brief: RecordBrief
    public let pipeline: RecordPipeline
    public let answer: RecordAnswer?
    public let claims: [RecordClaim]
    public let citations: [RecordCitation]
    public let sources: [RecordSource]
    public let captureFailures: [RecordCaptureFailure]
    public let conflicts: [RecordConflict]
    public let gaps: [RecordGap]
    public let validation: RecordValidation?
    public let openItems: RecordOpenItems
    public let tasks: [RecordTask]
    public let graph: RecordGraph
    public let cost: RecordCost
    public let limits: RecordLimits
    public let timeline: [RecordTimelineEntry]
    public let strippedMarkers: [RecordStrippedMarker]
    public let stats: RecordStats
    public let checks: [RecordCheck]

    public init(schema: String, id: String, questionID: String, kind: RunRecordKind, createdAt: String, updatedAt: String, finishedAt: String? = nil, status: RunRecordStatus, statusNote: String? = nil, refusal: RecordRefusal? = nil, brief: RecordBrief, pipeline: RecordPipeline, answer: RecordAnswer? = nil, claims: [RecordClaim], citations: [RecordCitation], sources: [RecordSource], captureFailures: [RecordCaptureFailure], conflicts: [RecordConflict], gaps: [RecordGap], validation: RecordValidation? = nil, openItems: RecordOpenItems, tasks: [RecordTask], graph: RecordGraph, cost: RecordCost, limits: RecordLimits, timeline: [RecordTimelineEntry], strippedMarkers: [RecordStrippedMarker], stats: RecordStats, checks: [RecordCheck]) {
        self.schema = schema
        self.id = id
        self.questionID = questionID
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.status = status
        self.statusNote = statusNote
        self.refusal = refusal
        self.brief = brief
        self.pipeline = pipeline
        self.answer = answer
        self.claims = claims
        self.citations = citations
        self.sources = sources
        self.captureFailures = captureFailures
        self.conflicts = conflicts
        self.gaps = gaps
        self.validation = validation
        self.openItems = openItems
        self.tasks = tasks
        self.graph = graph
        self.cost = cost
        self.limits = limits
        self.timeline = timeline
        self.strippedMarkers = strippedMarkers
        self.stats = stats
        self.checks = checks
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case id
        case questionID = "question_id"
        case kind
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case finishedAt = "finished_at"
        case status
        case statusNote = "status_note"
        case refusal
        case brief
        case pipeline
        case answer
        case claims
        case citations
        case sources
        case captureFailures = "capture_failures"
        case conflicts
        case gaps
        case validation
        case openItems = "open_items"
        case tasks
        case graph
        case cost
        case limits
        case timeline
        case strippedMarkers = "stripped_markers"
        case stats
        case checks
    }
}

public enum RunRecordKind: String, Codable, Sendable, Equatable, CaseIterable {
    case initial
    case followup
    case rerun
    case unknown

    public init(from decoder: Decoder) throws {
        self = RunRecordKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum RunRecordStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case running
    case complete
    case inconclusive
    case halted
    case failed
    case cancelled
    case crashed
    case unknown

    public init(from decoder: Decoder) throws {
        self = RunRecordStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordRefusal: Codable, Sendable, Equatable {
    public let kind: String
    public let reason: String

    public init(kind: String, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case reason
    }
}

public struct RecordBrief: Codable, Sendable, Equatable {
    public let question: String
    public let language: String

    public init(question: String, language: String) {
        self.question = question
        self.language = language
    }

    enum CodingKeys: String, CodingKey {
        case question
        case language
    }
}

public struct RecordPipeline: Codable, Sendable, Equatable {
    public let engineVersion: String
    public let build: String
    public let `protocol`: Int
    public let backend: String
    public let models: RecordModels
    public let grounding: RecordPipelineGrounding

    public init(engineVersion: String, build: String, protocol: Int, backend: String, models: RecordModels, grounding: RecordPipelineGrounding) {
        self.engineVersion = engineVersion
        self.build = build
        self.protocol = `protocol`
        self.backend = backend
        self.models = models
        self.grounding = grounding
    }

    enum CodingKeys: String, CodingKey {
        case engineVersion = "engine_version"
        case build
        case `protocol`
        case backend
        case models
        case grounding
    }
}

public struct RecordModels: Codable, Sendable, Equatable {
    public let planner: String
    public let research: String
    public let synthesis: String
    public let validator: String

    public init(planner: String, research: String, synthesis: String, validator: String) {
        self.planner = planner
        self.research = research
        self.synthesis = synthesis
        self.validator = validator
    }

    enum CodingKeys: String, CodingKey {
        case planner
        case research
        case synthesis
        case validator
    }
}

public enum RecordPipelineGrounding: String, Codable, Sendable, Equatable, CaseIterable {
    case captured
    case none
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordPipelineGrounding(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordAnswer: Codable, Sendable, Equatable {
    public let format: String
    public let taskID: String
    public let headline: String
    public let markdown: String

    public init(format: String, taskID: String, headline: String, markdown: String) {
        self.format = format
        self.taskID = taskID
        self.headline = headline
        self.markdown = markdown
    }

    enum CodingKeys: String, CodingKey {
        case format
        case taskID = "task_id"
        case headline
        case markdown
    }
}

public struct RecordClaim: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let citationIDs: [String]
    public let confidence: RecordClaimConfidence
    public let strength: RecordClaimStrength
    public let verdict: RecordVerdict
    public let taskID: String
    public let round: Int

    public init(id: String, text: String, citationIDs: [String], confidence: RecordClaimConfidence, strength: RecordClaimStrength, verdict: RecordVerdict, taskID: String, round: Int) {
        self.id = id
        self.text = text
        self.citationIDs = citationIDs
        self.confidence = confidence
        self.strength = strength
        self.verdict = verdict
        self.taskID = taskID
        self.round = round
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case citationIDs = "citation_ids"
        case confidence
        case strength
        case verdict
        case taskID = "task_id"
        case round
    }
}

public enum RecordClaimConfidence: String, Codable, Sendable, Equatable, CaseIterable {
    case high
    case medium
    case low
    case unverified
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordClaimConfidence(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum RecordClaimStrength: String, Codable, Sendable, Equatable, CaseIterable {
    case solid
    case shaky
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordClaimStrength(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordVerdict: Codable, Sendable, Equatable {
    public let verdict: RecordVerdictVerdict
    public let severity: RecordVerdictSeverity?
    public let reason: String?

    public init(verdict: RecordVerdictVerdict, severity: RecordVerdictSeverity? = nil, reason: String? = nil) {
        self.verdict = verdict
        self.severity = severity
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case verdict
        case severity
        case reason
    }
}

public enum RecordVerdictVerdict: String, Codable, Sendable, Equatable, CaseIterable {
    case supported
    case unsupported
    case misquoted
    case unjudged
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordVerdictVerdict(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum RecordVerdictSeverity: String, Codable, Sendable, Equatable, CaseIterable {
    case blocking
    case minor
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordVerdictSeverity(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordCitation: Codable, Sendable, Equatable {
    public let id: String
    public let sourceID: String
    public let quote: String
    public let match: RecordCitationMatch
    public let start: Int?
    public let end: Int?
    public let page: Int?
    public let taskID: String

    public init(id: String, sourceID: String, quote: String, match: RecordCitationMatch, start: Int? = nil, end: Int? = nil, page: Int? = nil, taskID: String) {
        self.id = id
        self.sourceID = sourceID
        self.quote = quote
        self.match = match
        self.start = start
        self.end = end
        self.page = page
        self.taskID = taskID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sourceID = "source_id"
        case quote
        case match
        case start
        case end
        case page
        case taskID = "task_id"
    }
}

public enum RecordCitationMatch: String, Codable, Sendable, Equatable, CaseIterable {
    case exact
    case normalized
    case fuzzy
    case unresolved
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordCitationMatch(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordSource: Codable, Sendable, Equatable {
    public let id: String
    public let url: String
    public let host: String
    public let title: String
    public let contentType: RecordSourceContentType
    public let sourceType: RecordSourceSourceType
    public let capture: RecordSourceCapture
    public let fetchedAt: String?
    public let snapshotPath: String?
    public let originalPath: String?
    public let textLength: Int
    public let byteSize: Int
    public let pageOffsets: [Int]
    public let readBy: [String]
    public let cited: Bool

    public init(id: String, url: String, host: String, title: String, contentType: RecordSourceContentType, sourceType: RecordSourceSourceType, capture: RecordSourceCapture, fetchedAt: String? = nil, snapshotPath: String? = nil, originalPath: String? = nil, textLength: Int, byteSize: Int, pageOffsets: [Int], readBy: [String], cited: Bool) {
        self.id = id
        self.url = url
        self.host = host
        self.title = title
        self.contentType = contentType
        self.sourceType = sourceType
        self.capture = capture
        self.fetchedAt = fetchedAt
        self.snapshotPath = snapshotPath
        self.originalPath = originalPath
        self.textLength = textLength
        self.byteSize = byteSize
        self.pageOffsets = pageOffsets
        self.readBy = readBy
        self.cited = cited
    }

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case host
        case title
        case contentType = "content_type"
        case sourceType = "source_type"
        case capture
        case fetchedAt = "fetched_at"
        case snapshotPath = "snapshot_path"
        case originalPath = "original_path"
        case textLength = "text_length"
        case byteSize = "byte_size"
        case pageOffsets = "page_offsets"
        case readBy = "read_by"
        case cited
    }
}

public enum RecordSourceContentType: String, Codable, Sendable, Equatable, CaseIterable {
    case html
    case pdf
    case text
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordSourceContentType(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum RecordSourceSourceType: String, Codable, Sendable, Equatable, CaseIterable {
    case primary
    case vendor
    case seo
    case academic
    case news
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordSourceSourceType(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum RecordSourceCapture: String, Codable, Sendable, Equatable, CaseIterable {
    case ok
    case degraded
    case failed
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordSourceCapture(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordCaptureFailure: Codable, Sendable, Equatable {
    public let sourceID: String
    public let url: String
    public let stage: String
    public let error: String
    public let kind: String?

    public init(sourceID: String, url: String, stage: String, error: String, kind: String? = nil) {
        self.sourceID = sourceID
        self.url = url
        self.stage = stage
        self.error = error
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case url
        case stage
        case error
        case kind
    }
}

public struct RecordConflict: Codable, Sendable, Equatable {
    public let id: String
    public let statement: String
    public let positions: [String]
    public let status: RecordConflictStatus
    public let taskID: String

    public init(id: String, statement: String, positions: [String], status: RecordConflictStatus, taskID: String) {
        self.id = id
        self.statement = statement
        self.positions = positions
        self.status = status
        self.taskID = taskID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case statement
        case positions
        case status
        case taskID = "task_id"
    }
}

public enum RecordConflictStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case `open`
    case settled
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordConflictStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordGap: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let taskID: String

    public init(id: String, text: String, taskID: String) {
        self.id = id
        self.text = text
        self.taskID = taskID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case taskID = "task_id"
    }
}

public struct RecordValidation: Codable, Sendable, Equatable {
    public let status: RecordValidationStatus
    public let holds: Bool
    public let blocking: Int
    public let spendUSD: Double
    public let objectionsAdmitted: Int
    public let objectionsResolved: Int
    public let objectionsOpen: [RecordOpenObjection]
    public let unsupportedCitations: [String]
    public let rounds: [RecordValidationRound]

    public init(status: RecordValidationStatus, holds: Bool, blocking: Int, spendUSD: Double, objectionsAdmitted: Int, objectionsResolved: Int, objectionsOpen: [RecordOpenObjection], unsupportedCitations: [String], rounds: [RecordValidationRound]) {
        self.status = status
        self.holds = holds
        self.blocking = blocking
        self.spendUSD = spendUSD
        self.objectionsAdmitted = objectionsAdmitted
        self.objectionsResolved = objectionsResolved
        self.objectionsOpen = objectionsOpen
        self.unsupportedCitations = unsupportedCitations
        self.rounds = rounds
    }

    enum CodingKeys: String, CodingKey {
        case status
        case holds
        case blocking
        case spendUSD = "spend_usd"
        case objectionsAdmitted = "objections_admitted"
        case objectionsResolved = "objections_resolved"
        case objectionsOpen = "objections_open"
        case unsupportedCitations = "unsupported_citations"
        case rounds
    }
}

public enum RecordValidationStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case validated
    case unvalidated
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordValidationStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordOpenObjection: Codable, Sendable, Equatable {
    public let lens: String
    public let statement: String
    public let severity: RecordOpenObjectionSeverity
    public let followup: String
    public let id: String

    public init(lens: String, statement: String, severity: RecordOpenObjectionSeverity, followup: String, id: String) {
        self.lens = lens
        self.statement = statement
        self.severity = severity
        self.followup = followup
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case lens
        case statement
        case severity
        case followup
        case id
    }
}

public enum RecordOpenObjectionSeverity: String, Codable, Sendable, Equatable, CaseIterable {
    case blocking
    case minor
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordOpenObjectionSeverity(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordValidationRound: Codable, Sendable, Equatable {
    public let round: Int
    public let sweep: RecordValidationRoundSweep
    public let critics: RecordValidationRoundCritics
    public let claimsFound: Int
    public let claimsChecked: Int
    public let verdicts: [RecordClaimVerdict]
    public let objections: [RecordObjection]
    public let discardedObjections: Int
    public let holds: Bool
    public let note: String?

    public init(round: Int, sweep: RecordValidationRoundSweep, critics: RecordValidationRoundCritics, claimsFound: Int, claimsChecked: Int, verdicts: [RecordClaimVerdict], objections: [RecordObjection], discardedObjections: Int, holds: Bool, note: String? = nil) {
        self.round = round
        self.sweep = sweep
        self.critics = critics
        self.claimsFound = claimsFound
        self.claimsChecked = claimsChecked
        self.verdicts = verdicts
        self.objections = objections
        self.discardedObjections = discardedObjections
        self.holds = holds
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case round
        case sweep
        case critics
        case claimsFound = "claims_found"
        case claimsChecked = "claims_checked"
        case verdicts
        case objections
        case discardedObjections = "discarded_objections"
        case holds
        case note
    }
}

public enum RecordValidationRoundSweep: String, Codable, Sendable, Equatable, CaseIterable {
    case run
    case skipped
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordValidationRoundSweep(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum RecordValidationRoundCritics: String, Codable, Sendable, Equatable, CaseIterable {
    case run
    case skipped
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordValidationRoundCritics(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordClaimVerdict: Codable, Sendable, Equatable {
    public let claimID: String
    public let claim: String
    public let verdict: RecordClaimVerdictVerdict
    public let severity: RecordClaimVerdictSeverity?
    public let reason: String?
    public let citationIDs: [String]?

    public init(claimID: String, claim: String, verdict: RecordClaimVerdictVerdict, severity: RecordClaimVerdictSeverity? = nil, reason: String? = nil, citationIDs: [String]? = nil) {
        self.claimID = claimID
        self.claim = claim
        self.verdict = verdict
        self.severity = severity
        self.reason = reason
        self.citationIDs = citationIDs
    }

    enum CodingKeys: String, CodingKey {
        case claimID = "claim_id"
        case claim
        case verdict
        case severity
        case reason
        case citationIDs = "citation_ids"
    }
}

public enum RecordClaimVerdictVerdict: String, Codable, Sendable, Equatable, CaseIterable {
    case supported
    case unsupported
    case misquoted
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordClaimVerdictVerdict(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum RecordClaimVerdictSeverity: String, Codable, Sendable, Equatable, CaseIterable {
    case blocking
    case minor
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordClaimVerdictSeverity(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordObjection: Codable, Sendable, Equatable {
    public let lens: String
    public let statement: String
    public let severity: RecordObjectionSeverity
    public let followup: String

    public init(lens: String, statement: String, severity: RecordObjectionSeverity, followup: String) {
        self.lens = lens
        self.statement = statement
        self.severity = severity
        self.followup = followup
    }

    enum CodingKeys: String, CodingKey {
        case lens
        case statement
        case severity
        case followup
    }
}

public enum RecordObjectionSeverity: String, Codable, Sendable, Equatable, CaseIterable {
    case blocking
    case minor
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordObjectionSeverity(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordOpenItems: Codable, Sendable, Equatable {
    public let conflicts: [String]
    public let objections: [String]
    public let gaps: [String]
    public let failedTasks: [String]

    public init(conflicts: [String], objections: [String], gaps: [String], failedTasks: [String]) {
        self.conflicts = conflicts
        self.objections = objections
        self.gaps = gaps
        self.failedTasks = failedTasks
    }

    enum CodingKeys: String, CodingKey {
        case conflicts
        case objections
        case gaps
        case failedTasks = "failed_tasks"
    }
}

public struct RecordTask: Codable, Sendable, Equatable {
    public let id: String
    public let nodeID: String
    public let kind: RecordTaskKind
    public let title: String
    public let prompt: String?
    public let round: Int
    public let status: RecordTaskStatus
    public let origin: String
    public let startedAt: String?
    public let finishedAt: String?
    public let costUSD: Double
    public let backend: String?
    public let model: String?
    public let sessionID: String?
    public let headline: String?
    public let writeup: String?
    public let note: String?
    public let findings: [RecordFinding]
    public let citationIDs: [String]
    public let sourceIDs: [String]
    public let transcript: String?

    public init(id: String, nodeID: String, kind: RecordTaskKind, title: String, prompt: String? = nil, round: Int, status: RecordTaskStatus, origin: String, startedAt: String? = nil, finishedAt: String? = nil, costUSD: Double, backend: String? = nil, model: String? = nil, sessionID: String? = nil, headline: String? = nil, writeup: String? = nil, note: String? = nil, findings: [RecordFinding], citationIDs: [String], sourceIDs: [String], transcript: String? = nil) {
        self.id = id
        self.nodeID = nodeID
        self.kind = kind
        self.title = title
        self.prompt = prompt
        self.round = round
        self.status = status
        self.origin = origin
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.costUSD = costUSD
        self.backend = backend
        self.model = model
        self.sessionID = sessionID
        self.headline = headline
        self.writeup = writeup
        self.note = note
        self.findings = findings
        self.citationIDs = citationIDs
        self.sourceIDs = sourceIDs
        self.transcript = transcript
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nodeID = "node_id"
        case kind
        case title
        case prompt
        case round
        case status
        case origin
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case costUSD = "cost_usd"
        case backend
        case model
        case sessionID = "session_id"
        case headline
        case writeup
        case note
        case findings
        case citationIDs = "citation_ids"
        case sourceIDs = "source_ids"
        case transcript
    }
}

public enum RecordTaskKind: String, Codable, Sendable, Equatable, CaseIterable {
    case plan
    case angle
    case objection
    case synthesis
    case reconciliation
    case verify
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordTaskKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum RecordTaskStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case queued
    case running
    case complete
    case inconclusive
    case halted
    case error
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordTaskStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordFinding: Codable, Sendable, Equatable {
    public let claim: String
    public let confidence: RecordFindingConfidence
    public let citationIDs: [String]
    public let sources: [String]

    public init(claim: String, confidence: RecordFindingConfidence, citationIDs: [String], sources: [String]) {
        self.claim = claim
        self.confidence = confidence
        self.citationIDs = citationIDs
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case claim
        case confidence
        case citationIDs = "citation_ids"
        case sources
    }
}

public enum RecordFindingConfidence: String, Codable, Sendable, Equatable, CaseIterable {
    case high
    case medium
    case low
    case unverified
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordFindingConfidence(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordGraph: Codable, Sendable, Equatable {
    public let nodes: [RecordGraphNode]
    public let edges: [RecordGraphEdge]

    public init(nodes: [RecordGraphNode], edges: [RecordGraphEdge]) {
        self.nodes = nodes
        self.edges = edges
    }

    enum CodingKeys: String, CodingKey {
        case nodes
        case edges
    }
}

public struct RecordGraphNode: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let title: String
    public let parentIDs: [String]
    public let depth: Int
    public let round: Int
    public let status: String
    public let origin: String
    public let costUSD: Double?
    public let lens: String?
    public let objections: [RecordObjection]?
    public let why: String?
    public let provokedBy: String?
    public let statement: String?
    public let severity: String?
    public let estCostUSD: Double?
    public let rejectedReason: String?

    public init(id: String, kind: String, title: String, parentIDs: [String], depth: Int, round: Int, status: String, origin: String, costUSD: Double? = nil, lens: String? = nil, objections: [RecordObjection]? = nil, why: String? = nil, provokedBy: String? = nil, statement: String? = nil, severity: String? = nil, estCostUSD: Double? = nil, rejectedReason: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.parentIDs = parentIDs
        self.depth = depth
        self.round = round
        self.status = status
        self.origin = origin
        self.costUSD = costUSD
        self.lens = lens
        self.objections = objections
        self.why = why
        self.provokedBy = provokedBy
        self.statement = statement
        self.severity = severity
        self.estCostUSD = estCostUSD
        self.rejectedReason = rejectedReason
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case parentIDs = "parent_ids"
        case depth
        case round
        case status
        case origin
        case costUSD = "cost_usd"
        case lens
        case objections
        case why
        case provokedBy = "provoked_by"
        case statement
        case severity
        case estCostUSD = "est_cost_usd"
        case rejectedReason = "rejected_reason"
    }
}

public struct RecordGraphEdge: Codable, Sendable, Equatable {
    public let from: String
    public let to: String
    public let kind: String
    public let label: String?

    public init(from: String, to: String, kind: String, label: String? = nil) {
        self.from = from
        self.to = to
        self.kind = kind
        self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case from
        case to
        case kind
        case label
    }
}

public struct RecordCost: Codable, Sendable, Equatable {
    public let usd: Double
    public let byRole: RecordCostByRole

    public init(usd: Double, byRole: RecordCostByRole) {
        self.usd = usd
        self.byRole = byRole
    }

    enum CodingKeys: String, CodingKey {
        case usd
        case byRole = "by_role"
    }
}

public struct RecordCostByRole: Codable, Sendable, Equatable {
    public let plan: Double
    public let research: Double
    public let synthesis: Double
    public let verify: Double
    public let validate: Double

    public init(plan: Double, research: Double, synthesis: Double, verify: Double, validate: Double) {
        self.plan = plan
        self.research = research
        self.synthesis = synthesis
        self.verify = verify
        self.validate = validate
    }

    enum CodingKeys: String, CodingKey {
        case plan
        case research
        case synthesis
        case verify
        case validate
    }
}

public struct RecordLimits: Codable, Sendable, Equatable {
    public let capUSD: Double?
    public let deadlineS: Double?

    public init(capUSD: Double? = nil, deadlineS: Double? = nil) {
        self.capUSD = capUSD
        self.deadlineS = deadlineS
    }

    enum CodingKeys: String, CodingKey {
        case capUSD = "cap_usd"
        case deadlineS = "deadline_s"
    }
}

public struct RecordTimelineEntry: Codable, Sendable, Equatable {
    public let at: String
    public let phase: String

    public init(at: String, phase: String) {
        self.at = at
        self.phase = phase
    }

    enum CodingKeys: String, CodingKey {
        case at
        case phase
    }
}

public struct RecordStrippedMarker: Codable, Sendable, Equatable {
    public let taskID: String
    public let marker: String

    public init(taskID: String, marker: String) {
        self.taskID = taskID
        self.marker = marker
    }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case marker
    }
}

public struct RecordStats: Codable, Sendable, Equatable {
    public let sourcesRead: Int
    public let sourcesCited: Int
    public let sourcesByType: RecordSourceTypeCounts
    public let citedByType: RecordSourceTypeCounts
    public let citations: Int
    public let citationsResolved: Int
    public let claims: Int
    public let claimsSolid: Int
    public let claimsShaky: Int
    public let claimsUnverified: Int
    public let verdicts: RecordVerdictCounts
    public let findings: Int
    public let conflictsOpen: Int
    public let gaps: Int
    public let objectionsOpen: Int
    public let strippedMarkers: Int
    public let tasks: Int
    public let tasksFailed: Int
    public let rounds: Int
    public let costUSD: Double
    public let durationS: Double
    public let trustLevel: RecordStatsTrustLevel

    public init(sourcesRead: Int, sourcesCited: Int, sourcesByType: RecordSourceTypeCounts, citedByType: RecordSourceTypeCounts, citations: Int, citationsResolved: Int, claims: Int, claimsSolid: Int, claimsShaky: Int, claimsUnverified: Int, verdicts: RecordVerdictCounts, findings: Int, conflictsOpen: Int, gaps: Int, objectionsOpen: Int, strippedMarkers: Int, tasks: Int, tasksFailed: Int, rounds: Int, costUSD: Double, durationS: Double, trustLevel: RecordStatsTrustLevel) {
        self.sourcesRead = sourcesRead
        self.sourcesCited = sourcesCited
        self.sourcesByType = sourcesByType
        self.citedByType = citedByType
        self.citations = citations
        self.citationsResolved = citationsResolved
        self.claims = claims
        self.claimsSolid = claimsSolid
        self.claimsShaky = claimsShaky
        self.claimsUnverified = claimsUnverified
        self.verdicts = verdicts
        self.findings = findings
        self.conflictsOpen = conflictsOpen
        self.gaps = gaps
        self.objectionsOpen = objectionsOpen
        self.strippedMarkers = strippedMarkers
        self.tasks = tasks
        self.tasksFailed = tasksFailed
        self.rounds = rounds
        self.costUSD = costUSD
        self.durationS = durationS
        self.trustLevel = trustLevel
    }

    enum CodingKeys: String, CodingKey {
        case sourcesRead = "sources_read"
        case sourcesCited = "sources_cited"
        case sourcesByType = "sources_by_type"
        case citedByType = "cited_by_type"
        case citations
        case citationsResolved = "citations_resolved"
        case claims
        case claimsSolid = "claims_solid"
        case claimsShaky = "claims_shaky"
        case claimsUnverified = "claims_unverified"
        case verdicts
        case findings
        case conflictsOpen = "conflicts_open"
        case gaps
        case objectionsOpen = "objections_open"
        case strippedMarkers = "stripped_markers"
        case tasks
        case tasksFailed = "tasks_failed"
        case rounds
        case costUSD = "cost_usd"
        case durationS = "duration_s"
        case trustLevel = "trust_level"
    }
}

public struct RecordSourceTypeCounts: Codable, Sendable, Equatable {
    public let primary: Int
    public let vendor: Int
    public let seo: Int
    public let academic: Int
    public let news: Int

    public init(primary: Int, vendor: Int, seo: Int, academic: Int, news: Int) {
        self.primary = primary
        self.vendor = vendor
        self.seo = seo
        self.academic = academic
        self.news = news
    }

    enum CodingKeys: String, CodingKey {
        case primary
        case vendor
        case seo
        case academic
        case news
    }
}

public struct RecordVerdictCounts: Codable, Sendable, Equatable {
    public let supported: Int
    public let unsupported: Int
    public let misquoted: Int
    public let unjudged: Int

    public init(supported: Int, unsupported: Int, misquoted: Int, unjudged: Int) {
        self.supported = supported
        self.unsupported = unsupported
        self.misquoted = misquoted
        self.unjudged = unjudged
    }

    enum CodingKeys: String, CodingKey {
        case supported
        case unsupported
        case misquoted
        case unjudged
    }
}

public enum RecordStatsTrustLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case solid
    case moderate
    case shaky
    case unchecked
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordStatsTrustLevel(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct RecordCheck: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let status: RecordCheckStatus
    public let detail: String

    public init(id: String, name: String, status: RecordCheckStatus, detail: String) {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case detail
    }
}

public enum RecordCheckStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pass
    case fail
    case warn
    case unknown

    public init(from decoder: Decoder) throws {
        self = RecordCheckStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public struct QuestionRecord: Codable, Sendable, Equatable {
    public let schema: String
    public let id: String
    public let createdAt: String
    public let originalText: String
    public let resolvedText: String
    public let language: String
    public let title: String
    public let titleSource: QuestionRecordTitleSource
    public let runIDs: [String]

    public init(schema: String, id: String, createdAt: String, originalText: String, resolvedText: String, language: String, title: String, titleSource: QuestionRecordTitleSource, runIDs: [String]) {
        self.schema = schema
        self.id = id
        self.createdAt = createdAt
        self.originalText = originalText
        self.resolvedText = resolvedText
        self.language = language
        self.title = title
        self.titleSource = titleSource
        self.runIDs = runIDs
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case id
        case createdAt = "created_at"
        case originalText = "original_text"
        case resolvedText = "resolved_text"
        case language
        case title
        case titleSource = "title_source"
        case runIDs = "run_ids"
    }
}

public enum QuestionRecordTitleSource: String, Codable, Sendable, Equatable, CaseIterable {
    case question
    case scope
    case unknown

    public init(from decoder: Decoder) throws {
        self = QuestionRecordTitleSource(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

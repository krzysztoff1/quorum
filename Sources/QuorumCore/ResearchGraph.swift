import Foundation

public enum GraphNodeKind: String, Sendable, Codable, Equatable, CaseIterable {
    case question, inquiry, source, finding, conflict, gap, synthesis, verification
    /// One validator task's judgement of one draft of the answer (PRD 06). It never edits that answer —
    /// it carries what it filed against it.
    case verdict

    /// What a node produced rather than what the run did. Detail hangs off the skeleton and stays folded
    /// away until a reader asks the node for it.
    public var isDetail: Bool {
        switch self {
        case .source, .finding, .conflict, .gap: return true
        case .question, .inquiry, .synthesis, .verification, .verdict: return false
        }
    }
}

/// Where a question came from. `followup` is the orchestrator chasing a prior synthesis's open points;
/// `spawn` is an agent asking mid-run; `dig` is the user digging down from a node.
public enum GraphNodeOrigin: String, Sendable, Codable, Equatable {
    case root, planner, followup, spawn, dig, objection, derived
}

/// A question's lifecycle, which is about permission rather than progress. `planning` is the root's alone:
/// the question has been asked and is being decomposed, which is neither waiting on a person nor doing
/// research of its own.
public enum QuestionState: String, Sendable, Codable, Equatable {
    case planning, pending, approved, rejected, expired
}

/// Kept apart from `QuestionState` on purpose: a question is admitted or refused, work runs or fails, a
/// verdict passed the answer or filed against it, and a derived node has no lifecycle at all. Collapsing
/// them into one enum would let "rejected" and "error" stand in for each other.
public enum GraphNodeState: Sendable, Equatable {
    case asked(QuestionState)
    case worked(TopicStatus)
    case judged(objections: Int)
    case derived
}

public struct GraphNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: GraphNodeKind
    /// Editable because a planned angle is a proposal until the reader says otherwise, and the card it is
    /// drawn on is where they say it.
    public var title: String
    public var state: GraphNodeState
    public let origin: GraphNodeOrigin
    public let depth: Int
    public let round: Int
    public var subtitle: String?
    /// What an angle would actually be sent to research — the card's second field, and the only part of a
    /// proposed node the engine reads.
    public var prompt: String?
    public var costUSD: Decimal
    public let confidence: Confidence?
    public let document: SourceDocument?
    /// Why a spawn was raised, or why it was refused — whichever this node is carrying.
    public let reason: String?
    public let provokedBy: String?
    public let estimatedCostUSD: Decimal?
    /// Which validator task a verdict is, or which one raised a question. Two passing verdicts are told
    /// apart by nothing else, and the canvas draws the lens rather than the word "verdict" four times.
    public let lens: String?
    /// What a verdict filed against the answer — empty on every other kind of node.
    public let objections: [RunStreamParser.ObjectionEvent]

    public init(id: String, kind: GraphNodeKind, title: String, state: GraphNodeState,
                origin: GraphNodeOrigin = .derived, depth: Int = 0, round: Int = 1,
                subtitle: String? = nil, prompt: String? = nil, costUSD: Decimal = 0,
                confidence: Confidence? = nil,
                document: SourceDocument? = nil, reason: String? = nil,
                provokedBy: String? = nil, estimatedCostUSD: Decimal? = nil, lens: String? = nil,
                objections: [RunStreamParser.ObjectionEvent] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
        self.origin = origin
        self.depth = depth
        self.round = round
        self.subtitle = subtitle
        self.prompt = prompt
        self.costUSD = costUSD
        self.confidence = confidence
        self.document = document
        self.reason = reason
        self.provokedBy = provokedBy
        self.estimatedCostUSD = estimatedCostUSD
        self.lens = lens
        self.objections = objections
    }

    public var isPending: Bool { state == .asked(.pending) }

    /// An angle the planner drew and nobody has paid for yet. A spawn waiting on a verdict is a question;
    /// this is work that has been written but not admitted, which is why it edits rather than just answers.
    public var isProposed: Bool { kind == .inquiry && state == .asked(.pending) }

    public var isSpent: Bool {
        if case .worked = state { return true }
        return false
    }
}

public enum GraphEdgeKind: String, Sendable, Codable, Equatable {
    case decomposes      // question → inquiry
    case spawned         // inquiry → question raised mid-run
    case reports         // inquiry → finding
    case cites           // finding → source
    case corroborates    // source → inquiry, only once a second inquiry reached it independently
    case contradicts     // finding → conflict
    case surfaces        // synthesis → conflict / gap
    case resolves        // synthesis → the inquiry chasing its open point
    case synthesizes     // inquiry → synthesis
    case verifies        // verification → synthesis
    case judges          // verdict → the draft of the answer it judged

    /// Edges that mean "this hangs off that". `corroborates` runs the other way (a shared source points
    /// back at the inquiries that reached it), so following it would make every angle a child of a
    /// document and collapse the whole graph into one node. `judges` and `verifies` run the other way too:
    /// the judgement points at the answer, so following them would collapse the answer under its critic.
    var descends: Bool { !pointsBackward }

    /// The same relation read upward. `synthesizes` climbs too, so focusing a later round's angle lights
    /// the synthesis it came from and the angles behind that.
    var climbs: Bool { !pointsBackward }

    private var pointsBackward: Bool { self == .corroborates || self == .judges || self == .verifies }
}

public struct GraphEdge: Identifiable, Sendable, Equatable, Hashable {
    public let from: String
    public let to: String
    public let kind: GraphEdgeKind
    public let label: String?

    public var id: String { "\(from)→\(to)·\(kind.rawValue)" }

    public init(from: String, to: String, kind: GraphEdgeKind, label: String? = nil) {
        self.from = from
        self.to = to
        self.kind = kind
        self.label = label
    }
}

/// What the run actually did, as structure rather than as a list. Insertion-ordered so a replay draws the
/// same picture every time, and so the layout has a stable tie-break with no clock to consult.
public struct ResearchGraph: Sendable, Equatable {
    public static let rootID = "root"

    public private(set) var nodes: [GraphNode] = []
    public private(set) var edges: [GraphEdge] = []
    /// What the run behind this shape could check its quotes against (PRD 07). The canvas is a reader
    /// surface like any other: an unvalidated run says so here too, from `run_start` onward.
    public private(set) var grounding: RunGrounding = .captured

    public var isValidated: Bool { grounding != .none }

    private var nodeIndex: [String: Int] = [:]
    private var edgeKeys: Set<String> = []

    public init() {}

    public func node(_ id: String) -> GraphNode? {
        nodeIndex[id].map { nodes[$0] }
    }

    public func nodes(of kind: GraphNodeKind) -> [GraphNode] {
        nodes.filter { $0.kind == kind }
    }

    public func edges(of kind: GraphEdgeKind) -> [GraphEdge] {
        edges.filter { $0.kind == kind }
    }

    /// What hangs off a node. A verdict's `judges` edge runs the other way — it points at the answer it
    /// read — so counting it here would make the answer a child of its own critic.
    public func children(of id: String) -> [GraphNode] {
        edges.filter { $0.from == id && $0.kind.descends }.compactMap { node($0.to) }
    }

    /// First write wins on placement: a document two angles both captured is one node, and re-inserting it
    /// must not move it out from under the reader. State is the exception — the run is authoritative about
    /// what a node is doing, so a node arriving again moves rather than being ignored.
    public mutating func insert(_ node: GraphNode) {
        guard let existing = nodeIndex[node.id] else {
            nodeIndex[node.id] = nodes.count
            nodes.append(node)
            return
        }
        nodes[existing].state = node.state
        if node.costUSD > 0 { nodes[existing].costUSD = node.costUSD }
    }

    /// The graph the moment the question is asked, before the planner has produced anything. The canvas is
    /// the surface for the whole run, so it must not start empty and fill in later.
    public static func planning(question: String, angleCount: Int? = nil) -> ResearchGraph {
        var graph = ResearchGraph()
        graph.insert(GraphNode(
            id: rootID, kind: .question, title: question, state: .asked(.planning), origin: .root,
            subtitle: angleCount.map { "decomposing into \($0) angles…" }))
        return graph
    }

    /// A relation is drawn once. The exception is the word on it: a node's `parent_ids` draw the wire
    /// before the `graph_edge` line that names what it is arrives, so a label lands on the edge already
    /// there rather than being refused as a duplicate.
    public mutating func connect(_ edge: GraphEdge) {
        guard !edgeKeys.contains(edge.id) else {
            guard edge.label != nil, let existing = edges.firstIndex(where: { $0.id == edge.id }),
                  edges[existing].label == nil else { return }
            edges[existing] = edge
            return
        }
        edgeKeys.insert(edge.id)
        edges.append(edge)
    }

    /// A verdict given on the canvas, applied straight away rather than waiting for the engine to echo it
    /// back — the button has to feel answered. The engine's own `graph_node_update` lands on top and says
    /// the same thing.
    public mutating func rule(on id: String, approved: Bool) {
        guard let index = nodeIndex[id], nodes[index].kind == .question else { return }
        nodes[index].state = .asked(approved ? .approved : .rejected)
    }

    /// What the canvas does the moment the button is pressed, ahead of the engine's own answer: a verdict
    /// lands on the card, a pruned branch greys, a re-filed inquiry goes back in the queue. The engine's
    /// `graph_node_update` arrives after and says the same thing.
    public mutating func steer(_ control: RunControl) {
        switch control {
        case let .approve(id): rule(on: id, approved: true)
        case let .reject(id):  rule(on: id, approved: false)
        case let .prune(id):   for target in [id] + descendants(of: id) { grey(target) }
        case let .retry(id):   refile(id)
        }
    }

    /// A branch dropped by hand, greyed as far as the run can actually drop it: an offer nobody has spent
    /// on is refused, while work already bought — which neither the engine nor this app can unspend —
    /// keeps the state it earned. The canvas says what the run did, not what the user wished it had done.
    private mutating func grey(_ id: String) {
        guard let index = nodeIndex[id], nodes[index].state == .asked(.pending) else { return }
        nodes[index].state = .asked(.rejected)
    }

    /// Every offer standing under a node, itself included — what pruning a branch actually withdraws. The
    /// engine rules on one offer at a time, so the branch travels as one line per offer.
    public func pendingOffers(under id: String) -> [GraphNode] {
        let branch = Set([id] + descendants(of: id))
        return pendingOffers.filter { branch.contains($0.id) }
    }

    /// Whether pruning here would stop anything. Offered only where it acts, because a menu item that
    /// does nothing is how steering stopped being believed the first time.
    public func canPrune(_ id: String) -> Bool { !pendingOffers(under: id).isEmpty }

    /// Whether a node is somewhere the reader can research further from. Everything the run has actually
    /// put on the canvas is, which is why the affordance can sit on the card rather than behind a
    /// right-click; an angle still being written is a card being edited, not a branch to grow from.
    public func canDig(_ id: String) -> Bool {
        guard let node = node(id) else { return false }
        return !node.isProposed
    }

    /// A topic that stopped — failed, halted or finished — and could be run again. One still queued has
    /// not run yet, and one in flight is already the thing a retry would ask for.
    public func canRetry(_ id: String) -> Bool {
        guard case let .worked(status) = node(id)?.state else { return false }
        return status != .running && status != .queued
    }

    /// An inquiry put back in the wave. One still running is left alone: it has not failed yet, and asking
    /// for it twice is how a retry turns into a second bill.
    private mutating func refile(_ id: String) {
        guard let index = nodeIndex[id], case let .worked(status) = nodes[index].state,
              status != .running else { return }
        nodes[index].state = .worked(.queued)
    }

    // MARK: the plan, while it is still only a proposal

    /// The planner's angles, staged on the canvas as cards that are not yet work: pending, editable, and
    /// costing nothing. The review happens where the run will happen, so the surface never changes hands.
    public mutating func propose(_ angles: [ResearchAngle], costCeilingUSD: Decimal? = nil) {
        if let root = nodeIndex[Self.rootID] {
            nodes[root].state = .asked(.approved)
            nodes[root].subtitle = nil
        }
        for angle in angles where node(angle.id) == nil {
            insert(GraphNode(id: angle.id, kind: .inquiry, title: angle.title, state: .asked(.pending),
                             origin: .planner, depth: 1, prompt: angle.prompt,
                             estimatedCostUSD: costCeilingUSD))
            if node(Self.rootID) != nil {
                connect(GraphEdge(from: Self.rootID, to: angle.id, kind: .decomposes))
            }
        }
    }

    public var proposedAngles: [GraphNode] { nodes.filter(\.isProposed) }

    /// An angle with nothing written in it is not something to spend on, and a plan with no angles is not
    /// a plan — the CTA is the last gate before money moves.
    public var planIsRunnable: Bool {
        let proposed = proposedAngles
        guard !proposed.isEmpty else { return false }
        return proposed.allSatisfy { !($0.prompt ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public mutating func revise(_ id: String, title: String? = nil, prompt: String? = nil) {
        guard let index = nodeIndex[id] else { return }
        if let title { nodes[index].title = title }
        if let prompt { nodes[index].prompt = prompt }
    }

    /// The reader's own angle, beside the planner's. It arrives empty on purpose: the card is the prompt
    /// box, so there is nothing to write into it but what they mean.
    @discardableResult
    public mutating func addProposedAngle(title: String = "New angle") -> String {
        let id = UUID().uuidString
        propose([ResearchAngle(id: id, title: title, prompt: "")],
                costCeilingUSD: proposedAngles.first?.estimatedCostUSD)
        return id
    }

    /// A node and every wire into or out of it, gone. Rebuilt rather than spliced, because the index that
    /// keeps insertion order is what the layout ties slots to.
    public mutating func drop(_ id: String) {
        guard nodeIndex[id] != nil else { return }
        var rebuilt = ResearchGraph()
        rebuilt.grounding = grounding
        for node in nodes where node.id != id { rebuilt.insert(node) }
        for edge in edges where edge.from != id && edge.to != id { rebuilt.connect(edge) }
        self = rebuilt
    }

    /// The one button that starts spending: every card becomes queued work, and what leaves here is exactly
    /// what is drawn — same angles, same order, carrying every edit made on the cards.
    @discardableResult
    public mutating func approvePlan() -> [ResearchAngle] {
        let proposed = proposedAngles
        guard !proposed.isEmpty else { return [] }
        for node in proposed {
            guard let index = nodeIndex[node.id] else { continue }
            nodes[index].state = .worked(.queued)
        }
        return proposed.map { ResearchAngle(id: $0.id, title: $0.title, prompt: $0.prompt ?? "") }
    }

    // MARK: what the canvas asks for

    /// The claims, sources, conflicts and gaps a node is holding but not showing.
    public func detailCount(under id: String) -> Int {
        edges.filter { $0.from == id && node($0.to)?.kind.isDetail == true }.count
    }

    /// The run's structure, with the detail folded into the nodes that produced it. A finished run puts
    /// twenty-odd findings on one rank — a canvas five thousand points wide that nobody can read — so the
    /// skeleton is what opens, and a node hands over its claims when asked.
    public func skeleton(expanding expanded: Set<String>) -> ResearchGraph {
        let shown = Set(nodes.filter { node -> Bool in
            guard node.kind.isDetail else { return true }
            return edges.contains { $0.to == node.id && expanded.contains($0.from) }
        }.map(\.id))
        guard shown.count < nodes.count else { return self }

        var pruned = ResearchGraph()
        for node in nodes where shown.contains(node.id) { pruned.insert(node) }
        for edge in edges where shown.contains(edge.from) && shown.contains(edge.to) {
            pruned.connect(edge)
        }
        return pruned
    }

    /// The graph with everything below a collapsed node removed. The collapsed node stays — it becomes the
    /// chip carrying the count — and an edge survives only when both of its ends do.
    public func hiding(under collapsed: Set<String>) -> ResearchGraph {
        guard !collapsed.isEmpty else { return self }
        var hidden: Set<String> = []
        for root in collapsed {
            for descendant in descendants(of: root) where !collapsed.contains(descendant) {
                hidden.insert(descendant)
            }
        }
        guard !hidden.isEmpty else { return self }

        var pruned = ResearchGraph()
        for node in nodes where !hidden.contains(node.id) { pruned.insert(node) }
        for edge in edges where !hidden.contains(edge.from) && !hidden.contains(edge.to) {
            pruned.connect(edge)
        }
        return pruned
    }

    /// A node and every node it hangs from, root last. Used to light one path and dim the rest; the seen
    /// set is what keeps a graph that somehow cycles from walking forever.
    public func ancestry(of id: String) -> [String] {
        guard node(id) != nil else { return [] }
        var path = [id]
        var seen: Set<String> = [id]
        var frontier = [id]
        while let current = frontier.popLast() {
            for edge in edges where edge.to == current && edge.kind.climbs {
                guard node(edge.from) != nil, seen.insert(edge.from).inserted else { continue }
                path.append(edge.from)
                frontier.append(edge.from)
            }
        }
        return path
    }

    private func descendants(of id: String) -> Set<String> {
        var found: Set<String> = []
        var frontier = [id]
        while let current = frontier.popLast() {
            for edge in edges where edge.from == current && edge.kind.descends {
                if found.insert(edge.to).inserted { frontier.append(edge.to) }
            }
        }
        return found
    }

    // MARK: shape

    public var maxDepth: Int { nodes.map(\.depth).max() ?? 0 }

    public var widestRank: Int {
        Dictionary(grouping: nodes, by: \.depth).values.map(\.count).max() ?? 0
    }

    /// The share of captured sources that more than one inquiry reached independently — the cross-angle
    /// agreement the fan-out exists to produce, as a number the layout can branch on.
    public var sourceConvergence: Double {
        let sources = nodes(of: .source)
        guard !sources.isEmpty else { return 0 }
        let reachedByMany = Set(edges(of: .corroborates).map(\.from))
        return Double(reachedByMany.count) / Double(sources.count)
    }

    // MARK: folding the live stream

    /// The same graph History rebuilds from a report, grown one event at a time instead. Forgiving by
    /// design: an event naming a node that never arrived is dropped rather than inventing a placeholder,
    /// because a node with no title is worse on the canvas than a node that is missing.
    public mutating func apply(_ event: RunStreamParser.Event) {
        switch event {
        case let .graphNode(node):
            insert(GraphNode(
                id: node.id, kind: kind(node.kind), title: node.title,
                state: state(node.status, kind: kind(node.kind)), origin: origin(node.origin),
                depth: node.depth, round: node.round, costUSD: node.costUSD ?? 0,
                reason: node.why ?? node.rejectedReason, provokedBy: node.provokedBy,
                estimatedCostUSD: node.estimatedCostUSD, lens: node.lens,
                objections: node.objections))
            for parent in node.parentIDs where self.node(parent) != nil {
                connect(GraphEdge(from: parent, to: node.id, kind: .spawned))
            }

        case let .graphEdge(edge):
            connect(GraphEdge(from: edge.from, to: edge.to, kind: edgeKind(edge.kind), label: edge.label))

        case let .graphNodeUpdate(id, status, costUSD):
            guard let index = nodeIndex[id] else { return }
            nodes[index].state = state(status, kind: nodes[index].kind)
            if let costUSD { nodes[index].costUSD = costUSD }

        case let .angleStatus(angleID, status):
            guard let index = nodeIndex[angleID] else { return }
            nodes[index].state = state(status, kind: nodes[index].kind)

        case let .document(angleID, document):
            absorb(document, reachedBy: angleID)

        case let .runStart(_, _, tier):
            grounding = tier

        case let .runResult(result):
            grounding = result.grounding

        // The in-process fallback emits no graph events at all, so the plan is also read as structure —
        // that path gets the same canvas, just without the spawns it cannot produce. An angle the
        // orchestrator already drew keeps the shape the orchestrator gave it: a round the loop bought
        // hangs off the objection that bought it, never off the root.
        case let .plan(angles), let .round(_, angles):
            if let root = nodeIndex[Self.rootID] { nodes[root].state = .asked(.approved) }
            for angle in angles where node(angle.angleID) == nil {
                insert(GraphNode(id: angle.angleID, kind: .inquiry, title: angle.title,
                                 state: .worked(.queued), origin: .planner, depth: 1))
                if node(Self.rootID) != nil {
                    connect(GraphEdge(from: Self.rootID, to: angle.angleID, kind: .decomposes))
                }
            }

        default:
            return
        }
    }

    /// A document is one node however many angles reach it; the second arrival is what turns those
    /// separate reaches into the corroboration the fan-out exists to produce.
    private mutating func absorb(_ document: SourceDocument, reachedBy angleID: String) {
        let depth = (node(angleID)?.depth ?? 0) + 1
        insert(GraphNode(id: document.sourceID, kind: .source,
                         title: document.title.isEmpty ? document.url : document.title,
                         state: .derived, depth: depth,
                         subtitle: document.url, document: document))
        guard !angleID.isEmpty else { return }
        connect(GraphEdge(from: angleID, to: document.sourceID, kind: .cites))

        let reaches = edges.filter { $0.to == document.sourceID && $0.kind == .cites }.map(\.from)
        guard reaches.count > 1 else { return }
        for reach in reaches {
            connect(GraphEdge(from: document.sourceID, to: reach, kind: .corroborates, label: "both reached"))
        }
    }

    private func kind(_ raw: String) -> GraphNodeKind { GraphNodeKind(rawValue: raw) ?? .inquiry }

    private func origin(_ raw: String) -> GraphNodeOrigin { GraphNodeOrigin(rawValue: raw) ?? .derived }

    private func edgeKind(_ raw: String) -> GraphEdgeKind { GraphEdgeKind(rawValue: raw) ?? .decomposes }

    /// The two lifecycles read from the same wire field, so which one a status means depends on what kind
    /// of node is carrying it — a question is admitted or refused, work runs or fails.
    private func state(_ raw: String, kind: GraphNodeKind) -> GraphNodeState {
        if kind == .question, let asked = QuestionState(rawValue: raw) { return .asked(asked) }
        if kind == .verdict { return judgement(raw) }
        switch raw {
        case "queued":                     return .worked(.queued)
        case "running":                    return .worked(.running)
        case "complete":                   return .worked(.complete)
        case "inconclusive":               return .worked(.inconclusive)
        case "halted":                     return .worked(.haltedManual)
        case "error":                      return .worked(.error)
        default:                           return kind == .question ? .asked(.pending) : .derived
        }
    }

    /// `pass` or `objections(n)` — a task the run skipped stays derived rather than reading as a pass.
    private func judgement(_ raw: String) -> GraphNodeState {
        if raw == "pass" { return .judged(objections: 0) }
        guard raw.hasPrefix("objections("), raw.hasSuffix(")"),
              let count = Int(raw.dropFirst("objections(".count).dropLast()) else { return .derived }
        return .judged(objections: count)
    }

    // MARK: rebuilding a finished run

    /// A persisted run as a graph. The fan is the special case this produces for a legacy report: one
    /// root question, its angles a rank below, the synthesis below them — so no run in History becomes
    /// unrenderable when the diagram changes.
    public static func from(report: RunReport) -> ResearchGraph {
        var graph = ResearchGraph()
        let entries = report.entries.filter { $0.status != .skipped }
        let inquiries = entries.filter { $0.isSynthesis != true }
        let syntheses = entries.filter { $0.isSynthesis == true }

        graph.insert(GraphNode(id: rootID, kind: .question,
                               title: rootQuestion(syntheses: syntheses, inquiries: inquiries),
                               state: .asked(.approved), origin: .root, depth: 0))
        if entries.contains(where: { $0.evidence?.grounding == RunGrounding.none }) { graph.grounding = .none }

        let rounds = Set(inquiries.map { $0.round ?? 1 }).sorted()
        for round in rounds {
            let parent = priorSynthesis(before: round, in: syntheses)
            let depth = parent == nil ? 1 : (graph.node(parent!.id)?.depth ?? 0) + 1
            for entry in inquiries where (entry.round ?? 1) == round {
                graph.insert(inquiryNode(entry, depth: depth, round: round, spawned: parent != nil))
                if let parent {
                    graph.connect(GraphEdge(from: parent.id, to: entry.id, kind: .resolves,
                                            label: "open point"))
                } else {
                    graph.connect(GraphEdge(from: rootID, to: entry.id, kind: .decomposes))
                }
            }
            if let synthesis = syntheses.first(where: { ($0.round ?? 1) == round }) {
                graph.insertSynthesis(synthesis, feeding: inquiries, round: round, depth: depth + 1)
            }
        }

        // A single synthesis on a multi-round report belongs to the last round, which the loop above only
        // places when its round tag matches. Nothing was placed → attach it below everything.
        if graph.nodes(of: .synthesis).isEmpty, let trailing = syntheses.last {
            graph.insertSynthesis(trailing, feeding: inquiries, round: trailing.round ?? 1,
                                  depth: graph.maxDepth + 1)
        }

        graph.deriveEvidence(from: inquiries + syntheses)
        return graph
    }

    private static func rootQuestion(syntheses: [RunReport.TopicEntry],
                                     inquiries: [RunReport.TopicEntry]) -> String {
        syntheses.first?.question ?? inquiries.first?.question ?? "Question"
    }

    /// The synthesis a later round is chasing: rounds beyond the first exist because the prior round left
    /// conflicts and gaps open, so they hang off that synthesis rather than off the root.
    private static func priorSynthesis(before round: Int,
                                       in syntheses: [RunReport.TopicEntry]) -> RunReport.TopicEntry? {
        syntheses.filter { ($0.round ?? 1) < round }.max { ($0.round ?? 1) < ($1.round ?? 1) }
    }

    private static func inquiryNode(_ entry: RunReport.TopicEntry, depth: Int, round: Int,
                                    spawned: Bool) -> GraphNode {
        GraphNode(id: entry.id, kind: .inquiry, title: entry.question, state: .worked(entry.status),
                  origin: spawned ? .followup : .planner, depth: depth, round: round,
                  subtitle: entry.headline, costUSD: entry.costUSD)
    }

    private mutating func insertSynthesis(_ entry: RunReport.TopicEntry,
                                          feeding inquiries: [RunReport.TopicEntry],
                                          round: Int, depth: Int) {
        insert(GraphNode(id: entry.id, kind: .synthesis, title: entry.headline,
                         state: .worked(entry.status), origin: .planner, depth: depth, round: round,
                         subtitle: entry.question, costUSD: entry.costUSD))
        for inquiry in inquiries where (inquiry.round ?? 1) <= round {
            connect(GraphEdge(from: inquiry.id, to: entry.id, kind: .synthesizes))
        }
        for conflict in entry.conflicts ?? [] {
            let id = "\(entry.id)·conflict·\(conflict.claim.hashValue)"
            insert(GraphNode(id: id, kind: .conflict, title: conflict.claim, state: .derived,
                             depth: depth + 1, round: round,
                             subtitle: conflict.positions.joined(separator: " · ")))
            connect(GraphEdge(from: entry.id, to: id, kind: .surfaces))
        }
        for gap in entry.gaps ?? [] {
            let id = "\(entry.id)·gap·\(gap.hashValue)"
            insert(GraphNode(id: id, kind: .gap, title: gap, state: .derived,
                             depth: depth + 1, round: round))
            connect(GraphEdge(from: entry.id, to: id, kind: .surfaces))
        }
    }

    /// Sources, findings and the links between them are already in the report — nothing here asks a model
    /// anything, it only reads what the run recorded.
    private mutating func deriveEvidence(from entries: [RunReport.TopicEntry]) {
        var reachedBy: [String: Set<String>] = [:]

        for entry in entries {
            let evidence = entry.evidence ?? EvidenceIndex()
            let depth = (node(entry.id)?.depth ?? 0) + 1
            let round = node(entry.id)?.round ?? 1

            for document in evidence.documents {
                insert(GraphNode(id: document.sourceID, kind: .source,
                                 title: document.title.isEmpty ? document.url : document.title,
                                 state: .derived, depth: depth, round: round,
                                 subtitle: document.url, document: document))
                // The inquiry that reached it, not only the findings that quote it — the same edge the live
                // fold draws, so a rebuilt run and a watched one are the same graph.
                connect(GraphEdge(from: entry.id, to: document.sourceID, kind: .cites))
            }
            for sourceID in Set(evidence.citations.map(\.sourceID)) where !sourceID.isEmpty {
                reachedBy[sourceID, default: []].insert(entry.id)
            }

            for (offset, finding) in (entry.findings ?? []).enumerated() {
                let id = "\(entry.id)·finding·\(offset)"
                insert(GraphNode(id: id, kind: .finding, title: finding.claim, state: .derived,
                                 depth: depth, round: round, confidence: finding.confidence))
                connect(GraphEdge(from: entry.id, to: id, kind: .reports))
                for citation in evidence.resolve(finding.citationIDs) {
                    connect(GraphEdge(from: id, to: citation.sourceID, kind: .cites))
                }
            }
        }

        for (sourceID, inquiryIDs) in reachedBy where inquiryIDs.count > 1 {
            for inquiryID in inquiryIDs.sorted() {
                connect(GraphEdge(from: sourceID, to: inquiryID, kind: .corroborates,
                                  label: "both reached"))
            }
        }
    }
}

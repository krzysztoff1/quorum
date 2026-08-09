import CoreGraphics
import Foundation

public struct NodeFrame: Identifiable, Sendable, Equatable {
    public let id: String
    public let rank: Int
    public let slot: Int
    public let rect: CGRect

    public init(id: String, rank: Int, slot: Int, rect: CGRect) {
        self.id = id
        self.rank = rank
        self.slot = slot
        self.rect = rect
    }
}

/// An orthogonal elbow between two node frames. `labelAnchor` is where an edge's word belongs — the
/// midpoint of the horizontal run, which is the only segment long enough to carry text.
public struct EdgeRoute: Sendable, Equatable {
    public let points: [CGPoint]
    public let labelAnchor: CGPoint?

    public init(points: [CGPoint], labelAnchor: CGPoint? = nil) {
        self.points = points
        self.labelAnchor = labelAnchor
    }
}

public struct PlacedGraph: Sendable, Equatable {
    public let frames: [NodeFrame]
    public let bounds: CGRect

    private let framesByID: [String: NodeFrame]

    public init(frames: [NodeFrame], bounds: CGRect) {
        self.frames = frames
        self.bounds = bounds
        self.framesByID = Dictionary(frames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func frame(_ id: String) -> NodeFrame? { framesByID[id] }

    public func route(_ edge: GraphEdge) -> EdgeRoute? {
        guard let from = framesByID[edge.from], let to = framesByID[edge.to] else { return nil }
        let start = CGPoint(x: from.rect.midX, y: from.rect.maxY)
        let end = CGPoint(x: to.rect.midX, y: to.rect.minY)
        let turn = (start.y + end.y) / 2
        let points = [start, CGPoint(x: start.x, y: turn), CGPoint(x: end.x, y: turn), end]
        let anchor = edge.label == nil ? nil : CGPoint(x: (start.x + end.x) / 2, y: turn)
        return EdgeRoute(points: points, labelAnchor: anchor)
    }
}

/// How the graph gets drawn, chosen from the graph's own shape rather than fixed in the view. The run
/// that fanned out wide draws as rows; the one that dug deep draws as a tree; the one whose angles kept
/// landing on the same documents pulls those documents out where the convergence is visible.
public enum GraphLayout: String, Sendable, Equatable, CaseIterable {
    case layered, tree, converging

    static let horizontalGutter: CGFloat = 32
    static let verticalGutter: CGFloat = 56
    static let referenceGutter: CGFloat = 72
    static let defaultSize = CGSize(width: 220, height: 96)
    static let canvasPadding: CGFloat = 24

    private static let deepEnoughForATree = 3
    private static let convergenceWorthPullingOut = 0.5

    public static func best(for graph: ResearchGraph) -> GraphLayout {
        if !graph.nodes(of: .source).isEmpty, graph.sourceConvergence >= convergenceWorthPullingOut {
            return .converging
        }
        if graph.maxDepth >= deepEnoughForATree, graph.widestRank <= graph.maxDepth { return .tree }
        return .layered
    }

    /// Node sizes are an input because an opened node is many times the height of a chip, and the reflow
    /// that follows has to be part of the same pure calculation the tests pin down.
    public func place(_ graph: ResearchGraph, sizes: [String: CGSize],
                      previous: PlacedGraph? = nil) -> PlacedGraph {
        let laidOut = self == .converging ? graph.nodes.filter { $0.kind != .source } : graph.nodes
        guard !laidOut.isEmpty else { return PlacedGraph(frames: [], bounds: .zero) }
        let ranks = Self.ranks(of: graph)

        var frames: [NodeFrame] = []
        var rankTop: CGFloat = Self.canvasPadding

        for rank in Set(laidOut.compactMap { ranks[$0.id] }).sorted() {
            let inRank = laidOut.filter { ranks[$0.id] == rank }
            let ordered = slotted(inRank, rank: rank, graph: graph, placed: frames, previous: previous)
            var x = Self.canvasPadding
            var tallest: CGFloat = 0
            for (node, slot) in ordered {
                let size = sizes[node.id] ?? Self.defaultSize
                frames.append(NodeFrame(id: node.id, rank: rank, slot: slot,
                                        rect: CGRect(x: x, y: rankTop,
                                                     width: size.width, height: size.height)))
                x += size.width + Self.horizontalGutter
                tallest = max(tallest, size.height)
            }
            rankTop += tallest + Self.verticalGutter
        }

        if self == .converging {
            frames += referenceColumn(graph, sizes: sizes, ranks: ranks, beside: frames)
        }
        return PlacedGraph(frames: frames, bounds: canvas(around: frames))
    }

    /// Which row each node is drawn on. The engine's `depth` says how far a question is from the one that
    /// was asked, which is not the same thing once the run loops: an objection's question is depth 1 and
    /// belongs BELOW the verdict at depth 3 that filed it. So a rank is one past everything that had to
    /// happen first, and depth is only the floor for a node nothing points at.
    static func ranks(of graph: ResearchGraph) -> [String: Int] {
        var ranks: [String: Int] = [:]
        var resolving: Set<String> = []

        func rank(_ node: GraphNode) -> Int {
            if let known = ranks[node.id] { return known }
            guard resolving.insert(node.id).inserted else { return node.depth }
            let value = precedents(of: node, in: graph).compactMap(graph.node).map(rank).max().map { $0 + 1 }
            resolving.remove(node.id)
            ranks[node.id] = value ?? node.depth
            return value ?? node.depth
        }

        for node in graph.nodes { _ = rank(node) }
        return ranks
    }

    /// What has to be drawn above a node. A verdict is placed under the answer it judged AND under the
    /// round it judged, because a round is judged after it ran rather than beside the round before it. A
    /// later round's `synthesizes` edge is a redraft of an answer that already exists, so it climbs back to
    /// it instead of hanging a second answer under the whole loop.
    private static func precedents(of node: GraphNode, in graph: ResearchGraph) -> [String] {
        if node.kind == .verdict {
            return graph.edges.filter { $0.from == node.id && $0.kind == .judges }.map(\.to)
                + graph.nodes.filter { $0.kind == .inquiry && $0.round == node.round }.map(\.id)
        }
        return graph.edges
            .filter { $0.to == node.id && $0.kind.descends && !redrafts($0, in: graph) }
            .map(\.from)
    }

    private static func redrafts(_ edge: GraphEdge, in graph: ResearchGraph) -> Bool {
        guard edge.kind == .synthesizes, let from = graph.node(edge.from), let to = graph.node(edge.to)
        else { return false }
        return from.round > to.round
    }

    /// Slot assignment is where a growing diagram is won or lost: a node that already has a slot keeps it,
    /// so an insertion elsewhere on the rank cannot shuffle what the reader is looking at. Only nodes with
    /// no history are ordered afresh, by the barycenter of their parents (Sugiyama's rule) with the
    /// graph's own insertion order as the tie-break, so the result never depends on a clock.
    private func slotted(_ nodes: [GraphNode], rank: Int, graph: ResearchGraph,
                         placed: [NodeFrame], previous: PlacedGraph?) -> [(GraphNode, Int)] {
        let order = Dictionary(uniqueKeysWithValues: graph.nodes.enumerated().map { ($0.element.id, $0.offset) })
        let centers = Dictionary(placed.map { ($0.id, $0.rect.midX) }, uniquingKeysWith: { first, _ in first })

        func barycenter(_ node: GraphNode) -> CGFloat? {
            let parents = graph.edges.filter { $0.to == node.id }.compactMap { centers[$0.from] }
            guard !parents.isEmpty else { return nil }
            return parents.reduce(0, +) / CGFloat(parents.count)
        }

        var kept: [(GraphNode, Int)] = []
        var fresh: [GraphNode] = []
        for node in nodes {
            if let held = previous?.frame(node.id), held.rank == rank { kept.append((node, held.slot)) }
            else { fresh.append(node) }
        }

        let byShape = fresh.sorted { left, right in
            let a = (barycenter(left) ?? .greatestFiniteMagnitude, order[left.id] ?? 0)
            let b = (barycenter(right) ?? .greatestFiniteMagnitude, order[right.id] ?? 0)
            return a < b
        }
        var next = (kept.map(\.1).max() ?? -1) + 1
        for node in byShape {
            kept.append((node, next))
            next += 1
        }
        return kept.sorted { $0.1 < $1.1 }
    }

    /// Sources that several inquiries reached are the point of a converging run, so they get a column of
    /// their own to the right rather than a rank of their own underneath, where the ties would cross
    /// every other edge on the way up.
    private func referenceColumn(_ graph: ResearchGraph, sizes: [String: CGSize], ranks: [String: Int],
                                 beside frames: [NodeFrame]) -> [NodeFrame] {
        let sources = graph.nodes(of: .source)
        guard !sources.isEmpty else { return [] }
        let x = (frames.map(\.rect.maxX).max() ?? 0) + Self.referenceGutter
        var y = Self.canvasPadding
        return sources.enumerated().map { slot, source in
            let size = sizes[source.id] ?? Self.defaultSize
            let frame = NodeFrame(id: source.id, rank: ranks[source.id] ?? source.depth, slot: slot,
                                  rect: CGRect(x: x, y: y, width: size.width, height: size.height))
            y += size.height + Self.horizontalGutter
            return frame
        }
    }

    private func canvas(around frames: [NodeFrame]) -> CGRect {
        guard let first = frames.first else { return .zero }
        let union = frames.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        return union.insetBy(dx: -Self.canvasPadding, dy: -Self.canvasPadding)
    }
}

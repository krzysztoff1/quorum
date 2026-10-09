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

public struct PlacedGraph: Sendable, Equatable {
    public let frames: [NodeFrame]
    public let bounds: CGRect

    private let framesByID: [String: NodeFrame]
    private let routes: [String: EdgeCurve]

    public init(frames: [NodeFrame], bounds: CGRect, edges: [GraphEdge] = [],
                sideMounted: Set<String> = []) {
        self.frames = frames
        self.bounds = bounds
        let byID = Dictionary(frames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.framesByID = byID
        self.routes = Self.wired(edges, frames: byID, sideMounted: sideMounted)
    }

    public func frame(_ id: String) -> NodeFrame? { framesByID[id] }

    public func route(_ edge: GraphEdge) -> EdgeCurve? { routes[edge.id] }

    private struct PortKey: Hashable {
        let node: String
        let face: PortFace
    }

    private struct Landing {
        let edgeID: String
        let isStart: Bool
        let face: PortFace
        let frame: NodeFrame
        let toward: CGPoint
    }

    /// Every wire gets its own port: the landings on each face are spread across its middle and ordered by
    /// where the other end sits, so a fan into one card arrives as a fan rather than a knot — and two wires
    /// into neighbouring ports never have to cross each other to reach them.
    private static func wired(_ edges: [GraphEdge], frames: [String: NodeFrame],
                              sideMounted: Set<String>) -> [String: EdgeCurve] {
        var landings: [Landing] = []
        for edge in edges {
            guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
            let (fromFace, toFace) = faces(from: from, to: to, sideMounted: sideMounted)
            landings.append(Landing(edgeID: edge.id, isStart: true, face: fromFace, frame: from,
                                    toward: CGPoint(x: to.rect.midX, y: to.rect.midY)))
            landings.append(Landing(edgeID: edge.id, isStart: false, face: toFace, frame: to,
                                    toward: CGPoint(x: from.rect.midX, y: from.rect.midY)))
        }

        var ports: [String: (point: CGPoint, face: PortFace)] = [:]
        for group in Dictionary(grouping: landings, by: { PortKey(node: $0.frame.id, face: $0.face) })
            .values {
            let ordered = group.sorted {
                (across($0), $0.edgeID, $0.isStart ? 0 : 1)
                    < (across($1), $1.edgeID, $1.isStart ? 0 : 1)
            }
            for (index, landing) in ordered.enumerated() {
                let fraction = ordered.count == 1
                    ? 0.5 : 0.2 + 0.6 * CGFloat(index) / CGFloat(ordered.count - 1)
                ports[key(landing)] = (anchor(on: landing.frame.rect, face: landing.face,
                                              fraction: fraction), landing.face)
            }
        }

        var routes: [String: EdgeCurve] = [:]
        for edge in edges {
            guard let start = ports["\(edge.id)·start"], let end = ports["\(edge.id)·end"]
            else { continue }
            routes[edge.id] = EdgeGeometry.curve(from: start.point, fromFace: start.face,
                                                 to: end.point, toFace: end.face)
        }
        return routes
    }

    private static func key(_ landing: Landing) -> String {
        "\(landing.edgeID)·\(landing.isStart ? "start" : "end")"
    }

    private static func across(_ landing: Landing) -> CGFloat {
        landing.face == .top || landing.face == .bottom ? landing.toward.x : landing.toward.y
    }

    /// Which side of each card a wire uses. The flow runs downward, so a descent leaves the bottom and a
    /// return leg leaves the top; a pulled-out source column sits beside the run, so anything touching it
    /// wires through the sides — and so does the odd edge between two cards on one rank.
    private static func faces(from: NodeFrame, to: NodeFrame,
                              sideMounted: Set<String>) -> (PortFace, PortFace) {
        if sideMounted.contains(from.id) || sideMounted.contains(to.id) || from.rank == to.rank {
            return to.rect.midX >= from.rect.midX ? (.trailing, .leading) : (.leading, .trailing)
        }
        return to.rank > from.rank ? (.bottom, .top) : (.top, .bottom)
    }

    private static func anchor(on rect: CGRect, face: PortFace, fraction: CGFloat) -> CGPoint {
        switch face {
        case .top:      return CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY)
        case .bottom:   return CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY)
        case .leading:  return CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction)
        case .trailing: return CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction)
        }
    }
}

/// How the graph gets drawn, chosen from the graph's own shape rather than fixed in the view. The run
/// that fanned out wide draws as rows; the one that dug deep draws as a tree; the one whose angles kept
/// landing on the same documents pulls those documents out where the convergence is visible.
public enum GraphLayout: String, Sendable, Equatable, CaseIterable {
    case layered, tree, converging

    static let horizontalGutter: CGFloat = 40
    static let verticalGutter: CGFloat = 60
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
        let rows = Set(laidOut.compactMap { ranks[$0.id] }).sorted()
        let axis = Self.canvasPadding + rows.map { rank in
            Self.width(of: laidOut.filter { ranks[$0.id] == rank }, sizes: sizes)
        }.max()! / 2

        for rank in rows {
            let inRank = laidOut.filter { ranks[$0.id] == rank }
            let ordered = slotted(inRank, rank: rank, graph: graph, placed: frames, previous: previous)
            var x = axis - Self.width(of: ordered.map(\.0), sizes: sizes) / 2
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

        var sideMounted: Set<String> = []
        if self == .converging {
            frames += referenceColumn(graph, sizes: sizes, ranks: ranks, beside: frames)
            sideMounted = Set(graph.nodes(of: .source).map(\.id))
        }
        return PlacedGraph(frames: frames, bounds: canvas(around: frames),
                           edges: graph.edges, sideMounted: sideMounted)
    }

    private static func width(of nodes: [GraphNode], sizes: [String: CGSize]) -> CGFloat {
        guard !nodes.isEmpty else { return 0 }
        return nodes.reduce(0) { $0 + (sizes[$1.id] ?? defaultSize).width }
            + CGFloat(nodes.count - 1) * horizontalGutter
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
    /// it instead of hanging a second answer under the whole loop. And a round beyond the first is placed
    /// under the verdicts that bought it however it is wired — a finished run hangs it off the answer's open
    /// points, which would otherwise draw the critics and the work they provoked side by side on one row.
    /// The fused answer is placed under every verdict for the same reason: it is what the loop ended on.
    private static func precedents(of node: GraphNode, in graph: ResearchGraph) -> [String] {
        if node.kind == .verdict {
            return graph.edges.filter { $0.from == node.id && $0.kind == .judges }.map(\.to)
                + graph.nodes.filter { $0.kind == .inquiry && $0.round == node.round }.map(\.id)
        }
        let inherited = graph.edges
            .filter { $0.to == node.id && $0.kind.descends && !redrafts($0, in: graph) }
            .map(\.from)
        if node.isReconciled {
            let judgingThis = Set(graph.edges.filter { $0.kind == .judges && $0.to == node.id }.map(\.from))
            return inherited + graph.nodes
                .filter { $0.kind == .verdict && !judgingThis.contains($0.id) }.map(\.id)
        }
        guard node.kind == .inquiry, node.round > 1 else { return inherited }
        return inherited + graph.nodes
            .filter { $0.kind == .verdict && $0.round == node.round - 1 }.map(\.id)
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

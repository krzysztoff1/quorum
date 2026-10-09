import XCTest
@testable import QuorumCore

/// Layout is a pure function of the graph plus measured node sizes, so a replayed run draws identically
/// and the whole thing is testable with no screen. The invariants that matter are the stability ones:
/// the reader's mental map is what a growing diagram destroys first.
final class GraphLayoutTests: XCTestCase {

    private func graph(_ build: (inout ResearchGraph) -> Void) -> ResearchGraph {
        var g = ResearchGraph()
        g.insert(GraphNode(id: "root", kind: .question, title: "root", state: .asked(.approved), depth: 0))
        build(&g)
        return g
    }

    private func inquiry(_ id: String, depth: Int = 1) -> GraphNode {
        GraphNode(id: id, kind: .inquiry, title: id, state: .worked(.complete), depth: depth)
    }

    private func fan(_ count: Int) -> ResearchGraph {
        graph { g in
            for i in 1...count {
                g.insert(inquiry("a\(i)"))
                g.connect(GraphEdge(from: "root", to: "a\(i)", kind: .decomposes))
            }
            g.insert(GraphNode(id: "s", kind: .synthesis, title: "s", state: .worked(.complete), depth: 2))
            for i in 1...count { g.connect(GraphEdge(from: "a\(i)", to: "s", kind: .synthesizes)) }
        }
    }

    private func uniformSizes(_ g: ResearchGraph, size: CGSize = CGSize(width: 200, height: 90))
        -> [String: CGSize] {
        Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, size) })
    }

    /// A run that argued with itself: two angles, an answer, four verdicts on it, the one objection that
    /// stood, and the round it bought — which redrafts the same answer rather than writing a second one.
    private func loop() -> ResearchGraph {
        var g = ResearchGraph()
        g.insert(GraphNode(id: "root", kind: .question, title: "root", state: .asked(.approved),
                           origin: .root, depth: 0))
        for id in ["a1", "a2"] {
            g.insert(GraphNode(id: id, kind: .inquiry, title: id, state: .worked(.complete),
                               origin: .planner, depth: 1, round: 1))
            g.connect(GraphEdge(from: "root", to: id, kind: .decomposes))
        }
        g.insert(GraphNode(id: "synthesis", kind: .synthesis, title: "answer",
                           state: .worked(.complete), depth: 2, round: 1))
        for id in ["a1", "a2"] { g.connect(GraphEdge(from: id, to: "synthesis", kind: .synthesizes)) }
        judge(&g, round: 1, objecting: "coverage")

        g.insert(GraphNode(id: "q1", kind: .question, title: "the objection", state: .asked(.approved),
                           origin: .objection, depth: 1, round: 1))
        g.connect(GraphEdge(from: "v1_coverage", to: "q1", kind: .spawned, label: "coverage"))
        g.insert(GraphNode(id: "x1", kind: .inquiry, title: "x1", state: .worked(.complete),
                           origin: .objection, depth: 1, round: 2))
        g.connect(GraphEdge(from: "q1", to: "x1", kind: .decomposes))
        g.connect(GraphEdge(from: "x1", to: "synthesis", kind: .synthesizes))
        judge(&g, round: 2, objecting: nil)
        return g
    }

    private func judge(_ g: inout ResearchGraph, round: Int, objecting lens: String?) {
        for task in lenses {
            let id = "v\(round)_\(task)"
            g.insert(GraphNode(id: id, kind: .verdict, title: task,
                               state: .judged(objections: task == lens ? 1 : 0),
                               depth: 3, round: round, lens: task))
            g.connect(GraphEdge(from: id, to: "synthesis", kind: .judges))
        }
    }

    // MARK: ranking

    func testEveryNodeLandsOnTheRankItsDepthNames() {
        let g = fan(3)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))

        XCTAssertEqual(placed.frame("root")?.rank, 0)
        XCTAssertEqual(placed.frame("a1")?.rank, 1)
        XCTAssertEqual(placed.frame("a2")?.rank, 1)
        XCTAssertEqual(placed.frame("s")?.rank, 2)
    }

    func testSiblingsOnARankDoNotOverlap() {
        let g = fan(4)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        let rank = placed.frames.filter { $0.rank == 1 }.sorted { $0.rect.minX < $1.rect.minX }

        for (left, right) in zip(rank, rank.dropFirst()) {
            XCTAssertLessThanOrEqual(left.rect.maxX, right.rect.minX, "\(left.id) overlaps \(right.id)")
        }
    }

    func testRanksAreOrderedTopToBottom() {
        let g = fan(2)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))

        XCTAssertLessThan(placed.frame("root")!.rect.maxY, placed.frame("a1")!.rect.minY)
        XCTAssertLessThan(placed.frame("a1")!.rect.maxY, placed.frame("s")!.rect.minY)
    }

    /// A question dumped at the left margin while its three angles run off to the right reads as four
    /// unrelated columns. Ranks share one axis, so a parent sits over the children it fanned into.
    func testARankIsCentredOverTheWidestOne() {
        let g = fan(3)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        let fanned = placed.frames.filter { $0.rank == 1 }
        let axis = (fanned.map(\.rect.minX).min()! + fanned.map(\.rect.maxX).max()!) / 2

        XCTAssertEqual(placed.frame("root")!.rect.midX, axis, accuracy: 0.5)
        XCTAssertEqual(placed.frame("s")!.rect.midX, axis, accuracy: 0.5)
    }

    // MARK: stability — the invariant a growing graph lives or dies on

    func testInsertingANodeLeavesEveryExistingNodeInItsSlot() {
        let before = fan(3)
        let placedBefore = GraphLayout.layered.place(before, sizes: uniformSizes(before))

        var after = before
        after.insert(inquiry("a4"))
        after.connect(GraphEdge(from: "root", to: "a4", kind: .decomposes))
        let placedAfter = GraphLayout.layered.place(after, sizes: uniformSizes(after),
                                                    previous: placedBefore)

        for id in ["a1", "a2", "a3"] {
            XCTAssertEqual(placedAfter.frame(id)?.slot, placedBefore.frame(id)?.slot,
                           "\(id) was moved to a different slot by an unrelated insertion")
        }
    }

    func testASpawnedChildDoesNotReorderItsParentsRank() {
        let before = fan(3)
        let placedBefore = GraphLayout.layered.place(before, sizes: uniformSizes(before))

        var after = before
        after.insert(GraphNode(id: "q1", kind: .question, title: "dig deeper",
                               state: .asked(.pending), depth: 2))
        after.connect(GraphEdge(from: "a2", to: "q1", kind: .spawned))
        let placedAfter = GraphLayout.layered.place(after, sizes: uniformSizes(after),
                                                    previous: placedBefore)

        let orderBefore = placedBefore.frames.filter { $0.rank == 1 }
            .sorted { $0.rect.minX < $1.rect.minX }.map(\.id)
        let orderAfter = placedAfter.frames.filter { $0.rank == 1 }
            .sorted { $0.rect.minX < $1.rect.minX }.map(\.id)
        XCTAssertEqual(orderBefore, orderAfter)
    }

    /// Semantic zoom depends on this: opening a node multiplies its height, and if that reshuffles the
    /// canvas the reader loses the thing they were reading.
    func testOpeningOneNodeReflowsWithoutReorderingAnything() {
        let g = fan(3)
        var sizes = uniformSizes(g)
        let placedClosed = GraphLayout.layered.place(g, sizes: sizes)

        sizes["a2"] = CGSize(width: 420, height: 640)
        let placedOpen = GraphLayout.layered.place(g, sizes: sizes, previous: placedClosed)

        let orderClosed = placedClosed.frames.filter { $0.rank == 1 }
            .sorted { $0.rect.minX < $1.rect.minX }.map(\.id)
        let orderOpen = placedOpen.frames.filter { $0.rank == 1 }
            .sorted { $0.rect.minX < $1.rect.minX }.map(\.id)
        XCTAssertEqual(orderClosed, orderOpen)
        XCTAssertEqual(placedOpen.frame("a2")?.rect.height, 640)
    }

    func testAGrownNodePushesTheRankBelowItDown() {
        let g = fan(3)
        var sizes = uniformSizes(g)
        let closed = GraphLayout.layered.place(g, sizes: sizes)

        sizes["a2"] = CGSize(width: 420, height: 640)
        let open = GraphLayout.layered.place(g, sizes: sizes, previous: closed)

        XCTAssertGreaterThan(open.frame("s")!.rect.minY, closed.frame("s")!.rect.minY)
        XCTAssertGreaterThanOrEqual(open.frame("s")!.rect.minY, open.frame("a2")!.rect.maxY)
    }

    // MARK: the diagram picks itself

    func testAWideShallowRunDrawsAsLayeredRows() {
        XCTAssertEqual(GraphLayout.best(for: fan(5)), .layered)
    }

    func testADeepBranchyRunDrawsAsATree() {
        let g = graph { g in
            var parent = "root"
            for depth in 1...4 {
                for branch in 1...2 {
                    let id = "d\(depth)b\(branch)"
                    g.insert(inquiry(id, depth: depth))
                    g.connect(GraphEdge(from: parent, to: id, kind: .spawned))
                }
                parent = "d\(depth)b1"
            }
        }
        XCTAssertEqual(GraphLayout.best(for: g), .tree)
    }

    func testARunConvergingOnSharedSourcesPullsReferencesOut() {
        let g = graph { g in
            for i in 1...3 {
                g.insert(inquiry("a\(i)"))
                g.connect(GraphEdge(from: "root", to: "a\(i)", kind: .decomposes))
            }
            for s in 1...2 {
                g.insert(GraphNode(id: "s\(s)", kind: .source, title: "src\(s)", state: .derived, depth: 2))
                for i in 1...3 {
                    g.connect(GraphEdge(from: "s\(s)", to: "a\(i)", kind: .corroborates))
                }
            }
        }
        XCTAssertEqual(GraphLayout.best(for: g), .converging)
    }

    func testConvergingLayoutPutsSourcesInTheirOwnColumn() {
        let g = graph { g in
            g.insert(inquiry("a1"))
            g.connect(GraphEdge(from: "root", to: "a1", kind: .decomposes))
            g.insert(GraphNode(id: "s1", kind: .source, title: "src", state: .derived, depth: 2))
            g.connect(GraphEdge(from: "s1", to: "a1", kind: .corroborates))
        }
        let placed = GraphLayout.converging.place(g, sizes: uniformSizes(g))

        XCTAssertGreaterThan(placed.frame("s1")!.rect.minX, placed.frame("a1")!.rect.maxX)
    }

    // MARK: the loop — PRD 08 R1

    func testTheVerdictRankSitsBetweenTheAnswerAndTheRoundItBought() {
        let g = loop()
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        func rank(_ id: String) -> Int { placed.frame(id)?.rank ?? -1 }

        XCTAssertGreaterThan(rank("synthesis"), rank("a1"))
        XCTAssertGreaterThan(rank("v1_coverage"), rank("synthesis"))
        XCTAssertEqual(Set(lenses.map { rank("v1_\($0)") }).count, 1, "one rank of verdicts, not four")
        XCTAssertGreaterThan(rank("q1"), rank("v1_coverage"))
        XCTAssertGreaterThan(rank("x1"), rank("q1"))
        XCTAssertGreaterThan(rank("v2_coverage"), rank("x1"),
                             "round two is judged after it ran, not beside round one's verdicts")
    }

    func testEachRoundReadsDownwardFromItsInquiriesToItsVerdicts() {
        let g = loop()
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))

        for (above, below) in [("a1", "synthesis"), ("synthesis", "v1_coverage"),
                               ("v1_coverage", "q1"), ("q1", "x1"), ("x1", "v2_coverage")] {
            XCTAssertLessThanOrEqual(placed.frame(above)!.rect.maxY, placed.frame(below)!.rect.minY,
                                     "\(below) is drawn above \(above)")
        }
    }

    /// The picture only earns "the loop's shape IS the graph" if the wire from a verdict into the round it
    /// bought can be followed by eye. Judgements point back at the answer they read, so they are read
    /// upward and left out — scoring them would mark the loop's own shape as a defect.
    func testTheLoopDrawsWithoutCrossingItsOwnWires() {
        let g = loop()
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))

        XCTAssertEqual(crossings(of: g, in: placed).map { "\($0.id) × \($1.id)" }, [])
    }

    func testAVerdictFlippingToObjectionsMovesNothingAboveIt() {
        let before = loop()
        var sizes = uniformSizes(before)
        let placedBefore = GraphLayout.layered.place(before, sizes: sizes)

        var after = before
        after.apply(.graphNodeUpdate(id: "v1_conflicts", status: "objections(2)", costUSD: nil))
        sizes["v1_conflicts"] = CGSize(width: 200, height: 220)
        let placedAfter = GraphLayout.layered.place(after, sizes: sizes, previous: placedBefore)

        XCTAssertEqual(after.node("v1_conflicts")?.state, .judged(objections: 2))
        for frame in placedBefore.frames {
            XCTAssertEqual(placedAfter.frame(frame.id)?.rank, frame.rank, "\(frame.id) changed rank")
            XCTAssertEqual(placedAfter.frame(frame.id)?.slot, frame.slot, "\(frame.id) changed slot")
        }
        for id in ["root", "a1", "a2", "synthesis", "v1_coverage", "v1_sources"] {
            XCTAssertEqual(placedAfter.frame(id)?.rect, placedBefore.frame(id)?.rect,
                           "\(id) was moved by a verdict flipping")
        }
    }

    /// The same loop as a rebuilt report draws it: the round the objections bought hangs off the answer's
    /// open points rather than off the verdict that filed them, because that is the edge a finished run
    /// keeps. The reading has to come out the same either way.
    private func redraft() -> ResearchGraph {
        var g = ResearchGraph()
        g.insert(GraphNode(id: "root", kind: .question, title: "root", state: .asked(.approved),
                           origin: .root, depth: 0))
        g.insert(GraphNode(id: "a1", kind: .inquiry, title: "a1", state: .worked(.complete), depth: 1,
                           round: 1))
        g.connect(GraphEdge(from: "root", to: "a1", kind: .decomposes))
        g.insert(GraphNode(id: "synthesis", kind: .synthesis, title: "answer",
                           state: .worked(.complete), depth: 2, round: 1))
        g.connect(GraphEdge(from: "a1", to: "synthesis", kind: .synthesizes))
        judge(&g, round: 1, objecting: "coverage")
        g.insert(GraphNode(id: "b1", kind: .inquiry, title: "b1", state: .worked(.complete), depth: 2,
                           round: 2))
        g.connect(GraphEdge(from: "synthesis", to: "b1", kind: .resolves, label: "open point"))
        return g
    }

    /// A round bought by a judgement is drawn under that judgement. Ranking it beside the verdicts puts
    /// the critics and the work they provoked on one row, and the loop stops reading as a loop.
    func testALaterRoundIsDrawnBelowTheVerdictsThatBoughtIt() {
        let g = redraft()
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))

        for lens in lenses {
            XCTAssertGreaterThan(placed.frame("b1")!.rank, placed.frame("v1_\(lens)")!.rank,
                                 "round two shares a rank with round one's \(lens) verdict")
        }
    }

    /// The answer a dive was fused into is what the whole loop was for, so it is drawn under the loop —
    /// not shoulder to shoulder with the last round's critics, where the reader has to work out which of
    /// six cards on one row the run actually ended on.
    func testTheAnswerTheLoopEndedOnIsDrawnBelowEverythingThatJudgedIt() {
        var g = loop()
        g.insert(GraphNode(id: "current", kind: .synthesis, title: "the current answer",
                           state: .worked(.complete), depth: 3, round: 2, isReconciled: true))
        g.connect(GraphEdge(from: "synthesis", to: "current", kind: .synthesizes))
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))

        for round in 1...2 {
            for lens in lenses {
                XCTAssertGreaterThan(placed.frame("current")!.rank, placed.frame("v\(round)_\(lens)")!.rank,
                                     "the answer shares a rank with round \(round)'s \(lens) verdict")
            }
        }
    }

    /// A judgement points back at the answer it read, so it leaves from the top of the verdict and lands on
    /// the bottom of the answer. Routed the other way it would set off downward from the verdict and climb
    /// back across every card in between — the long stray line that makes a validated run unreadable.
    func testAJudgementRoutesBackFromItsTopToTheAnswersBottom() {
        let g = loop()
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        let verdict = placed.frame("v1_sources")!, answer = placed.frame("synthesis")!
        let route = placed.route(GraphEdge(from: "v1_sources", to: "synthesis", kind: .judges))!

        XCTAssertEqual(route.start.y, verdict.rect.minY)
        XCTAssertTrue((verdict.rect.minX...verdict.rect.maxX).contains(route.start.x))
        XCTAssertEqual(route.end.y, answer.rect.maxY)
        XCTAssertTrue((answer.rect.minX...answer.rect.maxX).contains(route.end.x))
    }

    private let lenses = ["claim_sweep", "coverage", "conflicts", "sources"]

    /// Two forward edges cross when they share no end and their drawn runs properly intersect.
    private func crossings(of graph: ResearchGraph, in placed: PlacedGraph) -> [(GraphEdge, GraphEdge)] {
        let forward = graph.edges.filter { edge in
            guard let from = placed.frame(edge.from), let to = placed.frame(edge.to) else { return false }
            return from.rank < to.rank
        }
        var found: [(GraphEdge, GraphEdge)] = []
        for (offset, left) in forward.enumerated() {
            for right in forward.dropFirst(offset + 1) {
                guard Set([left.from, left.to]).isDisjoint(with: [right.from, right.to]),
                      let a = placed.route(left), let b = placed.route(right), meet(a, b) else { continue }
                found.append((left, right))
            }
        }
        return found
    }

    private func meet(_ a: EdgeCurve, _ b: EdgeCurve) -> Bool {
        let left = a.polyline(), right = b.polyline()
        for (p1, p2) in zip(left, left.dropFirst()) {
            for (p3, p4) in zip(right, right.dropFirst()) where cross(p1, p2, p3, p4) { return true }
        }
        return false
    }

    private func cross(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func side(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        return side(p3, p4, p1) * side(p3, p4, p2) < 0 && side(p1, p2, p3) * side(p1, p2, p4) < 0
    }

    // MARK: edges

    func testAnEdgeRoutesFromItsParentsBottomToItsChildsTop() {
        let g = fan(2)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        let route = placed.route(GraphEdge(from: "root", to: "a1", kind: .decomposes))

        XCTAssertEqual(route?.start.y, placed.frame("root")!.rect.maxY)
        XCTAssertEqual(route?.end.y, placed.frame("a1")!.rect.minY)
    }

    /// Every wire into a card gets its own port, spread across the face and ordered by where the wire
    /// comes from — five angles reporting into one answer through one point is a knot, not a diagram.
    func testWiresFanningIntoOneNodeLandOnTheirOwnPortsInOrder() {
        let g = fan(3)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        let landings = (1...3).map { i -> (source: CGFloat, port: CGFloat) in
            let route = placed.route(GraphEdge(from: "a\(i)", to: "s", kind: .synthesizes))!
            return (placed.frame("a\(i)")!.rect.midX, route.end.x)
        }

        XCTAssertEqual(Set(landings.map(\.port)).count, 3, "the ports overlap")
        XCTAssertEqual(landings.sorted { $0.source < $1.source }.map(\.port),
                       landings.map(\.port).sorted(), "the ports cross their own wires")
        for landing in landings {
            XCTAssertTrue((placed.frame("s")!.rect.minX...placed.frame("s")!.rect.maxX)
                .contains(landing.port))
        }
    }

    func testASoleWireAttachesAtTheMiddleOfItsFace() {
        let g = fan(2)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        let route = placed.route(GraphEdge(from: "a1", to: "s", kind: .synthesizes))!

        XCTAssertEqual(route.start.x, placed.frame("a1")!.rect.midX)
    }

    func testAnEdgeSkippingARankStillEndsOnBothNodes() {
        let g = spanning()
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        let route = placed.route(GraphEdge(from: "root", to: "s", kind: .spawned))!

        XCTAssertEqual(route.start.y, placed.frame("root")!.rect.maxY)
        XCTAssertEqual(route.end.y, placed.frame("s")!.rect.minY)
    }

    /// An answer that also hangs off the question directly: the wire has a rank of cards to get past.
    private func spanning() -> ResearchGraph {
        graph { g in
            g.insert(inquiry("a1"))
            g.connect(GraphEdge(from: "root", to: "a1", kind: .decomposes))
            g.insert(GraphNode(id: "s", kind: .synthesis, title: "s", state: .worked(.complete), depth: 2))
            g.connect(GraphEdge(from: "a1", to: "s", kind: .synthesizes))
            g.connect(GraphEdge(from: "root", to: "s", kind: .spawned))
        }
    }

    /// A label sits at the curve's own midpoint, which is always in the gutter between the two cards the
    /// wire connects — not on either of them.
    func testAWiresMidpointFallsBetweenTheCardsItConnects() {
        let g = fan(2)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        let route = placed.route(GraphEdge(from: "root", to: "a1", kind: .decomposes))!

        XCTAssertGreaterThan(route.midpoint.y, placed.frame("root")!.rect.maxY)
        XCTAssertLessThan(route.midpoint.y, placed.frame("a1")!.rect.minY)
    }

    /// A pulled-out source sits beside the run, not above or below it, so its tie leaves through the side
    /// facing the angles rather than through its top or bottom.
    func testASourceInItsOwnColumnWiresOutOfItsSide() {
        let g = graph { g in
            g.insert(inquiry("a1"))
            g.connect(GraphEdge(from: "root", to: "a1", kind: .decomposes))
            g.insert(GraphNode(id: "s1", kind: .source, title: "src", state: .derived, depth: 2))
            g.connect(GraphEdge(from: "s1", to: "a1", kind: .corroborates))
        }
        let placed = GraphLayout.converging.place(g, sizes: uniformSizes(g))
        let route = placed.route(GraphEdge(from: "s1", to: "a1", kind: .corroborates))!

        XCTAssertEqual(route.start.x, placed.frame("s1")!.rect.minX)
        XCTAssertEqual(route.end.x, placed.frame("a1")!.rect.maxX)
    }

    func testAnEdgeToAMissingNodeRoutesToNothingRatherThanCrashing() {
        let g = fan(2)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))

        XCTAssertNil(placed.route(GraphEdge(from: "root", to: "ghost", kind: .decomposes)))
    }

    func testTheCanvasBoundsCoverEveryNode() {
        let g = fan(4)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))

        for frame in placed.frames {
            XCTAssertTrue(placed.bounds.contains(frame.rect), "\(frame.id) falls outside the canvas")
        }
    }

    func testAnEmptyGraphLaysOutToAnEmptyCanvas() {
        let placed = GraphLayout.layered.place(ResearchGraph(), sizes: [:])

        XCTAssertEqual(placed.frames, [])
        XCTAssertEqual(placed.bounds, .zero)
    }
}

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

    // MARK: edges

    func testAnEdgeRoutesFromItsParentsBottomToItsChildsTop() {
        let g = fan(2)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        let route = placed.route(GraphEdge(from: "root", to: "a1", kind: .decomposes))

        XCTAssertEqual(route?.points.first?.y, placed.frame("root")!.rect.maxY)
        XCTAssertEqual(route?.points.last?.y, placed.frame("a1")!.rect.minY)
    }

    func testAnEdgeWithALabelCarriesAnAnchorToDrawItAt() {
        let g = fan(2)
        let placed = GraphLayout.layered.place(g, sizes: uniformSizes(g))
        let route = placed.route(GraphEdge(from: "root", to: "a1", kind: .spawned, label: "needs the filing"))

        XCTAssertNotNil(route?.labelAnchor)
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

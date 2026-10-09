import XCTest
@testable import QuorumCore

final class ResearchGraphTests: XCTestCase {

    private func node(_ id: String, _ kind: String, round: Int = 1, depth: Int = 1, status: String = "complete",
                      origin: String = "planner", parents: [String] = []) -> RunStreamParser.Event {
        .graphNode(RunStreamParser.GraphNodeEvent(
            id: id, kind: kind, title: "\(id) title", parentIDs: parents, depth: depth, round: round, status: status,
            origin: origin, why: nil, provokedBy: nil, rejectedReason: nil, estimatedCostUSD: nil, costUSD: nil,
            lens: nil, objections: []))
    }

    private func edge(_ from: String, _ to: String, _ kind: String) -> RunStreamParser.Event {
        .graphEdge(RunStreamParser.GraphEdgeEvent(from: from, to: to, kind: kind, label: nil))
    }

    private func document(_ sourceID: String) -> SourceDocument {
        SourceDocument(sourceID: sourceID, url: "https://example.com/\(sourceID)", title: sourceID, contentType: .html,
                       snapshotPath: "sources/\(sourceID).md", textLength: 100, byteSize: 100)
    }

    private func folded(_ events: [RunStreamParser.Event]) -> ResearchGraph {
        var graph = ResearchGraph()
        for event in events { graph.apply(event) }
        return graph
    }

    private func fan(_ angles: [String] = ["a1", "a2"], documents: [(String, String)] = []) -> ResearchGraph {
        folded([node("root", "question", depth: 0, status: "approved", origin: "root")]
               + angles.flatMap { [node($0, "inquiry"), edge("root", $0, "decomposes")] }
               + [node("synthesis", "synthesis", depth: 2, origin: "derived")]
               + angles.map { edge($0, "synthesis", "synthesizes") }
               + documents.map { .document(angleID: $0.0, document($0.1)) })
    }

    private func withFindings(_ graph: ResearchGraph, under id: String, count: Int) -> ResearchGraph {
        var graph = graph
        for index in 1...count {
            graph.insert(GraphNode(id: "\(id)·finding·\(index)", kind: .finding, title: "claim \(index)",
                                   state: .derived, depth: 2))
            graph.connect(GraphEdge(from: id, to: "\(id)·finding·\(index)", kind: .reports))
        }
        return graph
    }

    func testMetricsDescribeTheShapeTheLayoutWillDrawFrom() {
        let graph = fan(["a1", "a2", "a3"])
        XCTAssertEqual(graph.maxDepth, 2)
        XCTAssertEqual(graph.widestRank, 3)
    }

    func testTheSameDocumentReachedByTwoAnglesIsOneCorroboratedNode() {
        let graph = fan(documents: [("a1", "s3"), ("a2", "s3"), ("a1", "s4")])
        XCTAssertEqual(graph.nodes(of: .source).map(\.id).sorted(), ["s3", "s4"])
        XCTAssertEqual(Set(graph.edges(of: .corroborates).map(\.from)), ["s3"])
        XCTAssertEqual(graph.sourceConvergence, 0.5, accuracy: 0.0001)
    }

    func testConvergenceIsZeroWhenNothingWasCaptured() {
        XCTAssertEqual(fan().sourceConvergence, 0)
    }

    func testTheSkeletonHidesClaimsUntilTheyAreAskedFor() {
        let graph = withFindings(fan(), under: "a1", count: 10)
        XCTAssertEqual(graph.skeleton(expanding: []).nodes(of: .finding), [])
        XCTAssertEqual(graph.skeleton(expanding: ["a1"]).nodes(of: .finding).count, 10)
        XCTAssertLessThanOrEqual(graph.skeleton(expanding: []).widestRank, 3)
    }

    func testACardKnowsHowMuchDetailItIsHiding() {
        let graph = withFindings(fan(), under: "a1", count: 4)
        XCTAssertEqual(graph.detailCount(under: "a1"), 4)
        XCTAssertEqual(graph.detailCount(under: "root"), 0)
    }

    func testCollapsingANodeHidesWhatHangsBelowItButKeepsTheNode() {
        let visible = withFindings(fan(), under: "a1", count: 1).hiding(under: ["a1"])
        XCTAssertNotNil(visible.node("a1"))
        XCTAssertEqual(visible.nodes(of: .finding), [])
        XCTAssertNotNil(visible.node("a2"))
        XCTAssertEqual(visible.edges(of: .reports), [])
        XCTAssertEqual(visible.edges(of: .decomposes).map(\.to), ["a1", "a2"])
    }

    func testFocusLightsTheWholePathBackToTheRoot() {
        let graph = folded([
            node("root", "question", depth: 0, status: "approved", origin: "root"),
            node("a1", "inquiry"), edge("root", "a1", "decomposes"),
            node("synthesis", "synthesis", depth: 2, origin: "derived"), edge("a1", "synthesis", "synthesizes"),
            node("x1", "inquiry", round: 2, depth: 3, origin: "objection"), edge("synthesis", "x1", "spawned"),
        ])
        XCTAssertEqual(graph.ancestry(of: "x1"), ["x1", "synthesis", "a1", "root"])
        XCTAssertEqual(graph.ancestry(of: "ghost"), [])
    }

    func testAncestryTerminatesEvenIfTheGraphSomehowLoops() {
        var graph = ResearchGraph()
        graph.insert(GraphNode(id: "a", kind: .inquiry, title: "a", state: .derived))
        graph.insert(GraphNode(id: "b", kind: .inquiry, title: "b", state: .derived))
        graph.connect(GraphEdge(from: "a", to: "b", kind: .spawned))
        graph.connect(GraphEdge(from: "b", to: "a", kind: .spawned))
        XCTAssertEqual(graph.ancestry(of: "a").sorted(), ["a", "b"])
    }

    func testAValidatorTaskTheRunSkippedIsNotDrawnAsAPass() {
        let graph = folded([node("v3_coverage", "verdict", status: "skipped", origin: "derived"),
                            node("v1_coverage", "verdict", status: "objections(2)", origin: "derived")])
        XCTAssertEqual(graph.node("v3_coverage")?.state, .derived)
        XCTAssertEqual(graph.node("v1_coverage")?.state, .judged(objections: 2))
    }

    func testTheDiveOpensOnTheAnswerItCurrentlyHolds() {
        let graph = folded([node("synthesis", "synthesis", origin: "derived"),
                            node("reconciliation", "synthesis", origin: "derived")])
        XCTAssertEqual(graph.answer?.id, "reconciliation")
        XCTAssertEqual(fan().answer?.id, "synthesis")
    }

    func testARunWithNoAnswerYetOpensOnNothing() {
        var graph = ResearchGraph()
        graph.insert(GraphNode(id: "root", kind: .question, title: "q", state: .asked(.approved)))
        XCTAssertNil(graph.answer)
    }
}
